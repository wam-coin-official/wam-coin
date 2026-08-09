// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  wam-miner -- the reference CPU miner for WAM Coin
// ===========================================================================
//
//      wam-miner -o stratum+tcp://pool.wamcoin.org:3333 -u <your WAM address>
//
//  WHY THIS EXISTS
//  ---------------
//  WAM's proof of work is RandomX over a Bitcoin-style 80-byte header. That
//  combination is deliberate -- RandomX for CPU fairness, Bitcoin's header so
//  the chain inherits twenty years of reviewed consensus code -- but it means
//  no existing miner speaks it. xmrig hashes Monero's blob layout; cpuminer
//  hashes SHA-256. Without this binary, WAM would be a chain nobody could mine.
//
//  It is intentionally small and dependency-free: a stranger should be able to
//  read all of it in an afternoon and build it with one g++ invocation. A
//  miner asks people to run unknown code on their own hardware, and the only
//  honest answer to "why should I trust it" is "here is all of it".
//
//  WHAT IT DOES NOT DO
//  -------------------
//  No GPU, no CUDA, no OpenCL. RandomX is designed to be poor on GPUs; adding
//  half-speed GPU support would only invite people to waste electricity.
//  No developer fee: this binary mines to the address you pass and to nothing
//  else. WAM's 5% treasury is a consensus rule paid by the coinbase itself,
//  visible in every block, and is not something a miner needs to cooperate in.

#include <atomic>
#include <cinttypes>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "json.h"
#include "randomx_engine.h"
#include "sha256.h"
#include "stratum.h"
#include "util.h"

namespace wam {

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

namespace {

bool g_colour = true;

const char* C(const char* code) { return g_colour ? code : ""; }

#define CLR_RESET  C("\033[0m")
#define CLR_DIM    C("\033[90m")
#define CLR_GREEN  C("\033[32m")
#define CLR_YELLOW C("\033[33m")
#define CLR_RED    C("\033[31m")
#define CLR_CYAN   C("\033[36m")
#define CLR_BOLD   C("\033[1m")

std::mutex g_printMutex;

void LogLine(const char* colour, const char* tag, const std::string& msg)
{
    const std::time_t now = std::time(nullptr);
    std::tm tm{};
    localtime_r(&now, &tm);

    char stamp[16];
    std::strftime(stamp, sizeof(stamp), "%H:%M:%S", &tm);

    std::lock_guard<std::mutex> lock(g_printMutex);
    std::printf("%s%s%s %s%-8s%s %s\n",
                CLR_DIM, stamp, CLR_RESET, colour, tag, CLR_RESET, msg.c_str());
    std::fflush(stdout);
}

void Info(const std::string& m)  { LogLine(CLR_CYAN,   "miner",  m); }
void Good(const std::string& m)  { LogLine(CLR_GREEN,  "accept", m); }
void Warn(const std::string& m)  { LogLine(CLR_YELLOW, "warn",   m); }
void Fail(const std::string& m)  { LogLine(CLR_RED,    "error",  m); }
void Job(const std::string& m)   { LogLine(CLR_BOLD,   "job",    m); }

} // namespace

// ---------------------------------------------------------------------------
// Shared state between the I/O thread and the workers
// ---------------------------------------------------------------------------

struct SharedState {
    std::mutex  jobMutex;
    StratumJob  job;
    std::atomic<uint64_t> jobEpoch{0};       // bumped on every new job
    std::atomic<uint64_t> solvedEpoch{0};    // set once a job yields a block
    std::atomic<uint64_t> difficultyBits{0}; // double, bit-cast, for lock-free reads

    std::atomic<bool>     running{true};
    std::atomic<bool>     connected{false};

    std::atomic<uint64_t> hashes{0};
    std::atomic<uint64_t> submitted{0};
    std::atomic<uint64_t> accepted{0};
    std::atomic<uint64_t> rejected{0};
    std::atomic<uint64_t> blocksFound{0};

    void SetDifficulty(double d)
    {
        uint64_t bits;
        std::memcpy(&bits, &d, sizeof(bits));
        difficultyBits.store(bits);
    }

