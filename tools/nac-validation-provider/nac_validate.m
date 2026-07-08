#import <Foundation/Foundation.h>
#include <mach/machine.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "nac_validate.h"
#include "offsets.h"
#include "nac_scan.h"

int kappy_nac_load(const kappy_nac_offsets_t *offs);
int kappy_nac_init(const uint8_t *cert, size_t cert_len, void **out_ctx, NSData **out_request);
int kappy_nac_key_establishment(void *ctx, const uint8_t *response, size_t response_len);
int kappy_nac_sign(void *ctx, NSData **out_validation);

static uint32_t current_reference_address(void) {
    uint32_t reference = 0x0712b4;
    (void)kappy_nac_current_reference(&reference);
    return reference;
}

static NSData *fetch_cert(NSError **error) {
    NSURL *url = [NSURL URLWithString:@"http://static.ess.apple.com/identity/validation/cert-1.0.plist"];
    NSData *resp = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!resp) {
        return nil;
    }
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:resp options:0 format:NULL error:error];
    NSData *cert = plist[@"cert"];
    if (![cert isKindOfClass:[NSData class]] || cert.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"kappy.nac" code:1 userInfo:nil];
        }
        return nil;
    }
    return cert;
}

static NSData *initialize_validation(NSData *request, NSError **error) {
    NSURL *url = [NSURL URLWithString:@"https://identity.ess.apple.com/WebObjects/TDIdentityService.woa/wa/initializeValidation"];
    NSDictionary *body = @{@"session-info-request": request};
    NSData *encoded = [NSPropertyListSerialization dataWithPropertyList:body format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    if (!encoded) {
        return nil;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-apple-plist" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = encoded;
    NSURLResponse *resp = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:error];
    if (!data) {
        return nil;
    }
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:error];
    NSData *session = plist[@"session-info"];
    if (![session isKindOfClass:[NSData class]] || session.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"kappy.nac" code:2 userInfo:nil];
        }
        return nil;
    }
    return session;
}

int kappy_nac_generate_with_offsets(const kappy_nac_offsets_t *offs, void **out_bytes, size_t *out_len);

static char g_executable_path[PATH_MAX] = {0};
static bool g_guarded_quiet = false;

void kappy_nac_set_executable_path(const char *path) {
    if (!path) {
        g_executable_path[0] = '\0';
        return;
    }
    strncpy(g_executable_path, path, sizeof(g_executable_path) - 1);
    g_executable_path[sizeof(g_executable_path) - 1] = '\0';
}

void kappy_nac_set_guarded_quiet(bool quiet) {
    g_guarded_quiet = quiet;
}

