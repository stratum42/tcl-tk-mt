/*
 * Tcl::Tk::MT - Glyph & Text Atlas (C11)
 *
 * Uses FreeType + HarfBuzz when TKMT_HAVE_FREETYPE_HARFBUZZ is defined and a
 * system font is available, with a built-in zero-dependency 8x8 bitmap font
 * fallback so builds and headless tests never fail on any platform.
 */

#include "scene.h"

#include <ctype.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifdef TKMT_HAVE_FREETYPE_HARFBUZZ
#include <ft2build.h>
#include FT_FREETYPE_H
#include <hb.h>
#include <hb-ft.h>
#endif

/* -------------------------------------------------------------------------
 * Built-in 8x8 ASCII (32..126) bitmap font (LSB = leftmost pixel)
 * ------------------------------------------------------------------------- */

static const uint8_t k_font8x8[95][8] = {
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* 32 ' ' */
    {0x18,0x3C,0x3C,0x18,0x18,0x00,0x18,0x00}, /* 33 '!' */
    {0x36,0x36,0x14,0x00,0x00,0x00,0x00,0x00}, /* 34 '"' */
    {0x36,0x36,0x7F,0x36,0x7F,0x36,0x36,0x00}, /* 35 '#' */
    {0x0C,0x3E,0x03,0x1E,0x30,0x1F,0x0C,0x00}, /* 36 '$' */
    {0x00,0x63,0x33,0x18,0x0C,0x66,0x63,0x00}, /* 37 '%' */
    {0x1C,0x36,0x1C,0x6E,0x3B,0x33,0x6E,0x00}, /* 38 '&' */
    {0x06,0x06,0x03,0x00,0x00,0x00,0x00,0x00}, /* 39 '\'' */
    {0x18,0x0C,0x06,0x06,0x06,0x0C,0x18,0x00}, /* 40 '(' */
    {0x06,0x0C,0x18,0x18,0x18,0x0C,0x06,0x00}, /* 41 ')' */
    {0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00}, /* 42 '*' */
    {0x00,0x0C,0x0C,0x3F,0x0C,0x0C,0x00,0x00}, /* 43 '+' */
    {0x00,0x00,0x00,0x00,0x00,0x0C,0x0C,0x06}, /* 44 ',' */
    {0x00,0x00,0x00,0x3F,0x00,0x00,0x00,0x00}, /* 45 '-' */
    {0x00,0x00,0x00,0x00,0x00,0x0C,0x0C,0x00}, /* 46 '.' */
    {0x60,0x30,0x18,0x0C,0x06,0x03,0x01,0x00}, /* 47 '/' */
    {0x3E,0x63,0x73,0x7B,0x6F,0x67,0x3E,0x00}, /* 48 '0' */
    {0x0C,0x0E,0x0C,0x0C,0x0C,0x0C,0x3F,0x00}, /* 49 '1' */
    {0x1E,0x33,0x30,0x1C,0x06,0x33,0x3F,0x00}, /* 50 '2' */
    {0x1E,0x33,0x30,0x1C,0x30,0x33,0x1E,0x00}, /* 51 '3' */
    {0x38,0x3C,0x36,0x33,0x7F,0x30,0x78,0x00}, /* 52 '4' */
    {0x3F,0x03,0x1F,0x30,0x30,0x33,0x1E,0x00}, /* 53 '5' */
    {0x1C,0x06,0x03,0x1F,0x33,0x33,0x1E,0x00}, /* 54 '6' */
    {0x3F,0x33,0x30,0x18,0x0C,0x0C,0x0C,0x00}, /* 55 '7' */
    {0x1E,0x33,0x33,0x1E,0x33,0x33,0x1E,0x00}, /* 56 '8' */
    {0x1E,0x33,0x33,0x3E,0x30,0x18,0x0E,0x00}, /* 57 '9' */
    {0x00,0x0C,0x0C,0x00,0x00,0x0C,0x0C,0x00}, /* 58 ':' */
    {0x00,0x0C,0x0C,0x00,0x00,0x0C,0x0C,0x06}, /* 59 ';' */
    {0x18,0x0C,0x06,0x03,0x06,0x0C,0x18,0x00}, /* 60 '<' */
    {0x00,0x00,0x3F,0x00,0x00,0x3F,0x00,0x00}, /* 61 '=' */
    {0x06,0x0C,0x18,0x30,0x18,0x0C,0x06,0x00}, /* 62 '>' */
    {0x1E,0x33,0x30,0x18,0x0C,0x00,0x0C,0x00}, /* 63 '?' */
    {0x3E,0x63,0x7B,0x7B,0x7B,0x03,0x1E,0x00}, /* 64 '@' */
    {0x0C,0x1E,0x33,0x33,0x3F,0x33,0x33,0x00}, /* 65 'A' */
    {0x3F,0x66,0x66,0x3E,0x66,0x66,0x3F,0x00}, /* 66 'B' */
    {0x3C,0x66,0x03,0x03,0x03,0x66,0x3C,0x00}, /* 67 'C' */
    {0x1F,0x36,0x66,0x66,0x66,0x36,0x1F,0x00}, /* 68 'D' */
    {0x7F,0x46,0x16,0x1E,0x16,0x46,0x7F,0x00}, /* 69 'E' */
    {0x7F,0x46,0x16,0x1E,0x16,0x06,0x0F,0x00}, /* 70 'F' */
    {0x3C,0x66,0x03,0x03,0x73,0x66,0x7C,0x00}, /* 71 'G' */
    {0x33,0x33,0x33,0x3F,0x33,0x33,0x33,0x00}, /* 72 'H' */
    {0x1E,0x0C,0x0C,0x0C,0x0C,0x0C,0x1E,0x00}, /* 73 'I' */
    {0x78,0x30,0x30,0x30,0x33,0x33,0x1E,0x00}, /* 74 'J' */
    {0x67,0x66,0x36,0x1E,0x36,0x66,0x67,0x00}, /* 75 'K' */
    {0x0F,0x06,0x06,0x06,0x46,0x66,0x7F,0x00}, /* 76 'L' */
    {0x63,0x77,0x7F,0x7F,0x6B,0x63,0x63,0x00}, /* 77 'M' */
    {0x63,0x67,0x6F,0x7B,0x73,0x63,0x63,0x00}, /* 78 'N' */
    {0x1C,0x36,0x63,0x63,0x63,0x36,0x1C,0x00}, /* 79 'O' */
    {0x3F,0x66,0x66,0x3E,0x06,0x06,0x0F,0x00}, /* 80 'P' */
    {0x1E,0x33,0x33,0x33,0x3B,0x1E,0x38,0x00}, /* 81 'Q' */
    {0x3F,0x66,0x66,0x3E,0x36,0x66,0x67,0x00}, /* 82 'R' */
    {0x1E,0x33,0x07,0x0E,0x38,0x33,0x1E,0x00}, /* 83 'S' */
    {0x3F,0x2D,0x0C,0x0C,0x0C,0x0C,0x1E,0x00}, /* 84 'T' */
    {0x33,0x33,0x33,0x33,0x33,0x33,0x3F,0x00}, /* 85 'U' */
    {0x33,0x33,0x33,0x33,0x33,0x1E,0x0C,0x00}, /* 86 'V' */
    {0x63,0x63,0x63,0x6B,0x7F,0x77,0x63,0x00}, /* 87 'W' */
    {0x63,0x63,0x36,0x1C,0x1C,0x36,0x63,0x00}, /* 88 'X' */
    {0x33,0x33,0x33,0x1E,0x0C,0x0C,0x1E,0x00}, /* 89 'Y' */
    {0x7F,0x63,0x31,0x18,0x4C,0x66,0x7F,0x00}, /* 90 'Z' */
    {0x1E,0x06,0x06,0x06,0x06,0x06,0x1E,0x00}, /* 91 '[' */
    {0x03,0x06,0x0C,0x18,0x30,0x60,0x40,0x00}, /* 92 '\' */
    {0x1E,0x18,0x18,0x18,0x18,0x18,0x1E,0x00}, /* 93 ']' */
    {0x08,0x1C,0x36,0x63,0x00,0x00,0x00,0x00}, /* 94 '^' */
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFF}, /* 95 '_' */
    {0x0C,0x0C,0x18,0x00,0x00,0x00,0x00,0x00}, /* 96 '`' */
    {0x00,0x00,0x1E,0x30,0x3E,0x33,0x6E,0x00}, /* 97 'a' */
    {0x07,0x06,0x06,0x3E,0x66,0x66,0x3B,0x00}, /* 98 'b' */
    {0x00,0x00,0x1E,0x33,0x03,0x33,0x1E,0x00}, /* 99 'c' */
    {0x38,0x30,0x30,0x3E,0x33,0x33,0x6E,0x00}, /* 100 'd' */
    {0x00,0x00,0x1E,0x33,0x3F,0x03,0x1E,0x00}, /* 101 'e' */
    {0x1C,0x36,0x06,0x0F,0x06,0x06,0x0F,0x00}, /* 102 'f' */
    {0x00,0x00,0x6E,0x33,0x33,0x3E,0x30,0x1F}, /* 103 'g' */
    {0x07,0x06,0x36,0x6E,0x66,0x66,0x67,0x00}, /* 104 'h' */
    {0x0C,0x00,0x0E,0x0C,0x0C,0x0C,0x1E,0x00}, /* 105 'i' */
    {0x30,0x00,0x30,0x30,0x30,0x33,0x33,0x1E}, /* 106 'j' */
    {0x07,0x06,0x66,0x36,0x1E,0x36,0x67,0x00}, /* 107 'k' */
    {0x0E,0x0C,0x0C,0x0C,0x0C,0x0C,0x1E,0x00}, /* 108 'l' */
    {0x00,0x00,0x33,0x7F,0x7F,0x6B,0x63,0x00}, /* 109 'm' */
    {0x00,0x00,0x1F,0x33,0x33,0x33,0x33,0x00}, /* 110 'n' */
    {0x00,0x00,0x1E,0x33,0x33,0x33,0x1E,0x00}, /* 111 'o' */
    {0x00,0x00,0x3B,0x66,0x66,0x3E,0x06,0x0F}, /* 112 'p' */
    {0x00,0x00,0x6E,0x33,0x33,0x3E,0x30,0x78}, /* 113 'q' */
    {0x00,0x00,0x3B,0x6E,0x66,0x06,0x0F,0x00}, /* 114 'r' */
    {0x00,0x00,0x3E,0x03,0x1E,0x30,0x1F,0x00}, /* 115 's' */
    {0x08,0x0C,0x3E,0x0C,0x0C,0x2C,0x18,0x00}, /* 116 't' */
    {0x00,0x00,0x33,0x33,0x33,0x33,0x6E,0x00}, /* 117 'u' */
    {0x00,0x00,0x33,0x33,0x33,0x1E,0x0C,0x00}, /* 118 'v' */
    {0x00,0x00,0x63,0x6B,0x7F,0x7F,0x36,0x00}, /* 119 'w' */
    {0x00,0x00,0x63,0x36,0x1C,0x36,0x63,0x00}, /* 120 'x' */
    {0x00,0x00,0x33,0x33,0x33,0x3E,0x30,0x1F}, /* 121 'y' */
    {0x00,0x00,0x3F,0x19,0x0C,0x26,0x3F,0x00}, /* 122 'z' */
    {0x38,0x0C,0x0C,0x07,0x0C,0x0C,0x38,0x00}, /* 123 '{' */
    {0x18,0x18,0x18,0x00,0x18,0x18,0x18,0x00}, /* 124 '|' */
    {0x07,0x0C,0x0C,0x38,0x0C,0x0C,0x07,0x00}, /* 125 '}' */
    {0x6E,0x3B,0x00,0x00,0x00,0x00,0x00,0x00}, /* 126 '~' */
};

