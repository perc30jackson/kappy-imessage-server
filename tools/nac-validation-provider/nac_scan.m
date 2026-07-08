#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonCrypto.h>
#include <dlfcn.h>
#include <mach/machine.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "nac_scan.h"
#include "offsets.h"
#include "meow_memory.h"
#include "nac_proxy.h"

static const char *kIdentityServicesd =
    "/System/Library/PrivateFrameworks/IDS.framework/identityservicesd.app/Contents/MacOS/identityservicesd";

typedef int (*nac_init_fn)(void *cert_bytes, int cert_len, void **out_ctx, void **out_req, int *out_req_len);

static const uint8_t *g_probe_cert = NULL;
static size_t g_probe_cert_len = 0;

static void *g_dl_handle = NULL;
static void *g_image_base = NULL;

static const uint8_t kPacibsp[4] = {0x7f, 0x23, 0x03, 0xd5};
static const uint8_t kNacInitPrologue8[8] = {0x7f, 0x23, 0x03, 0xd5, 0xfc, 0x6f, 0xba, 0xa9};
static const uint8_t kNacKeyEstPrologue12[12] = {0x7f, 0x23, 0x03, 0xd5, 0xff, 0xc3, 0x05, 0xd1,
                                                0xfc, 0x6f, 0x11, 0xa9};

void kappy_nac_set_probe_cert(const uint8_t *cert, size_t len) {
    g_probe_cert = cert;
    g_probe_cert_len = len;
}

static NSData *read_file(NSString *path) {
    return [NSData dataWithContentsOfFile:path];
}

