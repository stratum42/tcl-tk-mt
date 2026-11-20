/*
 * c/tcl_bridge/tcl_bridge.c - Thread-safe Tcl/Tk interpreter bridge
 *
 * Pure C11 implementation.
 */
#include "../tkmt_thread.h"
#include "tcl_bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- One-time Tcl_FindExecutable initialization ---- */
static atomic_int g_tcl_exec_inited = 0;

static void
tkmt_ensure_tcl_init(void)
{
    int expected = 0;
    if (atomic_compare_exchange_strong_explicit(
            &g_tcl_exec_inited, &expected, 1,
            memory_order_acq_rel, memory_order_acquire)) {
        Tcl_FindExecutable(NULL);
    }
}

/* ---- Portable thread ID ---- */
uint64_t
tkmt_current_thread_id(void)
{
    return tkmt_thread_id();
}

/* ---- Interned Tcl_Obj* hash table ---- */
typedef struct tkmt_intern_slot {
    char     *key;
    size_t    len;
    uint64_t  hash;
    Tcl_Obj  *obj;
} tkmt_intern_slot_t;

typedef struct tkmt_intern_table {
    tkmt_intern_slot_t *slots;
    size_t              cap;
    size_t              count;
} tkmt_intern_table_t;

static uint64_t
tkmt_fnv1a(const char *s, size_t len)
{
    uint64_t h = 14695981039346656037ULL;
    for (size_t i = 0; i < len; i++) {
        h ^= (uint64_t)(unsigned char)s[i];
        h *= 1099511628211ULL;
    }
    return h ? h : 1;
}

static int
tkmt_intern_init(tkmt_intern_table_t *t, size_t cap)
{
    t->slots = (tkmt_intern_slot_t *)calloc(cap, sizeof(tkmt_intern_slot_t));
    if (!t->slots) return 0;
    t->cap = cap;
    t->count = 0;
    return 1;
}

static void
tkmt_intern_destroy(tkmt_intern_table_t *t)
{
    if (!t->slots) return;
    for (size_t i = 0; i < t->cap; i++) {
        if (t->slots[i].obj) {
            Tcl_DecrRefCount(t->slots[i].obj);
        }
        free(t->slots[i].key);
    }
    free(t->slots);
    t->slots = NULL;
    t->cap = 0;
    t->count = 0;
}

static int
tkmt_intern_grow(tkmt_intern_table_t *t)
{
    size_t new_cap = t->cap * 2;
    tkmt_intern_slot_t *ns = (tkmt_intern_slot_t *)calloc(new_cap, sizeof(tkmt_intern_slot_t));
    if (!ns) return 0;

    size_t mask = new_cap - 1;
    for (size_t i = 0; i < t->cap; i++) {
        if (!t->slots[i].obj) continue;
        size_t idx = (size_t)(t->slots[i].hash & mask);
        while (ns[idx].obj) idx = (idx + 1) & mask;
        ns[idx] = t->slots[i];
    }
    free(t->slots);
    t->slots = ns;
    t->cap = new_cap;
    return 1;
}

/* ---- Lock-free MPSC marshal queue (Vyukov intrusive MPSC) ---- */
typedef struct tkmt_mpsc_node {
    _Atomic(struct tkmt_mpsc_node *) next;
    tkmt_marshal_fn                  fn;
    void                            *arg;
} tkmt_mpsc_node_t;

typedef struct tkmt_mpsc_queue {
    _Atomic(tkmt_mpsc_node_t *) head;
    tkmt_mpsc_node_t           *tail;
    tkmt_mpsc_node_t            stub;
} tkmt_mpsc_queue_t;

static void
tkmt_mpsc_init(tkmt_mpsc_queue_t *q)
{
    atomic_init(&q->stub.next, NULL);
    q->stub.fn = NULL;
    q->stub.arg = NULL;
    atomic_init(&q->head, &q->stub);
    q->tail = &q->stub;
}

static void
tkmt_mpsc_push(tkmt_mpsc_queue_t *q, tkmt_mpsc_node_t *node)
{
    atomic_store_explicit(&node->next, NULL, memory_order_relaxed);
    tkmt_mpsc_node_t *prev = atomic_exchange_explicit(&q->head, node, memory_order_acq_rel);
    atomic_store_explicit(&prev->next, node, memory_order_release);
}

