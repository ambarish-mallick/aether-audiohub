// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
// Real-time engine: uniformly partitioned overlap-save convolution of a 2×2 FIR
// matrix with a shared input frequency-domain delay line, A/B crossfading
// between immutable filter banks, exact delay-compensated bypass, metering.
#include "aether/aether_core.h"
#include "design.hpp"
#include "fft.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <vector>

#if defined(__x86_64__) || defined(_M_X64)
#include <xmmintrin.h>
#endif

namespace aether {
namespace {

// Flush denormals to zero for the duration of a process() call.
class DenormalGuard {
public:
    DenormalGuard() {
#if defined(__aarch64__)
        asm volatile("mrs %0, fpcr" : "=r"(saved_));
        asm volatile("msr fpcr, %0" : : "r"(saved_ | (uint64_t(1) << 24)));
#elif defined(__x86_64__) || defined(_M_X64)
        saved_ = _mm_getcsr();
        _mm_setcsr(saved_ | 0x8040u);
#endif
    }
    ~DenormalGuard() {
#if defined(__aarch64__)
        asm volatile("msr fpcr, %0" : : "r"(saved_));
#elif defined(__x86_64__) || defined(_M_X64)
        _mm_setcsr(saved_);
#endif
    }
    DenormalGuard(const DenormalGuard &) = delete;
    DenormalGuard &operator=(const DenormalGuard &) = delete;

private:
#if defined(__aarch64__)
    uint64_t saved_ = 0;
#else
    unsigned saved_ = 0;
#endif
};

// Non-negative float stored as its bit pattern; ordering of the bits matches ordering
// of the values, so fetch-max is an integer CAS loop.
struct AtomicPeak {
    std::atomic<uint32_t> bits{0};
    void max(float v) {
        uint32_t nv;
        std::memcpy(&nv, &v, sizeof nv);
        uint32_t cur = bits.load(std::memory_order_relaxed);
        while (nv > cur && !bits.compare_exchange_weak(cur, nv, std::memory_order_relaxed)) {
        }
    }
    float read(bool reset) {
        const uint32_t b = reset ? bits.exchange(0, std::memory_order_relaxed)
                                 : bits.load(std::memory_order_relaxed);
        float v;
        std::memcpy(&v, &b, sizeof v);
        return v;
    }
};

// 4× polyphase interpolator for true-peak estimation: 64-tap Kaiser-windowed sinc,
// pass band to 0.45·fs, each phase normalised to unity DC gain.
class TruePeakDetector {
public:
    static constexpr int kPhases = 4, kTaps = 16;
    TruePeakDetector() {
        const int L = kPhases * kTaps;
        const double fc = 0.45 / kPhases, beta = 8.0, centre = (L - 1) / 2.0;
        auto bessel0 = [](double x) {
            double sum = 1, term = 1;
            for (int k = 1; k < 30; ++k) {
                term *= (x / (2 * k)) * (x / (2 * k));
                sum += term;
            }
            return sum;
        };
        double h[kPhases * kTaps];
        for (int n = 0; n < L; ++n) {
            const double t = n - centre;
            const double sinc = t == 0 ? 2 * fc : std::sin(2 * 3.14159265358979323846 * fc * t) / (3.14159265358979323846 * t);
            const double r = 2.0 * n / (L - 1) - 1.0;
            h[n] = sinc * bessel0(beta * std::sqrt(std::max(0.0, 1 - r * r))) / bessel0(beta);
        }
        for (int p = 0; p < kPhases; ++p) {
            double sum = 0;
            for (int m = 0; m < kTaps; ++m) sum += h[m * kPhases + p];
            for (int m = 0; m < kTaps; ++m) coef_[p][m] = float(h[m * kPhases + p] / sum);
        }
        reset();
    }
    void reset() {
        std::fill(std::begin(hist_), std::end(hist_), 0.f);
        pos_ = 0;
    }
    // Returns the maximum absolute interpolated value for this input sample.
    float push(float x) {
        hist_[pos_] = x;
        hist_[pos_ + kTaps] = x;
        pos_ = (pos_ + 1) % kTaps;
        const float *h = hist_ + pos_; // oldest … newest
        float peak = 0;
        for (int p = 0; p < kPhases; ++p) {
            float acc = 0;
            for (int m = 0; m < kTaps; ++m) acc += coef_[p][m] * h[kTaps - 1 - m];
            peak = std::max(peak, std::fabs(acc));
        }
        return peak;
    }

private:
    float coef_[kPhases][kTaps];
    float hist_[2 * kTaps];
    int pos_ = 0;
};

struct FilterBank {
    uint32_t generation = 0;
    int mode = AETHER_MODE_BYPASS;
    bool identity = true;
    bool engineOwned = false;
    float gain = 1.f;
    int taps = 1;
    int partitions = 0;
    std::vector<float> re[2][2], im[2][2]; // partitions × bins, [ear][source]
};

template <typename T, std::size_t Capacity>
class SpscRing {
public:
    bool push(T v) {
        const std::size_t h = head_.load(std::memory_order_relaxed);
        const std::size_t n = (h + 1) % Capacity;
        if (n == tail_.load(std::memory_order_acquire)) return false;
        buf_[h] = v;
        head_.store(n, std::memory_order_release);
        return true;
    }
    bool pop(T &v) {
        const std::size_t t = tail_.load(std::memory_order_relaxed);
        if (t == head_.load(std::memory_order_acquire)) return false;
        v = buf_[t];
        tail_.store((t + 1) % Capacity, std::memory_order_release);
        return true;
    }
    bool hasSpace() const {
        const std::size_t h = head_.load(std::memory_order_relaxed);
        return (h + 1) % Capacity != tail_.load(std::memory_order_acquire);
    }

private:
    T buf_[Capacity]{};
    std::atomic<std::size_t> head_{0}, tail_{0};
};

} // namespace
} // namespace aether

