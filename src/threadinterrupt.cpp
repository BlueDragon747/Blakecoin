// Copyright (c) 2009-2010 Satoshi Nakamoto
// Copyright (c) 2009-2016 The Bitcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include "threadinterrupt.h"

#ifdef _WIN32
#include <boost/thread/locks.hpp>
#endif

CThreadInterrupt::operator bool() const
{
    return flag.load(std::memory_order_acquire);
}

void CThreadInterrupt::reset()
{
    flag.store(false, std::memory_order_release);
}

void CThreadInterrupt::operator()()
{
    {
#ifdef _WIN32
        boost::unique_lock<boost::mutex> lock(mut);
#else
        std::unique_lock<std::mutex> lock(mut);
#endif
        flag.store(true, std::memory_order_release);
    }
    cond.notify_all();
}

bool CThreadInterrupt::sleep_for(ThreadInterruptChrono::milliseconds rel_time)
{
#ifdef _WIN32
    boost::unique_lock<boost::mutex> lock(mut);
#else
    std::unique_lock<std::mutex> lock(mut);
#endif
    return !cond.wait_for(lock, rel_time, [this]() { return flag.load(std::memory_order_acquire); });
}

bool CThreadInterrupt::sleep_for(ThreadInterruptChrono::seconds rel_time)
{
    return sleep_for(ThreadInterruptChrono::duration_cast<ThreadInterruptChrono::milliseconds>(rel_time));
}

bool CThreadInterrupt::sleep_for(ThreadInterruptChrono::minutes rel_time)
{
    return sleep_for(ThreadInterruptChrono::duration_cast<ThreadInterruptChrono::milliseconds>(rel_time));
}
