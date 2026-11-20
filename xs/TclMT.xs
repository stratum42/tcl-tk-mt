/*
 * xs/TclMT.xs - perl5-mt Tier-1 XS bridge to Tcl/Tk (8.6 & 9.x)
 *
 * Pure C11. Emits mt_threadsafe_boot_Tcl__MT on perl5-mt and builds cleanly
 * on stock Perl 5 as well.
 */
#include "mt_compat.h"
#include "../c/tcl_bridge/tcl_bridge.h"
#include "../c/tcl_bridge/tk_surface.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- Global callback ID generator (atomic, thread-safe) ---- */
static atomic_uint_fast64_t g_cb_seq = 1;

/* ---- Perl callback trampoline for Tcl commands ---- */
typedef struct tkmt_perl_cb {
#ifdef MULTIPLICITY
    PerlInterpreter *my_perl;
#endif
    tkmt_interp_t   *bi;
    SV              *cb_sv;
} tkmt_perl_cb_t;

static SV *
tkmt_tcl_obj_to_sv(pTHX_ Tcl_Obj *obj)
{
    if (!obj) return newSV(0);
    Tcl_Size len = 0;
    const char *s = tkmt_tcl_get_string(obj, &len);
    if (!s || len <= 0) {
        return newSVpvn("", 0);
    }

    int has_utf8 = 0;
    int has_mutf8_nul = 0;
    for (Tcl_Size i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == 0xC0 && (i + 1) < len && (unsigned char)s[i + 1] == 0x80) {
            has_mutf8_nul = 1;
            i++;
        } else if (c >= 0x80) {
            has_utf8 = 1;
        }
    }

    if (!has_mutf8_nul) {
        SV *sv = newSVpvn(s, (STRLEN)len);
        if (has_utf8) SvUTF8_on(sv);
        return sv;
    }

    /* Decode Tcl Modified UTF-8 NUL (\xC0\x80) -> \x00 */
    SV *sv = newSV((STRLEN)len);
    SvPOK_only(sv);
    char *dst = SvPVX(sv);
    STRLEN dlen = 0;
    for (Tcl_Size i = 0; i < len; i++) {
        if ((unsigned char)s[i] == 0xC0 && (i + 1) < len && (unsigned char)s[i + 1] == 0x80) {
            dst[dlen++] = '\0';
            i++;
        } else {
            dst[dlen++] = s[i];
        }
    }
    dst[dlen] = '\0';
    SvCUR_set(sv, dlen);
    if (has_utf8) SvUTF8_on(sv);
    return sv;
}

static int tkmt_register_perl_cmd(pTHX_ tkmt_interp_t *bi, const char *name, SV *cb_sv);

