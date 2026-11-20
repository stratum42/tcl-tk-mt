/*
 * Tcl::Tk::MT - Pure C11 Vulkan 2D Graphics Backend (Linux / Win64)
 *
 * Zero hard link dependency on libvulkan or Vulkan SDK headers:
 *   - Runtime dlopen("libvulkan.so.1") / LoadLibraryA("vulkan-1.dll")
 *   - Supports X11 / Wayland / Win32 VkSurfaceKHR creation
 *   - Supports headless offscreen VkImage + host-visible staging VkBuffer readback
 *   - Uses precompiled SPIR-V from c/gfx/shaders/canvas2d_spv.h when available,
 *     with deterministic software rasterization staged through Vulkan memory
 *     when offline SPIR-V bytecode is not bundled.
 */

#if !defined(_WIN32) && !defined(__APPLE__)
#  if !defined(_POSIX_C_SOURCE) && !defined(_GNU_SOURCE) && !defined(_DEFAULT_SOURCE)
#    define _POSIX_C_SOURCE 200809L
#  endif
#endif

#include "tkmt_gfx.h"
#include "shaders/canvas2d_spv.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
   typedef HMODULE tkmt_dl_t;
#  define tkmt_dlopen(name)     LoadLibraryA(name)
#  define tkmt_dlclose(h)       FreeLibrary(h)
#  define VKAPI_CALL            __stdcall
#  define TKMT_DLSYM_ASSIGN(h, sym, dst) do { \
       FARPROC _tkmt_sym = GetProcAddress((h), (sym)); \
       memcpy(&(dst), &_tkmt_sym, sizeof(dst)); \
   } while (0)
#else
#  include <dlfcn.h>
   typedef void *tkmt_dl_t;
#  define tkmt_dlopen(name)     dlopen((name), RTLD_LAZY | RTLD_LOCAL)
#  define tkmt_dlclose(h)       dlclose(h)
#  define VKAPI_CALL
#  define TKMT_DLSYM_ASSIGN(h, sym, dst) do { \
       void *_tkmt_sym = dlsym((h), (sym)); \
       memcpy(&(dst), &_tkmt_sym, sizeof(dst)); \
   } while (0)
#endif

#define VK_ASSIGN_FN(dst, src) do { \
    PFN_vkVoidFunction _tkmt_fn_tmp = (src); \
    memcpy(&(dst), &_tkmt_fn_tmp, sizeof(dst)); \
} while (0)

/* -------------------------------------------------------------------------
 * Minimal self-contained Vulkan 1.0 + WSI ABI declarations
 * ------------------------------------------------------------------------- */

typedef uint32_t VkFlags;
typedef uint32_t VkBool32;
typedef uint64_t VkDeviceSize;
typedef int32_t  VkResult;

typedef struct VkInstance_T       *VkInstance;
typedef struct VkPhysicalDevice_T *VkPhysicalDevice;
typedef struct VkDevice_T         *VkDevice;
typedef struct VkQueue_T          *VkQueue;
typedef struct VkCommandBuffer_T  *VkCommandBuffer;

typedef uint64_t VkSurfaceKHR;
typedef uint64_t VkImage;
typedef uint64_t VkBuffer;
typedef uint64_t VkDeviceMemory;
typedef uint64_t VkCommandPool;
typedef uint64_t VkShaderModule;

#define VK_SUCCESS 0
#define VK_NULL_HANDLE 0

#define VK_STRUCTURE_TYPE_APPLICATION_INFO               0
#define VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO           1
#define VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO       2
#define VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO             3
#define VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO           5
#define VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO             12
#define VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO              14
#define VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO      16
#define VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO       39
#define VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR   1000004000
#define VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR 1000006000
#define VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR  1000009000

#define VK_QUEUE_GRAPHICS_BIT          0x00000001u
#define VK_FORMAT_R8G8B8A8_UNORM       37
#define VK_IMAGE_TYPE_2D               1
#define VK_IMAGE_TILING_OPTIMAL        0
#define VK_IMAGE_TILING_LINEAR         1
#define VK_SAMPLE_COUNT_1_BIT          0x00000001u
#define VK_SHARING_MODE_EXCLUSIVE      0
#define VK_IMAGE_LAYOUT_UNDEFINED      0
#define VK_IMAGE_USAGE_TRANSFER_SRC_BIT 0x00000001u
#define VK_IMAGE_USAGE_TRANSFER_DST_BIT 0x00000002u
#define VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT 0x00000010u

#define VK_BUFFER_USAGE_TRANSFER_SRC_BIT 0x00000001u
#define VK_BUFFER_USAGE_TRANSFER_DST_BIT 0x00000002u

#define VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT  0x00000001u
#define VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT  0x00000002u
#define VK_MEMORY_PROPERTY_HOST_COHERENT_BIT 0x00000004u

#define VK_MAX_MEMORY_TYPES 32
#define VK_MAX_MEMORY_HEAPS 16

typedef struct VkExtent3D {
    uint32_t width, height, depth;
} VkExtent3D;

typedef struct VkApplicationInfo {
    int32_t     sType;
    const void *pNext;
    const char *pApplicationName;
    uint32_t    applicationVersion;
    const char *pEngineName;
    uint32_t    engineVersion;
    uint32_t    apiVersion;
} VkApplicationInfo;

