#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <ptrauth.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "nac_pac.h"

static const char *kIdentityServicesd =
    "/System/Library/PrivateFrameworks/IDS.framework/identityservicesd.app/Contents/MacOS/identityservicesd";

static const uint32_t kBraaX16X17 = 0xd71f0a11u;

static void *g_image_base = NULL;
static void *g_dl_handle = NULL;
static kappy_nac_auth_binding_t *g_bindings = NULL;
static size_t g_binding_count = 0;
static bool g_use_stubs = false;

static bool section_in_image(const struct mach_header_64 *mh, const char *segname, const char *sectname,
                             uint64_t *out_addr, uint64_t *out_size) {
    const uint8_t *p = (const uint8_t *)mh + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, segname, 16) == 0) {
                const struct section_64 *sec = (const struct section_64 *)(seg + 1);
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    if (strncmp(sec[j].sectname, sectname, 16) == 0) {
                        *out_addr = sec[j].addr;
                        *out_size = sec[j].size;
                        return true;
                    }
                }
            }
        }
        p += lc->cmdsize;
    }
    return false;
}

static const struct mach_header_64 *header_for_image_base(void *base) {
    Dl_info info;
    if (dladdr(base, &info) == 0 || info.dli_fbase == NULL) {
        return NULL;
    }
    return (const struct mach_header_64 *)info.dli_fbase;
}

static const uint64_t kImagePreferredVm = 0x100000000ULL;

static bool decode_auth_stub(const uint8_t *image_bytes, uint32_t stub_off, uint32_t *out_got_off) {
    uint32_t w0 = *(const uint32_t *)(image_bytes + stub_off);
    uint32_t w1 = *(const uint32_t *)(image_bytes + stub_off + 4);
    uint32_t w3 = *(const uint32_t *)(image_bytes + stub_off + 12);
    if (w3 != kBraaX16X17) {
        return false;
    }
    if ((w0 & 0x9f000000u) != 0x90000000u) {
        return false;
    }
    int64_t immhi = (w0 >> 5) & 0x7ffff;
    int64_t immlo = (w0 >> 29) & 0x3;
    int64_t imm21 = (immhi << 2) | immlo;
    if (imm21 & (1 << 20)) {
        imm21 -= (1 << 21);
    }
    int64_t page = ((int64_t)stub_off & ~0xfff) + (imm21 << 12);
    int64_t imm12 = (w1 >> 10) & 0xfff;
    if (w1 & (1u << 22)) {
        imm12 |= ~0xfff;
    }
    int64_t got_vm = page + imm12;
    if (got_vm < 0) {
        return false;
    }
    *out_got_off = (uint32_t)(got_vm - kImagePreferredVm);
    return true;
}

static void *strip_code_ptr(void *signed_ptr, void *auth_got_slot) {
    if (signed_ptr == NULL) {
        return NULL;
    }
    void *discriminated = ptrauth_auth_function(
        signed_ptr, ptrauth_key_process_independent_code, ptrauth_blend_discriminator(auth_got_slot, 0));
    if (discriminated != NULL) {
        return discriminated;
    }
    return ptrauth_strip(signed_ptr, ptrauth_key_asia);
}

