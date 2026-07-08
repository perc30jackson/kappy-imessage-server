#ifndef KAPPY_NAC_VALIDATE_H
#define KAPPY_NAC_VALIDATE_H

#include <stdint.h>

#include "offsets.h"

// Run full NAC validation pipeline with explicit offsets. Returns 0 on success.
int kappy_nac_generate_with_offsets(const kappy_nac_offsets_t *offs, void **out_bytes, size_t *out_len);

// Run through KeyEstablishment only (no Sign). Returns 0 if key_est succeeds.
int kappy_nac_try_through_keyest(const kappy_nac_offsets_t *offs);

int kappy_nac_guarded_generate(const kappy_nac_offsets_t *offs, void **out_bytes, size_t *out_len);

void kappy_nac_set_executable_path(const char *path);
void kappy_nac_set_guarded_quiet(bool quiet);

int kappy_nac_find_triple_fast(kappy_nac_offsets_t *found);

// Given a cert-validated NACInit offset, search nearby KeyEst + Sign prologues.
int kappy_nac_find_triple_for_init(uint32_t init_off, kappy_nac_offsets_t *found);

// Search init/key/sign candidates around the known KeyEstablishment anchor.
int kappy_nac_find_triple_key_anchor(uint32_t key_anchor, kappy_nac_offsets_t *found);

void kappy_nac_apply_reference_override(kappy_nac_offsets_t *offs);

int kappy_nac_current_reference(uint32_t *ref);
int kappy_nac_current_key_anchor(uint32_t *key_anchor);

const char *kappy_nac_generate_error_string(int code);

#endif
