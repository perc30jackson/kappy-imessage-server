#ifndef KAPPY_NAC_PROXY_H
#define KAPPY_NAC_PROXY_H

#include <stddef.h>
#include <stdint.h>

int kappy_nac_proxy_init(void *addr, const uint8_t *cert, size_t cert_len, void **out_ctx, void **out_req,
                         int *out_req_len);
int kappy_nac_proxy_key_establishment(void *addr, void *ctx, const uint8_t *response, size_t response_len);
int kappy_nac_proxy_sign(void *addr, void *ctx, void **out_data, int *out_len);

#endif