using namespace aether;

struct aether_engine {
    // ---- control side ----
    std::mutex control;
    aether_config config{};
    uint32_t generation = 0;
    EngineGeometry geo{};
    FFT<double> designFft; // size N, used to transform filter partitions
    bool prepared = false;

    // ---- audio side (owned by the audio thread once running) ----
    int B = 0, N = 0, bins = 0, D0 = 0, pmax = 0;
    FFT<float> fft;
    std::vector<float> inFifo[2], outFifo[2], prevIn[2], hist[2];
    std::vector<float> fdlRe[2], fdlIm[2];
    std::vector<float> zr, zi, accRe[2], accIm[2], outA[2], outB[2], bypassOut[2];
    int fifoPos = 0, fdlHead = 0;
    FilterBank *active = nullptr, *prev = nullptr;
    int xfadePos = 0, xfadeLen = 1;
    std::unique_ptr<FilterBank> identityBank;
    TruePeakDetector tp[2];

    // ---- handoff ----
    std::atomic<FilterBank *> pending{nullptr};
    SpscRing<FilterBank *, 16> retired;

    // ---- telemetry ----
    AtomicPeak inPeak[2], outPeak[2], outTp[2], tpMax;
    std::atomic<uint64_t> frames{0}, nonfiniteIn{0}, nonfiniteOut{0};
    std::atomic<uint32_t> activeGeneration{0}, activeTaps{0}, activePartitions{0};
    std::atomic<int32_t> activeMode{AETHER_MODE_REFERENCE}, crossfading{0}, safetyBypass{0};
    std::atomic<uint32_t> latency{0}, blockFrames{0}, submittedGeneration{0};
    std::atomic<double> sampleRate{0};

    // ------------------------------------------------------------------------

    void drainRetired() {
        FilterBank *b = nullptr;
        while (retired.pop(b))
            if (b && !b->engineOwned) delete b;
    }

