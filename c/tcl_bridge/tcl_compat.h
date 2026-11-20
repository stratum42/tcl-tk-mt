/*
 * c/tcl_bridge/tcl_compat.h - Unifies Tcl/Tk 8.6 and 9.x C APIs
 *
 * Pure C11. Handles Tcl_Size, Tcl_GetStringFromObj, Tcl_GetByteArrayFromObj,
 * Tcl_ListObjGetElements, Tcl_EvalObjv, Tcl_CreateObjCommand2,
 * Tk_PhotoPutBlock, and platform native handle extraction.
 */
#ifndef TKMT_TCL_COMPAT_H
#define TKMT_TCL_COMPAT_H

#include <stddef.h>
#include <stdint.h>
#include <tcl.h>
#ifndef TKMT_NO_TK
#  if defined(__APPLE__) && !defined(MAC_OSX_TK)
#    define MAC_OSX_TK 1
#  endif
#  include <tk.h>
#  if defined(__APPLE__) || defined(_WIN32)
#    include <tkPlatDecls.h>
#  endif
#endif

#if TCL_MAJOR_VERSION < 9
#  define TKMT_TCL_IS_9 0
#  ifndef TCL_SIZE_MAX
typedef int Tcl_Size;
#    define TCL_SIZE_MAX INT_MAX
#  endif
#else
#  define TKMT_TCL_IS_9 1
#endif

/* Unified string / byte-array accessors */
static inline const char *
tkmt_tcl_get_string(Tcl_Obj *obj, Tcl_Size *len_out)
{
    return Tcl_GetStringFromObj(obj, len_out);
}

static inline const unsigned char *
tkmt_tcl_get_bytes(Tcl_Obj *obj, Tcl_Size *len_out)
{
#if TKMT_TCL_IS_9
    return Tcl_GetBytesFromObj(NULL, obj, len_out);
#else
    return Tcl_GetByteArrayFromObj(obj, len_out);
#endif
}

static inline int
tkmt_tcl_list_get_elements(Tcl_Interp *interp, Tcl_Obj *list_obj,
                           Tcl_Size *objc_out, Tcl_Obj ***objv_out)
{
    return Tcl_ListObjGetElements(interp, list_obj, objc_out, objv_out);
}

static inline int
tkmt_tcl_eval_objv(Tcl_Interp *interp, Tcl_Size objc,
                   Tcl_Obj *const *objv, int flags)
{
    return Tcl_EvalObjv(interp, objc, objv, flags);
}

/* Unified ObjCmd registration (Tcl 8.6 int objc vs Tcl 9 Tcl_Size objc) */
typedef int (*tkmt_obj_cmd_proc_t)(void *client_data, Tcl_Interp *interp,
                                   Tcl_Size objc, Tcl_Obj *const *objv);
typedef void (*tkmt_cmd_delete_proc_t)(void *client_data);

static inline Tcl_Command
tkmt_tcl_create_obj_command(Tcl_Interp *interp, const char *cmd_name,
                            tkmt_obj_cmd_proc_t proc, void *client_data,
                            tkmt_cmd_delete_proc_t delete_proc)
{
#if TKMT_TCL_IS_9
    return Tcl_CreateObjCommand2(interp, cmd_name,
                                 (Tcl_ObjCmdProc2 *)proc,
                                 client_data,
                                 (Tcl_CmdDeleteProc *)delete_proc);
#else
    return Tcl_CreateObjCommand(interp, cmd_name,
                                (Tcl_ObjCmdProc *)proc,
                                (ClientData)client_data,
                                (Tcl_CmdDeleteProc *)delete_proc);
#endif
}

#ifndef TKMT_NO_TK
/* Unified Tk_PhotoPutBlock & Tk_PhotoSetSize */
static inline int
tkmt_tk_photo_put_block(Tcl_Interp *interp, Tk_PhotoHandle handle,
                        Tk_PhotoImageBlock *block,
                        int x, int y, int width, int height, int comp_rule)
{
    return Tk_PhotoPutBlock(interp, handle, block, x, y, width, height, comp_rule);
}

static inline int
tkmt_tk_photo_set_size(Tcl_Interp *interp, Tk_PhotoHandle handle,
                       int width, int height)
{
    return Tk_PhotoSetSize(interp, handle, width, height);
}
#endif /* !TKMT_NO_TK */

#endif /* TKMT_TCL_COMPAT_H */