    double GetDifficulty() const
    {
        const uint64_t bits = difficultyBits.load();
        double d;
        std::memcpy(&d, &bits, sizeof(d));
        return d > 0 ? d : 1.0;
    }
};

// ---------------------------------------------------------------------------
// Header assembly
// ---------------------------------------------------------------------------

/**
 * Build the 80-byte header for a job, with the nonce left at zero.
 *
 * This has to reproduce, byte for byte, what the pool will rebuild when it
 * validates the share -- see BlockTemplate.serializeHeader() in
 * pool/lib/blockTemplate.js. Any disagreement shows up as "share above
 * target" for every share, which looks like bad luck rather than a bug.
 */
void BuildHeader(const StratumJob& job, const Bytes& extranonce2, uint8_t header[80])
{
    // ---- coinbase = coinb1 | extranonce1 | extranonce2 | coinb2 -----------
    Bytes coinbase;
    coinbase.reserve(job.coinb1.size() + job.extranonce1.size() +
                     extranonce2.size() + job.coinb2.size());
    coinbase.insert(coinbase.end(), job.coinb1.begin(), job.coinb1.end());
    coinbase.insert(coinbase.end(), job.extranonce1.begin(), job.extranonce1.end());
    coinbase.insert(coinbase.end(), extranonce2.begin(), extranonce2.end());
    coinbase.insert(coinbase.end(), job.coinb2.begin(), job.coinb2.end());

    // ---- merkle root: fold the coinbase hash through the branch ----------
    uint8_t root[32];
    SHA256d(coinbase.data(), coinbase.size(), root);
    for (const std::array<uint8_t, 32>& node : job.merkleBranch) {
        uint8_t next[32];
        SHA256dPair(root, node.data(), next);
        std::memcpy(root, next, 32);
    }

    WriteLE32(header + 0, job.version);
    std::memcpy(header + 4, job.prevHash, 32);
    std::memcpy(header + 36, root, 32);
    WriteLE32(header + 68, job.ntime);
    WriteLE32(header + 72, job.nbits);
    WriteLE32(header + 76, 0);                  // nonce, filled per attempt
}

// ---------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------

void WorkerLoop(int workerId, RandomXEngine& engine, SharedState& state,
                StratumClient& client)
{
    // Each worker owns a distinct extranonce2, which gives it a completely
    // separate coinbase and therefore a separate search space. Without this,
    // every thread would hash the same header and find the same shares.
    // A VM cannot exist before the key does, and the key arrives with the
    // first job -- which is not the first message the pool sends. The I/O
    // thread builds every VM in one pass once the key is known; workers just
    // wait for theirs. See RandomXEngine::CreateVms for why they must not
    // build their own.
    while (state.running.load() && !engine.VmsReady()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    if (!state.running.load()) return;

    randomx_vm* vm = engine.Vm(size_t(workerId));
    if (!vm) {
        Fail("worker " + std::to_string(workerId) + " was not given a VM");
        state.running.store(false);
        return;
    }

    std::mt19937 rng(uint32_t(NowMs()) ^ uint32_t(workerId * 2654435761u));

    uint64_t seenEpoch = 0;
    StratumJob job;
    uint8_t   header[80];
    Target    shareTarget{};
    Target    blockTarget{};
    uint32_t  nonce = 0;
    bool      haveWork = false;

    const int kBatch = 64;                      // hashes per shared-lock hold

    while (state.running.load()) {
        const uint64_t epoch = state.jobEpoch.load();

        if (epoch != seenEpoch) {
            {
                std::lock_guard<std::mutex> lock(state.jobMutex);
                job = state.job;
            }
            seenEpoch = epoch;

            if (!job.valid) { haveWork = false; continue; }

            // extranonce2: worker id in the top bytes so no two threads collide.
            Bytes en2(size_t(job.extranonce2Size), 0);
            for (int i = 0; i < job.extranonce2Size && i < 4; i++) {
                en2[size_t(i)] = uint8_t(uint32_t(workerId) >> (8 * (job.extranonce2Size - 1 - i)));
            }
            job.extranonce2Hex = ToHex(en2);

            BuildHeader(job, en2, header);

            shareTarget = DifficultyToTarget(state.GetDifficulty());
            blockTarget = BitsToTarget(job.nbits);
            nonce       = rng();                // avoid repeating work on restart
            haveWork    = true;
        }

        if (!haveWork || state.solvedEpoch.load() == seenEpoch) {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            continue;
        }

        // ---- one batch, under a shared lock so a re-key can interrupt us --
        {
            RandomXEngine::HashLock lock(engine);

            WriteLE32(header + 76, nonce);
            randomx_calculate_hash_first(vm, header, 80);

            for (int i = 0; i < kBatch; i++) {
                const uint32_t hashedNonce = nonce;
                nonce++;
                WriteLE32(header + 76, nonce);

                uint8_t out[32];
                randomx_calculate_hash_next(vm, header, 80, out);
                state.hashes.fetch_add(1, std::memory_order_relaxed);

                uint8_t be[32];
                PowHashToBigEndian(out, be);

                // The block target and the share target are independent tests.
                // On a chain whose difficulty is below the pool's share
                // difficulty -- regtest, or a network just after launch -- a
                // hash can solve the block without reaching share difficulty,
                // and dropping it would throw away a real block.
                const bool isBlock = MeetsTarget(be, blockTarget);
                const bool isShare = MeetsTarget(be, shareTarget);

                if (isBlock || isShare) {
                    if (isBlock) {
                        state.blocksFound.fetch_add(1);
                        LogLine(CLR_GREEN, "BLOCK",
                                "worker " + std::to_string(workerId) +
                                " solved height " + std::to_string(job.height) +
                                "! hash " + ToHex(be, 32).substr(0, 24) + "...");
                    }

                    state.submitted.fetch_add(1);
                    client.QueueSubmit(job.jobId, job.extranonce2Hex,
                                       ToHexBE32(job.ntime), ToHexBE32(hashedNonce));

                    // Once this job is solved there is nothing left in it worth
                    // finding: any further solution is for a block already
                    // submitted, and any further share is against a template
                    // the pool is about to replace. Idle until the next job.
                    if (isBlock) {
                        state.solvedEpoch.store(seenEpoch);
                        break;
                    }
                }

                // A new job, a sibling thread having already solved this one,
                // or a re-key waiting to get in: all of them make everything
                // after this point wasted work.
                if (state.jobEpoch.load() != seenEpoch ||
                    state.solvedEpoch.load() == seenEpoch ||
                    engine.WriterWaiting() ||
                    !state.running.load()) break;
            }
        }
    }

    // The engine owns every VM and frees them in its destructor, so that a
    // worker exiting mid-rotation cannot free a VM another thread is re-keying.
}

// ---------------------------------------------------------------------------
// Self-test
// ---------------------------------------------------------------------------

bool SelfTest()
{
    bool ok = true;

    auto check = [&ok](const char* what, const std::string& got, const std::string& want) {
        if (got == want) {
            std::printf("  %sok%s    %s\n", CLR_GREEN, CLR_RESET, what);
        } else {
            std::printf("  %sFAIL%s  %s\n        got  %s\n        want %s\n",
                        CLR_RED, CLR_RESET, what, got.c_str(), want.c_str());
            ok = false;
        }
    };

    std::printf("\n%sSHA-256%s\n", CLR_BOLD, CLR_RESET);
    {
        uint8_t out[32];
        SHA256Once(reinterpret_cast<const uint8_t*>(""), 0, out);
        check("empty string",
              ToHex(out, 32),
              "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");

        SHA256Once(reinterpret_cast<const uint8_t*>("abc"), 3, out);
        check("\"abc\"",
              ToHex(out, 32),
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");

        const char* long_msg =
            "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
        SHA256Once(reinterpret_cast<const uint8_t*>(long_msg), std::strlen(long_msg), out);
        check("two-block message",
              ToHex(out, 32),
              "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");

        // The genesis block of Bitcoin, hashed the way a header is hashed.
        // If SHA256d and our byte order are right, this comes out exactly.
        Bytes hdr = ParseHexOrEmpty(
            "0100000000000000000000000000000000000000000000000000000000000000"
            "000000003ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa"
            "4b1e5e4a29ab5f49ffff001d1dac2b7c");
        SHA256d(hdr.data(), hdr.size(), out);
        uint8_t be[32];
        PowHashToBigEndian(out, be);
        check("SHA256d of a real 80-byte header",
              ToHex(be, 32),
              "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f");
    }

    std::printf("\n%sByte order%s\n", CLR_BOLD, CLR_RESET);
    {
        // Stratum sends prevhash word-swapped. Feeding it a known display
        // hash and checking we recover the header bytes catches the single
        // most common miner bug there is.
        const std::string display =
            "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f";
        Bytes d = ParseHexOrEmpty(display);

        // What the pool computes: reverseByteOrder(display bytes).
        Bytes wire(32);
        for (int w = 0; w < 8; w++) {
            for (int b = 0; b < 4; b++) wire[size_t(w * 4 + b)] = d[size_t(w * 4 + 3 - b)];
        }

        uint8_t recovered[32];
        StratumPrevHashToHeader(wire, recovered);

        // The header wants the plain reverse of the display bytes.
        Bytes want(d.rbegin(), d.rend());
        check("stratum prevhash -> header bytes", ToHex(recovered, 32), ToHex(want));
    }

    std::printf("\n%sTargets%s\n", CLR_BOLD, CLR_RESET);
    {
        Target t1 = DifficultyToTarget(1.0);
        check("difficulty 1",
              ToHex(t1.bytes, 32),
              "00000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffff");

        Target t2 = DifficultyToTarget(2.0);
        check("difficulty 2",
              ToHex(t2.bytes, 32),
              "000000007fffffffffffffffffffffffffffffffffffffffffffffffffffffff");

        Target tb = BitsToTarget(0x1d00ffff);
        check("nBits 0x1d00ffff",
              ToHex(tb.bytes, 32),
              "00000000ffff0000000000000000000000000000000000000000000000000000");

        Target tr = BitsToTarget(0x207fffff);      // regtest
        check("nBits 0x207fffff",
              ToHex(tr.bytes, 32),
              "7fffff0000000000000000000000000000000000000000000000000000000000");
    }

    std::printf("\n%sRandomX%s\n", CLR_BOLD, CLR_RESET);
    {
        randomx_flags flags = randomx_get_flags();
        randomx_cache* cache = randomx_alloc_cache(flags);
        if (!cache) {
            std::printf("  %sFAIL%s  could not allocate the cache\n", CLR_RED, CLR_RESET);
            return false;
        }

        const char* key = "test key 000";
        randomx_init_cache(cache, key, std::strlen(key));

        randomx_vm* vm = randomx_create_vm(flags, cache, nullptr);
        if (!vm) {
            randomx_release_cache(cache);
            std::printf("  %sFAIL%s  could not create a VM\n", CLR_RED, CLR_RESET);
            return false;
        }

        uint8_t out[32];
        const char* input = "This is a test";
        randomx_calculate_hash(vm, input, std::strlen(input), out);
        check("official test vector 1a",
              ToHex(out, 32),
              "639183aae1bf4c9a35884cb46b09cad9175f04efd7684e7262a0ac1c2f0b4e3f");

        const char* input2 = "Lorem ipsum dolor sit amet";
        randomx_calculate_hash(vm, input2, std::strlen(input2), out);
        check("official test vector 1b",
              ToHex(out, 32),
              "300a0adb47603dedb42228ccb2b211104f4da45af709cd7547cd049e9489c969");

        randomx_destroy_vm(vm);
        randomx_release_cache(cache);
    }

    std::printf("\n%s\n", ok ? "All self-tests passed." : "SELF-TEST FAILED.");
    return ok;
}

// ---------------------------------------------------------------------------
// Benchmark
// ---------------------------------------------------------------------------

int Benchmark(int threads, bool fullMem, bool largePages, int seconds)
{
    Info("benchmarking with " + std::to_string(threads) + " threads");

    RandomXEngine engine;
    std::string err;
    if (!engine.Init(threads, fullMem, largePages, err)) { Fail(err); return 1; }

    Info("mode: " + engine.Describe());

    // A fixed key, so two machines running --benchmark compare like for like.
    const std::string keyText = "WAM/benchmark";
    Bytes key(keyText.begin(), keyText.end());
    key.resize(32, 0);

    Info("preparing the dataset...");
    const int64_t t0 = NowMs();
    if (!engine.SetSeed(key, err)) { Fail(err); return 1; }
    Info("ready in " + std::to_string((NowMs() - t0) / 1000.0) + "s");

    if (!engine.CreateVms(threads, err)) { Fail(err); return 1; }

    std::atomic<uint64_t> hashes{0};
    std::atomic<bool>     run{true};
    std::vector<std::thread> pool;

    for (int i = 0; i < threads; i++) {
        pool.emplace_back([&, i]() {
            randomx_vm* vm = engine.Vm(size_t(i));
            if (!vm) { Fail("benchmark thread got no VM"); return; }

            uint8_t blob[80];
            std::memset(blob, 0, sizeof(blob));
            WriteLE32(blob, uint32_t(i));

            uint32_t nonce = 0;
            uint8_t out[32];

            WriteLE32(blob + 76, nonce);
            randomx_calculate_hash_first(vm, blob, 80);

            while (run.load(std::memory_order_relaxed)) {
                nonce++;
                WriteLE32(blob + 76, nonce);
                randomx_calculate_hash_next(vm, blob, 80, out);
                hashes.fetch_add(1, std::memory_order_relaxed);
            }
        });
    }

    const int64_t start = NowMs();
    for (int s = 1; s <= seconds; s++) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        const double elapsed = (NowMs() - start) / 1000.0;
        const double rate = elapsed > 0 ? hashes.load() / elapsed : 0;
        std::printf("\r  %s%2ds%s  %s        ", CLR_DIM, s, CLR_RESET,
                    HumanHashrate(rate).c_str());
        std::fflush(stdout);
    }
    std::printf("\n");

    run.store(false);
    for (std::thread& t : pool) t.join();

    const double elapsed = (NowMs() - start) / 1000.0;
    const double rate = hashes.load() / elapsed;
    Info("result: " + HumanHashrate(rate) + " over " +
         std::to_string(int(elapsed)) + "s (" +
         HumanHashrate(rate / threads) + " per thread)");
    return 0;
}

// ---------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------

struct Options {
    std::string host = "127.0.0.1";
    uint16_t    port = 3333;
    std::string user;
    std::string pass = "x";
    int         threads = 0;                 // 0 -> auto
    bool        fullMem = true;
    bool        largePages = false;
    bool        benchmark = false;
    int         benchmarkSeconds = 30;
    bool        selfTest = false;
    bool        help = false;
};

void PrintHelp()
{
    std::printf(
"wam-miner " "1.0.0" " -- the reference CPU miner for WAM Coin\n"
"\n"
"USAGE\n"
"    wam-miner -o <pool> -u <your WAM address>[.<worker>]\n"
"\n"
"OPTIONS\n"
"    -o, --url <host:port>   pool address; a stratum+tcp:// prefix is accepted\n"
"    -u, --user <address>    the WAM address to be paid at, optionally\n"
"                            followed by .<worker> to label this machine\n"
"    -p, --pass <password>   pool password (most pools ignore it; default 'x')\n"
"    -t, --threads <n>       mining threads (default: every core but one)\n"
"        --light             use the 256 MiB cache instead of the 2 GiB\n"
"                            dataset. Roughly four times slower; for machines\n"
"                            with under 4 GiB of RAM.\n"
"        --large-pages       ask for huge pages (needs system configuration;\n"
"                            worth about 5%% when it works)\n"
"        --benchmark [secs]  measure hashrate without connecting to a pool\n"
"        --self-test         verify SHA-256, byte order, targets and RandomX\n"
"                            against known vectors, then exit\n"
"        --no-colour         plain output, for logs and pipes\n"
"    -h, --help              this text\n"
"\n"
"EXAMPLES\n"
"    Mine to a pool:\n"
"        wam-miner -o stratum+tcp://pool.wamcoin.org:3333 -u wam1qexample...\n"
"\n"
"    Check the binary before trusting it with your electricity:\n"
"        wam-miner --self-test\n"
"        wam-miner --benchmark 60\n"
"\n"
"NOTES\n"
"    This miner takes no developer fee. It mines to the address you give it\n"
"    and to no other. WAM's 5%% treasury is a consensus rule paid by the\n"
"    coinbase, visible in every block, and ends at height 400,000.\n"
"\n"
"    Your address must belong to the network the pool is on: 'W...' or\n"
"    'wam1...' on mainnet. A wrong-network address means the pool refuses to\n"
"    authorize you, which is far better than being paid into a void.\n");
}

bool ParseOptions(int argc, char** argv, Options& opt, std::string& err)
{
    auto needsValue = [&](int& i, const char* flag) -> const char* {
        if (i + 1 >= argc) { err = std::string(flag) + " needs a value"; return nullptr; }
        return argv[++i];
    };

    for (int i = 1; i < argc; i++) {
        const std::string a = argv[i];

        if (a == "-h" || a == "--help") { opt.help = true; return true; }
        else if (a == "--self-test")    { opt.selfTest = true; }
        else if (a == "--light")        { opt.fullMem = false; }
        else if (a == "--large-pages")  { opt.largePages = true; }
        else if (a == "--no-colour" || a == "--no-color") { g_colour = false; }
        else if (a == "--benchmark") {
            opt.benchmark = true;
            if (i + 1 < argc && argv[i + 1][0] != '-') {
                opt.benchmarkSeconds = std::atoi(argv[++i]);
                if (opt.benchmarkSeconds < 1) opt.benchmarkSeconds = 30;
            }
        }
        else if (a == "-o" || a == "--url") {
            const char* v = needsValue(i, "--url");
            if (!v) return false;

            std::string url = v;
            const size_t scheme = url.find("://");
            if (scheme != std::string::npos) url = url.substr(scheme + 3);

            const size_t colon = url.rfind(':');
            if (colon == std::string::npos) {
                err = "--url must be host:port";
                return false;
            }
            opt.host = url.substr(0, colon);
            const int port = std::atoi(url.c_str() + colon + 1);
            if (port <= 0 || port > 65535) { err = "--url has a bad port"; return false; }
            opt.port = uint16_t(port);
        }
        else if (a == "-u" || a == "--user") {
            const char* v = needsValue(i, "--user"); if (!v) return false;
            opt.user = v;
        }
        else if (a == "-p" || a == "--pass") {
            const char* v = needsValue(i, "--pass"); if (!v) return false;
            opt.pass = v;
        }
        else if (a == "-t" || a == "--threads") {
            const char* v = needsValue(i, "--threads"); if (!v) return false;
            opt.threads = std::atoi(v);
            if (opt.threads < 1) { err = "--threads must be at least 1"; return false; }
        }
        else {
            err = "unknown option '" + a + "' (try --help)";
            return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------

std::atomic<bool>* g_running = nullptr;

void OnSignal(int)
{
    if (g_running) g_running->store(false);
}

int Run(int argc, char** argv)
{
    Options opt;
    std::string err;

    if (!ParseOptions(argc, argv, opt, err)) {
        std::fprintf(stderr, "error: %s\n", err.c_str());
        return 2;
    }
    if (opt.help) { PrintHelp(); return 0; }

    std::printf("%s wam-miner 1.0.0 -- RandomX CPU miner for WAM Coin%s\n\n",
                CLR_BOLD, CLR_RESET);

    if (opt.selfTest) return SelfTest() ? 0 : 1;

    const unsigned cores = std::max(1u, std::thread::hardware_concurrency());
    if (opt.threads == 0) {
        // Leave one core free so the machine stays usable; a miner that makes
        // a desktop unresponsive gets uninstalled.
        opt.threads = int(cores > 2 ? cores - 1 : 1);
    }

    if (opt.benchmark) {
        return Benchmark(opt.threads, opt.fullMem, opt.largePages, opt.benchmarkSeconds);
    }

    if (opt.user.empty()) {
        std::fprintf(stderr,
            "error: no payout address.\n"
            "       Pass -u <your WAM address>. Without it the pool has no way\n"
            "       to pay you, and will refuse the connection.\n");
        return 2;
    }

    // -----------------------------------------------------------------------

    SharedState state;
    state.SetDifficulty(1.0);
    g_running = &state.running;
    std::signal(SIGINT,  OnSignal);
    std::signal(SIGTERM, OnSignal);
    std::signal(SIGPIPE, SIG_IGN);

    RandomXEngine engine;
    if (!engine.Init(opt.threads, opt.fullMem, opt.largePages, err)) {
        Fail(err);
        return 1;
    }

    Info("pool     " + opt.host + ":" + std::to_string(opt.port));
    Info("address  " + opt.user);
    Info("threads  " + std::to_string(opt.threads) + " of " + std::to_string(cores) + " cores");
    Info("randomx  " + engine.Describe());

    StratumClient client(opt.host, opt.port, opt.user, opt.pass);

    client.onLog   = [](const std::string& m) { Info(m); };
    client.onError = [](const std::string& m) { Fail(m); };

    client.onDifficulty = [&state](double d) {
        state.SetDifficulty(d);
        Info("difficulty set to " + std::to_string(d));
        // Re-snapshot so workers pick up the new share target immediately.
        state.jobEpoch.fetch_add(1);
    };

    client.onSubmitResult = [&state](bool accepted, const std::string& reason) {
        if (accepted) {
            state.accepted.fetch_add(1);
            Good("share accepted (" + std::to_string(state.accepted.load()) + " total)");
        } else {
            state.rejected.fetch_add(1);
            Warn("share rejected: " + reason);
        }
    };

    client.onJob = [&](const StratumJob& incoming) {
        // Re-key before publishing: a worker must never hash a job against the
        // previous epoch's key, which would make every share invalid.
        std::string seedErr;
        const Bytes previous = engine.CurrentSeed();
        if (previous != incoming.seed) {
            if (!previous.empty()) {
                Warn("RandomX key rotated; rebuilding. Hashing pauses for a moment.");
            } else {
                Info("preparing RandomX (this takes a few seconds)...");
            }
            const int64_t t0 = NowMs();
            if (!engine.SetSeed(incoming.seed, seedErr)) {
                Fail(seedErr);
                state.running.store(false);
                return;
            }
            Info("RandomX ready in " + std::to_string((NowMs() - t0) / 1000.0) + "s" +
                 " (key " + ToHex(incoming.seed).substr(0, 16) + "...)");
        }

        // One VM per worker, built here rather than by the workers themselves.
        if (!engine.VmsReady()) {
            std::string vmErr;
            if (!engine.CreateVms(opt.threads, vmErr)) {
                Fail(vmErr);
                state.running.store(false);
                return;
            }
        }

        {
            std::lock_guard<std::mutex> lock(state.jobMutex);
            state.job = incoming;
        }
        state.jobEpoch.fetch_add(1);

        char line[160];
        std::snprintf(line, sizeof(line), "job %s  height %" PRId64 "  diff %.4g%s",
                      incoming.jobId.c_str(), incoming.height, state.GetDifficulty(),
                      incoming.cleanJobs ? "  (new block)" : "");
        Job(line);
    };

    // ---- workers ----------------------------------------------------------
    std::vector<std::thread> workers;
    workers.reserve(size_t(opt.threads));
    for (int i = 0; i < opt.threads; i++) {
        workers.emplace_back(WorkerLoop, i, std::ref(engine), std::ref(state),
                             std::ref(client));
    }

    // ---- I/O loop ---------------------------------------------------------
    int64_t nextStats  = NowMs() + 30000;
    int64_t retryDelay = 1000;
    uint64_t lastHashes = 0;
    int64_t  lastStatsAt = NowMs();

    while (state.running.load()) {
        if (!client.IsConnected()) {
            std::string connectError;
            if (client.Connect(connectError)) {
                Info("connected");
                retryDelay = 1000;
            } else {
                Fail(connectError);
                Info("retrying in " + std::to_string(retryDelay / 1000) + "s");
                for (int64_t slept = 0; slept < retryDelay && state.running.load(); slept += 200) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(200));
                }
                retryDelay = std::min<int64_t>(retryDelay * 2, 60000);
                continue;
            }
        }

        client.Poll();

        if (NowMs() >= nextStats) {
            const uint64_t now = state.hashes.load();
            const double window = (NowMs() - lastStatsAt) / 1000.0;
            const double rate = window > 0 ? double(now - lastHashes) / window : 0;

            char line[256];
            std::snprintf(line, sizeof(line),
                          "%s   accepted %" PRIu64 "  rejected %" PRIu64
                          "  blocks %" PRIu64 "  total %" PRIu64 " hashes",
                          HumanHashrate(rate).c_str(),
                          state.accepted.load(), state.rejected.load(),
                          state.blocksFound.load(), now);
            LogLine(CLR_DIM, "stats", line);

            lastHashes  = now;
            lastStatsAt = NowMs();
            nextStats   = NowMs() + 30000;
        }
    }

    Info("shutting down");
    state.running.store(false);
    for (std::thread& t : workers) if (t.joinable()) t.join();
    client.Close();

    Info("accepted " + std::to_string(state.accepted.load()) +
         ", rejected " + std::to_string(state.rejected.load()) +
         ", blocks " + std::to_string(state.blocksFound.load()));
    return 0;
}

} // namespace wam

int main(int argc, char** argv)
{
    return wam::Run(argc, argv);
}