static int rebuild_bindings(void) {
    free(g_bindings);
    g_bindings = NULL;
    g_binding_count = 0;

    const struct mach_header_64 *mh = header_for_image_base(g_image_base);
    if (!mh || g_image_base == NULL) {
        return -1;
    }

    uint64_t stub_addr = 0;
    uint64_t stub_size = 0;
    uint64_t got_addr = 0;
    uint64_t got_size = 0;
    if (!section_in_image(mh, "__TEXT", "__auth_stubs", &stub_addr, &stub_size) ||
        !section_in_image(mh, "__DATA_CONST", "__auth_got", &got_addr, &got_size)) {
        fprintf(stderr, "pac: missing __auth_stubs or __auth_got (stubs=%d got=%d)\n",
                section_in_image(mh, "__TEXT", "__auth_stubs", &stub_addr, &stub_size),
                section_in_image(mh, "__DATA_CONST", "__auth_got", &got_addr, &got_size));
        return -2;
    }
    uint64_t mh_vm = kImagePreferredVm;
    uint64_t text_addr = 0;
    uint64_t text_size = 0;
    if (!section_in_image(mh, "__TEXT", "__text", &text_addr, &text_size)) {
        fprintf(stderr, "pac: missing __text\n");
        return -2;
    }
    uint32_t text_off = (uint32_t)(text_addr - mh_vm);
    uint32_t text_sz = (uint32_t)text_size;
    uintptr_t text_lo = (uintptr_t)g_image_base + text_off;
    uintptr_t text_hi = text_lo + text_sz;
    if (getenv("KAPPY_PAC_DEBUG")) {
        fprintf(stderr, "pac: stubs=%#llx+%#llx got=%#llx+%#llx text=%#x+%#x\n", stub_addr, stub_size, got_addr,
                got_size, text_off, text_sz);
    }

    NSData *file = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:kIdentityServicesd]];
    if (file.length == 0) {
        return -3;
    }
    (void)file;

    size_t cap = 4096;
    g_bindings = calloc(cap, sizeof(kappy_nac_auth_binding_t));
    if (!g_bindings) {
        return -4;
    }

    size_t decoded = 0;
    size_t stripped_ok = 0;
    for (uint64_t stub_vm = stub_addr; stub_vm + 16 <= stub_addr + stub_size; stub_vm += 16) {
        uint64_t stub_off = stub_vm - mh_vm;
        const uint8_t *image_bytes = (const uint8_t *)g_image_base;
        if (stub_off + 16 > 0x10000000) {
            continue;
        }
        uint32_t got_off = 0;
        if (!decode_auth_stub(image_bytes, (uint32_t)stub_off, &got_off)) {
            continue;
        }
        decoded++;
        uint32_t got_sect_off = (uint32_t)(got_addr - mh_vm);
        if (got_off < got_sect_off || got_off + 8 > got_sect_off + got_size) {
            continue;
        }
        void *got_slot = (uint8_t *)g_image_base + got_off;
        void *signed_target = *(void **)got_slot;
        void *stripped = strip_code_ptr(signed_target, got_slot);
        if (stripped == NULL) {
            continue;
        }
        stripped_ok++;
        uintptr_t stripped_vm = (uintptr_t)stripped;
        if (stripped_vm < text_lo || stripped_vm >= text_hi) {
            continue;
        }
        uint32_t impl_off = (uint32_t)(stripped_vm - (uintptr_t)g_image_base);
        if (g_binding_count >= cap) {
            cap *= 2;
            kappy_nac_auth_binding_t *grown = realloc(g_bindings, cap * sizeof(*g_bindings));
            if (!grown) {
                return -5;
            }
            g_bindings = grown;
        }
        g_bindings[g_binding_count++] = (kappy_nac_auth_binding_t){
            .impl_offset = impl_off,
            .stub_offset = (uint32_t)stub_off,
            .auth_got_offset = got_off,
            .signed_target = signed_target,
            .stripped_target = stripped,
        };
    }
    if (getenv("KAPPY_PAC_DEBUG")) {
        fprintf(stderr, "pac: decoded=%zu stripped=%zu in_image=%zu\n", decoded, stripped_ok, g_binding_count);
    }
    return 0;
}

int kappy_nac_pac_load(void) {
    if (g_image_base != NULL) {
        return 0;
    }
    g_dl_handle = dlopen(kIdentityServicesd, RTLD_LAZY | RTLD_LOCAL);
    if (!g_dl_handle) {
        fprintf(stderr, "pac: dlopen failed: %s\n", dlerror());
        return -1;
    }
    void *ref = dlsym(g_dl_handle, "IDSProtoKeyTransparencyTrustedServiceReadFrom");
    if (!ref) {
        fprintf(stderr, "pac: dlsym reference failed\n");
        return -2;
    }
#if defined(__arm64__)
    g_image_base = (uint8_t *)ref - 0x0712b4;
#else
    g_image_base = (uint8_t *)ref - 0x0787a1;
#endif
    return rebuild_bindings();
}

void *kappy_nac_pac_image_base(void) {
    return g_image_base;
}

int kappy_nac_pac_stub_for_impl(uint32_t impl_offset, kappy_nac_auth_binding_t *out) {
    if (g_bindings == NULL || out == NULL) {
        return -1;
    }
    for (size_t i = 0; i < g_binding_count; i++) {
        if (g_bindings[i].impl_offset == impl_offset) {
            *out = g_bindings[i];
            return 0;
        }
    }
    return -1;
}