static Tcl_Obj *
tkmt_sv_to_tcl_obj(pTHX_ tkmt_interp_t *bi, SV *sv, int try_intern, int *out_interned)
{
    *out_interned = 0;
    if (!sv || !SvOK(sv)) {
        return Tcl_NewObj();
    }

    if (SvROK(sv)) {
        SV *target = SvRV(sv);
        svtype t = SvTYPE(target);
        if (t == SVt_PVAV) {
            AV *av = (AV *)target;
            SSize_t top = av_top_index(av);
            Tcl_Size n = (top < 0) ? 0 : (Tcl_Size)(top + 1);
            Tcl_Obj *list = Tcl_NewListObj(0, NULL);
#if TKMT_HAVE_PACKED_AV
            U8 ptype = AvPACKED_TYPE(av);
            if (ptype == AV_PACKED_NV) {
                const NV *data = (const NV *)AvPACKED_DATA(av);
                for (Tcl_Size i = 0; i < n; i++) {
                    Tcl_ListObjAppendElement(NULL, list, Tcl_NewDoubleObj((double)data[i]));
                }
                return list;
            } else if (ptype == AV_PACKED_IV) {
                const IV *data = (const IV *)AvPACKED_DATA(av);
                for (Tcl_Size i = 0; i < n; i++) {
                    Tcl_ListObjAppendElement(NULL, list, Tcl_NewWideIntObj((Tcl_WideInt)data[i]));
                }
                return list;
            } else if (ptype == AV_PACKED_U8) {
                const U8 *data = (const U8 *)AvPACKED_DATA(av);
                for (Tcl_Size i = 0; i < n; i++) {
                    Tcl_ListObjAppendElement(NULL, list, Tcl_NewIntObj((int)data[i]));
                }
                return list;
            }
#endif
            for (Tcl_Size i = 0; i < n; i++) {
                SV **elem = av_fetch(av, (SSize_t)i, 0);
                int sub_intern = 0;
                Tcl_Obj *sub = tkmt_sv_to_tcl_obj(aTHX_ bi, (elem && *elem) ? *elem : &PL_sv_undef, 0, &sub_intern);
                Tcl_ListObjAppendElement(NULL, list, sub);
            }
            return list;
        } else if (t == SVt_PVCV) {
            uint64_t id = (uint64_t)atomic_fetch_add_explicit(&g_cb_seq, 1, memory_order_relaxed);
            char name[64];
            int nlen = snprintf(name, sizeof(name), "::perl_mt_cb_%llu", (unsigned long long)id);
            tkmt_register_perl_cmd(aTHX_ bi, name, sv);
            return Tcl_NewStringObj(name, (Tcl_Size)nlen);
        }
    }

    if (SvIOK(sv) && !SvPOK(sv)) {
        return Tcl_NewWideIntObj((Tcl_WideInt)SvIV(sv));
    }
    if (SvNOK(sv) && !SvPOK(sv)) {
        return Tcl_NewDoubleObj((double)SvNV(sv));
    }

    STRLEN len = 0;
    const char *s = SvPVutf8(sv, len);
    if (len > 0 && memchr(s, '\0', len) != NULL) {
        /* Encode embedded NUL as Tcl Modified UTF-8 (\xC0\x80) */
        STRLEN nul_count = 0;
        for (STRLEN i = 0; i < len; i++) {
            if (s[i] == '\0') nul_count++;
        }
        STRLEN out_len = len + nul_count;
        char *buf = (char *)malloc(out_len + 1);
        if (!buf) croak("Tcl::MT: out of memory encoding Modified UTF-8");
        STRLEN d = 0;
        for (STRLEN i = 0; i < len; i++) {
            if (s[i] == '\0') {
                buf[d++] = (char)0xC0;
                buf[d++] = (char)0x80;
            } else {
                buf[d++] = s[i];
            }
        }
        buf[d] = '\0';
        Tcl_Obj *obj = Tcl_NewStringObj(buf, (Tcl_Size)out_len);
        free(buf);
        return obj;
    }
    if (try_intern && len > 0 && len <= 64) {
        Tcl_Obj *interned = tkmt_interp_intern(bi, s, (size_t)len);
        if (interned) {
            *out_interned = 1;
            return interned;
        }
    }
    return Tcl_NewStringObj(s, (Tcl_Size)len);
}

static int
tkmt_perl_cmd_trampoline(void *client_data, Tcl_Interp *interp,
                         Tcl_Size objc, Tcl_Obj *const *objv)
{
    tkmt_perl_cb_t *cb = (tkmt_perl_cb_t *)client_data;
    if (!cb || !cb->cb_sv) return TCL_OK;

#ifdef MULTIPLICITY
    pTHX = cb->my_perl;
#endif
    dSP;
    ENTER;
    SAVETMPS;

    PUSHMARK(SP);
    if (objc > 1) {
        EXTEND(SP, (SSize_t)(objc - 1));
        for (Tcl_Size i = 1; i < objc; i++) {
            mPUSHs(tkmt_tcl_obj_to_sv(aTHX_ objv[i]));
        }
    }
    PUTBACK;

    I32 count = call_sv(cb->cb_sv, G_SCALAR | G_EVAL);

    SPAGAIN;
    int rc = TCL_OK;
    if (SvTRUE(ERRSV)) {
        STRLEN elen = 0;
        const char *emsg = SvPV(ERRSV, elen);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(emsg, (Tcl_Size)elen));
        if (count > 0) (void)POPs;
        rc = TCL_ERROR;
    } else if (count > 0) {
        SV *ret = POPs;
        if (SvOK(ret)) {
            int interned = 0;
            Tcl_Obj *res = tkmt_sv_to_tcl_obj(aTHX_ cb->bi, ret, 0, &interned);
            Tcl_SetObjResult(interp, res);
        } else {
            Tcl_ResetResult(interp);
        }
    }

    PUTBACK;
    FREETMPS;
    LEAVE;
    return rc;
}

