// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  Stratum client.
// ===========================================================================
//
//  Newline-delimited JSON-RPC over TCP, speaking the dialect in
//  pool/lib/stratumServer.js:
//
//      -> mining.subscribe            <- [[subscriptions], extranonce1, en2size]
//      -> mining.authorize            <- true / false
//      -> mining.submit               <- true / [code, message, null]
//      <- mining.set_difficulty
//      <- mining.set_seedhash         (WAM extension)
//      <- mining.notify               (10th parameter is the RandomX seed)
//
//  All socket traffic happens on one thread. Workers hand submissions to a
//  queue rather than writing themselves, so two threads can never interleave
//  halves of a JSON line on the wire.

#pragma once

#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <array>
#include <cerrno>
#include <deque>
#include <functional>
#include <mutex>
#include <set>
#include <chrono>
#include <cstdlib>
#include <string>
#include <vector>

#include "json.h"
#include "util.h"

namespace wam {

struct StratumJob {
    std::string jobId;
    uint8_t     prevHash[32] = {0};              // already in header order
    Bytes       coinb1;
    Bytes       coinb2;
    std::vector<std::array<uint8_t, 32>> merkleBranch;
    uint32_t    version   = 0;
    uint32_t    nbits     = 0;
    uint32_t    ntime     = 0;
    bool        cleanJobs = false;
    Bytes       seed;                            // RandomX key for this height

    Bytes       extranonce1;
    int         extranonce2Size = 4;

    // Filled in by the worker that adopts this job.
    std::string extranonce2Hex;

    int64_t     height = 0;         // read out of the coinbase, see below
    bool        valid  = false;
};

/**
 * Recover the block height from coinb1.
 *
 * mining.notify does not carry the height, but BIP34 requires it to be the
 * first push of the coinbase scriptSig, so it is already in the bytes we were
 * sent. Miners expect to see it, and it is worth having: a miner watching the
 * height stall knows its pool is stuck long before the pool operator does.
 *
 * Layout of coinb1:
 *     4  txversion
 *     1  input count (always 0x01)
 *    32  null prevout hash
 *     4  prevout index (0xffffffff)
 *     1  scriptSig length (consensus caps the script at 100 bytes, so the
 *        CompactSize is always a single byte here)
 *     1  height push length
 *     n  height, little-endian
 */
inline int64_t ParseCoinbaseHeight(const Bytes& coinb1)
{
    constexpr size_t kPushLenOffset = 4 + 1 + 32 + 4 + 1;
    if (coinb1.size() <= kPushLenOffset) return 0;

    const size_t n = coinb1[kPushLenOffset];
    if (n < 1 || n > 4 || coinb1.size() < kPushLenOffset + 1 + n) return 0;

    int64_t height = 0;
    for (size_t i = 0; i < n; i++) {
        height |= int64_t(coinb1[kPushLenOffset + 1 + i]) << (8 * i);
    }
    return height;
}

class StratumClient {
public:
    StratumClient(std::string host, uint16_t port, std::string user, std::string pass)
        : m_host(std::move(host)), m_port(port),
          m_user(std::move(user)), m_pass(std::move(pass)) {}

    ~StratumClient() { Close(); }

    // -- callbacks, set before Connect() ------------------------------------
    std::function<void(const StratumJob&)>            onJob;
    std::function<void(double)>                       onDifficulty;
    std::function<void(bool, const std::string&)>     onSubmitResult;
    std::function<void(const std::string&)>           onLog;
    std::function<void(const std::string&)>           onError;

    bool IsConnected() const { return m_fd >= 0; }
    bool IsAuthorized() const { return m_authorized; }

    // -----------------------------------------------------------------------

