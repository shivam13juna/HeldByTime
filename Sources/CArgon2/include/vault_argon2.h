#ifndef VAULT_ARGON2_H
#define VAULT_ARGON2_H

#include <stddef.h>
#include <stdint.h>
#include "argon2.h"

/*
 * vault_argon2id — single Argon2id entry point used by both the production
 * key-derivation path (secret/ad NULL) and the cross-check test (secret/ad set,
 * for the published vectors). Wraps argon2id_ctx so Swift never constructs the
 * argon2_context struct itself. Returns ARGON2_OK (0) on success, an Argon2
 * error code (negative) otherwise.
 */
int vault_argon2id(uint32_t t_cost, uint32_t m_cost, uint32_t parallelism,
                   uint32_t version,
                   const uint8_t *pwd, size_t pwdlen,
                   const uint8_t *salt, size_t saltlen,
                   const uint8_t *secret, size_t secretlen,
                   const uint8_t *ad, size_t adlen,
                   uint8_t *out, size_t outlen);

#endif /* VAULT_ARGON2_H */