static void
tkmt_perl_cmd_delete(void *client_data)
{
    tkmt_perl_cb_t *cb = (tkmt_perl_cb_t *)client_data;
    if (!cb) return;
#ifdef MULTIPLICITY
    pTHX = cb->my_perl;
#endif
    if (cb->cb_sv) {
        SvREFCNT_dec(cb->cb_sv);
        cb->cb_sv = NULL;
    }
    free(cb);
}

static int
tkmt_register_perl_cmd(pTHX_ tkmt_interp_t *bi, const char *name, SV *cb_sv)
{
    if (!bi || !name || !cb_sv) return 0;
    tkmt_perl_cb_t *cb = (tkmt_perl_cb_t *)calloc(1, sizeof(tkmt_perl_cb_t));
    if (!cb) return 0;
#ifdef MULTIPLICITY
    cb->my_perl = aTHX;
#endif
    cb->bi = bi;
    cb->cb_sv = newSVsv(cb_sv);

    tkmt_tcl_create_obj_command(
        tkmt_interp_raw(bi),
        name,
        tkmt_perl_cmd_trampoline,
        cb,
        tkmt_perl_cmd_delete
    );
    return 1;
}

/* ---- Marshal eval helpers (safe from any worker thread) ---- */
typedef struct tkmt_marshal_eval_req {
    char  *script;
    size_t len;
    char  *result;
    size_t result_len;
    int    status;
    int    free_self;
} tkmt_marshal_eval_req_t;

static void
tkmt_marshal_eval_cb(tkmt_interp_t *bi, void *raw)
{
    tkmt_marshal_eval_req_t *req = (tkmt_marshal_eval_req_t *)raw;
    if (!req) return;

    req->status = tkmt_interp_eval(bi, req->script, req->len);
    if (!req->free_self) {
        Tcl_Obj *res = Tcl_GetObjResult(tkmt_interp_raw(bi));
        Tcl_Size rlen = 0;
        const char *rs = tkmt_tcl_get_string(res, &rlen);
        if (rs && rlen > 0) {
            req->result = (char *)malloc((size_t)rlen + 1);
            if (req->result) {
                memcpy(req->result, rs, (size_t)rlen);
                req->result[rlen] = '\0';
                req->result_len = (size_t)rlen;
            }
        }
    } else {
        free(req->script);
        free(req);
    }
}

/* ---- Helper to extract tkmt_interp_t* from blessed hash/scalar ---- */
static tkmt_interp_t *
tkmt_get_interp(pTHX_ SV *self)
{
    if (!self || !SvROK(self)) croak("Tcl::MT: invalid interpreter object");
    SV *rv = SvRV(self);
    if (SvTYPE(rv) == SVt_PVHV) {
        SV **svp = hv_fetchs((HV *)rv, "_ptr", 0);
        if (svp && *svp && SvOK(*svp)) {
            return (tkmt_interp_t *)(uintptr_t)SvUV(*svp);
        }
    } else if (SvIOK(rv)) {
        return (tkmt_interp_t *)(uintptr_t)SvUV(rv);
    }
    croak("Tcl::MT: interpreter has been destroyed");
    return NULL;
}

static tkmt_surface_t *
tkmt_get_surface(pTHX_ SV *self)
{
    if (!self || !SvROK(self)) croak("Tcl::MT::Surface: invalid surface object");
    SV *rv = SvRV(self);
    if (SvTYPE(rv) == SVt_PVHV) {
        SV **svp = hv_fetchs((HV *)rv, "_ptr", 0);
        if (svp && *svp && SvOK(*svp)) {
            return (tkmt_surface_t *)(uintptr_t)SvUV(*svp);
        }
    }
    return NULL;
}

MODULE = Tcl::MT    PACKAGE = Tcl::MT

PROTOTYPES: DISABLE

const char *
tcl_version()
  CODE:
    RETVAL = TCL_VERSION;
  OUTPUT:
    RETVAL