int kappy_nac_guarded_generate(const kappy_nac_offsets_t *offs, void **out_bytes, size_t *out_len) {
    if (g_executable_path[0] == '\0') {
        return -1;
    }
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        return -1;
    }
    pid_t pid = fork();
    if (pid == 0) {
        close(pipefd[0]);
        char init_hex[16];
        char key_hex[16];
        char sign_hex[16];
        char fd_hex[16];
        snprintf(init_hex, sizeof(init_hex), "%x", offs->nac_init_address);
        snprintf(key_hex, sizeof(key_hex), "%x", offs->nac_key_establishment_address);
        snprintf(sign_hex, sizeof(sign_hex), "%x", offs->nac_sign_address);
        snprintf(fd_hex, sizeof(fd_hex), "%d", pipefd[1]);
        setenv("KAPPY_WORKER_PIPE_FD", fd_hex, 1);
        char ref_hex[16];
        snprintf(ref_hex, sizeof(ref_hex), "%x", offs->reference_address);
        setenv("KAPPY_NAC_REF", ref_hex, 1);
        char *argv[] = {g_executable_path, "-worker-generate", init_hex, key_hex, sign_hex, NULL};
        execv(g_executable_path, argv);
        _exit(127);
    }
    if (pid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return -1;
    }
    close(pipefd[1]);
    struct {
        int rc;
        uint32_t len;
    } hdr = {-99, 0};
    ssize_t got = read(pipefd[0], &hdr, sizeof(hdr));
    if (got != (ssize_t)sizeof(hdr)) {
        close(pipefd[0]);
        int status = 0;
        (void)waitpid(pid, &status, 0);
        if (!g_guarded_quiet) {
            fprintf(stderr, "NAC child exited without result (likely exit() inside identityservicesd)\n");
        }
        return -99;
    }
    if (hdr.rc != 0 || hdr.len == 0) {
        close(pipefd[0]);
        (void)waitpid(pid, NULL, 0);
        return hdr.rc != 0 ? hdr.rc : -6;
    }
    void *copy = malloc(hdr.len);
    if (!copy) {
        close(pipefd[0]);
        (void)waitpid(pid, NULL, 0);
        return -7;
    }
    size_t total = 0;
    while (total < hdr.len) {
        ssize_t n = read(pipefd[0], (uint8_t *)copy + total, hdr.len - total);
        if (n <= 0) {
            free(copy);
            close(pipefd[0]);
            (void)waitpid(pid, NULL, 0);
            return -6;
        }
        total += (size_t)n;
    }
    close(pipefd[0]);
    (void)waitpid(pid, NULL, 0);
    *out_bytes = copy;
    *out_len = hdr.len;
    return 0;
}

const char *kappy_nac_generate_error_string(int code) {
    switch (code) {
    case 0:
        return "ok";
    case -1:
        return "dlopen/dlsym failed";
    case -2:
        return "cert fetch failed";
    case -3:
        return "NACInit failed";
    case -4:
        return "initializeValidation failed";
    case -5:
        return "NACKeyEstablishment failed";
    case -6:
        return "NACSign failed or empty";
    case -7:
        return "malloc failed";
    case -99:
        return "NAC pipeline crashed (bad key_est/sign offsets)";
    default:
        return "unknown error";
    }
}

int kappy_nac_generate_with_offsets(const kappy_nac_offsets_t *offs, void **out_bytes, size_t *out_len) {
    @autoreleasepool {
        if (kappy_nac_load(offs) != 0) {
            return -1;
        }
        NSError *error = nil;
        NSData *cert = fetch_cert(&error);
        if (!cert) {
            fprintf(stderr, "cert fetch: %s\n", error.localizedDescription.UTF8String ?: "unknown");
            return -2;
        }
        void *ctx = NULL;
        NSData *request = nil;
        int init_rc = kappy_nac_init(cert.bytes, cert.length, &ctx, &request);
        if (init_rc != 0) {
            fprintf(stderr, "NACInit returned %d\n", init_rc);
            return -3;
        }
        NSData *session = initialize_validation(request, &error);
        if (!session) {
            fprintf(stderr, "initializeValidation: %s\n", error.localizedDescription.UTF8String ?: "unknown");
            return -4;
        }
        int key_rc = kappy_nac_key_establishment(ctx, session.bytes, session.length);
        if (key_rc != 0) {
            fprintf(stderr, "NACKeyEstablishment returned %d\n", key_rc);
            return -5;
        }
        NSData *validation = nil;
        int sign_rc = kappy_nac_sign(ctx, &validation);
        if (sign_rc != 0 || validation.length == 0) {
            fprintf(stderr, "NACSign returned %d len=%lu\n", sign_rc, (unsigned long)validation.length);
            return -6;
        }
        void *copy = malloc(validation.length);
        if (!copy) {
            return -7;
        }
        memcpy(copy, validation.bytes, validation.length);
        *out_bytes = copy;
        *out_len = validation.length;
        return 0;
    }
}