static NSData *arm64e_slice(NSData *file) {
    const uint8_t *data = file.bytes;
    size_t len = file.length;
    if (len < sizeof(struct fat_header)) {
        return nil;
    }
    const struct fat_header *fat = (const struct fat_header *)data;
    if (OSSwapBigToHostInt32(fat->magic) != FAT_MAGIC) {
        return file;
    }
    uint32_t nfat = OSSwapBigToHostInt32(fat->nfat_arch);
    const struct fat_arch *archs = (const struct fat_arch *)(data + sizeof(struct fat_header));
    for (uint32_t i = 0; i < nfat; i++) {
        uint32_t cputype = OSSwapBigToHostInt32(archs[i].cputype);
#if defined(__arm64__)
        if (cputype == CPU_TYPE_ARM64) {
#else
        if (cputype == CPU_TYPE_X86_64) {
#endif
            uint32_t offset = OSSwapBigToHostInt32(archs[i].offset);
            uint32_t size = OSSwapBigToHostInt32(archs[i].size);
            if (offset + size > len) {
                return nil;
            }
            return [NSData dataWithBytes:data + offset length:size];
        }
    }
    return nil;
}

static int ensure_image_base(uint32_t reference_address) {
    if (g_image_base != NULL) {
        return 0;
    }
    g_dl_handle = dlopen(kIdentityServicesd, RTLD_LAZY);
    if (!g_dl_handle) {
        return -1;
    }
    void *ref = dlsym(g_dl_handle, "IDSProtoKeyTransparencyTrustedServiceReadFrom");
    if (!ref) {
        return -2;
    }
    g_image_base = (uint8_t *)ref - reference_address;
    return 0;
}

static sigjmp_buf g_probe_jmp;
static volatile sig_atomic_t g_in_probe = 0;

static void probe_fault_handler(int sig) {
    (void)sig;
    if (g_in_probe) {
        siglongjmp(g_probe_jmp, 1);
    }
}

static int call_sanity(nac_init_fn init) {
    struct sigaction sa = {0};
    struct sigaction old_segv = {0};
    struct sigaction old_bus = {0};
    sa.sa_handler = probe_fault_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;
    sigaction(SIGSEGV, &sa, &old_segv);
    sigaction(SIGBUS, &sa, &old_bus);

    g_in_probe = 1;
    int result = -1;
    if (sigsetjmp(g_probe_jmp, 1) == 0) {
        int resp = init(NULL, 0, NULL, NULL, NULL);
        result = resp == -44023 ? 0 : 1;
    }
    g_in_probe = 0;

    sigaction(SIGSEGV, &old_segv, NULL);
    sigaction(SIGBUS, &old_bus, NULL);
    return result;
}

static int call_cert_init(nac_init_fn init) {
    if (!g_probe_cert || g_probe_cert_len == 0) {
        return -3;
    }
    struct sigaction sa = {0};
    struct sigaction old_segv = {0};
    struct sigaction old_bus = {0};
    sa.sa_handler = probe_fault_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;
    sigaction(SIGSEGV, &sa, &old_segv);
    sigaction(SIGBUS, &sa, &old_bus);

    g_in_probe = 1;
    int result = -1;
    if (sigsetjmp(g_probe_jmp, 1) == 0) {
        void *ctx = NULL;
        void *req_ptr = NULL;
        int req_len = 0;
        int resp = init((void *)g_probe_cert, (int)g_probe_cert_len, &ctx, &req_ptr, &req_len);
        if (resp == 0 && req_ptr != NULL && req_len > 16 && req_len < 65536) {
            result = 0;
        } else {
            result = 1;
        }
    }
    g_in_probe = 0;

    sigaction(SIGSEGV, &old_segv, NULL);
    sigaction(SIGBUS, &old_bus, NULL);
    return result;
}

static int call_sanity_fork(uint32_t init_offset, uint32_t reference) {
    pid_t pid = fork();
    if (pid == 0) {
        @autoreleasepool {
            if (ensure_image_base(reference) != 0) {
                _exit(2);
            }
            nac_init_fn init = (nac_init_fn)((uint8_t *)g_image_base + init_offset);
            _exit(call_sanity(init) == 0 ? 0 : 1);
        }
    }
    if (pid < 0) {
        return -1;
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        return -1;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 1;
}

static int call_cert_init_fork(uint32_t init_offset, uint32_t reference) {
    pid_t pid = fork();
    if (pid == 0) {
        freopen("/dev/null", "w", stderr);
        @autoreleasepool {
            if (ensure_image_base(reference) != 0) {
                _exit(2);
            }
            nac_init_fn init = (nac_init_fn)((uint8_t *)g_image_base + init_offset);
            _exit(call_cert_init(init) == 0 ? 0 : 1);
        }
    }
    if (pid < 0) {
        return -1;
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        return -1;
    }
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        return 0;
    }
    return 1;
}

typedef struct {
    uint32_t *items;
    size_t count;
    size_t cap;
} offset_list_t;

static void offset_list_push(offset_list_t *list, uint32_t value) {
    if (list->count == list->cap) {
        size_t new_cap = list->cap == 0 ? 64 : list->cap * 2;
        list->items = realloc(list->items, new_cap * sizeof(uint32_t));
        list->cap = new_cap;
    }
    list->items[list->count++] = value;
}

static bool offset_list_contains(const offset_list_t *list, uint32_t value) {
    for (size_t i = 0; i < list->count; i++) {
        if (list->items[i] == value) {
            return true;
        }
    }
    return false;
}

static void collect_priority_candidates(const uint8_t *blob, size_t blob_len, offset_list_t *out) {
    static const uint32_t kPriorityInits[] = {0x7e3a44, 0x7fd004};
    for (size_t i = 0; i < sizeof(kPriorityInits) / sizeof(kPriorityInits[0]); i++) {
        offset_list_push(out, kPriorityInits[i]);
    }

    const uint32_t window = 0x25000;
    for (uint32_t off = 0; off + 12 <= blob_len; off += 4) {
        if (memcmp(blob + off, kNacKeyEstPrologue12, 12) != 0) {
            continue;
        }
        // Focus on the KeyEst hit binsearch finds on macOS 26.5.x arm64e.
        if (off < 0x7e0000 || off > 0x7f0000) {
            continue;
        }
        uint32_t key_est = off;
        (void)key_est;
        uint32_t lo = off > window ? off - window : 0;
        uint32_t hi = off + window;
        if (hi > blob_len) {
            hi = (uint32_t)blob_len;
        }
        for (uint32_t init = lo; init + 8 <= hi; init += 4) {
            if (memcmp(blob + init, kNacInitPrologue8, 8) == 0) {
                if (!offset_list_contains(out, init)) {
                    offset_list_push(out, init);
                }
                continue;
            }
            if (memcmp(blob + init, kPacibsp, 4) == 0 && blob[init + 4] == 0xff) {
                if (!offset_list_contains(out, init)) {
                    offset_list_push(out, init);
                }
            }
        }
        break;
    }
}

static void collect_prologue_candidates(const uint8_t *blob, size_t blob_len, uint32_t start, uint32_t end,
                                        offset_list_t *out) {
    if (end >= blob_len) {
        end = (uint32_t)blob_len - 1;
    }
    for (uint32_t off = start; off + 8 <= end; off += 4) {
        if (memcmp(blob + off, kNacInitPrologue8, 8) == 0) {
            offset_list_push(out, off);
        }
    }
}

static void log_progress(const char *phase, size_t done, size_t total, size_t hits, time_t started) {
    time_t now = time(NULL);
    double elapsed = difftime(now, started);
    double pct = total ? (100.0 * (double)done / (double)total) : 100.0;
    fprintf(stderr, "\r[%s] %zu/%zu (%.1f%%) hits=%zu elapsed=%.0fs   ", phase, done, total, pct, hits, elapsed);
    fflush(stderr);
}

int kappy_nac_cert_probe_init(uint32_t init_offset, uint32_t reference) {
    if (!g_probe_cert || g_probe_cert_len == 0) {
        return 1;
    }
    return call_cert_init_fork(init_offset, reference) == 0 ? 0 : 1;
}

int kappy_nac_probe_init(uint32_t init_offset, uint32_t reference) {
    if (ensure_image_base(reference) != 0) {
        return -1;
    }
    nac_init_fn init = (nac_init_fn)((uint8_t *)g_image_base + init_offset);
    int sanity = call_sanity(init);
    fprintf(stderr, "probe %#x sanity=%d\n", init_offset, sanity);
    if (!g_probe_cert) {
        return sanity;
    }
    struct sigaction sa = {0};
    sa.sa_handler = probe_fault_handler;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    g_in_probe = 1;
    if (sigsetjmp(g_probe_jmp, 1) == 0) {
        void *ctx = NULL;
        void *req_ptr = NULL;
        int req_len = 0;
        kappy_meow_scope *scope = kappy_meow_enter();
        if (!scope) {
            fprintf(stderr, "probe %#x cert meow enter failed\n", init_offset);
        } else {
            int resp = kappy_nac_proxy_init(init, g_probe_cert, g_probe_cert_len, &ctx, &req_ptr, &req_len);
            kappy_meow_leave(scope);
            fprintf(stderr, "probe %#x cert resp=%d req_ptr=%p req_len=%d\n", init_offset, resp, req_ptr, req_len);
        }
    } else {
        fprintf(stderr, "probe %#x cert fault (SIGSEGV/SIGBUS)\n", init_offset);
    }
    g_in_probe = 0;
    return 0;
}

int kappy_nac_find_init_offset_fast(uint32_t start, uint32_t end, int workers, uint32_t *found_init) {
    (void)workers;
    time_t started = time(NULL);

#if defined(__arm64__)
    const uint32_t reference = 0x0712b4;
#else
    const uint32_t reference = 0x0787a1;
#endif

    NSData *file = read_file(@(kIdentityServicesd));
    if (!file) {
        fprintf(stderr, "failed to read %s\n", kIdentityServicesd);
        return -10;
    }
    NSData *slice = arm64e_slice(file);
    if (!slice) {
        fprintf(stderr, "failed to locate arm64 slice\n");
        return -11;
    }

    offset_list_t prologue = {0};
    collect_priority_candidates(slice.bytes, slice.length, &prologue);
    if (prologue.count == 0) {
        collect_prologue_candidates(slice.bytes, slice.length, start, end, &prologue);
    }
    fprintf(stderr, "candidate set: %zu offsets (priority KeyEst+NACInit8, else range %#x-%#x)\n", prologue.count,
            start, end);

    if (ensure_image_base(reference) != 0) {
        fprintf(stderr, "failed to dlopen identityservicesd\n");
        free(prologue.items);
        return -12;
    }

    // Small candidate sets: in-process sigsetjmp (fork breaks some NACInit cert paths).
    bool use_fork = prologue.count > 64;
    for (size_t i = 0; i < prologue.count; i++) {
        if ((i % 5) == 0 || i + 1 == prologue.count) {
            log_progress("cert", i + 1, prologue.count, 0, started);
        }
        int ok = 0;
        if (use_fork) {
            ok = call_cert_init_fork(prologue.items[i], reference) == 0;
        } else {
            nac_init_fn init = (nac_init_fn)((uint8_t *)g_image_base + prologue.items[i]);
            ok = call_cert_init(init) == 0;
        }
        if (ok) {
            fprintf(stderr, "\n  cert-validated NACInit: %#x\n", prologue.items[i]);
            *found_init = prologue.items[i];
            free(prologue.items);
            return 0;
        }
    }

    fprintf(stderr, "\nno cert-validated hit in prologue set\n");
    free(prologue.items);
    return -1;
}

static int call_sanity_at_offset(uint32_t off) {
    nac_init_fn init = (nac_init_fn)((uint8_t *)g_image_base + off);
    return call_sanity(init);
}

static int call_sanity_at_offset_fork(uint32_t off, uint32_t reference) {
    pid_t pid = fork();
    if (pid == 0) {
        freopen("/dev/null", "w", stderr);
        @autoreleasepool {
            if (ensure_image_base(reference) != 0) {
                _exit(2);
            }
            _exit(call_sanity_at_offset(off) == 0 ? 0 : 1);
        }
    }
    if (pid < 0) {
        return -1;
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        return -1;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 1;
}

int kappy_nac_brute_find_init_cert(uint32_t start, uint32_t end, uint32_t *found_init) {
#if defined(__arm64__)
    const uint32_t reference = 0x0712b4;
#else
    const uint32_t reference = 0x0787a1;
#endif
    if (!g_probe_cert || g_probe_cert_len == 0) {
        return -3;
    }
    if (ensure_image_base(reference) != 0) {
        return -12;
    }

    NSData *file = read_file(@(kIdentityServicesd));
    NSData *slice = arm64e_slice(file);
    if (!slice) {
        return -11;
    }
    if (end > slice.length) {
        end = (uint32_t)slice.length;
    }

    time_t started = time(NULL);
    size_t tried = 0;
    size_t sanity_hits = 0;
    const uint8_t *blob = slice.bytes;
    for (uint32_t off = start; off + 4 <= end; off += 4) {
        if (memcmp(blob + off, kPacibsp, 4) != 0) {
            continue;
        }
        tried++;
        if (call_sanity_at_offset_fork(off, reference) != 0) {
            if ((tried % 250) == 0) {
                log_progress("sanity", tried, (end - start) / 4, sanity_hits, started);
            }
            continue;
        }
        sanity_hits++;
        fprintf(stderr, "\n  sanity hit %#x, testing cert...\n", off);
        if (call_cert_init_fork(off, reference) == 0) {
            fprintf(stderr, "  brute cert-validated NACInit: %#x (sanity=%zu tried=%zu)\n", off, sanity_hits, tried);
            *found_init = off;
            return 0;
        }
    }
    fprintf(stderr, "\nno brute cert hit (sanity=%zu pacibsp=%zu in %#x-%#x)\n", sanity_hits, tried, start, end);
    return -1;
}