int
is_perl5_mt()
  CODE:
    RETVAL = TKMT_IS_PERL5_MT;
  OUTPUT:
    RETVAL

int
have_packed_av()
  CODE:
    RETVAL = TKMT_HAVE_PACKED_AV;
  OUTPUT:
    RETVAL

UV
current_tid()
  CODE:
    RETVAL = (UV)tkmt_current_thread_id();
  OUTPUT:
    RETVAL

int
DONT_WAIT()
  CODE:
    RETVAL = TCL_DONT_WAIT;
  OUTPUT:
    RETVAL

int
WINDOW_EVENTS()
  CODE:
    RETVAL = TCL_WINDOW_EVENTS;
  OUTPUT:
    RETVAL

int
FILE_EVENTS()
  CODE:
    RETVAL = TCL_FILE_EVENTS;
  OUTPUT:
    RETVAL

int
TIMER_EVENTS()
  CODE:
    RETVAL = TCL_TIMER_EVENTS;
  OUTPUT:
    RETVAL

int
IDLE_EVENTS()
  CODE:
    RETVAL = TCL_IDLE_EVENTS;
  OUTPUT:
    RETVAL

int
ALL_EVENTS()
  CODE:
    RETVAL = TCL_ALL_EVENTS;
  OUTPUT:
    RETVAL

UV
_xs_create(int init_tk)
  CODE:
    char errbuf[512];
    errbuf[0] = '\0';
    tkmt_interp_t *bi = tkmt_interp_create(init_tk, errbuf, sizeof(errbuf));
    if (!bi) {
        croak("Tcl::MT: failed to create interpreter: %s", errbuf);
    }
    RETVAL = (UV)(uintptr_t)bi;
  OUTPUT:
    RETVAL

void
_xs_destroy(UV ptr)
  CODE:
    tkmt_interp_t *bi = (tkmt_interp_t *)(uintptr_t)ptr;
    if (bi) {
        tkmt_interp_destroy(bi);
    }

void
Init(SV *self)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    char errbuf[512];
    errbuf[0] = '\0';
    if (!tkmt_interp_init_tk(bi, errbuf, sizeof(errbuf))) {
        croak("Tcl::MT::Init failed: %s", errbuf);
    }

int
has_tk(SV *self)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    RETVAL = tkmt_interp_has_tk(bi);
  OUTPUT:
    RETVAL

int
is_owner_thread(SV *self)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    RETVAL = tkmt_interp_is_owner_thread(bi);
  OUTPUT:
    RETVAL

UV
owner_tid(SV *self)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    RETVAL = (UV)tkmt_interp_owner_tid(bi);
  OUTPUT:
    RETVAL

UV
raw_interp_ptr(SV *self)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    RETVAL = (UV)(uintptr_t)bi;
  OUTPUT:
    RETVAL

UV
intern_count(SV *self)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    RETVAL = (UV)tkmt_interp_intern_count(bi);
  OUTPUT:
    RETVAL

UV
marshal_count(SV *self)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    RETVAL = (UV)tkmt_interp_marshal_count(bi);
  OUTPUT:
    RETVAL

int
num_main_windows(SV *self)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    RETVAL = tkmt_interp_num_main_windows(bi);
  OUTPUT:
    RETVAL

SV *
Eval(SV *self, SV *script_sv)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    if (!tkmt_interp_is_owner_thread(bi)) {
        croak("Tcl::MT::Eval must be called on owning UI thread (use marshal_eval_sync from worker threads)");
    }
    STRLEN len = 0;
    const char *script = SvPV(script_sv, len);
    int rc = tkmt_interp_eval(bi, script, (size_t)len);
    Tcl_Obj *res = Tcl_GetObjResult(tkmt_interp_raw(bi));
    if (rc != TCL_OK) {
        Tcl_Size elen = 0;
        const char *emsg = tkmt_tcl_get_string(res, &elen);
        croak("%.*s", (int)elen, emsg ? emsg : "Tcl error");
    }
    RETVAL = tkmt_tcl_obj_to_sv(aTHX_ res);
  OUTPUT:
    RETVAL