int kappy_nac_try_through_keyest(const kappy_nac_offsets_t *offs) {
    @autoreleasepool {
        if (kappy_nac_load(offs) != 0) {
            return -1;
        }
        NSError *error = nil;
        NSData *cert = fetch_cert(&error);
        if (!cert) {
            return -2;
        }
        void *ctx = NULL;
        NSData *request = nil;
        int init_rc = kappy_nac_init(cert.bytes, cert.length, &ctx, &request);
        if (init_rc != 0) {
            return -3;
        }
        NSData *session = initialize_validation(request, &error);
        if (!session) {
            return -4;
        }
        int key_rc = kappy_nac_key_establishment(ctx, session.bytes, session.length);
        return key_rc == 0 ? 0 : -5;
    }
}

static int try_triple_sign_only(const kappy_nac_offsets_t *offs) {
    void *bytes = NULL;
    size_t len = 0;
    int rc = kappy_nac_guarded_generate(offs, &bytes, &len);
    if (rc == 0 && bytes != NULL && len > 0) {
        free(bytes);
        return 0;
    }
    if (bytes) {
        free(bytes);
    }
    return 1;
}

static int try_triple_fork(const kappy_nac_offsets_t *offs) {
    return try_triple_sign_only(offs);
}

static void collect_nearby(uint32_t *out, size_t *count, size_t cap, const uint8_t *blob, size_t blob_len,
                           uint32_t center, uint32_t radius, bool want_fc, bool want_ff) {
    uint32_t lo = center > radius ? center - radius : 0;
    uint32_t hi = center + radius;
    if (hi > blob_len) {
        hi = (uint32_t)blob_len;
    }
    for (uint32_t off = lo; off + 8 <= hi; off += 4) {
        if (want_fc && memcmp(blob + off, (const uint8_t[]){0x7f, 0x23, 0x03, 0xd5, 0xfc, 0x6f, 0xba, 0xa9}, 8) == 0) {
            bool dup = false;
            for (size_t i = 0; i < *count; i++) {
                if (out[i] == off) {
                    dup = true;
                    break;
                }
            }
            if (!dup && *count < cap) {
                out[(*count)++] = off;
            }
        }
        if (want_ff && memcmp(blob + off, (const uint8_t[]){0x7f, 0x23, 0x03, 0xd5}, 4) == 0 && blob[off + 4] == 0xff) {
            bool dup = false;
            for (size_t i = 0; i < *count; i++) {
                if (out[i] == off) {
                    dup = true;
                    break;
                }
            }
            if (!dup && *count < cap) {
                out[(*count)++] = off;
            }
        }
    }
}

static void collect_keyest(uint32_t *out, size_t *count, size_t cap, const uint8_t *blob, size_t blob_len, uint32_t center,
                           uint32_t radius) {
    const uint8_t key_pat[12] = {0x7f, 0x23, 0x03, 0xd5, 0xff, 0xc3, 0x05, 0xd1, 0xfc, 0x6f, 0x11, 0xa9};
    uint32_t lo = center > radius ? center - radius : 0;
    uint32_t hi = center + radius;
    if (hi > blob_len) {
        hi = (uint32_t)blob_len;
    }
    for (uint32_t off = lo; off + 12 <= hi; off += 4) {
        if (memcmp(blob + off, key_pat, 12) != 0) {
            continue;
        }
        bool dup = false;
        for (size_t i = 0; i < *count; i++) {
            if (out[i] == off) {
                dup = true;
                break;
            }
        }
        if (!dup && *count < cap) {
            out[(*count)++] = off;
        }
    }
}

static NSData *arm64e_file_slice(NSString *path) {
    NSData *file = [NSData dataWithContentsOfFile:path];
    if (!file || file.length < sizeof(struct fat_header)) {
        return nil;
    }
    const uint8_t *data = file.bytes;
    const struct fat_header *fat = (const struct fat_header *)data;
    if (OSSwapBigToHostInt32(fat->magic) != FAT_MAGIC) {
        return file;
    }
    uint32_t nfat = OSSwapBigToHostInt32(fat->nfat_arch);
    const struct fat_arch *archs = (const struct fat_arch *)(data + sizeof(struct fat_header));
    for (uint32_t i = 0; i < nfat; i++) {
        if (OSSwapBigToHostInt32(archs[i].cputype) == CPU_TYPE_ARM64) {
            uint32_t offset = OSSwapBigToHostInt32(archs[i].offset);
            uint32_t size = OSSwapBigToHostInt32(archs[i].size);
            if (offset + size > file.length) {
                return nil;
            }
            return [NSData dataWithBytes:data + offset length:size];
        }
    }
    return nil;
}