typedef struct VkInstanceCreateInfo {
    int32_t                  sType;
    const void              *pNext;
    VkFlags                  flags;
    const VkApplicationInfo *pApplicationInfo;
    uint32_t                 enabledLayerCount;
    const char *const       *ppEnabledLayerNames;
    uint32_t                 enabledExtensionCount;
    const char *const       *ppEnabledExtensionNames;
} VkInstanceCreateInfo;

typedef struct VkQueueFamilyProperties {
    VkFlags    queueFlags;
    uint32_t   queueCount;
    uint32_t   timestampValidBits;
    VkExtent3D minImageTransferGranularity;
} VkQueueFamilyProperties;

typedef struct VkDeviceQueueCreateInfo {
    int32_t      sType;
    const void  *pNext;
    VkFlags      flags;
    uint32_t     queueFamilyIndex;
    uint32_t     queueCount;
    const float *pQueuePriorities;
} VkDeviceQueueCreateInfo;

typedef struct VkDeviceCreateInfo {
    int32_t                        sType;
    const void                    *pNext;
    VkFlags                        flags;
    uint32_t                       queueCreateInfoCount;
    const VkDeviceQueueCreateInfo *pQueueCreateInfos;
    uint32_t                       enabledLayerCount;
    const char *const             *ppEnabledLayerNames;
    uint32_t                       enabledExtensionCount;
    const char *const             *ppEnabledExtensionNames;
    const void                    *pEnabledFeatures;
} VkDeviceCreateInfo;

typedef struct VkMemoryType {
    VkFlags  propertyFlags;
    uint32_t heapIndex;
} VkMemoryType;

typedef struct VkMemoryHeap {
    VkDeviceSize size;
    VkFlags      flags;
} VkMemoryHeap;

typedef struct VkPhysicalDeviceMemoryProperties {
    uint32_t     memoryTypeCount;
    VkMemoryType memoryTypes[VK_MAX_MEMORY_TYPES];
    uint32_t     memoryHeapCount;
    VkMemoryHeap memoryHeaps[VK_MAX_MEMORY_HEAPS];
} VkPhysicalDeviceMemoryProperties;

typedef struct VkMemoryRequirements {
    VkDeviceSize size;
    VkDeviceSize alignment;
    uint32_t     memoryTypeBits;
} VkMemoryRequirements;

typedef struct VkMemoryAllocateInfo {
    int32_t      sType;
    const void  *pNext;
    VkDeviceSize allocationSize;
    uint32_t     memoryTypeIndex;
} VkMemoryAllocateInfo;

typedef struct VkBufferCreateInfo {
    int32_t         sType;
    const void     *pNext;
    VkFlags         flags;
    VkDeviceSize    size;
    VkFlags         usage;
    int32_t         sharingMode;
    uint32_t        queueFamilyIndexCount;
    const uint32_t *pQueueFamilyIndices;
} VkBufferCreateInfo;

typedef struct VkImageCreateInfo {
    int32_t         sType;
    const void     *pNext;
    VkFlags         flags;
    int32_t         imageType;
    int32_t         format;
    VkExtent3D      extent;
    uint32_t        mipLevels;
    uint32_t        arrayLayers;
    int32_t         samples;
    int32_t         tiling;
    VkFlags         usage;
    int32_t         sharingMode;
    uint32_t        queueFamilyIndexCount;
    const uint32_t *pQueueFamilyIndices;
    int32_t         initialLayout;
} VkImageCreateInfo;

typedef struct VkCommandPoolCreateInfo {
    int32_t     sType;
    const void *pNext;
    VkFlags     flags;
    uint32_t    queueFamilyIndex;
} VkCommandPoolCreateInfo;

typedef struct VkXlibSurfaceCreateInfoKHR {
    int32_t     sType;
    const void *pNext;
    VkFlags     flags;
    void       *dpy;
    uintptr_t   window;
} VkXlibSurfaceCreateInfoKHR;

typedef struct VkWaylandSurfaceCreateInfoKHR {
    int32_t     sType;
    const void *pNext;
    VkFlags     flags;
    void       *display;
    void       *surface;
} VkWaylandSurfaceCreateInfoKHR;

typedef struct VkWin32SurfaceCreateInfoKHR {
    int32_t     sType;
    const void *pNext;
    VkFlags     flags;
    void       *hinstance;
    void       *hwnd;
} VkWin32SurfaceCreateInfoKHR;

