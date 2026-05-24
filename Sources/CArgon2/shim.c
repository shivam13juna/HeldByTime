#include "vault_argon2.h"
#include <string.h>

int vault_argon2id(uint32_t t_cost, uint32_t m_cost, uint32_t parallelism,
                   uint32_t version,
                   const uint8_t *pwd, size_t pwdlen,
                   const uint8_t *salt, size_t saltlen,
                   const uint8_t *secret, size_t secretlen,
                   const uint8_t *ad, size_t adlen,
                   uint8_t *out, size_t outlen) {
    argon2_context ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.out = out;
    ctx.outlen = (uint32_t)outlen;
    ctx.pwd = (uint8_t *)pwd;
    ctx.pwdlen = (uint32_t)pwdlen;
    ctx.salt = (uint8_t *)salt;
    ctx.saltlen = (uint32_t)saltlen;
    ctx.secret = (uint8_t *)secret;
    ctx.secretlen = (uint32_t)secretlen;
    ctx.ad = (uint8_t *)ad;
    ctx.adlen = (uint32_t)adlen;
    ctx.t_cost = t_cost;
    ctx.m_cost = m_cost;
    ctx.lanes = parallelism;
    ctx.threads = parallelism;
    ctx.version = version;
    ctx.allocate_cbk = NULL;
    ctx.free_cbk = NULL;
    ctx.flags = ARGON2_DEFAULT_FLAGS;
    return argon2id_ctx(&ctx);
}