static void push_offset(uint32_t *out, size_t *count, size_t cap, uint32_t off) {
    for (size_t i = 0; i < *count; i++) {
        if (out[i] == off) {
            return;
        }
    }
    if (*count < cap) {
        out[(*count)++] = off;
    }
}

static void collect_init8(uint32_t *out, size_t *count, size_t cap, const uint8_t *blob, size_t blob_len, uint32_t center,
                          uint32_t radius) {
    const uint8_t pat[8] = {0x7f, 0x23, 0x03, 0xd5, 0xfc, 0x6f, 0xba, 0xa9};
    uint32_t lo = center > radius ? center - radius : 0;
    uint32_t hi = center + radius;
    if (hi > blob_len) {
        hi = (uint32_t)blob_len;
    }
    for (uint32_t off = lo; off + 8 <= hi; off += 4) {
        if (memcmp(blob + off, pat, 8) == 0) {
            push_offset(out, count, cap, off);
        }
    }
}

static void collect_sign_nac(uint32_t *out, size_t *count, size_t cap, const uint8_t *blob, size_t blob_len,
                             uint32_t center, uint32_t radius) {
    const uint8_t pat[32] = {0x7f, 0x23, 0x03, 0xd5, 0xfc, 0x6f, 0xba, 0xa9, 0xfa, 0x67, 0x01, 0xa9, 0xf8, 0x5f,
                             0x02, 0xa9, 0xf6, 0x57, 0x03, 0xa9, 0xf4, 0x4f, 0x04, 0xa9, 0xfd, 0x7b, 0x05, 0xa9,
                             0xfd, 0x43, 0x01, 0x91};
    uint32_t lo = center > radius ? center - radius : 0;
    uint32_t hi = center + radius;
    if (hi > blob_len) {
        hi = (uint32_t)blob_len;
    }
    for (uint32_t off = lo; off + sizeof(pat) <= hi; off += 4) {
        if (memcmp(blob + off, pat, sizeof(pat)) == 0) {
            push_offset(out, count, cap, off);
        }
    }
}

static void collect_all_keyest(uint32_t *out, size_t *count, size_t cap, const uint8_t *blob, size_t blob_len,
                               uint32_t center, uint32_t radius) {
    const uint8_t key_pat[12] = {0x7f, 0x23, 0x03, 0xd5, 0xff, 0xc3, 0x05, 0xd1, 0xfc, 0x6f, 0x11, 0xa9};
    uint32_t lo = center > radius ? center - radius : 0;
    uint32_t hi = center + radius;
    if (hi > blob_len) {
        hi = (uint32_t)blob_len;
    }
    for (uint32_t off = lo; off + 12 <= hi; off += 4) {
        if (memcmp(blob + off, key_pat, 12) == 0) {
            push_offset(out, count, cap, off);
        }
    }
}

static void collect_obfuscated_init(uint32_t *out, size_t *count, size_t cap, const uint8_t *blob, size_t blob_len,
                                    uint32_t center, uint32_t radius) {
    const uint8_t pat[8] = {0x7f, 0x23, 0x03, 0xd5, 0xff, 0xc3, 0x00, 0xd1};
    uint32_t lo = center > radius ? center - radius : 0;
    uint32_t hi = center + radius;
    if (hi > blob_len) {
        hi = (uint32_t)blob_len;
    }
    for (uint32_t off = lo; off + 8 <= hi; off += 4) {
        if (memcmp(blob + off, pat, 8) == 0) {
            push_offset(out, count, cap, off);
        }
    }
}