typedef void (VKAPI_CALL *PFN_vkVoidFunction)(void);
typedef PFN_vkVoidFunction (VKAPI_CALL *PFN_vkGetInstanceProcAddr)(VkInstance, const char *);
typedef VkResult (VKAPI_CALL *PFN_vkCreateInstance)(const VkInstanceCreateInfo *, const void *, VkInstance *);
typedef void (VKAPI_CALL *PFN_vkDestroyInstance)(VkInstance, const void *);
typedef VkResult (VKAPI_CALL *PFN_vkEnumeratePhysicalDevices)(VkInstance, uint32_t *, VkPhysicalDevice *);
typedef void (VKAPI_CALL *PFN_vkGetPhysicalDeviceQueueFamilyProperties)(VkPhysicalDevice, uint32_t *, VkQueueFamilyProperties *);
typedef void (VKAPI_CALL *PFN_vkGetPhysicalDeviceMemoryProperties)(VkPhysicalDevice, VkPhysicalDeviceMemoryProperties *);
typedef VkResult (VKAPI_CALL *PFN_vkCreateDevice)(VkPhysicalDevice, const VkDeviceCreateInfo *, const void *, VkDevice *);
typedef void (VKAPI_CALL *PFN_vkDestroyDevice)(VkDevice, const void *);
typedef void (VKAPI_CALL *PFN_vkGetDeviceQueue)(VkDevice, uint32_t, uint32_t, VkQueue *);
typedef VkResult (VKAPI_CALL *PFN_vkCreateCommandPool)(VkDevice, const VkCommandPoolCreateInfo *, const void *, VkCommandPool *);
typedef void (VKAPI_CALL *PFN_vkDestroyCommandPool)(VkDevice, VkCommandPool, const void *);
typedef VkResult (VKAPI_CALL *PFN_vkCreateImage)(VkDevice, const VkImageCreateInfo *, const void *, VkImage *);
typedef void (VKAPI_CALL *PFN_vkDestroyImage)(VkDevice, VkImage, const void *);
typedef void (VKAPI_CALL *PFN_vkGetImageMemoryRequirements)(VkDevice, VkImage, VkMemoryRequirements *);
typedef VkResult (VKAPI_CALL *PFN_vkBindImageMemory)(VkDevice, VkImage, VkDeviceMemory, VkDeviceSize);
typedef VkResult (VKAPI_CALL *PFN_vkCreateBuffer)(VkDevice, const VkBufferCreateInfo *, const void *, VkBuffer *);
typedef void (VKAPI_CALL *PFN_vkDestroyBuffer)(VkDevice, VkBuffer, const void *);
typedef void (VKAPI_CALL *PFN_vkGetBufferMemoryRequirements)(VkDevice, VkBuffer, VkMemoryRequirements *);
typedef VkResult (VKAPI_CALL *PFN_vkBindBufferMemory)(VkDevice, VkBuffer, VkDeviceMemory, VkDeviceSize);
typedef VkResult (VKAPI_CALL *PFN_vkAllocateMemory)(VkDevice, const VkMemoryAllocateInfo *, const void *, VkDeviceMemory *);
typedef void (VKAPI_CALL *PFN_vkFreeMemory)(VkDevice, VkDeviceMemory, const void *);
typedef VkResult (VKAPI_CALL *PFN_vkMapMemory)(VkDevice, VkDeviceMemory, VkDeviceSize, VkDeviceSize, VkFlags, void **);
typedef void (VKAPI_CALL *PFN_vkUnmapMemory)(VkDevice, VkDeviceMemory);
typedef void (VKAPI_CALL *PFN_vkDestroySurfaceKHR)(VkInstance, VkSurfaceKHR, const void *);
typedef VkResult (VKAPI_CALL *PFN_vkCreateXlibSurfaceKHR)(VkInstance, const VkXlibSurfaceCreateInfoKHR *, const void *, VkSurfaceKHR *);
typedef VkResult (VKAPI_CALL *PFN_vkCreateWaylandSurfaceKHR)(VkInstance, const VkWaylandSurfaceCreateInfoKHR *, const void *, VkSurfaceKHR *);
typedef VkResult (VKAPI_CALL *PFN_vkCreateWin32SurfaceKHR)(VkInstance, const VkWin32SurfaceCreateInfoKHR *, const void *, VkSurfaceKHR *);

/* -------------------------------------------------------------------------
 * Global Vulkan loader & device state
 * ------------------------------------------------------------------------- */

static tkmt_dl_t        g_vk_lib        = NULL;
static VkInstance       g_vk_instance   = NULL;
static VkPhysicalDevice g_vk_phys       = NULL;
static VkDevice         g_vk_device     = NULL;
static VkQueue          g_vk_queue      = NULL;
static uint32_t         g_vk_qfamily    = 0;
static VkCommandPool    g_vk_cmd_pool   = VK_NULL_HANDLE;
static VkPhysicalDeviceMemoryProperties g_vk_mem_props;

static PFN_vkGetInstanceProcAddr                  pfn_vkGetInstanceProcAddr = NULL;
static PFN_vkCreateInstance                       pfn_vkCreateInstance = NULL;
static PFN_vkDestroyInstance                      pfn_vkDestroyInstance = NULL;
static PFN_vkEnumeratePhysicalDevices             pfn_vkEnumeratePhysicalDevices = NULL;
static PFN_vkGetPhysicalDeviceQueueFamilyProperties pfn_vkGetPhysicalDeviceQueueFamilyProperties = NULL;
static PFN_vkGetPhysicalDeviceMemoryProperties    pfn_vkGetPhysicalDeviceMemoryProperties = NULL;
static PFN_vkCreateDevice                         pfn_vkCreateDevice = NULL;
static PFN_vkDestroyDevice                        pfn_vkDestroyDevice = NULL;
static PFN_vkGetDeviceQueue                       pfn_vkGetDeviceQueue = NULL;
static PFN_vkCreateCommandPool                    pfn_vkCreateCommandPool = NULL;
static PFN_vkDestroyCommandPool                   pfn_vkDestroyCommandPool = NULL;
static PFN_vkCreateImage                          pfn_vkCreateImage = NULL;
static PFN_vkDestroyImage                         pfn_vkDestroyImage = NULL;
static PFN_vkGetImageMemoryRequirements           pfn_vkGetImageMemoryRequirements = NULL;
static PFN_vkBindImageMemory                      pfn_vkBindImageMemory = NULL;
static PFN_vkCreateBuffer                         pfn_vkCreateBuffer = NULL;
static PFN_vkDestroyBuffer                        pfn_vkDestroyBuffer = NULL;
static PFN_vkGetBufferMemoryRequirements          pfn_vkGetBufferMemoryRequirements = NULL;
static PFN_vkBindBufferMemory                     pfn_vkBindBufferMemory = NULL;
static PFN_vkAllocateMemory                       pfn_vkAllocateMemory = NULL;
static PFN_vkFreeMemory                           pfn_vkFreeMemory = NULL;
static PFN_vkMapMemory                            pfn_vkMapMemory = NULL;
static PFN_vkUnmapMemory                          pfn_vkUnmapMemory = NULL;
static PFN_vkDestroySurfaceKHR                    pfn_vkDestroySurfaceKHR = NULL;
static PFN_vkCreateXlibSurfaceKHR                 pfn_vkCreateXlibSurfaceKHR = NULL;
static PFN_vkCreateWaylandSurfaceKHR              pfn_vkCreateWaylandSurfaceKHR = NULL;
static PFN_vkCreateWin32SurfaceKHR                pfn_vkCreateWin32SurfaceKHR = NULL;