/* -------------------------------------------------------------------------
 * Atlas cache structures
 * ------------------------------------------------------------------------- */

#define ATLAS_HASH_BUCKETS 2048
#define ATLAS_FACE_SANS    0
#define ATLAS_FACE_MONO    1
#define ATLAS_FACE_COUNT   2

typedef struct atlas_glyph_entry {
    uint64_t key; /* (is_ft << 63) | (face_idx << 60) | (phys_px << 32) | codepoint_or_gid */
    float    u0, v0, u1, v1;
    float    bearing_x;
    float    bearing_y;
    float    width;
    float    height;
    float    advance;
    int      occupied;
} atlas_glyph_entry_t;

#ifdef TKMT_HAVE_FREETYPE_HARFBUZZ
typedef struct atlas_ft_face {
    FT_Face    face;
    hb_font_t *hb_font;
    uint32_t   cur_px;
    int        ready;
} atlas_ft_face_t;
#endif

struct tkmt_atlas {
    uint32_t            width;
    uint32_t            height;
    uint8_t            *pixels; /* R8 coverage buffer */
    float               dpi_scale;

    /* Shelf packer state */
    uint32_t            cursor_x;
    uint32_t            cursor_y;
    uint32_t            shelf_h;

    /* Texture sync state */
    tkmt_tex_id_t       tex_id;
    tkmt_gfx_surface_t *bound_surf;
    int                 dirty;
    uint32_t            dirty_x0, dirty_y0, dirty_x1, dirty_y1;