    FilterBank *buildBank(const aether_config &cfg, uint32_t gen) {
        const ResolvedConfig rc = resolve(cfg);
        const DesignedMatrix m = designMatrix(rc, geo);
        auto *bank = new FilterBank;
        bank->generation = gen;
        bank->mode = rc.mode;
        bank->identity = m.identity;
        bank->gain = float(m.gain);
        bank->taps = m.taps;
        if (m.identity) return bank;
        bank->partitions = (m.taps + B - 1) / B;
        std::vector<double> re(static_cast<std::size_t>(N)), im(static_cast<std::size_t>(N));
        for (int e = 0; e < 2; ++e)
            for (int s = 0; s < 2; ++s) {
                auto &dre = bank->re[e][s];
                auto &dim = bank->im[e][s];
                dre.assign(std::size_t(bank->partitions * bins), 0.f);
                dim.assign(std::size_t(bank->partitions * bins), 0.f);
                const std::vector<double> &h = m.h[e][s];
                for (int p = 0; p < bank->partitions; ++p) {
                    std::fill(re.begin(), re.end(), 0.0);
                    std::fill(im.begin(), im.end(), 0.0);
                    for (int i = 0; i < B; ++i) {
                        const std::size_t idx = std::size_t(p * B + i);
                        if (idx < h.size()) re[std::size_t(i)] = h[idx];
                    }
                    designFft.forward(re.data(), im.data());
                    for (int k = 0; k < bins; ++k) {
                        dre[std::size_t(p * bins + k)] = float(re[std::size_t(k)]);
                        dim[std::size_t(p * bins + k)] = float(im[std::size_t(k)]);
                    }
                }
            }
        return bank;
    }

    void publishActive(const FilterBank *b) {
        activeGeneration.store(b->generation, std::memory_order_relaxed);
        activeMode.store(b->mode, std::memory_order_relaxed);
        activeTaps.store(uint32_t(b->taps), std::memory_order_relaxed);
        activePartitions.store(uint32_t(b->partitions), std::memory_order_relaxed);
    }

    void retire(FilterBank *b) {
        if (!b || b->engineOwned) return;
        // Capacity is checked before a crossfade starts, so this cannot fail in practice;
        // if it ever did, leaking is preferable to freeing on the audio thread.
        (void)retired.push(b);
    }

    // y = delayed input × gain (exact; no FFT round-off)
    void renderIdentity(const FilterBank *b, std::vector<float> *out) {
        for (int c = 0; c < 2; ++c)
            for (int i = 0; i < B; ++i) out[c][std::size_t(i)] = bypassOut[c][std::size_t(i)] * b->gain;
    }

    void renderBank(const FilterBank *b, std::vector<float> *out) {
        if (b->identity) {
            renderIdentity(b, out);
            return;
        }
        for (int e = 0; e < 2; ++e) {
            std::fill(accRe[e].begin(), accRe[e].end(), 0.f);
            std::fill(accIm[e].begin(), accIm[e].end(), 0.f);
        }
        const std::size_t nb = std::size_t(bins);
        for (int p = 0; p < b->partitions; ++p) {
            const std::size_t slot = std::size_t((fdlHead - p + pmax) % pmax) * nb;
            const std::size_t off = std::size_t(p) * nb;
            for (int e = 0; e < 2; ++e) {
                float *ar = accRe[e].data(), *ai = accIm[e].data();
                for (int s = 0; s < 2; ++s) {
                    const float *xr = fdlRe[s].data() + slot, *xi = fdlIm[s].data() + slot;
                    const float *hr = b->re[e][s].data() + off, *hi = b->im[e][s].data() + off;
                    for (std::size_t k = 0; k < nb; ++k) {
                        ar[k] += xr[k] * hr[k] - xi[k] * hi[k];
                        ai[k] += xr[k] * hi[k] + xi[k] * hr[k];
                    }
                }
            }
        }
        // Pack Z = Y_L + j·Y_R over the full spectrum (Hermitian extension), one inverse FFT.
        const float *a0 = accRe[0].data(), *b0 = accIm[0].data();
        const float *a1 = accRe[1].data(), *b1 = accIm[1].data();
        for (int k = 0; k <= B; ++k) {
            zr[std::size_t(k)] = a0[k] - b1[k];
            zi[std::size_t(k)] = b0[k] + a1[k];
        }
        for (int k = B + 1; k < N; ++k) {
            const int m = N - k;
            zr[std::size_t(k)] = a0[m] + b1[m];
            zi[std::size_t(k)] = -b0[m] + a1[m];
        }
        fft.inverse(zr.data(), zi.data());
        const float scale = 1.f / float(N);
        for (int i = 0; i < B; ++i) {
            out[0][std::size_t(i)] = zr[std::size_t(B + i)] * scale;
            out[1][std::size_t(i)] = zi[std::size_t(B + i)] * scale;
        }
    }