void kappy_nac_pac_dump_bindings(void) {
    if (g_bindings == NULL) {
        fprintf(stderr, "pac: not loaded\n");
        return;
    }
    fprintf(stderr, "pac: %zu auth stub bindings\n", g_binding_count);
    for (size_t i = 0; i < g_binding_count; i++) {
        kappy_nac_auth_binding_t *b = &g_bindings[i];
        fprintf(stderr, "  impl=%#x stub=%#x got=%#x stripped=%p\n", b->impl_offset, b->stub_offset,
                b->auth_got_offset, b->stripped_target);
    }
}

bool kappy_nac_pac_use_stubs(void) {
    return g_use_stubs;
}

void kappy_nac_pac_set_use_stubs(bool enabled) {
    g_use_stubs = enabled;
}

void *kappy_nac_pac_call_target(uint32_t impl_offset) {
    if (!g_use_stubs || g_image_base == NULL) {
        return (uint8_t *)g_image_base + impl_offset;
    }
    kappy_nac_auth_binding_t binding = {0};
    if (kappy_nac_pac_stub_for_impl(impl_offset, &binding) == 0) {
        return (uint8_t *)g_image_base + binding.stub_offset;
    }
    return (uint8_t *)g_image_base + impl_offset;
}

int kappy_nac_pac_resolve_triple(kappy_nac_offsets_t *found) {
    extern int kappy_nac_cert_probe_init(uint32_t init_offset, uint32_t reference);
    extern int kappy_nac_guarded_generate(const kappy_nac_offsets_t *offs, void **out_bytes, size_t *out_len);

    if (kappy_nac_pac_load() != 0) {
        return -1;
    }

    const uint32_t known_inits[] = {0x2a7360};
    const uint32_t known_keys[] = {0x7e530c};
    const uint32_t known_signs[] = {0x6d5d98, 0x2335e8};

    for (size_t ii = 0; ii < sizeof(known_inits) / sizeof(known_inits[0]); ii++) {
        uint32_t init_impl = known_inits[ii];
        if (kappy_nac_cert_probe_init(init_impl, 0x0712b4) != 0) {
            continue;
        }
        kappy_nac_auth_binding_t init_b = {0};
        kappy_nac_auth_binding_t key_b = {0};
        kappy_nac_auth_binding_t sign_b = {0};
        if (kappy_nac_pac_stub_for_impl(init_impl, &init_b) != 0) {
            fprintf(stderr, "pac: no stub for init %#x\n", init_impl);
            continue;
        }

        for (size_t kk = 0; kk < sizeof(known_keys) / sizeof(known_keys[0]); kk++) {
            uint32_t key_impl = known_keys[kk];
            if (kappy_nac_pac_stub_for_impl(key_impl, &key_b) != 0) {
                fprintf(stderr, "pac: no stub for key %#x\n", key_impl);
                continue;
            }
            for (size_t ss = 0; ss < sizeof(known_signs) / sizeof(known_signs[0]); ss++) {
                uint32_t sign_impl = known_signs[ss];
                if (kappy_nac_pac_stub_for_impl(sign_impl, &sign_b) != 0) {
                    continue;
                }
                kappy_nac_offsets_t offs = {
                    .reference_symbol = "IDSProtoKeyTransparencyTrustedServiceReadFrom",
                    .reference_address = 0x0712b4,
                    .nac_init_address = init_b.stub_offset,
                    .nac_key_establishment_address = key_b.stub_offset,
                    .nac_sign_address = sign_b.stub_offset,
                };
                fprintf(stderr, "pac: trying init_stub=%#x key_stub=%#x sign_stub=%#x (impl %x/%x/%x)\n",
                        offs.nac_init_address, offs.nac_key_establishment_address, offs.nac_sign_address, init_impl,
                        key_impl, sign_impl);
                void *bytes = NULL;
                size_t len = 0;
                if (kappy_nac_guarded_generate(&offs, &bytes, &len) == 0 && len > 0) {
                    free(bytes);
                    *found = offs;
                    return 0;
                }
            }
        }
    }
    return -1;
}
