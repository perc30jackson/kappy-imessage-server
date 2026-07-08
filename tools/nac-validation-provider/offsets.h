#ifndef KAPPY_NAC_OFFSETS_H
#define KAPPY_NAC_OFFSETS_H

#include <stdint.h>
#include <string.h>

typedef struct {
    const char *reference_symbol;
    uint32_t reference_address;
    uint32_t nac_init_address;
    uint32_t nac_key_establishment_address;
    uint32_t nac_sign_address;
} kappy_nac_offsets_t;

// macOS 15.0 (24A335) identityservicesd sha256:
// 51637c96374ba4dba9a43f7b1c1b92c41be243900b9b193cdbe79c5d6200edeb
static const uint8_t kIdentityServicesdHash15_0[32] = {
    0x51, 0x63, 0x7c, 0x96, 0x37, 0x4b, 0xa4, 0xdb, 0xa9, 0xa4, 0x3f, 0x7b, 0x1c, 0x1b, 0x92, 0xc4,
    0x1b, 0xe2, 0x43, 0x90, 0x0b, 0x9b, 0x19, 0x3c, 0xdb, 0xe7, 0x9c, 0x5d, 0x62, 0x00, 0xed, 0xeb,
};

// macOS 26.5.1 (25F80) identityservicesd sha256:
// 1c394440c227e27f0ba6a9167b0725f9ebddf3559a377ba2116a01d34536e560
static const uint8_t kIdentityServicesdHash26_5_1[32] = {
    0x1c, 0x39, 0x44, 0x40, 0xc2, 0x27, 0xe2, 0x7f, 0x0b, 0xa6, 0xa9, 0x16, 0x7b, 0x07, 0x25, 0xf9,
    0xeb, 0xdd, 0xf3, 0x55, 0x9a, 0x37, 0x7b, 0xa2, 0x11, 0x6a, 0x01, 0xd3, 0x45, 0x36, 0xe5, 0x60,
};

// macOS 15 arm64e reference (verified): init=0x6782f8 key=0x65b6b0 sign=0x68b8f4
//   deltas from key: init +0x1cc48, sign +0x30244
// macOS 15 x86_64 reference (verified): init=0x683aa0 key=0x638ef0 sign=0x689b60
static const uint32_t kNacDeltaInitFromKeyArm64_15 = 0x1cc48;
static const uint32_t kNacDeltaSignFromKeyArm64_15 = 0x30244;
static const uint32_t kNacDeltaInitFromKeyX86_15 = 0x4abb0;
static const uint32_t kNacDeltaSignFromKeyX86_15 = 0x50c70;

// macOS 15.0 arm64e (24A335): manual Ghidra/string-xref RE (24A335 identityservicesd)
//   "Calling NACInit with:" @0x257148 -> init=0x66b05c
//   "Received validation initialization request" @0x257c28 -> key=0x64e200
//   "Successfully signed: %@" @0x255b30 -> sign=0x67e4d8
static const kappy_nac_offsets_t kOffsetsArm64e15_0 = {
    .reference_symbol = "IDSProtoKeyTransparencyTrustedServiceReadFrom",
    .reference_address = 0x0d3b84,
    .nac_init_address = 0x66b05c,
    .nac_key_establishment_address = 0x64e200,
    .nac_sign_address = 0x67e4d8,
};

// macOS 26.5.1 arm64e (25F80): string-xref RE on thin identityservicesd slice
//   "Calling NACInit with" @0x1dbec4 -> bl @0x1da944/@0x1dbf90 -> init wrapper 0x8832cc (braa)
//   NACInit body (pacibsp, cert probe): 0x2a7360
//   "Received validation initialization request" @0x1dc6c4 -> bl @0x1dc754 -> key 0x7e3a44
//   NACKeyEstablishment body (pacibsp): 0x7e530c
//   "Successfully signed: %@" @0x1daa3c -> bl @0x1da914 -> sign 0x7fd004
// Full pipeline via dlopen still blocked (PAC); wrappers pass -try-offsets only.
static const kappy_nac_offsets_t kOffsetsArm64e26_5_1 = {
    .reference_symbol = "IDSProtoKeyTransparencyTrustedServiceReadFrom",
    .reference_address = 0x0712b4,
    .nac_init_address = 0,
    .nac_key_establishment_address = 0,
    .nac_sign_address = 0,
};

static const kappy_nac_offsets_t kOffsetsX86_64_26_5_1 = {
    .reference_symbol = "IDSProtoKeyTransparencyTrustedServiceReadFrom",
    .reference_address = 0x0787a1,
    .nac_init_address = 0x0889020,
    .nac_key_establishment_address = 0x0869060,
    .nac_sign_address = 0x087c350,
};

static inline int kappy_nac_reference_for_hash(const uint8_t hash[32], int is_arm64, uint32_t *ref) {
    if (memcmp(hash, kIdentityServicesdHash15_0, 32) == 0) {
        if (!is_arm64) {
            return -1;
        }
        *ref = kOffsetsArm64e15_0.reference_address;
        return 0;
    }
    if (memcmp(hash, kIdentityServicesdHash26_5_1, 32) == 0) {
        *ref = is_arm64 ? kOffsetsArm64e26_5_1.reference_address : kOffsetsX86_64_26_5_1.reference_address;
        return 0;
    }
    return -1;
}

static inline int kappy_nac_key_anchor_for_hash(const uint8_t hash[32], int is_arm64, uint32_t *key_anchor) {
    if (memcmp(hash, kIdentityServicesdHash15_0, 32) == 0) {
        if (!is_arm64) {
            return -1;
        }
        *key_anchor = kOffsetsArm64e15_0.nac_key_establishment_address;
        return 0;
    }
    if (memcmp(hash, kIdentityServicesdHash26_5_1, 32) == 0 && is_arm64) {
        *key_anchor = 0x7e530c;
        return 0;
    }
    return -1;
}

static inline int kappy_nac_offsets_for_hash(const uint8_t hash[32], int is_arm64, kappy_nac_offsets_t *out) {
    if (memcmp(hash, kIdentityServicesdHash15_0, 32) == 0) {
        if (!is_arm64) {
            return -1;
        }
        *out = kOffsetsArm64e15_0;
        return 0;
    }
    if (memcmp(hash, kIdentityServicesdHash26_5_1, 32) != 0) {
        return -1;
    }
    *out = is_arm64 ? kOffsetsArm64e26_5_1 : kOffsetsX86_64_26_5_1;
    if (out->nac_init_address == 0) {
        return -1;
    }
    return 0;
}

static inline kappy_nac_offsets_t kappy_nac_candidate_offsets(uint32_t reference_address, uint32_t key_establishment, int is_arm64) {
    kappy_nac_offsets_t offs = {
        .reference_symbol = "IDSProtoKeyTransparencyTrustedServiceReadFrom",
        .reference_address = reference_address,
        .nac_key_establishment_address = key_establishment,
    };
    if (is_arm64) {
        offs.nac_init_address = key_establishment + kNacDeltaInitFromKeyArm64_15;
        offs.nac_sign_address = key_establishment + kNacDeltaSignFromKeyArm64_15;
    } else {
        offs.nac_init_address = key_establishment + kNacDeltaInitFromKeyX86_15;
        offs.nac_sign_address = key_establishment + kNacDeltaSignFromKeyX86_15;
    }
    return offs;
}

#endif