void
icall(SV *self, ...)
  ALIAS:
    call         = 1
    icall_scalar = 2
    icall_list   = 3
  PPCODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    if (!tkmt_interp_is_owner_thread(bi)) {
        croak("Tcl::MT::icall must be called on owning UI thread");
    }
    Tcl_Size objc = (Tcl_Size)(items - 1);
    if (objc <= 0) {
        XSRETURN_UNDEF;
    }

    Tcl_Obj *stack_objs[32];
    int      stack_interned[32];
    Tcl_Obj **objv = (objc <= 32) ? stack_objs : (Tcl_Obj **)malloc((size_t)objc * sizeof(Tcl_Obj *));
    int      *interned = (objc <= 32) ? stack_interned : (int *)malloc((size_t)objc * sizeof(int));
    if (!objv || !interned) {
        if (objv && objv != stack_objs) free(objv);
        if (interned && interned != stack_interned) free(interned);
        croak("Tcl::MT::icall: out of memory");
    }

    for (Tcl_Size i = 0; i < objc; i++) {
        SV *arg = ST(i + 1);
        /* Intern command name (i==0) and option flags (-foo) */
        int try_intern = (i == 0);
        if (!try_intern && SvPOK(arg) && !SvROK(arg)) {
            STRLEN alen = 0;
            const char *as = SvPV(arg, alen);
            if (alen > 1 && alen <= 32 && as[0] == '-') {
                try_intern = 1;
            }
        }
        objv[i] = tkmt_sv_to_tcl_obj(aTHX_ bi, arg, try_intern, &interned[i]);
        if (!interned[i]) {
            Tcl_IncrRefCount(objv[i]);
        }
    }

    int rc = tkmt_interp_eval_objv(bi, objc, objv);

    for (Tcl_Size i = 0; i < objc; i++) {
        if (!interned[i]) {
            Tcl_DecrRefCount(objv[i]);
        }
    }
    if (objv != stack_objs) free(objv);
    if (interned != stack_interned) free(interned);

    Tcl_Interp *interp = tkmt_interp_raw(bi);
    Tcl_Obj *res = Tcl_GetObjResult(interp);
    if (rc != TCL_OK) {
        Tcl_Size elen = 0;
        const char *emsg = tkmt_tcl_get_string(res, &elen);
        croak("%.*s", (int)elen, emsg ? emsg : "Tcl error");
    }

    int want_list = (ix == 3) || ((ix == 0 || ix == 1) && GIMME_V == G_ARRAY);
    if (want_list) {
        Tcl_Size lobjc = 0;
        Tcl_Obj **lobjv = NULL;
        if (tkmt_tcl_list_get_elements(interp, res, &lobjc, &lobjv) == TCL_OK) {
            EXTEND(SP, (SSize_t)lobjc);
            for (Tcl_Size i = 0; i < lobjc; i++) {
                mPUSHs(tkmt_tcl_obj_to_sv(aTHX_ lobjv[i]));
            }
            XSRETURN((SSize_t)lobjc);
        }
    }
    mPUSHs(tkmt_tcl_obj_to_sv(aTHX_ res));
    XSRETURN(1);

void
CreateCommand(SV *self, const char *name, SV *cb_sv)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    if (!tkmt_interp_is_owner_thread(bi)) {
        croak("Tcl::MT::CreateCommand must be called on owning UI thread");
    }
    if (!SvROK(cb_sv) || SvTYPE(SvRV(cb_sv)) != SVt_PVCV) {
        croak("Tcl::MT::CreateCommand: second argument must be a CODE ref");
    }
    if (!tkmt_register_perl_cmd(aTHX_ bi, name, cb_sv)) {
        croak("Tcl::MT::CreateCommand: failed to register command '%s'", name);
    }

int
DeleteCommand(SV *self, const char *name)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    if (!tkmt_interp_is_owner_thread(bi)) {
        croak("Tcl::MT::DeleteCommand must be called on owning UI thread");
    }
    RETVAL = (Tcl_DeleteCommand(tkmt_interp_raw(bi), name) == 0) ? 1 : 0;
  OUTPUT:
    RETVAL

