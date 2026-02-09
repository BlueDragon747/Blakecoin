// Copyright (c) 2013-2026 The Blakecoin Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BLAKECOIN_CRYPTO_BLAKE256_H
#define BLAKECOIN_CRYPTO_BLAKE256_H

#include <stdint.h>
#include <stdlib.h>

// Blake-256 with 14 rounds as used by Blakecoin
class CBlake256
{
private:
    uint32_t h[8];
    uint32_t t[2];
    uint32_t buf[16];
    size_t buflen;
    size_t nullt;

    void compress(const uint8_t *block);

public:
    static const size_t OUTPUT_SIZE = 32;

    CBlake256();
    CBlake256& Write(const unsigned char* data, size_t len);
    void Finalize(unsigned char hash[OUTPUT_SIZE]);
    CBlake256& Reset();
};

#endif // BLAKECOIN_CRYPTO_BLAKE256_H