    /* Open-addressing glyph cache */
    atlas_glyph_entry_t entries[ATLAS_HASH_BUCKETS];
    uint32_t            entry_count;

#ifdef TKMT_HAVE_FREETYPE_HARFBUZZ
    FT_Library          ft_lib;
    atlas_ft_face_t     faces[ATLAS_FACE_COUNT];
    int                 ft_ready;
#endif
};

static uint64_t hash_u64(uint64_t x) {
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;
    return x;
}

static void atlas_mark_dirty(tkmt_atlas_t *a, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    if (!a->dirty) {
        a->dirty    = 1;
        a->dirty_x0 = x;
        a->dirty_y0 = y;
        a->dirty_x1 = x + w;
        a->dirty_y1 = y + h;
    } else {
        if (x < a->dirty_x0)     a->dirty_x0 = x;
        if (y < a->dirty_y0)     a->dirty_y0 = y;
        if (x + w > a->dirty_x1) a->dirty_x1 = x + w;
        if (y + h > a->dirty_y1) a->dirty_y1 = y + h;
    }
}

static void atlas_reset_packing(tkmt_atlas_t *a) {
    memset(a->pixels, 0, (size_t)a->width * (size_t)a->height);
    memset(a->entries, 0, sizeof(a->entries));
    a->entry_count = 0;
    a->cursor_x    = 1;
    a->cursor_y    = 1;
    a->shelf_h     = 0;
    atlas_mark_dirty(a, 0, 0, a->width, a->height);
}