#define TKMT_MPSC_RETRY ((tkmt_mpsc_node_t *)(uintptr_t)1)

static tkmt_mpsc_node_t *
tkmt_mpsc_pop(tkmt_mpsc_queue_t *q)
{
    tkmt_mpsc_node_t *tail = q->tail;
    tkmt_mpsc_node_t *next = atomic_load_explicit(&tail->next, memory_order_acquire);
    if (tail == &q->stub) {
        if (!next) return NULL;
        q->tail = next;
        tail = next;
        next = atomic_load_explicit(&next->next, memory_order_acquire);
    }
    if (next) {
        q->tail = next;
        return tail;
    }
    tkmt_mpsc_node_t *head = atomic_load_explicit(&q->head, memory_order_acquire);
    if (tail != head) {
        return TKMT_MPSC_RETRY;
    }
    tkmt_mpsc_push(q, &q->stub);
    next = atomic_load_explicit(&tail->next, memory_order_acquire);
    if (next) {
        q->tail = next;
        return tail;
    }
    return NULL;
}

/* ---- Bridge interpreter struct ---- */
struct tkmt_interp {
    Tcl_Interp         *interp;
    int                 tk_initialized;
    uint64_t            owner_tid;
    Tcl_ThreadId        owner_tcl_tid;
    tkmt_intern_table_t intern;
    tkmt_mpsc_queue_t   mpsc;
    atomic_int          wakeup_pending;
    atomic_int          closing;
    atomic_uint_fast64_t marshal_count;
};

typedef struct tkmt_wakeup_event {
    Tcl_Event      header;
    tkmt_interp_t *bi;
} tkmt_wakeup_event_t;

static int
tkmt_wakeup_event_proc(Tcl_Event *ev_ptr, int flags)
{
    (void)flags;
    tkmt_wakeup_event_t *wev = (tkmt_wakeup_event_t *)ev_ptr;
    tkmt_interp_t *bi = wev->bi;
    if (bi && !atomic_load_explicit(&bi->closing, memory_order_acquire)) {
        atomic_store_explicit(&bi->wakeup_pending, 0, memory_order_release);
        tkmt_interp_drain_marshal_queue(bi);
    }
    return 1; /* event handled and freed by Tcl */
}

static void
tkmt_set_err(char *errbuf, size_t errbuf_len, const char *msg)
{
    if (!errbuf || errbuf_len == 0) return;
    if (!msg) msg = "unknown Tcl/Tk error";
    snprintf(errbuf, errbuf_len, "%s", msg);
}

/* ---- Public API ---- */
tkmt_interp_t *
tkmt_interp_create(int init_tk, char *errbuf, size_t errbuf_len)
{
    tkmt_ensure_tcl_init();

    tkmt_interp_t *bi = (tkmt_interp_t *)calloc(1, sizeof(tkmt_interp_t));
    if (!bi) {
        tkmt_set_err(errbuf, errbuf_len, "out of memory allocating tkmt_interp_t");
        return NULL;
    }

    bi->interp = Tcl_CreateInterp();
    if (!bi->interp) {
        free(bi);
        tkmt_set_err(errbuf, errbuf_len, "Tcl_CreateInterp failed");
        return NULL;
    }

    if (Tcl_Init(bi->interp) != TCL_OK) {
        tkmt_set_err(errbuf, errbuf_len, Tcl_GetStringResult(bi->interp));
        Tcl_DeleteInterp(bi->interp);
        free(bi);
        return NULL;
    }

    bi->owner_tid = tkmt_current_thread_id();
    bi->owner_tcl_tid = Tcl_GetCurrentThread();
    atomic_init(&bi->wakeup_pending, 0);
    atomic_init(&bi->closing, 0);
    atomic_init(&bi->marshal_count, 0);
    tkmt_mpsc_init(&bi->mpsc);

    if (!tkmt_intern_init(&bi->intern, 256)) {
        Tcl_DeleteInterp(bi->interp);
        free(bi);
        tkmt_set_err(errbuf, errbuf_len, "out of memory allocating intern table");
        return NULL;
    }

    if (init_tk) {
        if (!tkmt_interp_init_tk(bi, errbuf, errbuf_len)) {
            tkmt_interp_destroy(bi);
            return NULL;
        }
    }

    return bi;
}