static int search_key_anchor_nested(const uint8_t *blob, size_t blob_len, uint32_t key_anchor, uint32_t radius,
                                    kappy_nac_offsets_t *found) {
    const uint32_t reference = current_reference_address();
    uint32_t inits[256];
    uint32_t keys[32];
    uint32_t signs[256];
    size_t n_init = 0, n_key = 0, n_sign = 0;

    collect_init8(inits, &n_init, 256, blob, blob_len, key_anchor, radius);
    collect_obfuscated_init(inits, &n_init, 256, blob, blob_len, key_anchor, radius);
    collect_all_keyest(keys, &n_key, 32, blob, blob_len, key_anchor, radius);
    collect_sign_nac(signs, &n_sign, 256, blob, blob_len, key_anchor, radius);
    push_offset(keys, &n_key, 32, key_anchor);

    uint32_t filtered[256];
    size_t n_filtered = 0;
    fprintf(stderr, "key-anchor %#x: %zu init candidates x %zu keys x %zu signs (radius %#x)\n", key_anchor, n_init,
            n_key, n_sign, radius);
    fprintf(stderr, "filtering inits with cert probe...\n");
    for (size_t i = 0; i < n_init; i++) {
        if ((i % 10) == 0) {
            fprintf(stderr, "\r[cert-filter] %zu/%zu...", i + 1, n_init);
            fflush(stderr);
        }
        if (kappy_nac_cert_probe_init(inits[i], reference) == 0) {
            push_offset(filtered, &n_filtered, 256, inits[i]);
            fprintf(stderr, "\n  cert-valid init: %#x\n", inits[i]);
        }
    }
    if (n_filtered == 0) {
        fprintf(stderr, "\nno cert-valid inits near key anchor\n");
        return -1;
    }
    fprintf(stderr, "using %zu cert-valid inits\n", n_filtered);

    kappy_nac_set_guarded_quiet(true);
    size_t tried = 0;
    for (size_t ii = 0; ii < n_filtered; ii++) {
        for (size_t kk = 0; kk < n_key; kk++) {
            kappy_nac_offsets_t partial = {
                .reference_symbol = "IDSProtoKeyTransparencyTrustedServiceReadFrom",
                .reference_address = reference,
                .nac_init_address = filtered[ii],
                .nac_key_establishment_address = keys[kk],
                .nac_sign_address = 0,
            };
            tried++;
            if ((tried % 5) == 0) {
                fprintf(stderr, "\r[key-est] %zu (init %#x key %#x)...", tried, partial.nac_init_address,
                        partial.nac_key_establishment_address);
                fflush(stderr);
            }
            if (kappy_nac_try_through_keyest(&partial) != 0) {
                continue;
            }
            fprintf(stderr, "\nkey-est OK init=%#x key=%#x; searching sign...\n", partial.nac_init_address,
                    partial.nac_key_establishment_address);
            for (size_t ss = 0; ss < n_sign; ss++) {
                kappy_nac_offsets_t full = partial;
                full.nac_sign_address = signs[ss];
                if (try_triple_sign_only(&full) == 0) {
                    kappy_nac_set_guarded_quiet(false);
                    fprintf(stderr, "validated triple init=%#x key=%#x sign=%#x\n", full.nac_init_address,
                            full.nac_key_establishment_address, full.nac_sign_address);
                    *found = full;
                    return 0;
                }
            }
        }
    }
    kappy_nac_set_guarded_quiet(false);
    fprintf(stderr, "\nno triple after %zu init/key key-est attempts\n", tried);
    return -1;
}

