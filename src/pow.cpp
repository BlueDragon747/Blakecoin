// Copyright (c) 2009-2010 Satoshi Nakamoto
// Copyright (c) 2009-2016 The Bitcoin Core developers
// Copyright (c) 2013-2026 The Blakecoin Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include "pow.h"

#include "arith_uint256.h"
#include "chain.h"
#include "primitives/block.h"
#include "uint256.h"
#include "utilstrencodings.h"
#include "util.h"

// BEGIN BLAKECOIN: Blakecoin difficulty adjustment algorithm
// Difficulty adjustment every 20 blocks (1 hour with 3-minute blocks)
// Max difficulty increase: 15% (3% after block 3500)
// Max difficulty decrease: 50%

unsigned int GetNextWorkRequired(const CBlockIndex* pindexLast, const CBlockHeader *pblock, const Consensus::Params& params)
{
    assert(pindexLast != nullptr);
    unsigned int nProofOfWorkLimit = UintToArith256(params.powLimit).GetCompact();

    // Only change once per difficulty adjustment interval (every 20 blocks for Blakecoin)
    if ((pindexLast->nHeight+1) % params.DifficultyAdjustmentInterval() != 0)
    {
        if (params.fPowAllowMinDifficultyBlocks)
        {
            // Special difficulty rule for testnet:
            // If the new block's timestamp is more than 2* 3 minutes (Blakecoin)
            // then allow mining of a min-difficulty block.
            if (pblock->GetBlockTime() > pindexLast->GetBlockTime() + params.nPowTargetSpacing*2)
                return nProofOfWorkLimit;
            else
            {
                // Return the last non-special-min-difficulty-rules-block
                const CBlockIndex* pindex = pindexLast;
                while (pindex->pprev && pindex->nHeight % params.DifficultyAdjustmentInterval() != 0 && pindex->nBits == nProofOfWorkLimit)
                    pindex = pindex->pprev;
                return pindex->nBits;
            }
        }
        return pindexLast->nBits;
    }

    // Go back by what we want to be 1 hour worth of blocks (20 blocks for Blakecoin)
    int nHeightFirst = pindexLast->nHeight - (params.DifficultyAdjustmentInterval()-1);
    assert(nHeightFirst >= 0);
    const CBlockIndex* pindexFirst = pindexLast->GetAncestor(nHeightFirst);
    assert(pindexFirst);

    LogPrintf("DEBUG: GetNextWorkRequired at height %d (next block)\n", pindexLast->nHeight + 1);
    LogPrintf("DEBUG:   pindexLast height: %d, nBits: 0x%08x, time: %d\n", pindexLast->nHeight, pindexLast->nBits, pindexLast->GetBlockTime());
    LogPrintf("DEBUG:   pindexFirst height: %d, time: %d\n", pindexFirst->nHeight, pindexFirst->GetBlockTime());

    return CalculateNextWorkRequired(pindexLast, pindexFirst->GetBlockTime(), params);
}

unsigned int CalculateNextWorkRequired(const CBlockIndex* pindexLast, int64_t nFirstBlockTime, const Consensus::Params& params)
{
    if (params.fPowNoRetargeting)
        return pindexLast->nBits;

    // Blakecoin: Calculate actual timespan over 20 blocks
    int64_t nActualTimespan = pindexLast->GetBlockTime() - nFirstBlockTime;
    int64_t nTargetTimespan = params.nPowTargetTimespan; // 1 hour (20 blocks * 3 minutes)

    // BEGIN BLAKECOIN: Difficulty adjustment limits (from original Blakecoin main.cpp)
    // Max difficulty increase: 15% (for early blocks), 3% after height 3500 (only if timespan too fast)
    // Max difficulty decrease: 50%
    int64_t nMinActualTimespan = nTargetTimespan * 100 / 115;  // Up 15% max (3495 sec for 1 hour)
    int64_t nMinActualTimespan3Pct = nTargetTimespan * 100 / 103;  // Up 3% max (3495 sec for 1 hour)  
    int64_t nMaxActualTimespan = nTargetTimespan * 2;      // Down 50% max

    // Original Blakecoin logic: 3% limit only applies when blocks are mined too fast (< nTargetTimespan/4)
    // AND height >= 3500
    if (nActualTimespan < nTargetTimespan/4 && pindexLast->nHeight >= 3500)
    {
        nActualTimespan = nMinActualTimespan3Pct;  // Apply 3% limit only when too fast
    }
    else if (nActualTimespan < nMinActualTimespan && pindexLast->nHeight < 3500)
    {
        nActualTimespan = nMinActualTimespan;  // Apply 15% limit for blocks before 3500
    }
    
    if (nActualTimespan > nMaxActualTimespan)
        nActualTimespan = nMaxActualTimespan;
    // END BLAKECOIN

    LogPrintf("DEBUG:   nActualTimespan clamped: %d seconds\n", nActualTimespan);

    // Retarget
    const arith_uint256 bnPowLimit = UintToArith256(params.powLimit);
    arith_uint256 bnNew;
    bnNew.SetCompact(pindexLast->nBits);
    
    LogPrintf("DEBUG:   bnNew before retarget: 0x%s (compact: 0x%08x)\n", bnNew.GetHex(), pindexLast->nBits);
    
    bnNew *= nActualTimespan;
    bnNew /= nTargetTimespan;

    LogPrintf("DEBUG:   bnNew after retarget: 0x%s (compact: 0x%08x)\n", bnNew.GetHex(), bnNew.GetCompact());

    if (bnNew > bnPowLimit)
        bnNew = bnPowLimit;

    return bnNew.GetCompact();
}

// BEGIN BLAKECOIN: CheckProofOfWork for Blakecoin
bool CheckProofOfWork(uint256 hash, unsigned int nBits, const Consensus::Params& params)
{
    bool fNegative;
    bool fOverflow;
    arith_uint256 bnTarget;

    bnTarget.SetCompact(nBits, &fNegative, &fOverflow);

    // Check range
    if (fNegative || bnTarget == 0 || fOverflow || bnTarget > UintToArith256(params.powLimit))
        return false;

    // Hash is already in correct byte order for UintToArith256 (little-endian)
    // UintToArith256 uses ReadLE32 which correctly interprets the bytes
    arith_uint256 bnHash = UintToArith256(hash);
    
    if (bnHash > bnTarget)
        return false;

    return true;
}
// END BLAKECOIN
