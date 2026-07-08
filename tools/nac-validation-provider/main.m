#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <unistd.h>
#include "offsets.h"
#include "nac_scan.h"
#include "nac_validate.h"
#include "nac_pac.h"

int kappy_nac_load_for_current_os(void);
int kappy_nac_lookup_offsets_for_current_os(kappy_nac_offsets_t *offs);
int kappy_nac_try_offsets(const kappy_nac_offsets_t *offs);
int kappy_nac_get_loaded_offsets(kappy_nac_offsets_t *offs);
int kappy_nac_sanity_check(void);
int kappy_nac_find_init_offset_fast(uint32_t start, uint32_t end, int workers, uint32_t *found_init);
int kappy_nac_brute_find_init_cert(uint32_t start, uint32_t end, uint32_t *found_init);
int kappy_nac_probe_init(uint32_t init_offset, uint32_t reference);
NSData *kappy_fetch_validation_cert(NSError **error);
NSData *kappy_initialize_validation(NSData *request, NSError **error);
int kappy_nac_init(const uint8_t *cert, size_t cert_len, void **out_ctx, NSData **out_request);
int kappy_nac_key_establishment(void *ctx, const uint8_t *response, size_t response_len);
int kappy_nac_sign(void *ctx, NSData **out_validation);

static NSData *post_plist(NSString *urlString, id body, NSError **error) {
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:body ? @"POST" : @"GET"];
    [req setValue:@"application/x-apple-plist" forHTTPHeaderField:@"Content-Type"];
    if (body) {
        NSData *encoded = [NSPropertyListSerialization dataWithPropertyList:body
                                                                     format:NSPropertyListXMLFormat_v1_0
                                                                    options:0
                                                                      error:error];
        if (!encoded) {
            return nil;
        }
        [req setHTTPBody:encoded];
    }
    NSURLResponse *resp = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:error];
    if (!data) {
        return nil;
    }
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
    if (http.statusCode != 200) {
        if (error) {
            *error = [NSError errorWithDomain:@"kappy.nac" code:http.statusCode userInfo:@{NSLocalizedDescriptionKey: @"unexpected status"}];
        }
        return nil;
    }
    return data;
}

NSData *kappy_fetch_validation_cert(NSError **error) {
    NSData *resp = post_plist(@"http://static.ess.apple.com/identity/validation/cert-1.0.plist", nil, error);
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

NSData *kappy_initialize_validation(NSData *request, NSError **error) {
    NSDictionary *body = @{@"session-info-request": request};
    NSData *resp = post_plist(@"https://identity.ess.apple.com/WebObjects/TDIdentityService.woa/wa/initializeValidation", body, error);
    if (!resp) {
        return nil;
    }
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:resp options:0 format:NULL error:error];
    NSData *session = plist[@"session-info"];
    if (![session isKindOfClass:[NSData class]] || session.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"kappy.nac" code:2 userInfo:@{NSLocalizedDescriptionKey: @"missing session-info"}];
        }
        return nil;
    }
    return session;
}

static NSData *generate_validation_blob(NSError **error) {
    NSData *cert = kappy_fetch_validation_cert(error);
    if (!cert) {
        return nil;
    }
    void *ctx = NULL;
    NSData *request = nil;
    int rc = kappy_nac_init(cert.bytes, cert.length, &ctx, &request);
    if (rc != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"kappy.nac" code:rc userInfo:@{NSLocalizedDescriptionKey: @"NACInit failed"}];
        }
        return nil;
    }
    NSData *session = kappy_initialize_validation(request, error);
    if (!session) {
        return nil;
    }
    rc = kappy_nac_key_establishment(ctx, session.bytes, session.length);
    if (rc != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"kappy.nac" code:rc userInfo:@{NSLocalizedDescriptionKey: @"NACKeyEstablishment failed"}];
        }
        return nil;
    }
    NSData *validation = nil;
    rc = kappy_nac_sign(ctx, &validation);
    if (rc != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"kappy.nac" code:rc userInfo:@{NSLocalizedDescriptionKey: @"NACSign failed"}];
        }
        return nil;
    }
    return validation;
}

static void print_json_validation(NSData *validation) {
    NSDate *validUntil = [[NSDate date] dateByAddingTimeInterval:15 * 60];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    NSDictionary *payload = @{
        @"validation_data": [validation base64EncodedStringWithOptions:0],
        @"valid_until": [fmt stringFromDate:validUntil],
        @"nacserv_commit": @"kappy-nac-wrapper",
    };
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (!json) {
        fprintf(stderr, "json encode failed: %s\n", error.localizedDescription.UTF8String);
        return;
    }
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
}