static int try_triple_list(const kappy_nac_offsets_t *candidates, size_t count, kappy_nac_offsets_t *found,
                           const char *label) {
    kappy_nac_set_guarded_quiet(true);
    for (size_t i = 0; i < count; i++) {
        if ((i % 25) == 0 || i + 1 == count) {
            fprintf(stderr, "\r[%s] %zu/%zu...", label, i + 1, count);
            fflush(stderr);
        }
        if (try_triple_fork(&candidates[i]) == 0) {
            kappy_nac_set_guarded_quiet(false);
            fprintf(stderr, "\nvalidated triple init=%#x key=%#x sign=%#x (tried %zu)\n", candidates[i].nac_init_address,
                    candidates[i].nac_key_establishment_address, candidates[i].nac_sign_address, i + 1);
            *found = candidates[i];
            return 0;
        }
    }
    kappy_nac_set_guarded_quiet(false);
    fprintf(stderr, "\n[%s] no hit in %zu attempts\n", label, count);
    return -1;
}

static int build_key_anchor_search(const uint8_t *blob, size_t blob_len, uint32_t key_anchor, uint32_t radius,
                                   kappy_nac_offsets_t **out_candidates, size_t *out_count) {
    const uint32_t reference = current_reference_address();
    uint32_t inits[256];
    uint32_t keys[32];
    uint32_t signs[256];
    size_t n_init = 0, n_key = 0, n_sign = 0;

    collect_init8(inits, &n_init, 256, blob, blob_len, key_anchor, radius);
    collect_all_keyest(keys, &n_key, 32, blob, blob_len, key_anchor, radius);
    collect_sign_nac(signs, &n_sign, 256, blob, blob_len, key_anchor, radius);
    push_offset(keys, &n_key, 32, key_anchor);

    uint32_t filtered[256];
    size_t n_filtered = 0;
    fprintf(stderr, "key-anchor %#x: %zu init8 x %zu keys x %zu signs (radius %#x)\n", key_anchor, n_init, n_key,
            n_sign, radius);
    fprintf(stderr, "filtering inits with cert probe...\n");
    for (size_t i = 0; i < n_init; i++) {
        if ((i % 10) == 0) {
            fprintf(stderr, "\r[cert-filter] %zu/%zu...", i + 1, n_init);
            fflush(stderr);
        }
        if (kappy_nac_cert_probe_init(inits[i], reference) == 0) {
            push_offset(filtered, &n_filtered, 256, inits[i]);
            fprintf(stderr, "\n  cert-valid init: %#x\n", inits[i]);
        }
    }
    if (n_filtered == 0) {
        fprintf(stderr, "\nno cert-valid inits; falling back to all init8 candidates\n");
        memcpy(filtered, inits, n_init * sizeof(uint32_t));
        n_filtered = n_init;
    } else {
        fprintf(stderr, "using %zu cert-valid inits\n", n_filtered);
    }

    size_t total = n_filtered * n_key * n_sign;
    kappy_nac_offsets_t *candidates = calloc(total, sizeof(kappy_nac_offsets_t));
    if (!candidates) {
        return -1;
    }
    size_t n = 0;
    for (size_t ii = 0; ii < n_filtered; ii++) {
        for (size_t kk = 0; kk < n_key; kk++) {
            for (size_t ss = 0; ss < n_sign; ss++) {
                candidates[n++] = (kappy_nac_offsets_t){
                    .reference_symbol = "IDSProtoKeyTransparencyTrustedServiceReadFrom",
                    .reference_address = reference,
                    .nac_init_address = filtered[ii],
                    .nac_key_establishment_address = keys[kk],
                    .nac_sign_address = signs[ss],
                };
            }
        }
    }
    *out_candidates = candidates;
    *out_count = n;
    return 0;
}