int
tkmt_interp_init_tk(tkmt_interp_t *bi, char *errbuf, size_t errbuf_len)
{
    if (!bi || !bi->interp) {
        tkmt_set_err(errbuf, errbuf_len, "NULL interpreter");
        return 0;
    }
    if (bi->tk_initialized) return 1;
    if (!tkmt_interp_is_owner_thread(bi)) {
        tkmt_set_err(errbuf, errbuf_len, "Tk_Init must be called on owning UI thread");
        return 0;
    }
    if (Tk_Init(bi->interp) != TCL_OK) {
        tkmt_set_err(errbuf, errbuf_len, Tcl_GetStringResult(bi->interp));
        return 0;
    }
    bi->tk_initialized = 1;
    return 1;
}

void
tkmt_interp_destroy(tkmt_interp_t *bi)
{
    if (!bi) return;
    atomic_store_explicit(&bi->closing, 1, memory_order_release);

    /* Drain any leftover nodes without running callbacks on dead interp */
    for (;;) {
        tkmt_mpsc_node_t *node = tkmt_mpsc_pop(&bi->mpsc);
        if (!node) break;
        if (node == TKMT_MPSC_RETRY) continue;
        free(node);
    }

    tkmt_intern_destroy(&bi->intern);
    if (bi->interp) {
        Tcl_DeleteInterp(bi->interp);
        bi->interp = NULL;
    }
    free(bi);
}

Tcl_Interp *
tkmt_interp_raw(tkmt_interp_t *bi)
{
    return bi ? bi->interp : NULL;
}

int
tkmt_interp_has_tk(const tkmt_interp_t *bi)
{
    return bi ? bi->tk_initialized : 0;
}

int
tkmt_interp_is_owner_thread(const tkmt_interp_t *bi)
{
    if (!bi) return 0;
    return tkmt_current_thread_id() == bi->owner_tid;
}

uint64_t
tkmt_interp_owner_tid(const tkmt_interp_t *bi)
{
    return bi ? bi->owner_tid : 0;
}

Tcl_Obj *
tkmt_interp_intern(tkmt_interp_t *bi, const char *str, size_t len)
{
    if (!bi || !str) return NULL;
    if ((bi->intern.count + 1) * 10 >= bi->intern.cap * 7) {
        if (!tkmt_intern_grow(&bi->intern)) return NULL;
    }

    uint64_t h = tkmt_fnv1a(str, len);
    size_t mask = bi->intern.cap - 1;
    size_t idx = (size_t)(h & mask);

    while (bi->intern.slots[idx].obj) {
        if (bi->intern.slots[idx].hash == h &&
            bi->intern.slots[idx].len == len &&
            memcmp(bi->intern.slots[idx].key, str, len) == 0) {
            return bi->intern.slots[idx].obj;
        }
        idx = (idx + 1) & mask;
    }

    char *copy = (char *)malloc(len + 1);
    if (!copy) return NULL;
    memcpy(copy, str, len);
    copy[len] = '\0';

    Tcl_Obj *obj = Tcl_NewStringObj(copy, (Tcl_Size)len);
    Tcl_IncrRefCount(obj);

    bi->intern.slots[idx].key = copy;
    bi->intern.slots[idx].len = len;
    bi->intern.slots[idx].hash = h;
    bi->intern.slots[idx].obj = obj;
    bi->intern.count++;
    return obj;
}

size_t
tkmt_interp_intern_count(const tkmt_interp_t *bi)
{
    return bi ? bi->intern.count : 0;
}

int
tkmt_interp_eval(tkmt_interp_t *bi, const char *script, size_t len)
{
    if (!bi || !bi->interp || !script) return TCL_ERROR;
    return Tcl_EvalEx(bi->interp, script, (Tcl_Size)len, 0);
}

int
tkmt_interp_eval_objv(tkmt_interp_t *bi, Tcl_Size objc, Tcl_Obj *const *objv)
{
    if (!bi || !bi->interp) return TCL_ERROR;
    return tkmt_tcl_eval_objv(bi->interp, objc, objv, 0);
}

int
tkmt_interp_do_one_event(tkmt_interp_t *bi, int flags)
{
    if (!bi || !bi->interp) return 0;
    tkmt_interp_drain_marshal_queue(bi);
    int res = Tcl_DoOneEvent(flags);
    tkmt_interp_drain_marshal_queue(bi);
    return res;
}