    void processBlock() {
        // 1. Adopt a newly published bank (not during a crossfade).
        if (!prev && retired.hasSpace()) {
            if (FilterBank *nb = pending.exchange(nullptr, std::memory_order_acq_rel)) {
                prev = active;
                active = nb;
                xfadePos = 0;
                publishActive(nb);
                crossfading.store(1, std::memory_order_relaxed);
                if (safetyBypass.load(std::memory_order_relaxed)) safetyBypass.store(0, std::memory_order_relaxed);
            }
        }

        // 2. Exact delayed copy for bypass: hist = [last D0 samples | current block].
        for (int c = 0; c < 2; ++c) {
            std::memcpy(hist[c].data() + D0, inFifo[c].data(), sizeof(float) * std::size_t(B));
            std::memcpy(bypassOut[c].data(), hist[c].data(), sizeof(float) * std::size_t(B));
        }

        // 3. Forward FFT of [previous block | current block] for both channels at once.
        for (int i = 0; i < B; ++i) {
            zr[std::size_t(i)] = prevIn[0][std::size_t(i)];
            zi[std::size_t(i)] = prevIn[1][std::size_t(i)];
            zr[std::size_t(B + i)] = inFifo[0][std::size_t(i)];
            zi[std::size_t(B + i)] = inFifo[1][std::size_t(i)];
        }
        fft.forward(zr.data(), zi.data());
        fdlHead = (fdlHead + 1) % pmax;
        {
            const std::size_t slot = std::size_t(fdlHead) * std::size_t(bins);
            float *lr = fdlRe[0].data() + slot, *li = fdlIm[0].data() + slot;
            float *rr = fdlRe[1].data() + slot, *ri = fdlIm[1].data() + slot;
            for (int k = 0; k <= B; ++k) {
                const int m = (N - k) % N;
                const float ar = zr[std::size_t(k)], ai = zi[std::size_t(k)];
                const float br = zr[std::size_t(m)], bi = -zi[std::size_t(m)]; // conj(Z[N−k])
                lr[k] = 0.5f * (ar + br);
                li[k] = 0.5f * (ai + bi);
                rr[k] = 0.5f * (ai - bi);
                ri[k] = -0.5f * (ar - br);
            }
        }
        for (int c = 0; c < 2; ++c)
            std::memcpy(prevIn[c].data(), inFifo[c].data(), sizeof(float) * std::size_t(B));

        // 4. Render active (and previous during a crossfade) and blend with a raised cosine.
        renderBank(active, outA);
        if (prev) {
            renderBank(prev, outB);
            const float invLen = 1.f / float(xfadeLen);
            for (int i = 0; i < B; ++i) {
                const float t = std::min(1.f, float(xfadePos + i + 1) * invLen);
                const float w = 0.5f - 0.5f * std::cos(3.14159265358979f * t);
                for (int c = 0; c < 2; ++c)
                    outFifo[c][std::size_t(i)] = (1.f - w) * outB[c][std::size_t(i)] + w * outA[c][std::size_t(i)];
            }
            xfadePos += B;
            if (xfadePos >= xfadeLen) {
                retire(prev);
                prev = nullptr;
                crossfading.store(0, std::memory_order_relaxed);
            }
        } else {
            for (int c = 0; c < 2; ++c)
                std::memcpy(outFifo[c].data(), outA[c].data(), sizeof(float) * std::size_t(B));
        }

        // 5. Non-finite guard: fall back to unity bypass, faded in from silence.
        bool bad = false;
        for (int c = 0; c < 2 && !bad; ++c)
            for (int i = 0; i < B; ++i)
                if (!std::isfinite(outFifo[c][std::size_t(i)])) {
                    bad = true;
                    break;
                }
        if (bad) {
            nonfiniteOut.fetch_add(1, std::memory_order_relaxed);
            for (int c = 0; c < 2; ++c) {
                std::fill(fdlRe[c].begin(), fdlRe[c].end(), 0.f);
                std::fill(fdlIm[c].begin(), fdlIm[c].end(), 0.f);
                std::fill(prevIn[c].begin(), prevIn[c].end(), 0.f);
                for (int i = 0; i < B; ++i)
                    outFifo[c][std::size_t(i)] = bypassOut[c][std::size_t(i)] * (float(i) / float(B));
            }
            if (prev) retire(prev);
            prev = nullptr;
            if (active != identityBank.get()) retire(active);
            active = identityBank.get();
            publishActive(active);
            crossfading.store(0, std::memory_order_relaxed);
            safetyBypass.store(1, std::memory_order_relaxed);
        }

        // 6. Keep the last D0 input samples for the next block's bypass copy.
        for (int c = 0; c < 2; ++c)
            std::memmove(hist[c].data(), hist[c].data() + B, sizeof(float) * std::size_t(D0));

        // 7. Output metering.
        for (int c = 0; c < 2; ++c) {
            float pk = 0, tpk = 0;
            for (int i = 0; i < B; ++i) {
                const float y = outFifo[c][std::size_t(i)];
                pk = std::max(pk, std::fabs(y));
                tpk = std::max(tpk, tp[c].push(y));
            }
            tpk = std::max(tpk, pk);
            outPeak[c].max(pk);
            outTp[c].max(tpk);
            tpMax.max(tpk);
        }
    }

