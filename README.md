Forked from Bitcoin reference wallet 0.8.6

Blakecoin Wallet

https://www.blakecoin.org

Blake-256(optimized) is faster than Scrypt, SHA-256D, Keccak, Groestl

The algorithm was written as a candidate for sha3, Based on round one candidate code from the sphlib 2.1 and reduced rounds to 8.

Tweaks Removed some of the double hashing from the wallet as it is wasteful on compute, No changes to the ecdsa public/private function as that has proven to be secure so far on bitcoin.


What is Blakecoin?

Blakecoin is an experimental new digital currency that enables instant payments to
anyone, anywhere in the world. Blakecoin uses peer-to-peer technology to operate
with no central authority: managing transactions and issuing money are carried
out collectively by the network.

Ubuntu 18.04 dependancies that are used on the Linux build machine:

wget git curl build-essential libssl-dev libboost-all-dev libminiupnpc-dev libdb4.8-dev libdb4.8++-dev

Building with Boost 1.71+

License

Blakecoin is released under the terms of the MIT license. See `COPYING` for more
information or see http://opensource.org/licenses/MIT.



