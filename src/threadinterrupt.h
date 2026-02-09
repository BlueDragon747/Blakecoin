// Copyright (c) 2016 The Bitcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_THREADINTERRUPT_H
#define BITCOIN_THREADINTERRUPT_H

#include <atomic>

#ifdef _WIN32
// MinGW doesn't have full C++11 thread support, use Boost
#include <boost/thread/condition_variable.hpp>
#include <boost/thread/mutex.hpp>
#include <boost/chrono.hpp>
namespace ThreadInterruptChrono = boost::chrono;
#else
#include <chrono>
#include <condition_variable>
#include <mutex>
namespace ThreadInterruptChrono = std::chrono;
#endif

/*
    A helper class for interruptible sleeps. Calling operator() will interrupt
    any current sleep, and after that point operator bool() will return true
    until reset.
*/
class CThreadInterrupt
{
public:
    explicit operator bool() const;
    void operator()();
    void reset();
    bool sleep_for(ThreadInterruptChrono::milliseconds rel_time);
    bool sleep_for(ThreadInterruptChrono::seconds rel_time);
    bool sleep_for(ThreadInterruptChrono::minutes rel_time);

private:
#ifdef _WIN32
    boost::condition_variable cond;
    boost::mutex mut;
#else
    std::condition_variable cond;
    std::mutex mut;
#endif
    std::atomic<bool> flag;
};

#endif //BITCOIN_THREADINTERRUPT_H
