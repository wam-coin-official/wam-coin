// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  N-API binding to librandomx for the WAM stratum pool
// ===========================================================================
//
//  A pool must verify every submitted share, and a RandomX hash costs
//  milliseconds rather than microseconds. Doing that on the libuv event loop
//  would stall every other connection, so the design is:
//
//    * A small pool of VMs, one per worker thread, sharing one cache (light
//      mode) or one dataset (mining mode).
//    * hashAsync() runs on the libuv threadpool via Napi::AsyncWorker, so the
//      event loop never blocks.
//    * hashSync() exists for startup self-tests and for the payment processor,
//      where blocking is harmless and simplicity is worth more.
//
//  A verification pool should stay in LIGHT mode: 256 MiB total instead of
//  2 GiB per seed, and share verification is not throughput-critical.
//
//  Build:
//      RANDOMX_INCLUDE=/path/RandomX/src RANDOMX_LIB=/path/librandomx.a \
//          npx node-gyp rebuild
// ===========================================================================

#include <napi.h>
#include <randomx.h>

#include <condition_variable>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

// ---------------------------------------------------------------------------
// One initialised context per seed
// ---------------------------------------------------------------------------

struct SeedContext {
    std::string seed;                 // raw 32 bytes
    randomx_cache* cache{nullptr};
    randomx_dataset* dataset{nullptr};
    std::vector<randomx_vm*> vms;     // one per slot; guarded by `busy`
    std::vector<bool> busy;
    std::mutex mtx;
    std::condition_variable cv;
    bool full_mem{false};

    SeedContext(const std::string& s, bool fullMem, unsigned vmCount)
        : seed(s), full_mem(fullMem)
    {
        randomx_flags flags = randomx_get_flags();
        if (fullMem) flags |= RANDOMX_FLAG_FULL_MEM;
        else         flags = static_cast<randomx_flags>(flags & ~RANDOMX_FLAG_FULL_MEM);

        cache = randomx_alloc_cache(flags);
        if (!cache) throw std::runtime_error("randomx_alloc_cache failed");
        randomx_init_cache(cache, seed.data(), seed.size());

        if (fullMem) {
            dataset = randomx_alloc_dataset(flags);
            if (!dataset) {
                randomx_release_cache(cache);
                throw std::runtime_error(
                    "randomx_alloc_dataset failed: full mode needs ~2.1 GiB free RAM");
            }
            const unsigned long count = randomx_dataset_item_count();
            randomx_init_dataset(dataset, cache, 0, count);
        }

        vms.reserve(vmCount);
        busy.assign(vmCount, false);
        for (unsigned i = 0; i < vmCount; ++i) {
            randomx_vm* vm = randomx_create_vm(flags, cache, dataset);
            if (!vm) {
                for (auto* v : vms) randomx_destroy_vm(v);
                if (dataset) randomx_release_dataset(dataset);
                randomx_release_cache(cache);
                throw std::runtime_error("randomx_create_vm failed");
            }
            vms.push_back(vm);
        }
    }

    ~SeedContext()
    {
        for (auto* vm : vms) randomx_destroy_vm(vm);
        if (dataset) randomx_release_dataset(dataset);
        if (cache) randomx_release_cache(cache);
    }

    /** Block until a VM slot frees up, then take it. */
    int acquire()
    {
        std::unique_lock<std::mutex> lk(mtx);
        cv.wait(lk, [this] {
            for (size_t i = 0; i < busy.size(); ++i) if (!busy[i]) return true;
            return false;
        });
        for (size_t i = 0; i < busy.size(); ++i) {
            if (!busy[i]) { busy[i] = true; return static_cast<int>(i); }
        }
        return -1; // unreachable
    }

    void release(int slot)
    {
        {
            std::lock_guard<std::mutex> lk(mtx);
            busy[slot] = false;
        }
        cv.notify_one();
    }
};

std::mutex g_registry_mutex;
std::map<std::string, std::shared_ptr<SeedContext>> g_contexts;
bool g_full_mem = false;
unsigned g_vm_count = 4;
size_t g_max_seeds = 2;

std::shared_ptr<SeedContext> GetContext(const std::string& seed)
{
    std::lock_guard<std::mutex> lk(g_registry_mutex);

    auto it = g_contexts.find(seed);
    if (it != g_contexts.end()) return it->second;

    // Around an epoch boundary two seeds are live at once; more than that means
    // something is wrong upstream, so evict rather than grow without bound.
    while (g_contexts.size() >= g_max_seeds) {
        g_contexts.erase(g_contexts.begin());
    }

    auto ctx = std::make_shared<SeedContext>(seed, g_full_mem, g_vm_count);
    g_contexts.emplace(seed, ctx);
    return ctx;
}

std::string RequireSeed(const Napi::Env& env, const Napi::Value& v)
{
    if (!v.IsBuffer()) {
        throw Napi::TypeError::New(env, "seed must be a 32-byte Buffer");
    }
    auto buf = v.As<Napi::Buffer<char>>();
    if (buf.Length() != 32) {
        throw Napi::TypeError::New(env, "seed must be exactly 32 bytes");
    }
    return std::string(buf.Data(), buf.Length());
}

// ---------------------------------------------------------------------------
// Async worker
// ---------------------------------------------------------------------------

class HashWorker : public Napi::AsyncWorker {
public:
    HashWorker(Napi::Function& cb, std::string seed, std::string input)
        : Napi::AsyncWorker(cb), seed_(std::move(seed)), input_(std::move(input)) {}

    void Execute() override
    {
        try {
            auto ctx = GetContext(seed_);
            const int slot = ctx->acquire();
            randomx_calculate_hash(ctx->vms[slot], input_.data(), input_.size(), out_);
            ctx->release(slot);
        } catch (const std::exception& e) {
            SetError(e.what());
        }
    }