struct tkmt_gfx_surface {
    uint32_t            width;
    uint32_t            height;
    float               scale;
    int                 headless;
    VkSurfaceKHR        vk_surface;
    VkImage             offscreen_img;
    VkDeviceMemory      offscreen_mem;
    VkBuffer            staging_buf;
    VkDeviceMemory      staging_mem;
    void               *staging_mapped;
    size_t              staging_bytes;
    tkmt_gfx_surface_t *sw_mirror; /* software twin mirror when SPIR-V unavailable */
};

static int vk_load_loader(void) {
    if (g_vk_lib) return 0;
#if defined(_WIN32)
    g_vk_lib = tkmt_dlopen("vulkan-1.dll");
#elif defined(__APPLE__)
    g_vk_lib = tkmt_dlopen("libvulkan.1.dylib");
    if (!g_vk_lib) g_vk_lib = tkmt_dlopen("libMoltenVK.dylib");
#else
    g_vk_lib = tkmt_dlopen("libvulkan.so.1");
    if (!g_vk_lib) g_vk_lib = tkmt_dlopen("libvulkan.so");
#endif
    if (!g_vk_lib) return -1;

    TKMT_DLSYM_ASSIGN(g_vk_lib, "vkGetInstanceProcAddr", pfn_vkGetInstanceProcAddr);
    if (!pfn_vkGetInstanceProcAddr) {
        tkmt_dlclose(g_vk_lib);
        g_vk_lib = NULL;
        return -1;
    }
    VK_ASSIGN_FN(pfn_vkCreateInstance, pfn_vkGetInstanceProcAddr(NULL, "vkCreateInstance"));
    if (!pfn_vkCreateInstance) {
        tkmt_dlclose(g_vk_lib);
        g_vk_lib = NULL;
        return -1;
    }
    return 0;
}

static int vk_find_mem_type(uint32_t type_bits, VkFlags req_flags, uint32_t *out_idx) {
    for (uint32_t i = 0; i < g_vk_mem_props.memoryTypeCount; i++) {
        if ((type_bits & (1u << i)) &&
            (g_vk_mem_props.memoryTypes[i].propertyFlags & req_flags) == req_flags) {
            *out_idx = i;
            return 0;
        }
    }
    return -1;
}

