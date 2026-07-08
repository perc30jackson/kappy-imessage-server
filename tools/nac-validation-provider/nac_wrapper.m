#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCrypto.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "meow_memory.h"
#include "nac_proxy.h"
#include "offsets.h"

static const char *kIdentityServicesd =
    "/System/Library/PrivateFrameworks/IDS.framework/identityservicesd.app/Contents/MacOS/identityservicesd";

typedef int (*nac_init_fn)(void *cert_bytes, int cert_len, void **out_ctx, void **out_req, int *out_req_len);

static void *g_nac_init = NULL;
static void *g_nac_key_establishment = NULL;
static void *g_nac_sign = NULL;
static kappy_nac_offsets_t g_loaded_offsets = {0};
static bool g_has_loaded_offsets = false;

static int sha256_file(const char *path, uint8_t out[32]) {
    NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
    if (!data) {
        return -1;
    }
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    memcpy(out, digest, 32);
    return 0;
}

static void *resolve_base(const kappy_nac_offsets_t *offs) {
    void *handle = dlopen(kIdentityServicesd, RTLD_LAZY);
    if (!handle) {
        return NULL;
    }
    void *ref = dlsym(handle, offs->reference_symbol);
    if (!ref) {
        return NULL;
    }
    return (uint8_t *)ref - offs->reference_address;
}

int kappy_nac_load(const kappy_nac_offsets_t *offs) {
    void *base = resolve_base(offs);
    if (!base) {
        return -1;
    }
    g_nac_init = (uint8_t *)base + offs->nac_init_address;
    g_nac_key_establishment = (uint8_t *)base + offs->nac_key_establishment_address;
    g_nac_sign = (uint8_t *)base + offs->nac_sign_address;
    g_loaded_offsets = *offs;
    g_has_loaded_offsets = true;
    return 0;
}

int kappy_nac_get_loaded_offsets(kappy_nac_offsets_t *offs) {
    if (!g_has_loaded_offsets) {
        return -1;
    }
    *offs = g_loaded_offsets;
    return 0;
}

static NSData *fetch_validation_cert_local(NSError **error) {
    NSURL *url = [NSURL URLWithString:@"http://static.ess.apple.com/identity/validation/cert-1.0.plist"];
    NSData *resp = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!resp) {
        return nil;
    }
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:resp options:0 format:NULL error:error];
    NSData *cert = plist[@"cert"];
    if (![cert isKindOfClass:[NSData class]] || cert.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"kappy.nac" code:1 userInfo:@{NSLocalizedDescriptionKey: @"missing cert"}];
        }
        return nil;
    }
    return cert;
}

int kappy_nac_try_offsets(const kappy_nac_offsets_t *offs) {
    kappy_meow_scope *scope = kappy_meow_enter();
    if (!scope) {
        return -1;
    }
    void *base = resolve_base(offs);
    if (!base) {
        kappy_meow_leave(scope);
        return -2;
    }
    nac_init_fn init = (nac_init_fn)((uint8_t *)base + offs->nac_init_address);
    int resp = kappy_nac_proxy_init(init, NULL, 0, NULL, NULL, NULL);
    if (resp != -44023) {
        kappy_meow_leave(scope);
        return resp;
    }
    NSData *cert = fetch_validation_cert_local(NULL);
    if (!cert) {
        kappy_meow_leave(scope);
        return -3;
    }
    void *ctx = NULL;
    void *req_ptr = NULL;
    int req_len = 0;
    resp = kappy_nac_proxy_init(init, cert.bytes, cert.length, &ctx, &req_ptr, &req_len);
    kappy_meow_leave(scope);
    if (resp != 0 || req_ptr == NULL || req_len <= 0) {
        return resp != 0 ? resp : -4;
    }
    return 0;
}

int kappy_nac_sanity_check(void) {
    kappy_meow_scope *scope = kappy_meow_enter();
    if (!scope) {
        return -1;
    }
    int resp = kappy_nac_proxy_init(g_nac_init, NULL, 0, NULL, NULL, NULL);
    kappy_meow_leave(scope);
    return resp == -44023 ? 0 : resp;
}

int kappy_nac_init(const uint8_t *cert, size_t cert_len, void **out_ctx, NSData **out_request) {
    kappy_meow_scope *scope = kappy_meow_enter();
    if (!scope) {
        return -1;
    }
    void *req_ptr = NULL;
    int req_len = 0;
    int resp = kappy_nac_proxy_init(g_nac_init, cert, cert_len, out_ctx, &req_ptr, &req_len);
    NSData *request = nil;
    if (resp == 0 && req_ptr != NULL && req_len > 0) {
        request = [NSData dataWithBytes:req_ptr length:(NSUInteger)req_len];
    }
    kappy_meow_leave(scope);
    if (resp != 0) {
        return resp;
    }
    *out_request = request;
    return 0;
}