static int atlas_alloc_rect(tkmt_atlas_t *a, uint32_t w, uint32_t h,
                            uint32_t *out_x, uint32_t *out_y) {
    const uint32_t pad = 1;
    if (w + pad * 2 > a->width || h + pad * 2 > a->height) {
        return 0;
    }
    if (a->cursor_x + w + pad > a->width) {
        a->cursor_x = 1;
        a->cursor_y += a->shelf_h + pad;
        a->shelf_h = 0;
    }
    if (a->cursor_y + h + pad > a->height) {
        /* Atlas full: evict and start fresh */
        atlas_reset_packing(a);
    }
    *out_x = a->cursor_x;
    *out_y = a->cursor_y;
    a->cursor_x += w + pad;
    if (h > a->shelf_h) {
        a->shelf_h = h;
    }
    return 1;
}

static atlas_glyph_entry_t *atlas_find_entry(tkmt_atlas_t *a, uint64_t key) {
    uint32_t idx = (uint32_t)(hash_u64(key) & (ATLAS_HASH_BUCKETS - 1));
    for (uint32_t i = 0; i < ATLAS_HASH_BUCKETS; i++) {
        atlas_glyph_entry_t *e = &a->entries[(idx + i) & (ATLAS_HASH_BUCKETS - 1)];
        if (!e->occupied) {
            return NULL;
        }
        if (e->key == key) {
            return e;
        }
    }
    return NULL;
}

static atlas_glyph_entry_t *atlas_insert_entry(tkmt_atlas_t *a, uint64_t key) {
    if (a->entry_count >= (ATLAS_HASH_BUCKETS * 3) / 4) {
        atlas_reset_packing(a);
    }
    uint32_t idx = (uint32_t)(hash_u64(key) & (ATLAS_HASH_BUCKETS - 1));
    for (uint32_t i = 0; i < ATLAS_HASH_BUCKETS; i++) {
        atlas_glyph_entry_t *e = &a->entries[(idx + i) & (ATLAS_HASH_BUCKETS - 1)];
        if (!e->occupied || e->key == key) {
            if (!e->occupied) {
                e->occupied = 1;
                a->entry_count++;
            }
            e->key = key;
            return e;
        }
    }
    return NULL;
}

/* Decode one UTF-8 codepoint, advancing *p */
static uint32_t utf8_next(const char **p) {
    const uint8_t *s = (const uint8_t *)(*p);
    if (!*s) return 0;
    uint8_t c = s[0];
    if (c < 0x80) {
        *p += 1;
        return c;
    } else if ((c & 0xE0) == 0xC0 && s[1]) {
        *p += 2;
        return ((uint32_t)(c & 0x1F) << 6) | (uint32_t)(s[1] & 0x3F);
    } else if ((c & 0xF0) == 0xE0 && s[1] && s[2]) {
        *p += 3;
        return ((uint32_t)(c & 0x0F) << 12) |
               ((uint32_t)(s[1] & 0x3F) << 6) |
               (uint32_t)(s[2] & 0x3F);
    } else if ((c & 0xF8) == 0xF0 && s[1] && s[2] && s[3]) {
        *p += 4;
        return ((uint32_t)(c & 0x07) << 18) |
               ((uint32_t)(s[1] & 0x3F) << 12) |
               ((uint32_t)(s[2] & 0x3F) << 6) |
               (uint32_t)(s[3] & 0x3F);
    }
    *p += 1;
    return '?';
}

