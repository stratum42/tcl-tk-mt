/*
 * c/tcl_bridge/tcl_bridge.h - Thread-safe Tcl/Tk interpreter bridge
 *
 * Pure C11. Provides:
 * - Tcl_Interp lifecycle & optional Tk_Init
 * - Interned Tcl_Obj* cache for hot commands/options
 * - Owning UI-thread guard (pthread/OS tid + Tcl_ThreadId)
 * - Lock-free MPSC marshal queue (C11 stdatomic) woken via
 *   Tcl_ThreadQueueEvent + Tcl_ThreadAlert
 */
#ifndef TKMT_TCL_BRIDGE_H
#define TKMT_TCL_BRIDGE_H

#include "tcl_compat.h"
#include <stddef.h>
#include <stdint.h>

typedef struct tkmt_interp tkmt_interp_t;

/* Callback executed on the owning UI thread via marshal queue */
typedef void (*tkmt_marshal_fn)(tkmt_interp_t *bi, void *arg);

/* Current OS thread ID (portable across macOS/Linux/Win32) */
uint64_t tkmt_current_thread_id(void);

/* Create/destroy a Tcl/Tk bridge interpreter on the calling (UI) thread */
tkmt_interp_t *tkmt_interp_create(int init_tk, char *errbuf, size_t errbuf_len);
void           tkmt_interp_destroy(tkmt_interp_t *bi);

/* Access underlying Tcl_Interp* and Tk status */
Tcl_Interp    *tkmt_interp_raw(tkmt_interp_t *bi);
int            tkmt_interp_has_tk(const tkmt_interp_t *bi);
int            tkmt_interp_init_tk(tkmt_interp_t *bi, char *errbuf, size_t errbuf_len);

/* Owning UI-thread guard */
int            tkmt_interp_is_owner_thread(const tkmt_interp_t *bi);
uint64_t       tkmt_interp_owner_tid(const tkmt_interp_t *bi);

/* Interned Tcl_Obj* cache (UI thread only; returned Tcl_Obj* is owned by cache) */
Tcl_Obj       *tkmt_interp_intern(tkmt_interp_t *bi, const char *str, size_t len);
size_t         tkmt_interp_intern_count(const tkmt_interp_t *bi);

/* Fast-path evaluation (UI thread only) */
int            tkmt_interp_eval(tkmt_interp_t *bi, const char *script, size_t len);
int            tkmt_interp_eval_objv(tkmt_interp_t *bi, Tcl_Size objc, Tcl_Obj *const *objv);

/* Event loop pumping (UI thread only) */
int            tkmt_interp_do_one_event(tkmt_interp_t *bi, int flags);
int            tkmt_interp_num_main_windows(const tkmt_interp_t *bi);

/*
 * Lock-free MPSC marshal queue (safe to call from ANY worker thread).
 * - marshal_async: enqueues fn(bi, arg) and wakes UI thread via
 *   Tcl_ThreadQueueEvent + Tcl_ThreadAlert.
 * - marshal_sync: if already on UI thread, executes immediately; otherwise
 *   enqueues and blocks until the UI thread completes fn(bi, arg).
 * - drain_marshal_queue: UI thread drains all pending tasks (also called
 *   automatically by the Tcl event handler when woken).
 */
int            tkmt_interp_marshal_async(tkmt_interp_t *bi, tkmt_marshal_fn fn, void *arg);
int            tkmt_interp_marshal_sync(tkmt_interp_t *bi, tkmt_marshal_fn fn, void *arg);
int            tkmt_interp_drain_marshal_queue(tkmt_interp_t *bi);
uint64_t       tkmt_interp_marshal_count(const tkmt_interp_t *bi);

#endif /* TKMT_TCL_BRIDGE_H */