    // Five block times. A pool sends a job on every block, so this is
    // generous: nothing legitimate is quiet for ten minutes.
    //
    // Overridable so the behaviour can actually be tested. A watchdog that
    // has never been seen to fire is a watchdog nobody knows works, and this
    // one exists precisely because something failed silently for six hours.
    static long SilenceLimitSeconds()
    {
        if (const char* e = std::getenv("WAM_MINER_SILENCE_SECONDS")) {
            const long v = std::atol(e);
            if (v > 0) return v;
        }
        return 600;
    }

    /**
     * Called only from the one place it can be called honestly: straight
     * after a read that returned nothing, so we know the socket was asked
     * and had nothing to give.
     *
     * The first version of this ran at the top of Poll(), before the read,
     * and was wrong in a way a test caught immediately. RandomX builds its
     * dataset on a seed change and that takes 80 seconds on one thread; the
     * whole loop stops for the duration. The pool had sent a job two seconds
     * in and it sat unread in the kernel's buffer the entire time -- so the
     * check woke up, measured "nothing read for 80s", and threw away a live
     * connection carrying a job it had not yet looked at.
     *
     * Silence is a property of the pool, not of how busy we were. Measuring
     * it anywhere but here confuses the two.
     */
    void CheckSilence()
    {
        if (m_lastRx.time_since_epoch().count() == 0) return;

        const auto quiet = std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::steady_clock::now() - m_lastRx).count();
        if (quiet <= SilenceLimitSeconds()) return;

        // Closing is the whole action: the main loop reconnects as soon as
        // IsConnected() goes false.
        Report("no job or reply from the pool for " + std::to_string(quiet)
               + "s -- the connection is carrying nothing; reconnecting");
        Close();
    }

    bool Connect(std::string& err)
    {
        Close();

        addrinfo hints{};
        hints.ai_family   = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;

        const std::string portStr = std::to_string(m_port);
        addrinfo* res = nullptr;
        const int rc = getaddrinfo(m_host.c_str(), portStr.c_str(), &hints, &res);
        if (rc != 0 || !res) {
            err = "cannot resolve " + m_host + ": " + gai_strerror(rc);
            return false;
        }

        int fd = -1;
        for (addrinfo* ai = res; ai; ai = ai->ai_next) {
            fd = ::socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
            if (fd < 0) continue;

            timeval to{};
            to.tv_sec = 10;
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &to, sizeof(to));

            if (::connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;

            ::close(fd);
            fd = -1;
        }
        freeaddrinfo(res);

        if (fd < 0) {
            err = "cannot connect to " + m_host + ":" + portStr + ": " + std::strerror(errno);
            return false;
        }

        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));

        // Bounded read so Poll() returns to the caller even on a silent link.
        timeval rto{};
        rto.tv_sec  = 1;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rto, sizeof(rto));
        m_lastRx = std::chrono::steady_clock::now();

        m_fd = fd;
        m_buffer.clear();
        m_authorized = false;
        m_subscribed = false;

        SendRaw("{\"id\":1,\"method\":\"mining.subscribe\",\"params\":[\"" +
                json::Escape(kUserAgent) + "\"]}");
        return true;
    }

    void Close()
    {
        if (m_fd >= 0) { ::close(m_fd); m_fd = -1; }
        m_authorized = false;
        m_subscribed = false;
    }

    /** Queue a share. Safe to call from any worker thread. */
    void QueueSubmit(const std::string& jobId, const std::string& en2Hex,
                     const std::string& nTimeHex, const std::string& nonceHex)
    {
        std::lock_guard<std::mutex> lock(m_queueMutex);
        m_pendingSubmits.push_back({jobId, en2Hex, nTimeHex, nonceHex});
    }

    /**
     * One turn of the I/O loop: flush queued shares, then read whatever has
     * arrived. Blocks for at most the socket's receive timeout (1s).
     */
    void Poll()
    {
        FlushSubmits();

        if (m_fd < 0) return;

        // Seconds in which this loop was not listening cannot be charged to
        // the pool.
        //
        // RandomX rebuilds its dataset whenever the seed changes, and that
        // stops the whole loop -- 78 seconds on one thread, measured. The
        // pool has nothing to answer for during it, and we could not have
        // read a byte if it had. Without this the watchdog wakes up, counts
        // the stall as silence, and throws away a healthy connection holding
        // a fresh job. That is not hypothetical: it is what the test showed
        // on the first two attempts at this file.
        //
        // A healthy turn of the loop comes back within the socket's 1s
        // receive timeout, so any gap far past that was time spent elsewhere.
        const auto now = std::chrono::steady_clock::now();
        if (m_lastPoll.time_since_epoch().count() != 0 &&
            m_lastRx.time_since_epoch().count() != 0) {
            const auto gap = now - m_lastPoll;
            if (gap > std::chrono::seconds(5)) m_lastRx += gap;
        }
        m_lastPoll = now;

        char chunk[8192];
        const ssize_t n = ::recv(m_fd, chunk, sizeof(chunk), 0);

        if (n == 0) {
            Report("the pool closed the connection");
            Close();
            return;
        }
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                // The socket was asked and had nothing to give. That is the
                // only moment at which silence can honestly be measured.
                CheckSilence();
                return;
            }
            Report(std::string("read failed: ") + std::strerror(errno));
            Close();
            return;
        }

        m_lastRx = std::chrono::steady_clock::now();
        m_buffer.append(chunk, size_t(n));

        // A pool that never sends a newline is either broken or hostile.
        if (m_buffer.size() > 1u << 20) {
            Report("the pool sent an oversized line; disconnecting");
            Close();
            return;
        }

        size_t start = 0;
        for (;;) {
            const size_t nl = m_buffer.find('\n', start);
            if (nl == std::string::npos) break;

            std::string line = m_buffer.substr(start, nl - start);
            start = nl + 1;

            while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
            if (!line.empty()) HandleLine(line);

            if (m_fd < 0) return;                // a handler disconnected us
        }
        m_buffer.erase(0, start);
    }