SV *
GetVar(SV *self, const char *name, int flags = 0)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    Tcl_Obj *val = Tcl_GetVar2Ex(tkmt_interp_raw(bi), name, NULL, flags);
    RETVAL = val ? tkmt_tcl_obj_to_sv(aTHX_ val) : newSV(0);
  OUTPUT:
    RETVAL

SV *
SetVar(SV *self, const char *name, SV *val_sv, int flags = 0)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    int interned = 0;
    Tcl_Obj *obj = tkmt_sv_to_tcl_obj(aTHX_ bi, val_sv, 0, &interned);
    Tcl_Obj *res = Tcl_SetVar2Ex(tkmt_interp_raw(bi), name, NULL, obj, flags);
    RETVAL = res ? tkmt_tcl_obj_to_sv(aTHX_ res) : newSV(0);
  OUTPUT:
    RETVAL

SV *
GetVar2(SV *self, const char *name1, const char *name2, int flags = 0)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    Tcl_Obj *val = Tcl_GetVar2Ex(tkmt_interp_raw(bi), name1, name2, flags);
    RETVAL = val ? tkmt_tcl_obj_to_sv(aTHX_ val) : newSV(0);
  OUTPUT:
    RETVAL

SV *
SetVar2(SV *self, const char *name1, const char *name2, SV *val_sv, int flags = 0)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    int interned = 0;
    Tcl_Obj *obj = tkmt_sv_to_tcl_obj(aTHX_ bi, val_sv, 0, &interned);
    Tcl_Obj *res = Tcl_SetVar2Ex(tkmt_interp_raw(bi), name1, name2, obj, flags);
    RETVAL = res ? tkmt_tcl_obj_to_sv(aTHX_ res) : newSV(0);
  OUTPUT:
    RETVAL

int
UnsetVar(SV *self, const char *name, int flags = 0)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    RETVAL = (Tcl_UnsetVar(tkmt_interp_raw(bi), name, flags) == TCL_OK) ? 1 : 0;
  OUTPUT:
    RETVAL

int
DoOneEvent(SV *self, int flags = 0)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    RETVAL = tkmt_interp_do_one_event(bi, flags);
  OUTPUT:
    RETVAL

int
drain_marshal_queue(SV *self)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    RETVAL = tkmt_interp_drain_marshal_queue(bi);
  OUTPUT:
    RETVAL

int
marshal_eval_async(SV *self, SV *script_sv)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    STRLEN len = 0;
    const char *s = SvPV(script_sv, len);
    tkmt_marshal_eval_req_t *req = (tkmt_marshal_eval_req_t *)calloc(1, sizeof(*req));
    if (!req) croak("Tcl::MT::marshal_eval_async: out of memory");
    req->script = (char *)malloc((size_t)len + 1);
    if (!req->script) {
        free(req);
        croak("Tcl::MT::marshal_eval_async: out of memory");
    }
    memcpy(req->script, s, (size_t)len);
    req->script[len] = '\0';
    req->len = (size_t)len;
    req->free_self = 1;
    if (!tkmt_interp_marshal_async(bi, tkmt_marshal_eval_cb, req)) {
        free(req->script);
        free(req);
        RETVAL = 0;
    } else {
        RETVAL = 1;
    }
  OUTPUT:
    RETVAL

SV *
marshal_eval_sync(SV *self, SV *script_sv)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    STRLEN len = 0;
    const char *s = SvPV(script_sv, len);
    tkmt_marshal_eval_req_t req;
    memset(&req, 0, sizeof(req));
    req.script = (char *)s;
    req.len = (size_t)len;
    req.free_self = 0;

    if (!tkmt_interp_marshal_sync(bi, tkmt_marshal_eval_cb, &req)) {
        croak("Tcl::MT::marshal_eval_sync: marshal failed");
    }
    if (req.status != TCL_OK) {
        SV *err = newSVpvn(req.result ? req.result : "Tcl marshal error",
                           req.result ? (STRLEN)req.result_len : 17);
        free(req.result);
        sv_2mortal(err);
        croak("%s", SvPV_nolen(err));
    }
    RETVAL = newSVpvn(req.result ? req.result : "",
                      req.result ? (STRLEN)req.result_len : 0);
    free(req.result);
  OUTPUT:
    RETVAL

