/*
 * Tcl::Tk::MT - Graphics Backend Registry, Runtime Probing, Telemetry & SHA-256
 *
 * Pure C11 implementation modeled on perl5-mt/accel/perl_accel.c.
 */

#include "../tkmt_thread.h"
#include "tkmt_gfx.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* -------------------------------------------------------------------------
 * Non-darwin stub for Metal backend so Linux/Win64 link cleanly
 * ------------------------------------------------------------------------- */
#if !defined(__APPLE__)
const tkmt_gfx_backend_t *tkmt_gfx_get_metal_backend(void) {
    return NULL;
}
#endif

/* -------------------------------------------------------------------------
 * Registry state
 * ------------------------------------------------------------------------- */

#define TKMT_MAX_BACKENDS 16

static const tkmt_gfx_backend_t *g_backends[TKMT_MAX_BACKENDS];
static int                       g_backend_avail[TKMT_MAX_BACKENDS];
static int                       g_backend_inited[TKMT_MAX_BACKENDS];
static size_t                    g_backend_count = 0;

static const tkmt_gfx_backend_t *g_active_backend = NULL;
static int                       g_initialized    = 0;
static int                       g_enabled        = 1;

static _Atomic uint64_t g_stat_frames    = 0;
static _Atomic uint64_t g_stat_draws     = 0;
static _Atomic uint64_t g_stat_verts     = 0;
static _Atomic uint64_t g_stat_instances = 0;
static _Atomic uint64_t g_stat_offload   = 0;
static _Atomic uint64_t g_stat_fallback  = 0;
static _Atomic uint64_t g_stat_readback  = 0;
static _Atomic(const char *) g_stat_last_backend = NULL;

static tkmt_static_mutex_t g_reg_lock = TKMT_STATIC_MUTEX_INIT;
static void reg_lock(void)   { tkmt_static_mutex_lock(&g_reg_lock); }
static void reg_unlock(void) { tkmt_static_mutex_unlock(&g_reg_lock); }

static int ascii_strcasecmp(const char *a, const char *b) {
    if (!a || !b) return (a == b) ? 0 : (a ? 1 : -1);
    while (*a && *b) {
        int ca = tolower((unsigned char)*a);
        int cb = tolower((unsigned char)*b);
        if (ca != cb) return ca - cb;
        a++;
        b++;
    }
    return tolower((unsigned char)*a) - tolower((unsigned char)*b);
}

static int env_is_truthy(const char *val) {
    if (!val || !*val) return 0;
    if (strcmp(val, "0") == 0) return 0;
    if (ascii_strcasecmp(val, "false") == 0) return 0;
    if (ascii_strcasecmp(val, "no") == 0) return 0;
    if (ascii_strcasecmp(val, "off") == 0) return 0;
    return 1;
}

static int register_locked(const tkmt_gfx_backend_t *backend) {
    if (!backend || !backend->name) return -1;
    for (size_t i = 0; i < g_backend_count; i++) {
        if (g_backends[i] == backend ||
            ascii_strcasecmp(g_backends[i]->name, backend->name) == 0) {
            return 0; /* already registered */
        }
    }
    if (g_backend_count >= TKMT_MAX_BACKENDS) return -1;
    g_backends[g_backend_count]      = backend;
    g_backend_avail[g_backend_count] = backend->probe ? (backend->probe() ? 1 : 0) : 1;
    g_backend_inited[g_backend_count] = 0;
    g_backend_count++;
    return 0;
}

static int ensure_backend_inited_locked(size_t idx) {
    if (idx >= g_backend_count) return -1;
    if (!g_backend_avail[idx]) return -1;
    if (g_backend_inited[idx]) return 0;
    if (g_backends[idx]->init) {
        if (g_backends[idx]->init() != 0) {
            g_backend_avail[idx] = 0;
            return -1;
        }
    }
    g_backend_inited[idx] = 1;
    return 0;
}

