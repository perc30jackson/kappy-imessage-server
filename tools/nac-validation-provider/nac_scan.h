#ifndef KAPPY_NAC_SCAN_H
#define KAPPY_NAC_SCAN_H

#include <stdint.h>

#include "offsets.h"

// Fast offset discovery: prologue prefilter + single dlopen + parallel cert validation.
int kappy_nac_find_init_offset_fast(uint32_t start, uint32_t end, int workers, uint32_t *found_init);

// Brute pacibsp-aligned offsets for cert init that yields a session request blob.
int kappy_nac_brute_find_init_cert(uint32_t start, uint32_t end, uint32_t *found_init);

void kappy_nac_set_probe_cert(const uint8_t *cert, size_t len);

// Returns 0 if NACInit passes cert probe at offset, 1 otherwise.
int kappy_nac_cert_probe_init(uint32_t init_offset, uint32_t reference);

int kappy_nac_probe_init(uint32_t init_offset, uint32_t reference);

#endif
