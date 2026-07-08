#ifndef KAPPY_NAC_PAC_H
#define KAPPY_NAC_PAC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "offsets.h"

typedef struct {
    uint32_t impl_offset;
    uint32_t stub_offset;
    uint32_t auth_got_offset;
    void *signed_target;
    void *stripped_target;
} kappy_nac_auth_binding_t;

// Load identityservicesd and map __auth_stubs -> implementation via live __auth_got.
int kappy_nac_pac_load(void);

// Return image base used for offset arithmetic (same as nac_wrapper resolve_base).
void *kappy_nac_pac_image_base(void);

// Find an __auth_stubs entry whose __auth_got target matches impl_offset.
int kappy_nac_pac_stub_for_impl(uint32_t impl_offset, kappy_nac_auth_binding_t *out);

// Print all auth stub bindings (stderr).
void kappy_nac_pac_dump_bindings(void);

// Resolve init/key/sign using PAC stubs + cert probe (fork-isolated full pipeline test).
int kappy_nac_pac_resolve_triple(kappy_nac_offsets_t *found);

// Use PAC stub addresses instead of raw implementation offsets in nac_wrapper.
bool kappy_nac_pac_use_stubs(void);
void kappy_nac_pac_set_use_stubs(bool enabled);

// Translate an implementation offset to callable address (stub if known, else raw).
void *kappy_nac_pac_call_target(uint32_t impl_offset);

#endif