/* Rasterize fallback 8x8 glyph scaled to phys_px */
static atlas_glyph_entry_t *atlas_get_fallback_glyph(tkmt_atlas_t *a,
                                                     uint32_t cp,
                                                     uint32_t px_size) {
    if (cp < 32 || cp > 126) cp = '?';
    if (px_size < 6) px_size = 6;
    if (px_size > 256) px_size = 256;

    uint64_t key = ((uint64_t)(px_size & 0xFFFFu) << 32) | (uint64_t)cp;
    atlas_glyph_entry_t *e = atlas_find_entry(a, key);
    if (e) return e;

    uint32_t gw = px_size;
    uint32_t gh = px_size;
    uint32_t ax = 0, ay = 0;

    if (cp == ' ') {
        e = atlas_insert_entry(a, key);
        if (!e) return NULL;
        e->u0 = e->v0 = e->u1 = e->v1 = 0.0f;
        e->bearing_x = 0.0f;
        e->bearing_y = (float)gh * 0.85f;
        e->width     = 0.0f;
        e->height    = 0.0f;
        e->advance   = floorf((float)gw * 0.85f + 0.5f);
        return e;
    }

    if (!atlas_alloc_rect(a, gw, gh, &ax, &ay)) {
        return NULL;
    }

    const uint8_t *rows = k_font8x8[cp - 32];
    for (uint32_t y = 0; y < gh; y++) {
        uint32_t sy = (y * 8u) / gh;
        if (sy > 7) sy = 7;
        uint8_t bits = rows[sy];
        uint8_t *dst = a->pixels + (size_t)(ay + y) * a->width + ax;
        for (uint32_t x = 0; x < gw; x++) {
            uint32_t sx = (x * 8u) / gw;
            if (sx > 7) sx = 7;
            /* Bit sx from LSB in k_font8x8 (standard 8x8 LSB-left layout) */
            dst[x] = (bits & (1u << sx)) ? 255u : 0u;
        }
    }
    atlas_mark_dirty(a, ax, ay, gw, gh);

    e = atlas_insert_entry(a, key);
    if (!e) return NULL;
    e->u0        = (float)ax / (float)a->width;
    e->v0        = (float)ay / (float)a->height;
    e->u1        = (float)(ax + gw) / (float)a->width;
    e->v1        = (float)(ay + gh) / (float)a->height;
    e->bearing_x = 0.0f;
    e->bearing_y = (float)gh * 0.85f;
    e->width     = (float)gw;
    e->height    = (float)gh;
    e->advance   = floorf((float)gw * 0.85f + 0.5f);
    return e;
}

#ifdef TKMT_HAVE_FREETYPE_HARFBUZZ
static const char *k_sans_font_paths[] = {
    "/System/Library/Fonts/HelveticaNeue.ttc",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/Library/Fonts/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/arial.ttf",
    NULL
};

static const char *k_mono_font_paths[] = {
    "/System/Library/Fonts/Menlo.ttc",
    "/System/Library/Fonts/SFNSMono.ttf",
    "/System/Library/Fonts/Monaco.ttf",
    "/System/Library/Fonts/Courier.ttc",
    "/System/Library/Fonts/Supplemental/Courier New.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
    "C:/Windows/Fonts/consola.ttf",
    "C:/Windows/Fonts/cour.ttf",
    NULL
};

static int str_contains_ci(const char *haystack, const char *needle) {
    if (!haystack || !needle || !needle[0]) return 0;
    size_t nlen = strlen(needle);
    for (const char *p = haystack; *p; p++) {
        size_t i = 0;
        while (i < nlen && p[i] &&
               tolower((unsigned char)p[i]) == tolower((unsigned char)needle[i])) {
            i++;
        }
        if (i == nlen) return 1;
    }
    return 0;
}

static int atlas_is_mono_family(const char *family) {
    if (!family || family[0] == '\0') return 0;
    static const char *k_mono_hints[] = {
        "mono", "menlo", "monaco", "courier", "consolas", "fixed",
        "code", "inconsolata", "fira", "jetbrains", "hack",
        "andale", "terminal", "tty", NULL
    };
    for (int i = 0; k_mono_hints[i] != NULL; i++) {
        if (str_contains_ci(family, k_mono_hints[i])) {
            return 1;
        }
    }
    return 0;
}

static int atlas_load_face(FT_Library lib, const char *env_var,
                           const char *const *paths, atlas_ft_face_t *out) {
    memset(out, 0, sizeof(*out));

    if (env_var) {
        const char *env_font = getenv(env_var);
        if (env_font && env_font[0] != '\0') {
            if (FT_New_Face(lib, env_font, 0, &out->face) == 0) {
                out->ready = 1;
            }
        }
    }

    if (!out->ready) {
        for (int i = 0; paths[i] != NULL; i++) {
            if (FT_New_Face(lib, paths[i], 0, &out->face) == 0) {
                out->ready = 1;
                break;
            }
        }
    }

    if (!out->ready) {
        return 0;
    }

    FT_Set_Pixel_Sizes(out->face, 0, 14);
    out->cur_px  = 14;
    out->hb_font = hb_ft_font_create(out->face, NULL);
    if (!out->hb_font) {
        FT_Done_Face(out->face);
        out->face  = NULL;
        out->ready = 0;
        return 0;
    }
    hb_ft_font_set_load_flags(out->hb_font, FT_LOAD_TARGET_LIGHT);
    return 1;
}

static void atlas_init_freetype(tkmt_atlas_t *a) {
    a->ft_ready = 0;
    a->ft_lib   = NULL;
    memset(a->faces, 0, sizeof(a->faces));

    if (FT_Init_FreeType(&a->ft_lib) != 0) {
        a->ft_lib = NULL;
        return;
    }

    int have_sans = atlas_load_face(a->ft_lib, "TKMT_FONT_PATH",
                                    k_sans_font_paths, &a->faces[ATLAS_FACE_SANS]);
    int have_mono = atlas_load_face(a->ft_lib, "TKMT_MONO_FONT_PATH",
                                    k_mono_font_paths, &a->faces[ATLAS_FACE_MONO]);

    if (!have_sans && !have_mono) {
        FT_Done_FreeType(a->ft_lib);
        a->ft_lib = NULL;
        return;
    }
    a->ft_ready = 1;
}