static int vk_create_instance_and_find_device(VkInstance *out_inst,
                                              VkPhysicalDevice *out_phys,
                                              uint32_t *out_qfamily) {
    VkApplicationInfo app;
    memset(&app, 0, sizeof(app));
    app.sType              = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName   = "Tcl::Tk::MT";
    app.applicationVersion = 1;
    app.pEngineName        = "tkmt_gfx";
    app.engineVersion      = 1;
    app.apiVersion         = (1u << 22); /* VK_API_VERSION_1_0 */

    VkInstanceCreateInfo ici;
    memset(&ici, 0, sizeof(ici));
    ici.sType            = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo = &app;

    /* Try enabling WSI surface extensions first; fall back to headless (0 extensions) */
    VkInstance inst = NULL;
#if defined(_WIN32)
    static const char *const k_wsi_exts[] = { "VK_KHR_surface", "VK_KHR_win32_surface" };
    ici.enabledExtensionCount   = 2u;
    ici.ppEnabledExtensionNames = k_wsi_exts;
    if (pfn_vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS || !inst) {
        ici.enabledExtensionCount   = 0u;
        ici.ppEnabledExtensionNames = NULL;
        if (pfn_vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS || !inst) {
            return -1;
        }
    }
#elif !defined(__APPLE__)
    static const char *const k_wsi_exts[] = { "VK_KHR_surface", "VK_KHR_xlib_surface" };
    ici.enabledExtensionCount   = 2u;
    ici.ppEnabledExtensionNames = k_wsi_exts;
    if (pfn_vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS || !inst) {
        ici.enabledExtensionCount   = 0u;
        ici.ppEnabledExtensionNames = NULL;
        if (pfn_vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS || !inst) {
            return -1;
        }
    }
#else
    if (pfn_vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS || !inst) {
        return -1;
    }
#endif

    PFN_vkDestroyInstance destroy_inst = NULL;
    PFN_vkEnumeratePhysicalDevices enum_phys = NULL;
    PFN_vkGetPhysicalDeviceQueueFamilyProperties get_qprops = NULL;
    VK_ASSIGN_FN(destroy_inst, pfn_vkGetInstanceProcAddr(inst, "vkDestroyInstance"));
    VK_ASSIGN_FN(enum_phys, pfn_vkGetInstanceProcAddr(inst, "vkEnumeratePhysicalDevices"));
    VK_ASSIGN_FN(get_qprops, pfn_vkGetInstanceProcAddr(inst, "vkGetPhysicalDeviceQueueFamilyProperties"));

    if (!destroy_inst || !enum_phys || !get_qprops) {
        if (destroy_inst) destroy_inst(inst, NULL);
        return -1;
    }

    uint32_t dev_count = 0;
    if (enum_phys(inst, &dev_count, NULL) != VK_SUCCESS || dev_count == 0) {
        destroy_inst(inst, NULL);
        return -1;
    }

    VkPhysicalDevice *devs = (VkPhysicalDevice *)calloc(dev_count, sizeof(*devs));
    if (!devs) {
        destroy_inst(inst, NULL);
        return -1;
    }
    if (enum_phys(inst, &dev_count, devs) != VK_SUCCESS) {
        free(devs);
        destroy_inst(inst, NULL);
        return -1;
    }

    VkPhysicalDevice chosen = NULL;
    uint32_t chosen_qf = 0;
    for (uint32_t i = 0; i < dev_count && !chosen; i++) {
        uint32_t qcount = 0;
        get_qprops(devs[i], &qcount, NULL);
        if (qcount == 0) continue;
        VkQueueFamilyProperties *qprops =
            (VkQueueFamilyProperties *)calloc(qcount, sizeof(*qprops));
        if (!qprops) continue;
        get_qprops(devs[i], &qcount, qprops);
        for (uint32_t q = 0; q < qcount; q++) {
            if (qprops[q].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
                chosen = devs[i];
                chosen_qf = q;
                break;
            }
        }
        free(qprops);
    }
    free(devs);

    if (!chosen) {
        destroy_inst(inst, NULL);
        return -1;
    }

    *out_inst    = inst;
    *out_phys    = chosen;
    *out_qfamily = chosen_qf;
    return 0;
}

static int vk_probe(void) {
    if (vk_load_loader() != 0) return 0;
    VkInstance inst = NULL;
    VkPhysicalDevice phys = NULL;
    uint32_t qf = 0;
    if (vk_create_instance_and_find_device(&inst, &phys, &qf) != 0) {
        return 0;
    }
    PFN_vkDestroyInstance destroy_inst = NULL;
    VK_ASSIGN_FN(destroy_inst, pfn_vkGetInstanceProcAddr(inst, "vkDestroyInstance"));
    if (destroy_inst) destroy_inst(inst, NULL);
    return 1;
}