static void submit_validation(NSString *urlString, NSData *validation) {
    NSDate *validUntil = [[NSDate date] dateByAddingTimeInterval:15 * 60];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    NSDictionary *payload = @{
        @"validation_data": validation,
        @"valid_until": [fmt stringFromDate:validUntil],
        @"nacserv_commit": @"kappy-nac-wrapper",
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = body;
    NSError *error = nil;
    NSURLResponse *resp = nil;
    [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&error];
    if (error) {
        fprintf(stderr, "submit failed: %s\n", error.localizedDescription.UTF8String);
    } else {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        fprintf(stderr, "submitted validation (status %ld)\n", (long)http.statusCode);
    }
}

static void init_executable_path(void) {
    char path[PATH_MAX];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) == 0) {
        kappy_nac_set_executable_path(path);
    }
}

static int run_worker_generate(const char *init_hex, const char *key_hex, const char *sign_hex) {
    const char *fd_env = getenv("KAPPY_WORKER_PIPE_FD");
    if (!fd_env) {
        return 127;
    }
    int pipefd = atoi(fd_env);
    kappy_nac_offsets_t offs = {
        .reference_symbol = "IDSProtoKeyTransparencyTrustedServiceReadFrom",
#if defined(__arm64__)
        .reference_address = 0x0712b4,
#else
        .reference_address = 0x0787a1,
#endif
    };
    sscanf(init_hex, "%x", &offs.nac_init_address);
    sscanf(key_hex, "%x", &offs.nac_key_establishment_address);
    sscanf(sign_hex, "%x", &offs.nac_sign_address);
    kappy_nac_apply_reference_override(&offs);

    void *bytes = NULL;
    size_t len = 0;
    int rc = kappy_nac_generate_with_offsets(&offs, &bytes, &len);
    struct {
        int rc;
        uint32_t len;
    } hdr = {rc, (uint32_t)len};
    (void)write(pipefd, &hdr, sizeof(hdr));
    if (rc == 0 && bytes != NULL && len > 0) {
        (void)write(pipefd, bytes, len);
        free(bytes);
    } else if (bytes) {
        free(bytes);
    }
    close(pipefd);
    return rc == 0 ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 5 && strcmp(argv[1], "-worker-generate") == 0) {
            return run_worker_generate(argv[2], argv[3], argv[4]);
        }
        init_executable_path();
        BOOL once = NO;
        BOOL check = NO;
        BOOL find = NO;
        BOOL brute = NO;
        BOOL resolve = NO;
        uint32_t resolve_init = 0;
        BOOL test_generate = NO;
        BOOL try_offsets = NO;
        BOOL probe = NO;
        uint32_t probe_off = 0;
        BOOL pac_scan = NO;
        BOOL pac_resolve = NO;
        NSTimeInterval interval = 0;
        NSMutableArray<NSString *> *submitURLs = [NSMutableArray array];

        int workers = 0;
        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"-once"]) {
                once = YES;
            } else if ([arg isEqualToString:@"-check-compatibility"]) {
                check = YES;
            } else if ([arg isEqualToString:@"-find-offsets"]) {
                find = YES;
            } else if ([arg isEqualToString:@"-brute-init"]) {
                brute = YES;
            } else if ([arg isEqualToString:@"-test-generate"]) {
                test_generate = YES;
            } else if ([arg isEqualToString:@"-try-offsets"]) {
                try_offsets = YES;
            } else if ([arg isEqualToString:@"-resolve-init"] && i + 1 < argc) {
                resolve = YES;
                resolve_init = strtoul(argv[++i], NULL, 0);
            } else if ([arg hasPrefix:@"-probe="]) {
                probe = YES;
                probe_off = strtoul([[arg substringFromIndex:7] UTF8String], NULL, 0);
            } else if ([arg isEqualToString:@"-probe"] && i + 1 < argc) {
                probe = YES;
                probe_off = strtoul(argv[++i], NULL, 0);
            } else if ([arg isEqualToString:@"-pac-scan"]) {
                pac_scan = YES;
            } else if ([arg isEqualToString:@"-pac-resolve"]) {
                pac_resolve = YES;
            } else if ([arg hasPrefix:@"-workers="]) {
                workers = [[arg substringFromIndex:9] intValue];
            } else if ([arg isEqualToString:@"-workers"] && i + 1 < argc) {
                workers = [[NSString stringWithUTF8String:argv[++i]] intValue];
            } else if ([arg hasPrefix:@"-submit-interval="]) {
                interval = [[arg substringFromIndex:16] doubleValue];
            } else if ([arg isEqualToString:@"-submit-interval"] && i + 1 < argc) {
                interval = [[NSString stringWithUTF8String:argv[++i]] doubleValue];
            } else if ([arg hasPrefix:@"http://"] || [arg hasPrefix:@"https://"]) {
                [submitURLs addObject:arg];
            }
        }

        if (probe) {
            NSError *error = nil;
            NSData *cert = kappy_fetch_validation_cert(&error);
            if (cert) {
                kappy_nac_set_probe_cert(cert.bytes, cert.length);
            }
            uint32_t reference = 0x0712b4;
            (void)kappy_nac_current_reference(&reference);
            return kappy_nac_probe_init(probe_off, reference);
        }

        if (pac_scan) {
            if (kappy_nac_pac_load() != 0) {
                return 1;
            }
            kappy_nac_pac_dump_bindings();
            const uint32_t watch[] = {0x2a7360, 0x7e530c, 0x6d5d98, 0x2335e8};
            for (size_t i = 0; i < sizeof(watch) / sizeof(watch[0]); i++) {
                kappy_nac_auth_binding_t b = {0};
                if (kappy_nac_pac_stub_for_impl(watch[i], &b) == 0) {
                    fprintf(stderr, "watch impl=%#x -> stub=%#x got=%#x\n", watch[i], b.stub_offset, b.auth_got_offset);
                } else {
                    fprintf(stderr, "watch impl=%#x -> (no auth stub)\n", watch[i]);
                }
            }
            return 0;
        }

        if (pac_resolve) {
            kappy_nac_offsets_t triple = {0};
            if (kappy_nac_pac_resolve_triple(&triple) != 0) {
                return 1;
            }
            printf("init=0x%x key_est=0x%x sign=0x%x\n", triple.nac_init_address, triple.nac_key_establishment_address,
                   triple.nac_sign_address);
            fflush(stdout);
            return 0;
        }

        if (brute) {
            NSError *error = nil;
            NSData *cert = kappy_fetch_validation_cert(&error);
            if (!cert) {
                fprintf(stderr, "failed to fetch cert: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            kappy_nac_set_probe_cert(cert.bytes, cert.length);
            uint32_t init_off = 0;
#if defined(__arm64__)
            if (kappy_nac_brute_find_init_cert(0x7d0000, 0x810000, &init_off) != 0) {
                return 1;
            }
#else
            if (kappy_nac_brute_find_init_cert(0x500000, 0x900000, &init_off) != 0) {
                return 1;
            }
#endif
            printf("init=0x%x\n", init_off);
            return 0;
        }

        if (try_offsets) {
            kappy_nac_offsets_t offs = {0};
            if (kappy_nac_lookup_offsets_for_current_os(&offs) != 0) {
                fprintf(stderr, "offset lookup failed\n");
                return 10;
            }
            fprintf(stderr, "trying init=%#x key=%#x sign=%#x ref=%#x\n", offs.nac_init_address,
                    offs.nac_key_establishment_address, offs.nac_sign_address, offs.reference_address);
            int rc = kappy_nac_try_offsets(&offs);
            fprintf(stderr, "try-offsets rc=%d\n", rc);
            return rc == 0 ? 0 : 12;
        }

        if (test_generate) {
            kappy_nac_offsets_t offs = {0};
            if (kappy_nac_lookup_offsets_for_current_os(&offs) != 0) {
                fprintf(stderr, "offset lookup failed\n");
                return 10;
            }
            fprintf(stderr, "testing init=%#x key=%#x sign=%#x\n", offs.nac_init_address, offs.nac_key_establishment_address,
                    offs.nac_sign_address);
            fflush(stderr);
            void *bytes = NULL;
            size_t len = 0;
            int rc = kappy_nac_guarded_generate(&offs, &bytes, &len);
            fprintf(stderr, "result rc=%d (%s) len=%zu\n", rc, kappy_nac_generate_error_string(rc), len);
            fflush(stderr);
            if (rc == 0 && bytes != NULL && len > 0) {
                NSData *validation = [NSData dataWithBytes:bytes length:len];
                free(bytes);
                print_json_validation(validation);
                fflush(stdout);
                return 0;
            }
            if (bytes) {
                free(bytes);
            }
            return 12;
        }

        if (resolve) {
            kappy_nac_offsets_t triple = {0};
            if (kappy_nac_find_triple_for_init(resolve_init, &triple) != 0) {
                return 1;
            }
            printf("init=0x%x key_est=0x%x sign=0x%x\n", triple.nac_init_address, triple.nac_key_establishment_address,
                   triple.nac_sign_address);
            fflush(stdout);
            return 0;
        }

        if (find) {
            NSError *error = nil;
            NSData *cert = kappy_fetch_validation_cert(&error);
            if (!cert) {
                fprintf(stderr, "failed to fetch cert: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            kappy_nac_set_probe_cert(cert.bytes, cert.length);
#if defined(__arm64__)
            uint32_t start = 0x600000, end = 0x900000;
            uint32_t key_anchor = 0x7e530c;
            (void)kappy_nac_current_key_anchor(&key_anchor);
#else
            uint32_t start = 0x500000, end = 0x900000;
            const uint32_t key_anchor = 0;
#endif
            if (workers <= 0) {
                workers = 8;
            }
            uint32_t init_off = 0;
            kappy_nac_offsets_t triple = {0};
#if defined(__arm64__)
            fprintf(stderr, "searching triples around KeyEst anchor %#x...\n", key_anchor);
            if (kappy_nac_find_triple_key_anchor(key_anchor, &triple) == 0) {
                printf("init=0x%x key_est=0x%x sign=0x%x\n", triple.nac_init_address, triple.nac_key_establishment_address,
                       triple.nac_sign_address);
                return 0;
            }
            fprintf(stderr, "key-anchor search failed; brute cert scan %#x-%#x...\n", key_anchor - 0x100000,
                    key_anchor + 0x70000);
            if (kappy_nac_brute_find_init_cert(key_anchor - 0x100000, key_anchor + 0x70000, &init_off) == 0) {
                kappy_nac_offsets_t found = {0};
                if (kappy_nac_find_triple_for_init(init_off, &found) == 0) {
                    printf("init=0x%x key_est=0x%x sign=0x%x\n", found.nac_init_address, found.nac_key_establishment_address,
                           found.nac_sign_address);
                    return 0;
                }
                fprintf(stderr, "found init %#x but no working key/sign triple\n", init_off);
                return 1;
            }
#endif
            fprintf(stderr, "searching full NAC triple (init + key_est + sign)...\n");
            if (kappy_nac_find_triple_fast(&triple) == 0) {
                printf("init=0x%x key_est=0x%x sign=0x%x\n", triple.nac_init_address, triple.nac_key_establishment_address,
                       triple.nac_sign_address);
                return 0;
            }
            fprintf(stderr, "triple search failed; trying init-only scan %#x-%#x...\n", start, end);
            if (kappy_nac_find_init_offset_fast(start, end, workers, &init_off) != 0) {
                fprintf(stderr, "no cert-valid NACInit in %#x-%#x\n", start, end);
                return 1;
            }
            fprintf(stderr, "cert-valid init %#x from prologue scan; resolving key/sign...\n", init_off);
            kappy_nac_offsets_t found = {0};
            if (kappy_nac_find_triple_for_init(init_off, &found) != 0) {
                fprintf(stderr, "found init %#x but no working key/sign triple\n", init_off);
                return 1;
            }
            printf("init=0x%x key_est=0x%x sign=0x%x\n", found.nac_init_address, found.nac_key_establishment_address,
                   found.nac_sign_address);
            return 0;
        }

        if (kappy_nac_load_for_current_os() != 0) {
            fprintf(stderr, "unsupported identityservicesd build; try -find-offsets\n");
            return 10;
        }
        int sanity = kappy_nac_sanity_check();
        if (sanity != 0) {
            fprintf(stderr, "sanity check failed: %d (try -find-offsets)\n", sanity);
            return 11;
        }
        if (check) {
            fprintf(stderr, "compatibility check OK\n");
            return 0;
        }

        if (once) {
            kappy_nac_offsets_t offs = {0};
            if (kappy_nac_lookup_offsets_for_current_os(&offs) != 0) {
                fprintf(stderr, "generate failed: offset lookup failed\n");
                return 12;
            }
            void *bytes = NULL;
            size_t len = 0;
            int rc = kappy_nac_guarded_generate(&offs, &bytes, &len);
            if (rc != 0 || bytes == NULL || len == 0) {
                fprintf(stderr, "generate failed (%d): %s\n", rc, kappy_nac_generate_error_string(rc));
                if (bytes) {
                    free(bytes);
                }
                return 12;
            }
            NSData *validation = [NSData dataWithBytes:bytes length:len];
            free(bytes);
            print_json_validation(validation);
            if (validation.length == 0) {
                fprintf(stderr, "generate failed: empty validation blob\n");
                return 12;
            }
            return 0;
        }

        if (interval > 0 && submitURLs.count > 0) {
            while (true) {
                NSError *error = nil;
                NSData *validation = generate_validation_blob(&error);
                if (validation) {
                    for (NSString *url in submitURLs) {
                        submit_validation(url, validation);
                    }
                } else {
                    fprintf(stderr, "generate failed: %s\n", error.localizedDescription.UTF8String);
                }
                [NSThread sleepForTimeInterval:interval];
            }
        }

        fprintf(stderr, "usage: %s [-check-compatibility|-once|-find-offsets|-brute-init|-probe OFF|-submit-interval SECS URL...]\n", argv[0]);
        return 2;
    }
}