static int atlas_select_face(const tkmt_atlas_t *a, const char *font_family) {
    if (!a || !a->ft_ready) return -1;
    int want_mono = atlas_is_mono_family(font_family);
    if (want_mono && a->faces[ATLAS_FACE_MONO].ready) {
        return ATLAS_FACE_MONO;
    }
    if (a->faces[ATLAS_FACE_SANS].ready) {
        return ATLAS_FACE_SANS;
    }
    if (a->faces[ATLAS_FACE_MONO].ready) {
        return ATLAS_FACE_MONO;
    }
    return -1;
}

static atlas_glyph_entry_t *atlas_get_ft_glyph(tkmt_atlas_t *a,
                                               int face_idx,
                                               uint32_t gid,
                                               uint32_t phys_px) {
    atlas_ft_face_t *f = &a->faces[face_idx];
    uint64_t key = (1ULL << 63)
                 | ((uint64_t)((uint32_t)face_idx & 0x3u) << 60)
                 | ((uint64_t)(phys_px & 0xFFFFu) << 32)
                 | (uint64_t)gid;
    atlas_glyph_entry_t *e = atlas_find_entry(a, key);
    if (e) return e;

    if (f->cur_px != phys_px) {
        FT_Set_Pixel_Sizes(f->face, 0, phys_px);
        hb_ft_font_changed(f->hb_font);
        f->cur_px = phys_px;
    }

    if (FT_Load_Glyph(f->face, gid, FT_LOAD_RENDER | FT_LOAD_TARGET_LIGHT) != 0) {
        return NULL;
    }

    FT_GlyphSlot slot = f->face->glyph;
    FT_Bitmap *bm     = &slot->bitmap;
    uint32_t gw       = (uint32_t)bm->width;
    uint32_t gh       = (uint32_t)bm->rows;

    uint32_t ax = 0, ay = 0;
    if (gw > 0 && gh > 0) {
        if (!atlas_alloc_rect(a, gw, gh, &ax, &ay)) {
            return NULL;
        }
        for (uint32_t y = 0; y < gh; y++) {
            const uint8_t *src = bm->buffer + (size_t)y * (size_t)abs(bm->pitch);
            uint8_t *dst       = a->pixels + (size_t)(ay + y) * a->width + ax;
            memcpy(dst, src, gw);
        }
        atlas_mark_dirty(a, ax, ay, gw, gh);
    }

    e = atlas_insert_entry(a, key);
    if (!e) return NULL;
    if (gw > 0 && gh > 0) {
        e->u0 = (float)ax / (float)a->width;
        e->v0 = (float)ay / (float)a->height;
        e->u1 = (float)(ax + gw) / (float)a->width;
        e->v1 = (float)(ay + gh) / (float)a->height;
    } else {
        e->u0 = e->v0 = e->u1 = e->v1 = 0.0f;
    }
    e->bearing_x = (float)slot->bitmap_left;
    e->bearing_y = (float)slot->bitmap_top;
    e->width     = (float)gw;
    e->height    = (float)gh;
    e->advance   = (float)(slot->advance.x >> 6);
    return e;
}
#endif /* TKMT_HAVE_FREETYPE_HARFBUZZ */

/* -------------------------------------------------------------------------
 * Public Atlas API
 * ------------------------------------------------------------------------- */

tkmt_atlas_t *tkmt_atlas_create(uint32_t width, uint32_t height) {
    if (width < 64)  width  = 512;
    if (height < 64) height = 512;

    tkmt_atlas_t *a = (tkmt_atlas_t *)calloc(1, sizeof(tkmt_atlas_t));
    if (!a) return NULL;

    a->width     = width;
    a->height    = height;
    a->dpi_scale = 1.0f;
    a->pixels    = (uint8_t *)calloc((size_t)width * (size_t)height, 1);
    if (!a->pixels) {
        free(a);
        return NULL;
    }

    a->cursor_x = 1;
    a->cursor_y = 1;
    a->shelf_h  = 0;
    a->dirty    = 1;
    a->dirty_x0 = 0;
    a->dirty_y0 = 0;
    a->dirty_x1 = width;
    a->dirty_y1 = height;

#ifdef TKMT_HAVE_FREETYPE_HARFBUZZ
    atlas_init_freetype(a);
#endif
    return a;
}

void tkmt_atlas_destroy(tkmt_atlas_t *atlas) {
    if (!atlas) return;
#ifdef TKMT_HAVE_FREETYPE_HARFBUZZ
    for (int i = 0; i < ATLAS_FACE_COUNT; i++) {
        if (atlas->faces[i].hb_font) hb_font_destroy(atlas->faces[i].hb_font);
        if (atlas->faces[i].face)    FT_Done_Face(atlas->faces[i].face);
    }
    if (atlas->ft_lib) FT_Done_FreeType(atlas->ft_lib);
#endif
    free(atlas->pixels);
    free(atlas);
}

