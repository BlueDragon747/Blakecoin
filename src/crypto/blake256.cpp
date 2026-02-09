// Copyright (c) 2013-2026 The Blakecoin Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include "crypto/blake256.h"

#include <string.h>

// Blake-256 constants
static const uint32_t blake256_iv[8] = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
};

// Blake-256 sigma permutation
static const uint8_t blake256_sigma[14][16] = {
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
    {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3},
    {11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4},
    {7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8},
    {9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13},
    {2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9},
    {12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11},
    {13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10},
    {6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5},
    {10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0},
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
    {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3},
    {11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4},
    {7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8}
};

// Blake-256 constants for each round
static const uint32_t blake256_cst[16] = {
    0x243f6a88, 0x85a308d3, 0x13198a2e, 0x03707344,
    0xa4093822, 0x299f31d0, 0x082efa98, 0xec4e6c89,
    0x452821e6, 0x38d01377, 0xbe5466cf, 0x34e90c6c,
    0xc0ac29b7, 0xc97c50dd, 0x3f84d5b5, 0xb5470917
};

// Helper macros
#define ROT(x, n) (((x) << (32 - (n))) | ((x) >> (n)))
#define G(a, b, c, d, e, i)                                       \
    do {                                                          \
        v[a] += (m[blake256_sigma[e][i]] ^ blake256_cst[blake256_sigma[e][i + 1]]) + v[b]; \
        v[d] = ROT(v[d] ^ v[a], 16);                             \
        v[c] += v[d];                                             \
        v[b] = ROT(v[b] ^ v[c], 12);                             \
        v[a] += (m[blake256_sigma[e][i + 1]] ^ blake256_cst[blake256_sigma[e][i]]) + v[b]; \
        v[d] = ROT(v[d] ^ v[a], 8);                              \
        v[c] += v[d];                                             \
        v[b] = ROT(v[b] ^ v[c], 7);                              \
    } while(0)

CBlake256::CBlake256()
{
    Reset();
}

CBlake256& CBlake256::Reset()
{
    for (int i = 0; i < 8; i++)
        h[i] = blake256_iv[i];
    t[0] = t[1] = 0;
    buflen = 0;
    nullt = 0;
    return *this;
}

void CBlake256::compress(const uint8_t *block)
{
    uint32_t m[16];
    uint32_t v[16];

    // Convert bytes to words
    for (int i = 0; i < 16; i++)
        m[i] = ((uint32_t)block[i * 4 + 0] << 0) |
               ((uint32_t)block[i * 4 + 1] << 8) |
               ((uint32_t)block[i * 4 + 2] << 16) |
               ((uint32_t)block[i * 4 + 3] << 24);

    // Initialize v
    for (int i = 0; i < 8; i++)
        v[i] = h[i];
    for (int i = 0; i < 8; i++)
        v[i + 8] = blake256_iv[i];

    v[12] ^= t[0];
    v[13] ^= t[1];

    if (nullt)
        v[14] = ~v[14];

    // 14 rounds for Blakecoin
    for (int r = 0; r < 14; r++) {
        G(0, 4, 8, 12, r, 0);
        G(1, 5, 9, 13, r, 2);
        G(2, 6, 10, 14, r, 4);
        G(3, 7, 11, 15, r, 6);
        G(3, 4, 9, 14, r, 14);
        G(2, 7, 8, 13, r, 12);
        G(0, 5, 10, 15, r, 8);
        G(1, 6, 11, 12, r, 10);
    }

    // Update h
    for (int i = 0; i < 8; i++)
        h[i] ^= v[i] ^ v[i + 8];
}

CBlake256& CBlake256::Write(const unsigned char* data, size_t len)
{
    size_t left = buflen;
    size_t fill = 64 - left;

    if (left && len >= fill) {
        memcpy((uint8_t*)buf + left, data, fill);
        t[0] += 512;
        if (t[0] == 0)
            t[1]++;
        compress((uint8_t*)buf);
        data += fill;
        len -= fill;
        left = 0;
    }

    while (len >= 64) {
        t[0] += 512;
        if (t[0] == 0)
            t[1]++;
        compress(data);
        data += 64;
        len -= 64;
    }

    if (len > 0) {
        memcpy((uint8_t*)buf + left, data, len);
        buflen = left + len;
    }

    return *this;
}

void CBlake256::Finalize(unsigned char hash[OUTPUT_SIZE])
{
    uint8_t msglen[8];
    uint32_t lo = t[0] + (buflen << 3);
    uint32_t hi = t[1];

    if (lo < (buflen << 3))
        hi++;

    msglen[0] = (uint8_t)(hi >> 24);
    msglen[1] = (uint8_t)(hi >> 16);
    msglen[2] = (uint8_t)(hi >> 8);
    msglen[3] = (uint8_t)hi;
    msglen[4] = (uint8_t)(lo >> 24);
    msglen[5] = (uint8_t)(lo >> 16);
    msglen[6] = (uint8_t)(lo >> 8);
    msglen[7] = (uint8_t)lo;

    if (buflen == 55) {
        t[0] -= 8;
        Write((const unsigned char*)"\x81", 1);
    } else {
        if (buflen < 55) {
            if (!buflen)
                nullt = 1;
            t[0] -= 440 - (buflen << 3);
            Write((const unsigned char*)"\x01", 1);
            while (buflen < 55)
                Write((const unsigned char*)"\x00", 1);
        } else {
            t[0] -= 512 - (buflen << 3);
            Write((const unsigned char*)"\x01", 1);
            while (buflen)
                Write((const unsigned char*)"\x00", 1);
            t[0] -= 440;
            nullt = 1;
        }
        Write((const unsigned char*)"\x00", 1);
        while (buflen < 54)
            Write((const unsigned char*)"\x00", 1);
    }
    t[0] -= 64;
    Write(msglen, 8);

    // Output hash
    for (int i = 0; i < 8; i++) {
        hash[i * 4 + 0] = (uint8_t)(h[i] >> 24);
        hash[i * 4 + 1] = (uint8_t)(h[i] >> 16);
        hash[i * 4 + 2] = (uint8_t)(h[i] >> 8);
        hash[i * 4 + 3] = (uint8_t)h[i];
    }
}

#undef ROT
#undef G