    void OnOK() override
    {
        Napi::HandleScope scope(Env());
        Callback().Call({ Env().Null(),
                          Napi::Buffer<char>::Copy(Env(), out_, RANDOMX_HASH_SIZE) });
    }

private:
    std::string seed_;
    std::string input_;
    char out_[RANDOMX_HASH_SIZE]{};
};

// ---------------------------------------------------------------------------
// JS surface
// ---------------------------------------------------------------------------

Napi::Value Configure(const Napi::CallbackInfo& info)
{
    Napi::Env env = info.Env();
    if (info.Length() < 1 || !info[0].IsObject()) {
        Napi::TypeError::New(env, "configure(options) requires an object").ThrowAsJavaScriptException();
        return env.Undefined();
    }
    Napi::Object opts = info[0].As<Napi::Object>();

    std::lock_guard<std::mutex> lk(g_registry_mutex);

    if (opts.Has("fullMemory")) g_full_mem = opts.Get("fullMemory").ToBoolean();
    if (opts.Has("vmCount")) {
        const int n = opts.Get("vmCount").ToNumber().Int32Value();
        g_vm_count = (n > 0 && n <= 128) ? static_cast<unsigned>(n) : 4;
    }
    if (opts.Has("maxSeeds")) {
        const int n = opts.Get("maxSeeds").ToNumber().Int32Value();
        g_max_seeds = (n >= 1 && n <= 8) ? static_cast<size_t>(n) : 2;
    }

    // Any change invalidates every existing context.
    g_contexts.clear();

    Napi::Object out = Napi::Object::New(env);
    out.Set("fullMemory", Napi::Boolean::New(env, g_full_mem));
    out.Set("vmCount", Napi::Number::New(env, g_vm_count));
    out.Set("maxSeeds", Napi::Number::New(env, static_cast<double>(g_max_seeds)));
    return out;
}

Napi::Value HashSync(const Napi::CallbackInfo& info)
{
    Napi::Env env = info.Env();
    if (info.Length() < 2 || !info[1].IsBuffer()) {
        Napi::TypeError::New(env, "hashSync(seed, input) requires two Buffers")
            .ThrowAsJavaScriptException();
        return env.Undefined();
    }

    try {
        const std::string seed = RequireSeed(env, info[0]);
        auto inBuf = info[1].As<Napi::Buffer<char>>();

        auto ctx = GetContext(seed);
        const int slot = ctx->acquire();
        char out[RANDOMX_HASH_SIZE];
        randomx_calculate_hash(ctx->vms[slot], inBuf.Data(), inBuf.Length(), out);
        ctx->release(slot);

        return Napi::Buffer<char>::Copy(env, out, RANDOMX_HASH_SIZE);
    } catch (const Napi::Error& e) {
        e.ThrowAsJavaScriptException();
        return env.Undefined();
    } catch (const std::exception& e) {
        Napi::Error::New(env, e.what()).ThrowAsJavaScriptException();
        return env.Undefined();
    }
}

Napi::Value HashAsync(const Napi::CallbackInfo& info)
{
    Napi::Env env = info.Env();
    if (info.Length() < 3 || !info[1].IsBuffer() || !info[2].IsFunction()) {
        Napi::TypeError::New(env, "hashAsync(seed, input, callback)")
            .ThrowAsJavaScriptException();
        return env.Undefined();
    }

    try {
        const std::string seed = RequireSeed(env, info[0]);
        auto inBuf = info[1].As<Napi::Buffer<char>>();
        Napi::Function cb = info[2].As<Napi::Function>();

        auto* worker = new HashWorker(cb, seed,
                                      std::string(inBuf.Data(), inBuf.Length()));
        worker->Queue();
        return env.Undefined();
    } catch (const Napi::Error& e) {
        e.ThrowAsJavaScriptException();
        return env.Undefined();
    }
}

Napi::Value Stats(const Napi::CallbackInfo& info)
{
    Napi::Env env = info.Env();
    std::lock_guard<std::mutex> lk(g_registry_mutex);

    Napi::Array seeds = Napi::Array::New(env, g_contexts.size());
    uint32_t i = 0;
    for (const auto& [seed, ctx] : g_contexts) {
        std::string hex;
        hex.reserve(64);
        static const char* H = "0123456789abcdef";
        for (unsigned char c : seed) { hex += H[c >> 4]; hex += H[c & 0xf]; }
        seeds.Set(i++, Napi::String::New(env, hex));
    }

    Napi::Object out = Napi::Object::New(env);
    out.Set("seeds", seeds);
    out.Set("fullMemory", Napi::Boolean::New(env, g_full_mem));
    out.Set("vmCount", Napi::Number::New(env, g_vm_count));
    out.Set("approxBytes", Napi::Number::New(env,
        static_cast<double>(g_contexts.size()) *
        (g_full_mem ? 2181038080.0 : 268435456.0)));
    return out;
}

Napi::Value Flush(const Napi::CallbackInfo& info)
{
    std::lock_guard<std::mutex> lk(g_registry_mutex);
    g_contexts.clear();
    return info.Env().Undefined();
}

Napi::Object Init(Napi::Env env, Napi::Object exports)
{
    exports.Set("configure", Napi::Function::New(env, Configure));
    exports.Set("hashSync",  Napi::Function::New(env, HashSync));
    exports.Set("hashAsync", Napi::Function::New(env, HashAsync));
    exports.Set("stats",     Napi::Function::New(env, Stats));
    exports.Set("flush",     Napi::Function::New(env, Flush));
    exports.Set("HASH_SIZE", Napi::Number::New(env, RANDOMX_HASH_SIZE));
    return exports;
}

} // namespace

NODE_API_MODULE(wamrandomx, Init)