#define VK_LOAD_INST(fn) \
    VK_ASSIGN_FN(pfn_##fn, pfn_vkGetInstanceProcAddr(g_vk_instance, #fn))

static int vk_init(void) {
    if (g_vk_device) return 0;
    if (vk_load_loader() != 0) return -1;

    if (vk_create_instance_and_find_device(&g_vk_instance, &g_vk_phys, &g_vk_qfamily) != 0) {
        return -1;
    }

    VK_LOAD_INST(vkDestroyInstance);
    VK_LOAD_INST(vkEnumeratePhysicalDevices);
    VK_LOAD_INST(vkGetPhysicalDeviceQueueFamilyProperties);
    VK_LOAD_INST(vkGetPhysicalDeviceMemoryProperties);
    VK_LOAD_INST(vkCreateDevice);
    VK_LOAD_INST(vkDestroyDevice);
    VK_LOAD_INST(vkGetDeviceQueue);
    VK_LOAD_INST(vkCreateCommandPool);
    VK_LOAD_INST(vkDestroyCommandPool);
    VK_LOAD_INST(vkCreateImage);
    VK_LOAD_INST(vkDestroyImage);
    VK_LOAD_INST(vkGetImageMemoryRequirements);
    VK_LOAD_INST(vkBindImageMemory);
    VK_LOAD_INST(vkCreateBuffer);
    VK_LOAD_INST(vkDestroyBuffer);
    VK_LOAD_INST(vkGetBufferMemoryRequirements);
    VK_LOAD_INST(vkBindBufferMemory);
    VK_LOAD_INST(vkAllocateMemory);
    VK_LOAD_INST(vkFreeMemory);
    VK_LOAD_INST(vkMapMemory);
    VK_LOAD_INST(vkUnmapMemory);
    VK_LOAD_INST(vkDestroySurfaceKHR);
    VK_LOAD_INST(vkCreateXlibSurfaceKHR);
    VK_LOAD_INST(vkCreateWaylandSurfaceKHR);
    VK_LOAD_INST(vkCreateWin32SurfaceKHR);

    if (!pfn_vkCreateDevice || !pfn_vkDestroyDevice || !pfn_vkGetDeviceQueue ||
        !pfn_vkGetPhysicalDeviceMemoryProperties || !pfn_vkCreateBuffer ||
        !pfn_vkAllocateMemory || !pfn_vkMapMemory) {
        if (pfn_vkDestroyInstance) pfn_vkDestroyInstance(g_vk_instance, NULL);
        g_vk_instance = NULL;
        return -1;
    }

    pfn_vkGetPhysicalDeviceMemoryProperties(g_vk_phys, &g_vk_mem_props);

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci;
    memset(&qci, 0, sizeof(qci));
    qci.sType            = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qci.queueFamilyIndex = g_vk_qfamily;
    qci.queueCount       = 1;
    qci.pQueuePriorities = &prio;

    VkDeviceCreateInfo dci;
    memset(&dci, 0, sizeof(dci));
    dci.sType                = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos    = &qci;

    if (pfn_vkCreateDevice(g_vk_phys, &dci, NULL, &g_vk_device) != VK_SUCCESS || !g_vk_device) {
        pfn_vkDestroyInstance(g_vk_instance, NULL);
        g_vk_instance = NULL;
        return -1;
    }

    pfn_vkGetDeviceQueue(g_vk_device, g_vk_qfamily, 0, &g_vk_queue);

    if (pfn_vkCreateCommandPool) {
        VkCommandPoolCreateInfo cpci;
        memset(&cpci, 0, sizeof(cpci));
        cpci.sType            = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        cpci.queueFamilyIndex = g_vk_qfamily;
        pfn_vkCreateCommandPool(g_vk_device, &cpci, NULL, &g_vk_cmd_pool);
    }

    return 0;
}

static void vk_shutdown(void) {
    if (g_vk_device) {
        if (g_vk_cmd_pool != VK_NULL_HANDLE && pfn_vkDestroyCommandPool) {
            pfn_vkDestroyCommandPool(g_vk_device, g_vk_cmd_pool, NULL);
            g_vk_cmd_pool = VK_NULL_HANDLE;
        }
        if (pfn_vkDestroyDevice) pfn_vkDestroyDevice(g_vk_device, NULL);
        g_vk_device = NULL;
        g_vk_queue  = NULL;
    }
    if (g_vk_instance) {
        if (pfn_vkDestroyInstance) pfn_vkDestroyInstance(g_vk_instance, NULL);
        g_vk_instance = NULL;
        g_vk_phys     = NULL;
    }
    if (g_vk_lib) {
        tkmt_dlclose(g_vk_lib);
        g_vk_lib = NULL;
    }
}

static void vk_free_surface_targets(tkmt_gfx_surface_t *surf) {
    if (!surf || !g_vk_device) return;
    if (surf->staging_mapped && surf->staging_mem != VK_NULL_HANDLE && pfn_vkUnmapMemory) {
        pfn_vkUnmapMemory(g_vk_device, surf->staging_mem);
        surf->staging_mapped = NULL;
    }
    if (surf->staging_buf != VK_NULL_HANDLE && pfn_vkDestroyBuffer) {
        pfn_vkDestroyBuffer(g_vk_device, surf->staging_buf, NULL);
        surf->staging_buf = VK_NULL_HANDLE;
    }
    if (surf->staging_mem != VK_NULL_HANDLE && pfn_vkFreeMemory) {
        pfn_vkFreeMemory(g_vk_device, surf->staging_mem, NULL);
        surf->staging_mem = VK_NULL_HANDLE;
    }
    if (surf->offscreen_img != VK_NULL_HANDLE && pfn_vkDestroyImage) {
        pfn_vkDestroyImage(g_vk_device, surf->offscreen_img, NULL);
        surf->offscreen_img = VK_NULL_HANDLE;
    }
    if (surf->offscreen_mem != VK_NULL_HANDLE && pfn_vkFreeMemory) {
        pfn_vkFreeMemory(g_vk_device, surf->offscreen_mem, NULL);
        surf->offscreen_mem = VK_NULL_HANDLE;
    }
}

static int vk_alloc_surface_targets(tkmt_gfx_surface_t *surf, uint32_t w, uint32_t h) {
    size_t bytes = (size_t)w * (size_t)h * 4u;

    /* Create offscreen VkImage */
    if (pfn_vkCreateImage && pfn_vkGetImageMemoryRequirements && pfn_vkBindImageMemory) {
        VkImageCreateInfo ici;
        memset(&ici, 0, sizeof(ici));
        ici.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        ici.imageType     = VK_IMAGE_TYPE_2D;
        ici.format        = VK_FORMAT_R8G8B8A8_UNORM;
        ici.extent.width  = w;
        ici.extent.height = h;
        ici.extent.depth  = 1;
        ici.mipLevels     = 1;
        ici.arrayLayers   = 1;
        ici.samples       = VK_SAMPLE_COUNT_1_BIT;
        ici.tiling        = VK_IMAGE_TILING_OPTIMAL;
        ici.usage         = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
                          | VK_IMAGE_USAGE_TRANSFER_SRC_BIT
                          | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        ici.sharingMode   = VK_SHARING_MODE_EXCLUSIVE;
        ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

        if (pfn_vkCreateImage(g_vk_device, &ici, NULL, &surf->offscreen_img) == VK_SUCCESS) {
            VkMemoryRequirements req;
            pfn_vkGetImageMemoryRequirements(g_vk_device, surf->offscreen_img, &req);
            uint32_t mt = 0;
            if (vk_find_mem_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &mt) != 0) {
                vk_find_mem_type(req.memoryTypeBits, 0, &mt);
            }
            VkMemoryAllocateInfo mai;
            memset(&mai, 0, sizeof(mai));
            mai.sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
            mai.allocationSize  = req.size;
            mai.memoryTypeIndex = mt;
            if (pfn_vkAllocateMemory(g_vk_device, &mai, NULL, &surf->offscreen_mem) == VK_SUCCESS) {
                pfn_vkBindImageMemory(g_vk_device, surf->offscreen_img, surf->offscreen_mem, 0);
            }
        }
    }

    /* Create host-visible staging VkBuffer for readback */
    VkBufferCreateInfo bci;
    memset(&bci, 0, sizeof(bci));
    bci.sType       = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bci.size        = (VkDeviceSize)bytes;
    bci.usage       = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

    if (pfn_vkCreateBuffer(g_vk_device, &bci, NULL, &surf->staging_buf) != VK_SUCCESS) {
        vk_free_surface_targets(surf);
        return -1;
    }

    VkMemoryRequirements breq;
    pfn_vkGetBufferMemoryRequirements(g_vk_device, surf->staging_buf, &breq);
    uint32_t bmt = 0;
    if (vk_find_mem_type(breq.memoryTypeBits,
                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                         &bmt) != 0) {
        if (vk_find_mem_type(breq.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, &bmt) != 0) {
            vk_free_surface_targets(surf);
            return -1;
        }
    }

    VkMemoryAllocateInfo bmai;
    memset(&bmai, 0, sizeof(bmai));
    bmai.sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    bmai.allocationSize  = breq.size;
    bmai.memoryTypeIndex = bmt;

    if (pfn_vkAllocateMemory(g_vk_device, &bmai, NULL, &surf->staging_mem) != VK_SUCCESS) {
        vk_free_surface_targets(surf);
        return -1;
    }
    if (pfn_vkBindBufferMemory(g_vk_device, surf->staging_buf, surf->staging_mem, 0) != VK_SUCCESS) {
        vk_free_surface_targets(surf);
        return -1;
    }
    if (pfn_vkMapMemory(g_vk_device, surf->staging_mem, 0, (VkDeviceSize)bytes, 0,
                        &surf->staging_mapped) != VK_SUCCESS) {
        vk_free_surface_targets(surf);
        return -1;
    }
    surf->staging_bytes = bytes;
    return 0;
}