private:
    struct PendingSubmit {
        std::string jobId, en2Hex, nTimeHex, nonceHex;
    };

    static constexpr const char* kUserAgent = "wam-miner/1.0.0";

    void Report(const std::string& msg) { if (onError) onError(msg); }
    void Log(const std::string& msg)    { if (onLog)   onLog(msg); }

    bool SendRaw(const std::string& payload)
    {
        if (m_fd < 0) return false;
        const std::string line = payload + "\n";

        size_t sent = 0;
        while (sent < line.size()) {
            const ssize_t n = ::send(m_fd, line.data() + sent, line.size() - sent, MSG_NOSIGNAL);
            if (n <= 0) {
                if (errno == EINTR) continue;
                Report(std::string("write failed: ") + std::strerror(errno));
                Close();
                return false;
            }
            sent += size_t(n);
        }
        return true;
    }

    void FlushSubmits()
    {
        std::deque<PendingSubmit> batch;
        {
            std::lock_guard<std::mutex> lock(m_queueMutex);
            batch.swap(m_pendingSubmits);
        }

        for (const PendingSubmit& s : batch) {
            if (m_fd < 0 || !m_authorized) continue;

            const int id = m_nextId++;
            m_submitIds.insert(id);

            SendRaw("{\"id\":" + std::to_string(id) +
                    ",\"method\":\"mining.submit\",\"params\":[\"" +
                    json::Escape(m_user) + "\",\"" + json::Escape(s.jobId) + "\",\"" +
                    s.en2Hex + "\",\"" + s.nTimeHex + "\",\"" + s.nonceHex + "\"]}");
        }
    }

    void HandleLine(const std::string& line)
    {
        json::Value msg;
        std::string parseError;
        if (!json::ParseLine(line, msg, parseError)) {
            Report("the pool sent malformed JSON (" + parseError + ")");
            return;
        }

        const json::Value& method = msg["method"];
        if (method.IsString()) { HandleNotification(method.string, msg["params"]); return; }

        HandleResponse(msg);
    }

    void HandleNotification(const std::string& method, const json::Value& params)
    {
        if (method == "mining.notify") {
            HandleNotify(params);
        } else if (method == "mining.set_difficulty") {
            const double d = params.At(0).AsNumber(0);
            if (d > 0 && onDifficulty) onDifficulty(d);
        } else if (method == "mining.set_seedhash") {
            Bytes seed;
            if (ParseHex(params.At(0).AsString(), seed) && seed.size() == 32) {
                m_lastSeed = seed;
                Log("RandomX key change announced for height " +
                    std::to_string(params.At(2).AsInt()));
            }
        } else if (method == "client.reconnect") {
            Log("the pool asked us to reconnect");
            Close();
        } else if (method == "mining.set_extranonce") {
            Bytes en1;
            if (ParseHex(params.At(0).AsString(), en1) && !en1.empty()) {
                m_extranonce1 = en1;
                const int64_t size = params.At(1).AsInt(m_extranonce2Size);
                if (size >= 1 && size <= 8) m_extranonce2Size = int(size);
                Log("extranonce1 changed to " + ToHex(m_extranonce1));
            }
        }
        // Anything else is a pool extension we do not need.
    }

    void HandleResponse(const json::Value& msg)
    {
        const int64_t id = msg["id"].AsInt(-1);
        const json::Value& result = msg["result"];
        const json::Value& error  = msg["error"];

        if (id == 1) { HandleSubscribeResult(result, error); return; }

        if (id == 2) {
            if (result.AsBool(false)) {
                m_authorized = true;
                Log("authorized as " + m_user);
            } else {
                Report("the pool refused to authorize '" + m_user + "'. "
                       "Check that it is a valid address for this network.");
                Close();
            }
            return;
        }

        if (m_submitIds.erase(int(id)) > 0) {
            if (result.AsBool(false)) {
                if (onSubmitResult) onSubmitResult(true, "");
            } else {
                std::string reason = "rejected";
                if (error.IsArray() && error.Size() >= 2) {
                    reason = error.At(1).AsString("rejected");
                } else if (error.IsString()) {
                    reason = error.string;
                }
                if (onSubmitResult) onSubmitResult(false, reason);
            }
        }
    }

    void HandleSubscribeResult(const json::Value& result, const json::Value& error)
    {
        if (!result.IsArray() || result.Size() < 3) {
            std::string why = "mining.subscribe returned something unexpected";
            if (error.IsArray() && error.Size() >= 2) why += ": " + error.At(1).AsString();
            Report(why);
            Close();
            return;
        }

        Bytes en1;
        if (!ParseHex(result.At(1).AsString(), en1) || en1.empty()) {
            Report("the pool sent an unusable extranonce1");
            Close();
            return;
        }

        const int64_t en2size = result.At(2).AsInt(4);
        if (en2size < 1 || en2size > 8) {
            Report("the pool asked for a " + std::to_string(en2size) +
                   "-byte extranonce2, which this miner does not support");
            Close();
            return;
        }

        m_extranonce1     = en1;
        m_extranonce2Size = int(en2size);
        m_subscribed      = true;

        Log("subscribed: extranonce1=" + ToHex(m_extranonce1) +
            " extranonce2 size=" + std::to_string(m_extranonce2Size));

        SendRaw("{\"id\":2,\"method\":\"mining.authorize\",\"params\":[\"" +
                json::Escape(m_user) + "\",\"" + json::Escape(m_pass) + "\"]}");
    }

    void HandleNotify(const json::Value& p)
    {
        if (!p.IsArray() || p.Size() < 9) {
            Report("mining.notify had too few parameters");
            return;
        }

        StratumJob job;
        job.jobId = p.At(0).AsString();

        Bytes prev;
        if (!ParseHex(p.At(1).AsString(), prev) ||
            !StratumPrevHashToHeader(prev, job.prevHash)) {
            Report("mining.notify carried a malformed prevhash");
            return;
        }

        if (!ParseHex(p.At(2).AsString(), job.coinb1) ||
            !ParseHex(p.At(3).AsString(), job.coinb2)) {
            Report("mining.notify carried a malformed coinbase");
            return;
        }

        const json::Value& branch = p.At(4);
        for (size_t i = 0; i < branch.Size(); i++) {
            Bytes node;
            if (!ParseHex(branch.At(i).AsString(), node) || node.size() != 32) {
                Report("mining.notify carried a malformed merkle branch");
                return;
            }
            std::array<uint8_t, 32> a{};
            std::memcpy(a.data(), node.data(), 32);
            job.merkleBranch.push_back(a);
        }

        // version, nbits and ntime all arrive as big-endian hex.
        Bytes v, b, t;
        if (!ParseHex(p.At(5).AsString(), v) || v.size() != 4 ||
            !ParseHex(p.At(6).AsString(), b) || b.size() != 4 ||
            !ParseHex(p.At(7).AsString(), t) || t.size() != 4) {
            Report("mining.notify carried a malformed version, bits or ntime");
            return;
        }
        job.version = ReadBE32(v.data());
        job.nbits   = ReadBE32(b.data());
        job.ntime   = ReadBE32(t.data());

        job.cleanJobs = p.At(8).AsBool(false);

        // The WAM extension. Fall back to the last set_seedhash, because a
        // pool is allowed to announce the key out of band and omit it here.
        Bytes seed;
        if (p.Size() >= 10 && ParseHex(p.At(9).AsString(), seed) && seed.size() == 32) {
            job.seed   = seed;
            m_lastSeed = seed;
        } else if (!m_lastSeed.empty()) {
            job.seed = m_lastSeed;
        } else {
            Report("the pool sent a job with no RandomX seed. This miner cannot "
                   "guess the key; the pool must send it in mining.notify[9] or "
                   "mining.set_seedhash.");
            return;
        }

        job.extranonce1     = m_extranonce1;
        job.extranonce2Size = m_extranonce2Size;
        job.height          = ParseCoinbaseHeight(job.coinb1);
        job.valid           = true;

        if (onJob) onJob(job);
    }

    std::string m_host;
    uint16_t    m_port;
    std::string m_user;
    std::string m_pass;

    int         m_fd = -1;
    std::string m_buffer;

    bool  m_subscribed = false;
    bool  m_authorized = false;

    // When anything last arrived from the pool.
    //
    // On 2026-08-24 this miner sat for six hours on a job from height 1370
    // while the chain reached 1430. It was not disconnected: recv() never
    // returned 0 and never returned an error, so nothing here noticed. The
    // socket was half-open -- alive as far as this end could tell, and
    // carrying nothing. SO_KEEPALIVE is set, but Linux waits two hours
    // before its first probe and the machine had been quiet for six.
    //
    // The log said "0.0 H/s" every thirty seconds and systemd reported the
    // service active. Nothing was wrong anywhere except that no work was
    // being done.
    //
    // Rather than diagnose which kind of silence it was -- a dropped NAT
    // entry, a pool that stopped writing, a route that changed -- silence
    // itself past a threshold is treated as failure. The pool sends a job on
    // every block, roughly every two minutes, so several minutes of nothing
    // at all can only mean the connection is no longer carrying anything.
    std::chrono::steady_clock::time_point m_lastRx{};
    std::chrono::steady_clock::time_point m_lastPoll{};
    Bytes m_extranonce1;
    int   m_extranonce2Size = 4;
    Bytes m_lastSeed;

    int             m_nextId = 100;
    std::set<int>   m_submitIds;

    std::mutex               m_queueMutex;
    std::deque<PendingSubmit> m_pendingSubmits;
};

} // namespace wam