static void select_active_locked(const char *mode_override) {
    const char *mode = mode_override;
    if (!mode || !*mode) {
        mode = getenv("TCL_TK_MT_ACCEL");
    }
    if (!mode || !*mode) {
        mode = "auto";
    }

    const char *force_scalar_env = getenv("PERL_FORCE_SCALAR");
    int force_scalar = env_is_truthy(force_scalar_env);

    g_enabled        = 1;
    g_active_backend = NULL;

    /* Find software backend index as guaranteed fallback */
    size_t sw_idx = TKMT_MAX_BACKENDS;
    for (size_t i = 0; i < g_backend_count; i++) {
        if (g_backends[i]->id == TKMT_GFX_BACKEND_SOFTWARE) {
            sw_idx = i;
            break;
        }
    }

    if (ascii_strcasecmp(mode, "off") == 0 || ascii_strcasecmp(mode, "none") == 0) {
        g_enabled = 0;
        if (sw_idx < g_backend_count && ensure_backend_inited_locked(sw_idx) == 0) {
            g_active_backend = g_backends[sw_idx];
        }
        return;
    }

    if (force_scalar || ascii_strcasecmp(mode, "software") == 0 ||
        ascii_strcasecmp(mode, "cpu") == 0 || ascii_strcasecmp(mode, "scalar") == 0) {
        if (sw_idx < g_backend_count && ensure_backend_inited_locked(sw_idx) == 0) {
            g_active_backend = g_backends[sw_idx];
        }
        return;
    }

    if (ascii_strcasecmp(mode, "auto") != 0) {
        /* Explicit backend requested (e.g. "metal" or "vulkan") */
        for (size_t i = 0; i < g_backend_count; i++) {
            if (ascii_strcasecmp(g_backends[i]->name, mode) == 0) {
                if (ensure_backend_inited_locked(i) == 0) {
                    g_active_backend = g_backends[i];
                    return;
                }
                break;
            }
        }
        /* Requested backend unavailable; fall back to software twin */
        if (sw_idx < g_backend_count && ensure_backend_inited_locked(sw_idx) == 0) {
            g_active_backend = g_backends[sw_idx];
        }
        return;
    }

    /* auto: pick highest-priority available backend that initializes cleanly */
    while (1) {
        size_t best_idx = TKMT_MAX_BACKENDS;
        int    best_pri = -2147483647;
        for (size_t i = 0; i < g_backend_count; i++) {
            if (!g_backend_avail[i]) continue;
            if (g_backends[i]->priority > best_pri) {
                best_pri = g_backends[i]->priority;
                best_idx = i;
            }
        }
        if (best_idx == TKMT_MAX_BACKENDS) break;
        if (ensure_backend_inited_locked(best_idx) == 0) {
            g_active_backend = g_backends[best_idx];
            return;
        }
        /* init failed -> g_backend_avail[best_idx] was cleared; try next best */
    }
}

static void init_locked(const char *mode_override) {
    if (!g_initialized) {
        const tkmt_gfx_backend_t *sw = tkmt_gfx_get_software_backend();
        const tkmt_gfx_backend_t *mt = tkmt_gfx_get_metal_backend();
        const tkmt_gfx_backend_t *vk = tkmt_gfx_get_vulkan_backend();
        if (sw) register_locked(sw);
        if (mt) register_locked(mt);
        if (vk) register_locked(vk);
        g_initialized = 1;
    }
    select_active_locked(mode_override);
}

int tkmt_gfx_init(void) {
    reg_lock();
    if (!g_initialized) {
        init_locked(NULL);
    }
    int ok = (g_active_backend != NULL) ? 0 : -1;
    reg_unlock();
    return ok;
}

void tkmt_gfx_shutdown(void) {
    reg_lock();
    for (size_t i = 0; i < g_backend_count; i++) {
        if (g_backend_inited[i] && g_backends[i] && g_backends[i]->shutdown) {
            g_backends[i]->shutdown();
        }
        g_backend_inited[i] = 0;
        g_backend_avail[i]  = 0;
        g_backends[i]       = NULL;
    }
    g_backend_count  = 0;
    g_active_backend = NULL;
    g_initialized    = 0;
    g_enabled        = 1;
    reg_unlock();
}