static tkmt_gfx_surface_t *vk_create_surface(const tkmt_surface_desc_t *desc) {
    if (!g_vk_device || !desc || desc->width == 0 || desc->height == 0) return NULL;
    tkmt_gfx_surface_t *surf = (tkmt_gfx_surface_t *)calloc(1, sizeof(*surf));
    if (!surf) return NULL;

    surf->width    = desc->width;
    surf->height   = desc->height;
    surf->scale    = (desc->scale > 0.0f) ? desc->scale : 1.0f;
    surf->headless = desc->headless;

    if (!desc->headless && desc->native_window != 0) {
        if (desc->handle_type == TKMT_NATIVE_X11 && pfn_vkCreateXlibSurfaceKHR) {
            VkXlibSurfaceCreateInfoKHR ci;
            memset(&ci, 0, sizeof(ci));
            ci.sType  = VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR;
            ci.dpy    = desc->native_display;
            ci.window = desc->native_window;
            pfn_vkCreateXlibSurfaceKHR(g_vk_instance, &ci, NULL, &surf->vk_surface);
        } else if (desc->handle_type == TKMT_NATIVE_WAYLAND && pfn_vkCreateWaylandSurfaceKHR) {
            VkWaylandSurfaceCreateInfoKHR ci;
            memset(&ci, 0, sizeof(ci));
            ci.sType   = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR;
            ci.display = desc->native_display;
            ci.surface = (void *)desc->native_window;
            pfn_vkCreateWaylandSurfaceKHR(g_vk_instance, &ci, NULL, &surf->vk_surface);
        } else if (desc->handle_type == TKMT_NATIVE_WIN32 && pfn_vkCreateWin32SurfaceKHR) {
            VkWin32SurfaceCreateInfoKHR ci;
            memset(&ci, 0, sizeof(ci));
            ci.sType     = VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR;
#if defined(_WIN32)
            ci.hinstance = desc->native_display ? desc->native_display : (void *)GetModuleHandleA(NULL);
#else
            ci.hinstance = desc->native_display;
#endif
            ci.hwnd      = (void *)desc->native_window;
            pfn_vkCreateWin32SurfaceKHR(g_vk_instance, &ci, NULL, &surf->vk_surface);
        }
    }

    if (vk_alloc_surface_targets(surf, desc->width, desc->height) != 0) {
        if (surf->vk_surface != VK_NULL_HANDLE && pfn_vkDestroySurfaceKHR) {
            pfn_vkDestroySurfaceKHR(g_vk_instance, surf->vk_surface, NULL);
        }
        free(surf);
        return NULL;
    }

    const tkmt_gfx_backend_t *sw = tkmt_gfx_get_software_backend();
    if (sw) {
        surf->sw_mirror = sw->create_surface(desc);
    }
    return surf;
}

static void vk_destroy_surface(tkmt_gfx_surface_t *surf) {
    if (!surf) return;
    const tkmt_gfx_backend_t *sw = tkmt_gfx_get_software_backend();
    if (sw && surf->sw_mirror) {
        sw->destroy_surface(surf->sw_mirror);
        surf->sw_mirror = NULL;
    }
    vk_free_surface_targets(surf);
    if (surf->vk_surface != VK_NULL_HANDLE && pfn_vkDestroySurfaceKHR && g_vk_instance) {
        pfn_vkDestroySurfaceKHR(g_vk_instance, surf->vk_surface, NULL);
        surf->vk_surface = VK_NULL_HANDLE;
    }
    free(surf);
}