int
blit_rgba_photo(SV *self, const char *photo_name, SV *rgba_sv, int width, int height)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    size_t expected = (size_t)width * (size_t)height * 4;
    int ok = 0;
    if (SvROK(rgba_sv) && SvTYPE(SvRV(rgba_sv)) == SVt_PVAV) {
        const uint8_t *buf = NULL;
        size_t len = 0;
        int owned = 0;
        if (tkmt_av_read_u8(aTHX_ (AV *)SvRV(rgba_sv), &buf, &len, &owned)) {
            if (len >= expected && buf) {
                ok = tkmt_surface_blit_rgba_photo(bi, photo_name, buf, width, height);
            }
            if (owned) free((void *)buf);
        }
    } else {
        STRLEN len = 0;
        const char *bytes = SvPV(rgba_sv, len);
        if ((size_t)len >= expected) {
            ok = tkmt_surface_blit_rgba_photo(bi, photo_name, (const uint8_t *)bytes, width, height);
        }
    }
    RETVAL = ok;
  OUTPUT:
    RETVAL

UV
_xs_create_surface(SV *self, const char *widget_path, int width, int height)
  CODE:
    tkmt_interp_t *bi = tkmt_get_interp(aTHX_ self);
    char errbuf[512];
    errbuf[0] = '\0';
    tkmt_surface_t *surf = tkmt_surface_create(bi, widget_path, width, height, errbuf, sizeof(errbuf));
    if (!surf) {
        croak("Tcl::MT::create_surface failed: %s", errbuf);
    }
    RETVAL = (UV)(uintptr_t)surf;
  OUTPUT:
    RETVAL

MODULE = Tcl::MT    PACKAGE = Tcl::MT::Surface

PROTOTYPES: DISABLE

void
_xs_destroy_surface(UV ptr)
  CODE:
    tkmt_surface_t *surf = (tkmt_surface_t *)(uintptr_t)ptr;
    if (surf) {
        tkmt_surface_destroy(surf);
    }

SV *
native_info(SV *self)
  CODE:
    tkmt_surface_t *surf = tkmt_get_surface(aTHX_ self);
    if (!surf) croak("Tcl::MT::Surface: destroyed");
    tkmt_native_surface_t ns;
    int realized = tkmt_surface_get_native(surf, &ns);
    HV *hv = newHV();
    (void)hv_stores(hv, "realized", newSViv(realized));
    (void)hv_stores(hv, "platform", newSViv((IV)ns.platform));
    (void)hv_stores(hv, "view",     newSVuv((UV)(uintptr_t)ns.view));
    (void)hv_stores(hv, "display",  newSVuv((UV)(uintptr_t)ns.display));
    (void)hv_stores(hv, "window",   newSVuv((UV)ns.window));
    (void)hv_stores(hv, "width",    newSViv(ns.width));
    (void)hv_stores(hv, "height",   newSViv(ns.height));
    (void)hv_stores(hv, "scale",    newSVnv((double)ns.scale));
    (void)hv_stores(hv, "visible",  newSViv(ns.visible));
    RETVAL = newRV_noinc((SV *)hv);
  OUTPUT:
    RETVAL

void
request_redraw(SV *self)
  CODE:
    tkmt_surface_t *surf = tkmt_get_surface(aTHX_ self);
    if (surf) tkmt_surface_request_redraw(surf);

const char *
path(SV *self)
  CODE:
    tkmt_surface_t *surf = tkmt_get_surface(aTHX_ self);
    RETVAL = surf ? tkmt_surface_path(surf) : "";
  OUTPUT:
    RETVAL

int
place_child(SV *self, const char *child_path, int x, int y, int width = 0, int height = 0, int visible = 1)
  CODE:
    tkmt_surface_t *surf = tkmt_get_surface(aTHX_ self);
    RETVAL = surf ? tkmt_surface_place_child(surf, child_path, x, y, width, height, visible) : 0;
  OUTPUT:
    RETVAL

int
remove_child(SV *self, const char *child_path)
  CODE:
    tkmt_surface_t *surf = tkmt_get_surface(aTHX_ self);
    RETVAL = surf ? tkmt_surface_remove_child(surf, child_path) : 0;
  OUTPUT:
    RETVAL