int kappy_nac_find_triple_key_anchor(uint32_t key_anchor, kappy_nac_offsets_t *found) {
    const char *path = "/System/Library/PrivateFrameworks/IDS.framework/identityservicesd.app/Contents/MacOS/identityservicesd";
    NSData *slice = arm64e_file_slice(@(path));
    if (!slice) {
        return -10;
    }
    if (search_key_anchor_nested(slice.bytes, slice.length, key_anchor, 0x100000, found) == 0) {
        return 0;
    }
    kappy_nac_offsets_t predicted = kappy_nac_candidate_offsets(current_reference_address(), key_anchor, 1);
    fprintf(stderr, "trying macOS 15 delta prediction init=%#x key=%#x sign=%#x\n", predicted.nac_init_address,
            predicted.nac_key_establishment_address, predicted.nac_sign_address);
    if (try_triple_sign_only(&predicted) == 0) {
        *found = predicted;
        return 0;
    }
    fprintf(stderr, "nested key-anchor search failed; trying global obfuscated-init cert scan...\n");
    uint32_t global_inits[512];
    size_t n_global = 0;
    collect_obfuscated_init(global_inits, &n_global, 512, slice.bytes, slice.length, 0x750000, 0x350000);
    fprintf(stderr, "global obfuscated-init candidates: %zu\n", n_global);
    for (size_t i = 0; i < n_global; i++) {
        if ((i % 20) == 0) {
            fprintf(stderr, "\r[global-cert] %zu/%zu...", i + 1, n_global);
            fflush(stderr);
        }
        if (kappy_nac_cert_probe_init(global_inits[i], current_reference_address()) != 0) {
            continue;
        }
        fprintf(stderr, "\n  global cert-valid init: %#x -> resolve\n", global_inits[i]);
        if (kappy_nac_find_triple_for_init(global_inits[i], found) == 0) {
            return 0;
        }
    }
    fprintf(stderr, "\nglobal obfuscated-init scan found no working triple\n");
    return -1;
}

int kappy_nac_find_triple_for_init(uint32_t init_off, kappy_nac_offsets_t *found) {
    const uint32_t reference = current_reference_address();
    const char *path = "/System/Library/PrivateFrameworks/IDS.framework/identityservicesd.app/Contents/MacOS/identityservicesd";
    NSData *slice = arm64e_file_slice(@(path));
    if (!slice) {
        return -10;
    }
    const uint8_t *blob = slice.bytes;
    size_t blob_len = slice.length;

    uint32_t keys[32];
    uint32_t signs[256];
    size_t n_key = 0, n_sign = 0;
    collect_all_keyest(keys, &n_key, 32, blob, blob_len, init_off, 0x100000);
    collect_sign_nac(signs, &n_sign, 256, blob, blob_len, init_off, 0x100000);
    if (n_sign == 0) {
        collect_nearby(signs, &n_sign, 256, blob, blob_len, init_off, 0x100000, true, false);
    }

    fprintf(stderr, "resolve triple for init=%#x: %zu keys x %zu signs\n", init_off, n_key, n_sign);
    kappy_nac_set_guarded_quiet(true);
    size_t tried = 0;
    for (size_t kk = 0; kk < n_key; kk++) {
        for (size_t ss = 0; ss < n_sign; ss++) {
            tried++;
            kappy_nac_offsets_t offs = {
                .reference_symbol = "IDSProtoKeyTransparencyTrustedServiceReadFrom",
                .reference_address = reference,
                .nac_init_address = init_off,
                .nac_key_establishment_address = keys[kk],
                .nac_sign_address = signs[ss],
            };
            int rc = try_triple_fork(&offs);
            if (rc == 0) {
                fprintf(stderr, "validated triple init=%#x key=%#x sign=%#x (tried %zu)\n", offs.nac_init_address,
                        offs.nac_key_establishment_address, offs.nac_sign_address, tried);
                *found = offs;
                return 0;
            }
            if (tried % 10 == 0) {
                fprintf(stderr, "\r[resolve] %zu...", tried);
            }
        }
    }
    kappy_nac_set_guarded_quiet(false);
    fprintf(stderr, "\nno triple for init %#x after %zu attempts\n", init_off, tried);
    return -1;
}

int kappy_nac_find_triple_fast(kappy_nac_offsets_t *found) {
    uint32_t key_anchor = 0x7e530c;
    (void)kappy_nac_current_key_anchor(&key_anchor);
    return kappy_nac_find_triple_key_anchor(key_anchor, found);
}