int tkmt_gfx_register(const tkmt_gfx_backend_t *backend) {
    reg_lock();
    int rc = register_locked(backend);
    reg_unlock();
    return rc;
}

const tkmt_gfx_backend_t *tkmt_gfx_active(void) {
    reg_lock();
    if (!g_initialized) {
        init_locked(NULL);
    }
    const tkmt_gfx_backend_t *b = g_active_backend;
    reg_unlock();
    return b;
}

const tkmt_gfx_backend_t *tkmt_gfx_find(const char *name) {
    if (!name) return NULL;
    reg_lock();
    if (!g_initialized) {
        init_locked(NULL);
    }
    const tkmt_gfx_backend_t *found = NULL;
    for (size_t i = 0; i < g_backend_count; i++) {
        if (ascii_strcasecmp(g_backends[i]->name, name) == 0) {
            if (ensure_backend_inited_locked(i) == 0) {
                found = g_backends[i];
            }
            break;
        }
    }
    reg_unlock();
    return found;
}

size_t tkmt_gfx_list(const tkmt_gfx_backend_t **out, size_t max_out) {
    reg_lock();
    if (!g_initialized) {
        init_locked(NULL);
    }
    size_t n = g_backend_count;
    if (out && max_out > 0) {
        size_t copy_n = (n < max_out) ? n : max_out;
        for (size_t i = 0; i < copy_n; i++) {
            out[i] = g_backends[i];
        }
    }
    reg_unlock();
    return n;
}

int tkmt_gfx_backend_available(const char *name) {
    if (!name) return 0;
    reg_lock();
    if (!g_initialized) {
        init_locked(NULL);
    }
    int avail = 0;
    for (size_t i = 0; i < g_backend_count; i++) {
        if (ascii_strcasecmp(g_backends[i]->name, name) == 0) {
            avail = g_backend_avail[i];
            break;
        }
    }
    reg_unlock();
    return avail;
}

int tkmt_gfx_is_enabled(void) {
    reg_lock();
    if (!g_initialized) {
        init_locked(NULL);
    }
    int en = g_enabled;
    reg_unlock();
    return en;
}

void tkmt_gfx_get_stats(tkmt_gfx_stats_t *out) {
    if (!out) return;
    out->frames_rendered     = atomic_load_explicit(&g_stat_frames, memory_order_relaxed);
    out->draw_calls          = atomic_load_explicit(&g_stat_draws, memory_order_relaxed);
    out->vertices_submitted  = atomic_load_explicit(&g_stat_verts, memory_order_relaxed);
    out->instances_submitted = atomic_load_explicit(&g_stat_instances, memory_order_relaxed);
    out->offload_calls       = atomic_load_explicit(&g_stat_offload, memory_order_relaxed);
    out->fallback_calls      = atomic_load_explicit(&g_stat_fallback, memory_order_relaxed);
    out->readback_calls      = atomic_load_explicit(&g_stat_readback, memory_order_relaxed);
    out->last_backend_name   = atomic_load_explicit(&g_stat_last_backend, memory_order_relaxed);
}

void tkmt_gfx_reset_stats(void) {
    atomic_store_explicit(&g_stat_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&g_stat_draws, 0, memory_order_relaxed);
    atomic_store_explicit(&g_stat_verts, 0, memory_order_relaxed);
    atomic_store_explicit(&g_stat_instances, 0, memory_order_relaxed);
    atomic_store_explicit(&g_stat_offload, 0, memory_order_relaxed);
    atomic_store_explicit(&g_stat_fallback, 0, memory_order_relaxed);
    atomic_store_explicit(&g_stat_readback, 0, memory_order_relaxed);
    atomic_store_explicit(&g_stat_last_backend, NULL, memory_order_relaxed);
}

