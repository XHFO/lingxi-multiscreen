#include <CommonCrypto/CommonDigest.h>
#include "private/mbedtls/sha256.h"
int mbedtls_sha256(const unsigned char *p, size_t n, unsigned char out[32], int is224) {
    if (is224 || n > 0xffffffffu) return -1;
    return CC_SHA256(p, (CC_LONG)n, out) ? 0 : -1;
}