void tkmt_atlas_set_scale(tkmt_atlas_t *atlas, float scale) {
    if (!atlas) return;
    if (scale < 1.0f) scale = 1.0f;
    if (scale > 4.0f) scale = 4.0f;
    atlas->dpi_scale = scale;
}

float tkmt_atlas_get_scale(const tkmt_atlas_t *atlas) {
    if (!atlas) return 1.0f;
    return atlas->dpi_scale >= 1.0f ? atlas->dpi_scale : 1.0f;
}

void tkmt_atlas_detach_texture(tkmt_atlas_t *atlas) {
    if (!atlas) return;
    atlas->tex_id     = 0;
    atlas->bound_surf = NULL;
    atlas->dirty      = 1;
    atlas->dirty_x0   = 0;
    atlas->dirty_y0   = 0;
    atlas->dirty_x1   = atlas->width;
    atlas->dirty_y1   = atlas->height;
}

tkmt_tex_id_t tkmt_atlas_sync_texture(tkmt_atlas_t *atlas,
                                      const tkmt_gfx_backend_t *backend,
                                      tkmt_gfx_surface_t *surf) {
    if (!atlas || !backend || !surf) {
        return 0;
    }

    if (atlas->tex_id == 0 || atlas->bound_surf != surf) {
        atlas->tex_id = backend->texture_create(surf, atlas->width, atlas->height,
                                                TKMT_TEX_R8, atlas->pixels);
        atlas->bound_surf = surf;
        atlas->dirty      = 0;
        return atlas->tex_id;
    }

    if (atlas->dirty && backend->texture_update) {
        backend->texture_update(surf, atlas->tex_id,
                                0, 0, atlas->width, atlas->height,
                                atlas->pixels);
        atlas->dirty = 0;
    }

    return atlas->tex_id;
}

int tkmt_atlas_using_freetype(const tkmt_atlas_t *atlas) {
#ifdef TKMT_HAVE_FREETYPE_HARFBUZZ
    return (atlas && atlas->ft_ready) ? 1 : 0;
#else
    (void)atlas;
    return 0;
#endif
}

const uint8_t *tkmt_atlas_pixels(const tkmt_atlas_t *atlas,
                                 uint32_t *out_w, uint32_t *out_h) {
    if (!atlas) return NULL;
    if (out_w) *out_w = atlas->width;
    if (out_h) *out_h = atlas->height;
    return atlas->pixels;
}