void tkmt_gfx_reset_for_test(const char *mode_override) {
    tkmt_gfx_reset_stats();
    reg_lock();
    for (size_t i = 0; i < g_backend_count; i++) {
        if (g_backend_inited[i] && g_backends[i] && g_backends[i]->shutdown) {
            g_backends[i]->shutdown();
        }
        g_backend_inited[i] = 0;
        g_backend_avail[i]  = 0;
        g_backends[i]       = NULL;
    }
    g_backend_count  = 0;
    g_active_backend = NULL;
    g_initialized    = 0;
    g_enabled        = 1;
    init_locked(mode_override);
    reg_unlock();
}

void tkmt_gfx_record_frame(const char *backend_name, uint32_t draw_calls,
                           uint64_t vertices, uint64_t instances, int is_fallback) {
    atomic_fetch_add_explicit(&g_stat_frames, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&g_stat_draws, draw_calls, memory_order_relaxed);
    atomic_fetch_add_explicit(&g_stat_verts, vertices, memory_order_relaxed);
    atomic_fetch_add_explicit(&g_stat_instances, instances, memory_order_relaxed);
    if (is_fallback) {
        atomic_fetch_add_explicit(&g_stat_fallback, 1, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(&g_stat_offload, 1, memory_order_relaxed);
    }
    atomic_store_explicit(&g_stat_last_backend, backend_name, memory_order_relaxed);
}

void tkmt_gfx_record_readback(void) {
    atomic_fetch_add_explicit(&g_stat_readback, 1, memory_order_relaxed);
}

/* -------------------------------------------------------------------------
 * Pure C11 SHA-256 (FIPS 180-4) for deterministic offscreen readback parity
 * ------------------------------------------------------------------------- */

static const uint32_t k_sha256[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u
};

static inline uint32_t rotr32(uint32_t x, uint32_t n) {
    return (x >> n) | (x << (32u - n));
}

static void sha256_transform(uint32_t state[8], const uint8_t block[64]) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)block[i * 4 + 0] << 24)
             | ((uint32_t)block[i * 4 + 1] << 16)
             | ((uint32_t)block[i * 4 + 2] << 8)
             | ((uint32_t)block[i * 4 + 3]);
    }
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
    uint32_t e = state[4], f = state[5], g = state[6], h = state[7];

    for (int i = 0; i < 64; i++) {
        uint32_t S1    = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
        uint32_t ch    = (e & f) ^ ((~e) & g);
        uint32_t temp1 = h + S1 + ch + k_sha256[i] + w[i];
        uint32_t S0    = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        uint32_t maj   = (a & b) ^ (a & c) ^ (b & c);
        uint32_t temp2 = S0 + maj;

        h = g; g = f; f = e; e = d + temp1;
        d = c; c = b; b = a; a = temp1 + temp2;
    }

    state[0] += a; state[1] += b; state[2] += c; state[3] += d;
    state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

void tkmt_gfx_sha256_hex(const uint8_t *data, size_t len, char out_hex[65]) {
    uint32_t state[8] = {
        0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
        0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u
    };

    size_t offset = 0;
    while (len - offset >= 64) {
        sha256_transform(state, data + offset);
        offset += 64;
    }

    uint8_t tail[128];
    memset(tail, 0, sizeof(tail));
    size_t rem = len - offset;
    if (rem > 0 && data) {
        memcpy(tail, data + offset, rem);
    }
    tail[rem] = 0x80u;

    size_t pad_len = (rem < 56) ? 64 : 128;
    uint64_t bit_len = (uint64_t)len * 8u;
    for (int i = 0; i < 8; i++) {
        tail[pad_len - 1 - i] = (uint8_t)(bit_len >> (i * 8));
    }

    sha256_transform(state, tail);
    if (pad_len == 128) {
        sha256_transform(state, tail + 64);
    }

    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 8; i++) {
        for (int j = 7; j >= 0; j--) {
            out_hex[i * 8 + (7 - j)] = hex[(state[i] >> (j * 4)) & 0xFu];
        }
    }
    out_hex[64] = '\0';
}