int kappy_nac_key_establishment(void *ctx, const uint8_t *response, size_t response_len) {
    kappy_meow_scope *scope = kappy_meow_enter();
    if (!scope) {
        return -1;
    }
    int resp = kappy_nac_proxy_key_establishment(g_nac_key_establishment, ctx, response, response_len);
    kappy_meow_leave(scope);
    return resp;
}

int kappy_nac_sign(void *ctx, NSData **out_validation) {
    kappy_meow_scope *scope = kappy_meow_enter();
    if (!scope) {
        return -1;
    }
    void *data_ptr = NULL;
    int data_len = 0;
    int resp = kappy_nac_proxy_sign(g_nac_sign, ctx, &data_ptr, &data_len);
    NSData *validation = nil;
    if (resp == 0 && data_ptr != NULL && data_len > 0) {
        validation = [NSData dataWithBytes:data_ptr length:(NSUInteger)data_len];
    }
    kappy_meow_leave(scope);
    if (resp != 0) {
        return resp;
    }
    *out_validation = validation;
    return 0;
}

static uint32_t kappy_nac_reference_from_env(uint32_t fallback) {
    const char *ref_env = getenv("KAPPY_NAC_REF");
    if (!ref_env || !ref_env[0]) {
        return fallback;
    }
    uint32_t ref = 0;
    if (sscanf(ref_env, "%x", &ref) == 1 && ref != 0) {
        return ref;
    }
    return fallback;
}

void kappy_nac_apply_reference_override(kappy_nac_offsets_t *offs) {
#if defined(__arm64__)
    const uint32_t fallback = 0x0712b4;
#else
    const uint32_t fallback = 0x0787a1;
#endif
    offs->reference_address = kappy_nac_reference_from_env(fallback);
}

int kappy_nac_current_reference(uint32_t *ref) {
#if defined(__arm64__)
    const int is_arm64 = 1;
#else
    const int is_arm64 = 0;
#endif
    uint8_t hash[32];
    if (sha256_file(kIdentityServicesd, hash) != 0) {
        return -1;
    }
    if (kappy_nac_reference_for_hash(hash, is_arm64, ref) != 0) {
        *ref = is_arm64 ? 0x0712b4 : 0x0787a1;
    }
    return 0;
}

int kappy_nac_current_key_anchor(uint32_t *key_anchor) {
#if defined(__arm64__)
    const int is_arm64 = 1;
#else
    const int is_arm64 = 0;
#endif
    uint8_t hash[32];
    if (sha256_file(kIdentityServicesd, hash) != 0) {
        return -1;
    }
    if (kappy_nac_key_anchor_for_hash(hash, is_arm64, key_anchor) != 0) {
        *key_anchor = is_arm64 ? 0x7e530c : 0;
    }
    return 0;
}

int kappy_nac_lookup_offsets_for_current_os(kappy_nac_offsets_t *offs) {
#if defined(__arm64__)
    const int is_arm64 = 1;
#else
    const int is_arm64 = 0;
#endif
    const char *init_env = getenv("KAPPY_NAC_INIT");
    const char *key_env = getenv("KAPPY_NAC_KEY_EST");
    const char *sign_env = getenv("KAPPY_NAC_SIGN");
    if (init_env && key_env && sign_env) {
        kappy_nac_offsets_t env_offs = {
            .reference_symbol = "IDSProtoKeyTransparencyTrustedServiceReadFrom",
#if defined(__arm64__)
            .reference_address = 0x0712b4,
#else
            .reference_address = 0x0787a1,
#endif
        };
        sscanf(init_env, "%x", &env_offs.nac_init_address);
        sscanf(key_env, "%x", &env_offs.nac_key_establishment_address);
        sscanf(sign_env, "%x", &env_offs.nac_sign_address);
        kappy_nac_apply_reference_override(&env_offs);
        if (env_offs.nac_init_address != 0 && env_offs.nac_key_establishment_address != 0 &&
            env_offs.nac_sign_address != 0) {
            fprintf(stderr, "using env offsets init=%#x key=%#x sign=%#x\n", env_offs.nac_init_address,
                    env_offs.nac_key_establishment_address, env_offs.nac_sign_address);
            *offs = env_offs;
            return 0;
        }
        fprintf(stderr, "ignoring invalid KAPPY_NAC_* env overrides (use unset or non-zero hex values)\n");
    }

    uint8_t hash[32];
    if (sha256_file(kIdentityServicesd, hash) != 0) {
        return -10;
    }
    if (kappy_nac_offsets_for_hash(hash, is_arm64, offs) != 0) {
        return -11;
    }
    return 0;
}

int kappy_nac_load_for_current_os(void) {
    kappy_nac_offsets_t offs;
    int lookup = kappy_nac_lookup_offsets_for_current_os(&offs);
    if (lookup != 0) {
        return lookup;
    }
    return kappy_nac_load(&offs);
}