int
tkmt_interp_num_main_windows(const tkmt_interp_t *bi)
{
    if (!bi || !bi->tk_initialized) return 0;
    return Tk_GetNumMainWindows();
}

int
tkmt_interp_marshal_async(tkmt_interp_t *bi, tkmt_marshal_fn fn, void *arg)
{
    if (!bi || !fn) return 0;
    if (atomic_load_explicit(&bi->closing, memory_order_acquire)) return 0;

    tkmt_mpsc_node_t *node = (tkmt_mpsc_node_t *)malloc(sizeof(tkmt_mpsc_node_t));
    if (!node) return 0;
    node->fn = fn;
    node->arg = arg;

    tkmt_mpsc_push(&bi->mpsc, node);

    int expected = 0;
    if (atomic_compare_exchange_strong_explicit(
            &bi->wakeup_pending, &expected, 1,
            memory_order_acq_rel, memory_order_acquire)) {
        tkmt_wakeup_event_t *wev = (tkmt_wakeup_event_t *)ckalloc(sizeof(tkmt_wakeup_event_t));
        wev->header.proc = tkmt_wakeup_event_proc;
        wev->header.nextPtr = NULL;
        wev->bi = bi;
        Tcl_ThreadQueueEvent(bi->owner_tcl_tid, &wev->header, TCL_QUEUE_TAIL);
        Tcl_ThreadAlert(bi->owner_tcl_tid);
    }
    return 1;
}

typedef struct tkmt_sync_req {
    tkmt_marshal_fn fn;
    void           *arg;
    tkmt_mutex_t    mu;
    tkmt_cond_t     cv;
    int             done;
} tkmt_sync_req_t;

static void
tkmt_sync_trampoline(tkmt_interp_t *bi, void *raw)
{
    tkmt_sync_req_t *req = (tkmt_sync_req_t *)raw;
    req->fn(bi, req->arg);
    tkmt_mutex_lock(&req->mu);
    req->done = 1;
    tkmt_cond_signal(&req->cv);
    tkmt_mutex_unlock(&req->mu);
}

int
tkmt_interp_marshal_sync(tkmt_interp_t *bi, tkmt_marshal_fn fn, void *arg)
{
    if (!bi || !fn) return 0;
    if (tkmt_interp_is_owner_thread(bi)) {
        fn(bi, arg);
        atomic_fetch_add_explicit(&bi->marshal_count, 1, memory_order_relaxed);
        return 1;
    }

    tkmt_sync_req_t req;
    req.fn = fn;
    req.arg = arg;
    req.done = 0;

    tkmt_mutex_init(&req.mu);
    tkmt_cond_init(&req.cv);

    if (!tkmt_interp_marshal_async(bi, tkmt_sync_trampoline, &req)) {
        tkmt_cond_destroy(&req.cv);
        tkmt_mutex_destroy(&req.mu);
        return 0;
    }

    tkmt_mutex_lock(&req.mu);
    while (!req.done) {
        tkmt_cond_wait(&req.cv, &req.mu);
    }
    tkmt_mutex_unlock(&req.mu);

    tkmt_cond_destroy(&req.cv);
    tkmt_mutex_destroy(&req.mu);
    return 1;
}

int
tkmt_interp_drain_marshal_queue(tkmt_interp_t *bi)
{
    if (!bi || !tkmt_interp_is_owner_thread(bi)) return 0;
    int drained = 0;
    int retries = 0;

    for (;;) {
        tkmt_mpsc_node_t *node = tkmt_mpsc_pop(&bi->mpsc);
        if (!node) break;
        if (node == TKMT_MPSC_RETRY) {
            if (++retries > 1000) break;
            tkmt_thread_yield();
            continue;
        }
        retries = 0;
        tkmt_marshal_fn fn = node->fn;
        void *arg = node->arg;
        free(node);
        if (fn) {
            fn(bi, arg);
            atomic_fetch_add_explicit(&bi->marshal_count, 1, memory_order_relaxed);
            drained++;
        }
    }
    return drained;
}

uint64_t
tkmt_interp_marshal_count(const tkmt_interp_t *bi)
{
    if (!bi) return 0;
    return (uint64_t)atomic_load_explicit(&bi->marshal_count, memory_order_relaxed);
}
