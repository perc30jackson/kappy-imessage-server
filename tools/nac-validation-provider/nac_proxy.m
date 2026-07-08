#include "nac_proxy.h"

int kappy_nac_proxy_init(void *addr, const uint8_t *cert, size_t cert_len, void **out_ctx, void **out_req,
                         int *out_req_len) {
    int (*nac_init)(void *, int, void *, void *, int *) = addr;
    return nac_init((void *)cert, (int)cert_len, out_ctx, out_req, out_req_len);
}

int kappy_nac_proxy_key_establishment(void *addr, void *ctx, const uint8_t *response, size_t response_len) {
    int (*nac_key_establishment)(void *, void *, int) = addr;
    return nac_key_establishment(ctx, (void *)response, (int)response_len);
}

int kappy_nac_proxy_sign(void *addr, void *ctx, void **out_data, int *out_len) {
    int (*nac_sign)(void *, void *, int, void *, int *) = addr;
    return nac_sign(ctx, NULL, 0, out_data, out_len);
}