uint32_t tkmt_atlas_layout_text_scaled(tkmt_atlas_t *atlas,
                                       const char *text,
                                       const char *font_family,
                                       float font_size,
                                       float dpi_scale,
                                       tkmt_glyph_quad_t *out_quads,
                                       uint32_t max_quads,
                                       float *out_width,
                                       float *out_height) {
    if (!atlas || !text || text[0] == '\0') {
        if (out_width)  *out_width  = 0.0f;
        if (out_height) *out_height = 0.0f;
        return 0;
    }

    if (font_size < 6.0f)   font_size = 12.0f;
    if (font_size > 128.0f) font_size = 128.0f;
    if (dpi_scale < 1.0f)   dpi_scale = 1.0f;
    if (dpi_scale > 4.0f)   dpi_scale = 4.0f;

    uint32_t phys_px = (uint32_t)(font_size * dpi_scale + 0.5f);
    if (phys_px < 6)   phys_px = 6;
    if (phys_px > 256) phys_px = 256;

    float inv_scale  = 1.0f / dpi_scale;
    float line_h     = floorf((float)phys_px * 1.25f + 0.5f);
    float baseline_y = floorf((float)phys_px * 0.85f + 0.5f);

#ifdef TKMT_HAVE_FREETYPE_HARFBUZZ
    int face_idx = atlas_select_face(atlas, font_family);
    if (face_idx >= 0) {
        atlas_ft_face_t *f = &atlas->faces[face_idx];
        if (f->cur_px != phys_px) {
            FT_Set_Pixel_Sizes(f->face, 0, phys_px);
            hb_ft_font_changed(f->hb_font);
            f->cur_px = phys_px;
        }
        float asc  = (float)f->face->size->metrics.ascender / 64.0f;
        float desc = (float)(-f->face->size->metrics.descender) / 64.0f;
        float lh   = (float)f->face->size->metrics.height / 64.0f;
        if (asc > 0.0f) {
            baseline_y = floorf(asc + 0.5f);
        }
        if (lh < asc + desc) {
            lh = asc + desc;
        }
        if (lh < (float)phys_px * 1.15f) {
            lh = (float)phys_px * 1.20f;
        }
        line_h = floorf(lh + 0.5f);
    }
#else
    (void)font_family;
#endif

    uint32_t total_quads = 0;
    float max_line_w     = 0.0f;
    float pen_y          = 0.0f;
    int line_count       = 0;

    const char *line_start = text;
    while (1) {
        const char *nl = strchr(line_start, '\n');
        size_t line_len = nl ? (size_t)(nl - line_start) : strlen(line_start);
        float pen_x = 0.0f;
        line_count++;

#ifdef TKMT_HAVE_FREETYPE_HARFBUZZ
        if (face_idx >= 0 && line_len > 0) {
            atlas_ft_face_t *f = &atlas->faces[face_idx];
            hb_buffer_t *buf = hb_buffer_create();
            hb_buffer_add_utf8(buf, line_start, (int)line_len, 0, (int)line_len);
            hb_buffer_guess_segment_properties(buf);
            hb_shape(f->hb_font, buf, NULL, 0);

            unsigned int gcount = 0;
            hb_glyph_info_t *ginfo    = hb_buffer_get_glyph_infos(buf, &gcount);
            hb_glyph_position_t *gpos = hb_buffer_get_glyph_positions(buf, &gcount);

            for (unsigned int i = 0; i < gcount; i++) {
                atlas_glyph_entry_t *e = atlas_get_ft_glyph(atlas, face_idx, ginfo[i].codepoint, phys_px);
                float x_off = (float)gpos[i].x_offset / 64.0f;
                float y_off = (float)gpos[i].y_offset / 64.0f;
                float x_adv = (float)gpos[i].x_advance / 64.0f;
                if (face_idx == ATLAS_FACE_MONO) {
                    x_adv = floorf(x_adv + 0.5f);
                }
                if (e && e->width > 0.0f && e->height > 0.0f) {
                    if (out_quads && total_quads < max_quads) {
                        tkmt_glyph_quad_t *q = &out_quads[total_quads];
                        float qx0 = floorf(pen_x + x_off + e->bearing_x + 0.5f);
                        float qy0 = floorf(pen_y + baseline_y - e->bearing_y - y_off + 0.5f);
                        q->x0 = qx0 * inv_scale;
                        q->y0 = qy0 * inv_scale;
                        q->x1 = (qx0 + e->width) * inv_scale;
                        q->y1 = (qy0 + e->height) * inv_scale;
                        q->u0 = e->u0;
                        q->v0 = e->v0;
                        q->u1 = e->u1;
                        q->v1 = e->v1;
                    }
                    total_quads++;
                }
                pen_x += x_adv;
            }
            hb_buffer_destroy(buf);
        } else
#endif
        {
            const char *p   = line_start;
            const char *end = line_start + line_len;
            while (p < end) {
                uint32_t cp = utf8_next(&p);
                if (cp == '\r') continue;
                atlas_glyph_entry_t *e = atlas_get_fallback_glyph(atlas, cp, phys_px);
                if (e) {
                    if (e->width > 0.0f && e->height > 0.0f) {
                        if (out_quads && total_quads < max_quads) {
                            tkmt_glyph_quad_t *q = &out_quads[total_quads];
                            float qx0 = floorf(pen_x + e->bearing_x + 0.5f);
                            float qy0 = floorf(pen_y + baseline_y - e->bearing_y + 0.5f);
                            q->x0 = qx0 * inv_scale;
                            q->y0 = qy0 * inv_scale;
                            q->x1 = (qx0 + e->width) * inv_scale;
                            q->y1 = (qy0 + e->height) * inv_scale;
                            q->u0 = e->u0;
                            q->v0 = e->v0;
                            q->u1 = e->u1;
                            q->v1 = e->v1;
                        }
                        total_quads++;
                    }
                    pen_x += e->advance;
                }
            }
        }

        if (pen_x > max_line_w) max_line_w = pen_x;
        pen_y += line_h;

        if (!nl) break;
        line_start = nl + 1;
    }

    if (out_width)  *out_width  = max_line_w * inv_scale;
    if (out_height) *out_height = (float)line_count * line_h * inv_scale;
    return total_quads;
}

uint32_t tkmt_atlas_layout_text(tkmt_atlas_t *atlas,
                                const char *text,
                                const char *font_family,
                                float font_size,
                                tkmt_glyph_quad_t *out_quads,
                                uint32_t max_quads,
                                float *out_width,
                                float *out_height) {
    float sc = atlas ? tkmt_atlas_get_scale(atlas) : 1.0f;
    return tkmt_atlas_layout_text_scaled(atlas, text, font_family, font_size, sc,
                                         out_quads, max_quads, out_width, out_height);
}

void tkmt_atlas_measure_text(tkmt_atlas_t *atlas,
                             const char *text,
                             const char *font_family,
                             float font_size,
                             float *out_width,
                             float *out_height) {
    (void)tkmt_atlas_layout_text(atlas, text, font_family, font_size,
                                 NULL, 0, out_width, out_height);
}