    void freeBanks() {
        drainRetired();
        if (FilterBank *p = pending.exchange(nullptr)) delete p;
        if (prev && !prev->engineOwned) delete prev;
        if (active && !active->engineOwned) delete active;
        prev = active = nullptr;
    }
};

// ---------------------------------------------------------------------------
// C ABI

extern "C" {

uint32_t aether_abi_version(void) { return AETHER_ABI_VERSION; }
const char *aether_version_string(void) { return "Aether DSP core 1.1.0 (ABI 2)"; }

float aether_eq_frequency(int index) { return float(eqFrequency(index)); }

void aether_config_default(aether_config *cfg) {
    if (!cfg) return;
    std::memset(cfg, 0, sizeof *cfg);
    cfg->struct_size = sizeof(aether_config);
    cfg->mode = AETHER_MODE_REFERENCE;
    cfg->speaker_left_deg = 30.f;
    cfg->speaker_right_deg = 30.f;
    cfg->room_level = 0.3f;
    cfg->room_size = AETHER_ROOM_MEDIUM;
    cfg->width = 1.f;
    cfg->clarity = 1.f;
    cfg->speaker_enabled[0] = cfg->speaker_enabled[1] = 1;
    cfg->fold_disabled = 0;
    cfg->crossfeed_level_db = -9.f;
    cfg->crossfeed_cutoff_hz = 700.f;
    cfg->crossfeed_delay_ms = 0.3f;
    cfg->headroom_db = -6.f;
    cfg->level_match_bypass = 0;
    cfg->iem_enabled = 0;
}

int aether_config_validate(const aether_config *cfg) {
    if (!cfg || cfg->struct_size != sizeof(aether_config)) return AETHER_ERR_INVALID_ARGUMENT;
    if (cfg->mode < AETHER_MODE_BYPASS || cfg->mode > AETHER_MODE_CUSTOM) return AETHER_ERR_INVALID_CONFIG;
    if (cfg->room_size < AETHER_ROOM_SMALL || cfg->room_size > AETHER_ROOM_LARGE) return AETHER_ERR_INVALID_CONFIG;
    if (!cfg->speaker_enabled[0] && !cfg->speaker_enabled[1]) return AETHER_ERR_INVALID_CONFIG;
    const float scalars[] = {cfg->speaker_left_deg,   cfg->speaker_right_deg,   cfg->room_level,
                             cfg->width,              cfg->clarity,             cfg->crossfeed_level_db,
                             cfg->crossfeed_cutoff_hz, cfg->crossfeed_delay_ms, cfg->headroom_db};
    for (float v : scalars)
        if (!std::isfinite(v)) return AETHER_ERR_INVALID_CONFIG;
    for (int e = 0; e < 2; ++e)
        for (int i = 0; i < AETHER_EQ_POINTS; ++i)
            if (!std::isfinite(cfg->iem_db[e][i])) return AETHER_ERR_INVALID_CONFIG;
    return AETHER_OK;
}

void aether_config_set_iem_curve(aether_config *cfg, int ear, const float *db, int count) {
    if (!cfg || !db || ear < 0 || ear > 1) return;
    for (int i = 0; i < AETHER_EQ_POINTS; ++i) cfg->iem_db[ear][i] = i < count ? db[i] : 0.f;
}

void aether_config_get_iem_curve(const aether_config *cfg, int ear, float *db, int count) {
    if (!cfg || !db || ear < 0 || ear > 1) return;
    for (int i = 0; i < count && i < AETHER_EQ_POINTS; ++i) db[i] = cfg->iem_db[ear][i];
}

aether_engine *aether_engine_create(void) {
    auto *e = new (std::nothrow) aether_engine;
    if (e) aether_config_default(&e->config);
    return e;
}

void aether_engine_destroy(aether_engine *e) {
    if (!e) return;
    {
        std::lock_guard<std::mutex> lock(e->control);
        e->freeBanks();
    }
    delete e;
}

int aether_engine_prepare(aether_engine *e, double sampleRate) {
    if (!e) return AETHER_ERR_INVALID_ARGUMENT;
    if (!std::isfinite(sampleRate) || sampleRate < 8000.0 || sampleRate > 768000.0)
        return AETHER_ERR_UNSUPPORTED_RATE;
    std::lock_guard<std::mutex> lock(e->control);
    e->freeBanks();

    e->geo = geometryFor(sampleRate);
    e->B = e->geo.block;
    e->N = 2 * e->B;
    e->bins = e->B + 1;
    e->D0 = e->geo.bulkDelay;
    e->pmax = e->geo.maxTaps / e->B;
    e->fft.init(std::size_t(e->N));
    e->designFft.init(std::size_t(e->N));

    const std::size_t B = std::size_t(e->B), bins = std::size_t(e->bins);
    for (int c = 0; c < 2; ++c) {
        e->inFifo[c].assign(B, 0.f);
        e->outFifo[c].assign(B, 0.f);
        e->prevIn[c].assign(B, 0.f);
        e->hist[c].assign(std::size_t(e->D0) + B, 0.f);
        e->fdlRe[c].assign(std::size_t(e->pmax) * bins, 0.f);
        e->fdlIm[c].assign(std::size_t(e->pmax) * bins, 0.f);
        e->accRe[c].assign(bins, 0.f);
        e->accIm[c].assign(bins, 0.f);
        e->outA[c].assign(B, 0.f);
        e->outB[c].assign(B, 0.f);
        e->bypassOut[c].assign(B, 0.f);
        e->tp[c].reset();
    }
    e->zr.assign(std::size_t(e->N), 0.f);
    e->zi.assign(std::size_t(e->N), 0.f);
    e->fifoPos = 0;
    e->fdlHead = 0;
    e->xfadeLen = std::max(e->B, int(std::lround(0.05 * sampleRate))); // 50 ms

    e->identityBank = std::make_unique<FilterBank>();
    e->identityBank->engineOwned = true;
    e->identityBank->mode = AETHER_MODE_BYPASS;

    e->active = e->buildBank(e->config, e->generation);
    e->prev = nullptr;
    e->publishActive(e->active);
    e->crossfading.store(0);
    e->safetyBypass.store(0);
    for (int c = 0; c < 2; ++c) {
        e->inPeak[c].read(true);
        e->outPeak[c].read(true);
        e->outTp[c].read(true);
    }
    e->tpMax.read(true);
    e->latency.store(uint32_t(e->B + e->D0));
    e->blockFrames.store(uint32_t(e->B));
    e->sampleRate.store(sampleRate);
    e->prepared = true;
    return AETHER_OK;
}

int aether_engine_submit_config(aether_engine *e, const aether_config *cfg) {
    if (!e) return AETHER_ERR_INVALID_ARGUMENT;
    const int v = aether_config_validate(cfg);
    if (v != AETHER_OK) return v; // previous snapshot stays active
    std::lock_guard<std::mutex> lock(e->control);
    e->drainRetired();
    e->config = *cfg;
    const uint32_t gen = ++e->generation;
    e->submittedGeneration.store(gen, std::memory_order_relaxed);
    if (!e->prepared) return AETHER_OK;
    FilterBank *bank = e->buildBank(*cfg, gen);
    if (FilterBank *old = e->pending.exchange(bank, std::memory_order_acq_rel)) delete old;
    return AETHER_OK;
}

void aether_engine_process(aether_engine *e, const float *inL, const float *inR, size_t inStride,
                           float *outL, float *outR, size_t outStride, uint32_t frames) {
    if (!e || !outL || !outR) return;
    if (!e->prepared || !e->active) {
        for (uint32_t n = 0; n < frames; ++n) outL[n * outStride] = outR[n * outStride] = 0.f;
        return;
    }
    DenormalGuard guard;
    float pk[2] = {0.f, 0.f};
    uint64_t bad = 0;
    int pos = e->fifoPos;
    float *f0 = e->inFifo[0].data(), *f1 = e->inFifo[1].data();
    const float *o0 = e->outFifo[0].data(), *o1 = e->outFifo[1].data();
    for (uint32_t n = 0; n < frames; ++n) {
        float l = inL ? inL[n * inStride] : 0.f;
        float r = inR ? inR[n * inStride] : 0.f;
        if (!std::isfinite(l)) { l = 0.f; ++bad; }
        if (!std::isfinite(r)) { r = 0.f; ++bad; }
        pk[0] = std::max(pk[0], std::fabs(l));
        pk[1] = std::max(pk[1], std::fabs(r));
        f0[pos] = l;
        f1[pos] = r;
        outL[n * outStride] = o0[pos];
        outR[n * outStride] = o1[pos];
        if (++pos == e->B) {
            e->processBlock();
            pos = 0;
        }
    }
    e->fifoPos = pos;
    e->inPeak[0].max(pk[0]);
    e->inPeak[1].max(pk[1]);
    if (bad) e->nonfiniteIn.fetch_add(bad, std::memory_order_relaxed);
    e->frames.fetch_add(frames, std::memory_order_relaxed);
}

uint32_t aether_engine_latency_frames(const aether_engine *e) {
    return e ? e->latency.load(std::memory_order_relaxed) : 0;
}

void aether_engine_get_info(const aether_engine *e, aether_engine_info *info) {
    if (!info) return;
    std::memset(info, 0, sizeof *info);
    if (!e) return;
    info->sample_rate = e->sampleRate.load(std::memory_order_relaxed);
    info->block_frames = e->blockFrames.load(std::memory_order_relaxed);
    info->latency_frames = e->latency.load(std::memory_order_relaxed);
    info->filter_taps = e->activeTaps.load(std::memory_order_relaxed);
    info->partitions = e->activePartitions.load(std::memory_order_relaxed);
    info->generation = e->submittedGeneration.load(std::memory_order_relaxed);
}

void aether_engine_read_meters(aether_engine *e, aether_meters *m, int reset) {
    if (!m) return;
    std::memset(m, 0, sizeof *m);
    if (!e) return;
    const bool r = reset != 0;
    for (int c = 0; c < 2; ++c) {
        m->in_peak[c] = e->inPeak[c].read(r);
        m->out_peak[c] = e->outPeak[c].read(r);
        m->out_true_peak[c] = e->outTp[c].read(r);
    }
    m->out_true_peak_max = e->tpMax.read(false);
    m->frames_processed = e->frames.load(std::memory_order_relaxed);
    m->nonfinite_input_samples = e->nonfiniteIn.load(std::memory_order_relaxed);
    m->nonfinite_output_events = e->nonfiniteOut.load(std::memory_order_relaxed);
    m->active_generation = e->activeGeneration.load(std::memory_order_relaxed);
    m->active_mode = e->activeMode.load(std::memory_order_relaxed);
    m->crossfading = e->crossfading.load(std::memory_order_relaxed);
    m->safety_bypass = e->safetyBypass.load(std::memory_order_relaxed);
}

int aether_describe_room(const aether_config *cfg, aether_reflection *out, int maxCount,
                         aether_room_summary *summary) {
    if (!cfg || aether_config_validate(cfg) != AETHER_OK) return AETHER_ERR_INVALID_CONFIG;
    const ResolvedConfig rc = resolve(*cfg);
    const std::vector<Reflection> refl = computeReflections(rc);
    const int n = int(refl.size());
    if (out)
        for (int i = 0; i < n && i < maxCount; ++i) {
            const Reflection &r = refl[std::size_t(i)];
            out[i] = {r.speaker, r.order, float(r.azDeg), float(r.elDeg), float(r.delay * 1000.0),
                      float(r.gain), float(r.distance)};
        }
    if (summary) {
        std::memset(summary, 0, sizeof *summary);
        const RoomGeometry g = roomGeometry(rc.roomSize);
        summary->count = n;
        summary->room_width_m = float(g.width);
        summary->room_depth_m = float(g.depth);
        summary->room_height_m = float(g.height);
        summary->speaker_distance_m = float(g.speakerDistance);
        double energy = 0;
        for (const Reflection &r : refl) energy += r.gain * r.gain;
        if (n > 0) {
            summary->first_delay_ms = float(refl.front().delay * 1000.0);
            summary->last_delay_ms = float(refl.back().delay * 1000.0);
            // Direct energy: one unit-gain direct path per enabled speaker.
            const double direct = double(int(rc.enabled[0]) + int(rc.enabled[1]));
            summary->direct_to_reflected_db = float(10.0 * std::log10(direct / energy));
        } else {
            summary->direct_to_reflected_db = INFINITY;
        }
    }
    return n;
}

int aether_design_user_eq(float bass, float presence, float treble, float *out) {
    return designUserEq(bass, presence, treble, out);
}

int aether_design_correction(const float *mh, const float *md, int mc, const float *th,
                             const float *td, int tc, float relHigh, float *out,
                             aether_correction_report *report) {
    return designCorrection(mh, md, mc, th, td, tc, relHigh, out, report);
}

} // extern "C"