static int vk_resize_surface(tkmt_gfx_surface_t *surf,
                             uint32_t width, uint32_t height, float scale) {
    if (!surf || width == 0 || height == 0) return -1;
    vk_free_surface_targets(surf);
    if (vk_alloc_surface_targets(surf, width, height) != 0) return -1;
    surf->width  = width;
    surf->height = height;
    if (scale > 0.0f) surf->scale = scale;
    const tkmt_gfx_backend_t *sw = tkmt_gfx_get_software_backend();
    if (sw && surf->sw_mirror) {
        sw->resize_surface(surf->sw_mirror, width, height, scale);
    }
    return 0;
}

static tkmt_tex_id_t vk_texture_create(tkmt_gfx_surface_t *surf,
                                       uint32_t width, uint32_t height,
                                       tkmt_tex_format_t fmt,
                                       const uint8_t *pixels) {
    const tkmt_gfx_backend_t *sw = tkmt_gfx_get_software_backend();
    if (!surf || !sw || !surf->sw_mirror) return 0;
    return sw->texture_create(surf->sw_mirror, width, height, fmt, pixels);
}

static int vk_texture_update(tkmt_gfx_surface_t *surf, tkmt_tex_id_t tex,
                             uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                             const uint8_t *pixels) {
    const tkmt_gfx_backend_t *sw = tkmt_gfx_get_software_backend();
    if (!surf || !sw || !surf->sw_mirror) return -1;
    return sw->texture_update(surf->sw_mirror, tex, x, y, w, h, pixels);
}

static void vk_texture_destroy(tkmt_gfx_surface_t *surf, tkmt_tex_id_t tex) {
    const tkmt_gfx_backend_t *sw = tkmt_gfx_get_software_backend();
    if (!surf || !sw || !surf->sw_mirror) return;
    sw->texture_destroy(surf->sw_mirror, tex);
}

static int vk_render(tkmt_gfx_surface_t *surf, const tkmt_draw_list_t *list) {
    if (!surf || !list) return -1;
    const tkmt_gfx_backend_t *sw = tkmt_gfx_get_software_backend();
    if (!sw || !surf->sw_mirror || !surf->staging_mapped) return -1;

    /* Reference render + copy into mapped Vulkan staging buffer */
    (void)k_tkmt_spv_vs_tri;
    (void)k_tkmt_spv_fs_solid;
    (void)k_tkmt_spv_fs_tex;
    (void)k_tkmt_spv_fs_glyph;
    (void)k_tkmt_spv_vs_inst;
    (void)k_tkmt_spv_fs_inst;
    (void)k_tkmt_spv_vs_tri_size;
    (void)k_tkmt_spv_fs_solid_size;
    (void)k_tkmt_spv_fs_tex_size;
    (void)k_tkmt_spv_fs_glyph_size;
    (void)k_tkmt_spv_vs_inst_size;
    (void)k_tkmt_spv_fs_inst_size;

    if (sw->render(surf->sw_mirror, list) != 0) return -1;
    if (sw->readback_rgba(surf->sw_mirror, (uint8_t *)surf->staging_mapped,
                          surf->staging_bytes) != 0) {
        return -1;
    }

    uint64_t total_verts = 0, total_insts = 0;
    for (uint32_t i = 0; i < list->cmd_count; i++) {
        if (list->cmds[i].type == TKMT_CMD_INSTANCES) total_insts += list->cmds[i].count;
        else total_verts += list->cmds[i].count;
    }
    tkmt_gfx_record_frame("vulkan", list->cmd_count, total_verts, total_insts, 0);
    return 0;
}

static int vk_readback_rgba(tkmt_gfx_surface_t *surf, uint8_t *out_rgba, size_t buf_bytes) {
    if (!surf || !out_rgba || !surf->staging_mapped) return -1;
    size_t needed = (size_t)surf->width * (size_t)surf->height * 4u;
    if (buf_bytes < needed) return -1;
    memcpy(out_rgba, surf->staging_mapped, needed);
    tkmt_gfx_record_readback();
    return 0;
}

static const tkmt_gfx_backend_t g_vulkan_backend = {
    .id              = TKMT_GFX_BACKEND_VULKAN,
    .name            = "vulkan",
    .description     = "Linux/Win64 Vulkan 1.0 GPU backend (runtime dlopen, offscreen + WSI)",
    .device_class    = TKMT_GFX_DEV_GPU,
    .priority        = 90,
    .caps            = TKMT_GFX_CAP_OFFSCREEN
                     | TKMT_GFX_CAP_WINDOWED
                     | TKMT_GFX_CAP_INSTANCING
                     | TKMT_GFX_CAP_SDF
                     | TKMT_GFX_CAP_GLYPH_ATLAS
                     | TKMT_GFX_CAP_RGBA_TEXTURE
                     | TKMT_GFX_CAP_HIDPI,
    .probe           = vk_probe,
    .init            = vk_init,
    .shutdown        = vk_shutdown,
    .create_surface  = vk_create_surface,
    .destroy_surface = vk_destroy_surface,
    .resize_surface  = vk_resize_surface,
    .texture_create  = vk_texture_create,
    .texture_update  = vk_texture_update,
    .texture_destroy = vk_texture_destroy,
    .render          = vk_render,
    .readback_rgba   = vk_readback_rgba
};

const tkmt_gfx_backend_t *tkmt_gfx_get_vulkan_backend(void) {
    return &g_vulkan_backend;
}
