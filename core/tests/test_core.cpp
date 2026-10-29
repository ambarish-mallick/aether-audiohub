// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
// Aether DSP core tests: exactness, determinism, chunking invariance, offline
// reference agreement, stereo integrity, transitions, headroom and design bounds.
#include "aether/aether_core.h"
#include "design.hpp"

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

namespace {

int g_failures = 0, g_checks = 0;

#define CHECK(cond, ...)                                                                      \
    do {                                                                                      \
        ++g_checks;                                                                           \
        if (!(cond)) {                                                                        \
            ++g_failures;                                                                     \
            std::printf("    FAIL %s:%d: %s — ", __FILE__, __LINE__, #cond);                  \
            std::printf(__VA_ARGS__);                                                         \
            std::printf("\n");                                                                \
        }                                                                                     \
    } while (0)

struct Rng {
    uint64_t s;
    explicit Rng(uint64_t seed) : s(seed * 2654435761u + 1) {}
    uint64_t next() {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        return s;
    }
    float uniform() { return float(next() >> 11) * (1.0f / 9007199254740992.0f) * 2.f - 1.f; }
    int range(int lo, int hi) { return lo + int(next() % uint64_t(hi - lo + 1)); }
};

std::vector<float> pinkNoise(std::size_t n, uint64_t seed, float peak) {
    Rng r(seed);
    std::vector<float> out(n);
    double b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;
    for (std::size_t i = 0; i < n; ++i) {
        const double w = r.uniform();
        b0 = 0.99886 * b0 + w * 0.0555179;
        b1 = 0.99332 * b1 + w * 0.0750759;
        b2 = 0.96900 * b2 + w * 0.1538520;
        b3 = 0.86650 * b3 + w * 0.3104856;
        b4 = 0.55000 * b4 + w * 0.5329522;
        b5 = -0.7616 * b5 - w * 0.0168980;
        out[i] = float(b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362);
        b6 = w * 0.115926;
    }
    float m = 0;
    for (float v : out) m = std::max(m, std::fabs(v));
    for (float &v : out) v *= peak / m;
    return out;
}

double rms(const std::vector<float> &x, std::size_t from = 0) {
    double s = 0;
    for (std::size_t i = from; i < x.size(); ++i) s += double(x[i]) * x[i];
    return std::sqrt(s / double(std::max<std::size_t>(1, x.size() - from)));
}

double db(double v) { return 20.0 * std::log10(std::max(v, 1e-30)); }

struct Run {
    std::vector<float> l, r;
};

// Processes the whole signal; chunk(i) returns the size of the next host buffer.
Run process(aether_engine *e, const std::vector<float> &l, const std::vector<float> &r,
            const std::function<int()> &chunk,
            const std::function<void(std::size_t)> &atFrame = nullptr) {
    Run out{std::vector<float>(l.size()), std::vector<float>(l.size())};
    std::size_t pos = 0;
    while (pos < l.size()) {
        if (atFrame) atFrame(pos);
        const std::size_t n = std::min<std::size_t>(std::size_t(std::max(1, chunk())), l.size() - pos);
        aether_engine_process(e, l.data() + pos, r.data() + pos, 1, out.l.data() + pos, out.r.data() + pos, 1,
                              uint32_t(n));
        pos += n;
    }
    return out;
}

aether_config config(int mode) {
    aether_config c;
    aether_config_default(&c);
    c.mode = mode;
    return c;
}

aether_engine *makeEngine(double fs, const aether_config &c) {
    aether_engine *e = aether_engine_create();
    aether_engine_submit_config(e, &c);
    aether_engine_prepare(e, fs);
    return e;
}

const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000};

// ---------------------------------------------------------------------------

void testBypassExact() {
    for (double fs : kRates) {
        aether_engine *e = makeEngine(fs, config(AETHER_MODE_BYPASS));
        const std::size_t n = std::size_t(fs * 0.5);
        const auto l = pinkNoise(n, 1, 0.9f), r = pinkNoise(n, 2, 0.9f);
        Rng rng(7);
        const Run out = process(e, l, r, [&] { return rng.range(1, 1500); });
        const std::size_t lat = aether_engine_latency_frames(e);
        double maxErr = 0;
        for (std::size_t i = 0; i < n; ++i) {
            const float el = i >= lat ? l[i - lat] : 0.f, er = i >= lat ? r[i - lat] : 0.f;
            maxErr = std::max({maxErr, double(std::fabs(out.l[i] - el)), double(std::fabs(out.r[i] - er))});
        }
        CHECK(maxErr <= 1e-7, "fs=%.0f max error %.3g", fs, maxErr);
        aether_engine_destroy(e);
    }
}

void testChunkInvariance() {
    aether_config c = config(AETHER_MODE_CUSTOM);
    c.speaker_left_deg = c.speaker_right_deg = 40;
    c.room_level = 0.6f;
    c.width = 1.2f;
    c.iem_enabled = 1;
    float eq[AETHER_EQ_POINTS];
    aether_design_user_eq(3.f, -2.f, 2.f, eq);
    aether_config_set_iem_curve(&c, 0, eq, AETHER_EQ_POINTS);
    aether_config_set_iem_curve(&c, 1, eq, AETHER_EQ_POINTS);
    const double fs = 48000;
    const std::size_t n = 48000;
    const auto l = pinkNoise(n, 3, 0.5f), r = pinkNoise(n, 4, 0.5f);
    aether_engine *a = makeEngine(fs, c), *b = makeEngine(fs, c);
    Rng rng(11);
    const Run ra = process(a, l, r, [&] { return rng.range(1, 3000); });
    const Run rb = process(b, l, r, [] { return 512; });
    CHECK(std::memcmp(ra.l.data(), rb.l.data(), n * sizeof(float)) == 0 &&
              std::memcmp(ra.r.data(), rb.r.data(), n * sizeof(float)) == 0,
          "output depends on host buffer chunking");
    aether_engine_destroy(a);
    aether_engine_destroy(b);
}

void testAgainstOfflineReference() {
    struct Case {
        int mode;
        float az, room, width;
        bool iem;
    };
    const Case cases[] = {{AETHER_MODE_REFERENCE, 30, 0.3f, 1, false},
                          {AETHER_MODE_CUSTOM, 50, 0.8f, 0.8f, true},
                          {AETHER_MODE_CROSSFEED, 30, 0, 1, false}};
    for (const Case &cs : cases) {
        aether_config c = config(cs.mode);
        c.speaker_left_deg = c.speaker_right_deg = cs.az;
        c.room_level = cs.room;
        c.width = cs.width;
        c.iem_enabled = cs.iem;
        float eq[AETHER_EQ_POINTS];
        aether_design_user_eq(4.f, 0.f, -3.f, eq);
        aether_config_set_iem_curve(&c, 0, eq, AETHER_EQ_POINTS);
        aether_design_user_eq(-2.f, 2.f, 1.f, eq);
        aether_config_set_iem_curve(&c, 1, eq, AETHER_EQ_POINTS);
        const double fs = 48000;
        const aether::EngineGeometry geo = aether::geometryFor(fs);
        const aether::DesignedMatrix m = aether::designMatrix(aether::resolve(c), geo);
        const std::size_t n = 24000;
        const auto l = pinkNoise(n, 5, 0.5f), r = pinkNoise(n, 6, 0.5f);
        aether_engine *e = makeEngine(fs, c);
        Rng rng(13);
        const Run out = process(e, l, r, [&] { return rng.range(16, 900); });
        const std::size_t B = std::size_t(geo.block);
        double errPow = 0, sigPow = 0;
        for (std::size_t i = B + std::size_t(m.taps); i < n; ++i) {
            const std::size_t t = i - B; // engine output is the filter output delayed by B
            double ref[2] = {0, 0};
            for (int ear = 0; ear < 2; ++ear)
                for (int k = 0; k < m.taps && std::size_t(k) <= t; ++k)
                    ref[ear] += m.h[ear][0][std::size_t(k)] * l[t - std::size_t(k)] +
                                m.h[ear][1][std::size_t(k)] * r[t - std::size_t(k)];
            errPow += (out.l[i] - ref[0]) * (out.l[i] - ref[0]) + (out.r[i] - ref[1]) * (out.r[i] - ref[1]);
            sigPow += ref[0] * ref[0] + ref[1] * ref[1];
        }
        const double snr = 10.0 * std::log10(sigPow / std::max(errPow, 1e-300));
        CHECK(snr > 100.0, "mode %d: engine vs float64 direct convolution SNR %.1f dB", cs.mode, snr);
        std::printf("    mode %d, %d taps: agreement with float64 reference %.1f dB\n", cs.mode, m.taps, snr);
        aether_engine_destroy(e);
    }
}

void testNonFiniteInput() {
    aether_engine *e = makeEngine(48000, config(AETHER_MODE_REFERENCE));
    auto l = pinkNoise(48000, 8, 0.5f), r = pinkNoise(48000, 9, 0.5f);
    l[1000] = NAN;
    r[2000] = INFINITY;
    l[30000] = -INFINITY;
    const Run out = process(e, l, r, [] { return 256; });
    bool finite = true;
    for (std::size_t i = 0; i < l.size(); ++i) finite &= std::isfinite(out.l[i]) && std::isfinite(out.r[i]);
    aether_meters m;
    aether_engine_read_meters(e, &m, 0);
    CHECK(finite, "non-finite output");
    CHECK(m.nonfinite_input_samples == 3, "counted %llu", (unsigned long long)m.nonfinite_input_samples);
    CHECK(m.safety_bypass == 0, "safety bypass should not latch for sanitised input");
    aether_engine_destroy(e);
}

void testSafetyBypass() {
    aether_engine *e = makeEngine(48000, config(AETHER_MODE_REFERENCE));
    std::vector<float> l(48000, 0.f), r(48000, 0.f);
    for (std::size_t i = 10000; i < 10600; ++i) l[i] = r[i] = (i & 1) ? 3e38f : -3e38f; // finite, overflows FFT
    const Run out = process(e, l, r, [] { return 512; });
    bool finite = true;
    for (std::size_t i = 0; i < l.size(); ++i) finite &= std::isfinite(out.l[i]) && std::isfinite(out.r[i]);
    aether_meters m;
    aether_engine_read_meters(e, &m, 0);
    CHECK(finite, "safety path produced non-finite output");
    CHECK(m.safety_bypass == 1 && m.nonfinite_output_events >= 1, "safety bypass did not latch");
    CHECK(m.active_mode == AETHER_MODE_BYPASS, "active mode %d", m.active_mode);
    const aether_config c = config(AETHER_MODE_REFERENCE);
    aether_engine_submit_config(e, &c);
    std::vector<float> z(4800, 0.f);
    process(e, z, z, [] { return 512; });
    aether_engine_read_meters(e, &m, 0);
    CHECK(m.safety_bypass == 0 && m.active_mode == AETHER_MODE_REFERENCE, "did not recover on new config");
    aether_engine_destroy(e);
}

void testCentreMonoStaysCentred() {
    for (int mode : {AETHER_MODE_CROSSFEED, AETHER_MODE_REFERENCE, AETHER_MODE_CUSTOM}) {
        aether_config c = config(mode);
        c.speaker_left_deg = c.speaker_right_deg = 45;
        c.room_level = 0.7f;
        aether_engine *e = makeEngine(48000, c);
        const auto mono = pinkNoise(48000, 10, 0.5f);
        const Run out = process(e, mono, mono, [] { return 333; });
        std::vector<float> diff(mono.size());
        for (std::size_t i = 0; i < mono.size(); ++i) diff[i] = out.l[i] - out.r[i];
        const double ratio = db(rms(diff, 4800) / rms(out.l, 4800));
        CHECK(ratio < -80.0, "mode %d: L−R residual %.1f dB", mode, ratio);
        aether_engine_destroy(e);
    }
}

// Cross-correlation lag (samples) of b relative to a, within ±maxLag.
int bestLag(const std::vector<float> &a, const std::vector<float> &b, int maxLag, std::size_t from) {
    double best = -1e300;
    int lag = 0;
    for (int d = -maxLag; d <= maxLag; ++d) {
        double s = 0;
        for (std::size_t i = from; i + std::size_t(maxLag) < a.size(); ++i)
            s += double(a[i]) * b[std::size_t(int(i) + d)];
        if (s > best) {
            best = s;
            lag = d;
        }
    }
    return lag;
}

// Second-order section, direct form I, for measurement filters in tests.
struct Biquad {
    double b0, b1, b2, a1, a2, x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    double run(double x) {
        const double y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1; x1 = x; y2 = y1; y1 = y;
        return y;
    }
};

std::vector<float> highPass(const std::vector<float> &x, double fc, double fs) {
    const double w0 = 2 * 3.14159265358979 * fc / fs, c = std::cos(w0), al = std::sin(w0) / (2 * 0.7071);
    const double a0 = 1 + al;
    Biquad a{(1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - al) / a0};
    Biquad b = a;
    std::vector<float> y(x.size());
    for (std::size_t i = 0; i < x.size(); ++i) y[i] = float(b.run(a.run(x[i])));
    return y;
}

// ITU-R BS.1770 K-weighting at 48 kHz.
std::vector<float> kWeight(const std::vector<float> &x) {
    Biquad shelf{1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585};
    Biquad rlb{1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621};
    std::vector<float> y(x.size());
    for (std::size_t i = 0; i < x.size(); ++i) y[i] = float(rlb.run(shelf.run(x[i])));
    return y;
}

void testHardPanNotSwapped() {
    const double fs = 48000;
    for (int mode : {AETHER_MODE_CROSSFEED, AETHER_MODE_REFERENCE}) {
        aether_engine *e = makeEngine(fs, config(mode));
        const auto l = pinkNoise(48000, 12, 0.5f);
        const std::vector<float> silent(l.size(), 0.f);
        const Run out = process(e, l, silent, [] { return 256; });
        const double ild = db(rms(out.l, 4800) / rms(out.r, 4800));
        const double ildHigh = db(rms(highPass(out.l, 3000, fs), 4800) / rms(highPass(out.r, 3000, fs), 4800));
        const int lag = bestLag(out.l, out.r, 48, 4800);
        const double itdMs = 1000.0 * lag / fs;
        CHECK(ild > 0.5, "mode %d: left input should be louder at the left ear (ILD %.1f dB)", mode, ild);
        CHECK(ildHigh > 6.0, "mode %d: high-band ILD %.1f dB", mode, ildHigh);
        CHECK(itdMs > 0.1 && itdMs < 0.8, "mode %d: right ear should lag (ITD %.3f ms)", mode, itdMs);
        std::printf("    mode %d hard-left: ILD %.1f dB broadband, %.1f dB above 3 kHz, ITD %.3f ms\n", mode, ild,
                    ildHigh, itdMs);
        // Mirror: right-only input must favour the right ear.
        const Run out2 = process(e, silent, l, [] { return 256; });
        CHECK(db(rms(out2.r, 4800) / rms(out2.l, 4800)) > 0.5, "mode %d: right input not at right ear", mode);
        aether_engine_destroy(e);
    }
}

void testClickFreeTransitions() {
    const double fs = 48000;
    const std::size_t n = std::size_t(fs * 3.2);
    std::vector<float> l(n), r(n);
    const double w = 2 * 3.14159265358979 * 997.0 / fs;
    for (std::size_t i = 0; i < n; ++i) {
        l[i] = float(0.25 * std::sin(w * double(i)));
        r[i] = float(0.25 * std::sin(w * double(i) + 1.0));
    }
    aether_engine *e = makeEngine(fs, config(AETHER_MODE_REFERENCE));
    const int sequence[] = {AETHER_MODE_CROSSFEED, AETHER_MODE_BYPASS, AETHER_MODE_CUSTOM, AETHER_MODE_REFERENCE,
                            AETHER_MODE_BYPASS};
    int next = 0;
    std::vector<std::size_t> switches;
    const Run out = process(e, l, r, [] { return 480; }, [&](std::size_t pos) {
        if (pos >= std::size_t(fs * 0.5) * std::size_t(next + 1) && next < 5) {
            aether_config c = config(sequence[next]);
            c.speaker_left_deg = c.speaker_right_deg = 55;
            c.room_level = 0.9f;
            aether_engine_submit_config(e, &c);
            switches.push_back(pos);
            ++next;
        }
    });
    // A click shows up as a second difference far above what any sinusoid of the
    // observed amplitude can produce: |x''| ≤ A·ω².
    double peak = 0, maxD2 = 0;
    for (std::size_t i = 4800; i < n; ++i) peak = std::max({peak, double(std::fabs(out.l[i])), double(std::fabs(out.r[i]))});
    for (std::size_t i = 4802; i < n; ++i)
        for (const auto *ch : {&out.l, &out.r}) {
            const auto &x = *ch;
            maxD2 = std::max(maxD2, std::fabs(double(x[i]) - 2.0 * x[i - 1] + x[i - 2]));
        }
    const double bound = peak * 2.0 * (1.0 - std::cos(w));
    CHECK(maxD2 <= bound * 1.25, "second difference %.3g exceeds sinusoid bound %.3g", maxD2, bound);
    CHECK(switches.size() == 5, "switches %zu", switches.size());
    aether_engine_destroy(e);
}

void testLevelMatchedModes() {
    // K-weighted power (BS.1770 weighting, ungated) averaged over a centre-mono and an
    // uncorrelated-stereo pink-noise condition, with headroom at 0 dB.
    const double fs = 48000;
    const std::size_t n = 192000;
    const auto a = pinkNoise(n, 14, 0.25f), b = pinkNoise(n, 15, 0.25f);
    struct Case {
        int mode;
        float left, right, room;
        int enabledL = 1, enabledR = 1, fold = 0;
    };
    // Bypass first; then crossfeed, reference and custom layouts including asymmetric,
    // rear and side-swapped speakers.
    const Case cases[] = {{AETHER_MODE_BYPASS, 30, 30, 0},       {AETHER_MODE_CROSSFEED, 30, 30, 0},
                          {AETHER_MODE_REFERENCE, 30, 30, 0},    {AETHER_MODE_CUSTOM, 50, 50, 0.6f},
                          {AETHER_MODE_CUSTOM, 60, 20, 0.3f},    {AETHER_MODE_CUSTOM, 150, 150, 0.3f},
                          {AETHER_MODE_CUSTOM, 270, 90, 0.0f},   {AETHER_MODE_CUSTOM, 30, 30, 0.3f, 0, 1, 0},
                          {AETHER_MODE_CUSTOM, 30, 30, 0.3f, 1, 0, 1}};
    const int count = int(sizeof cases / sizeof cases[0]);
    double levels[sizeof cases / sizeof cases[0]];
    int idx = 0;
    for (const Case &cs : cases) {
        aether_config c = config(cs.mode);
        c.headroom_db = 0;
        c.speaker_left_deg = cs.left;
        c.speaker_right_deg = cs.right;
        c.room_level = cs.room;
        c.speaker_enabled[0] = cs.enabledL;
        c.speaker_enabled[1] = cs.enabledR;
        c.fold_disabled = cs.fold;
        double power = 0;
        for (int cond = 0; cond < 2; ++cond) {
            aether_engine *e = makeEngine(fs, c);
            const Run out = process(e, a, cond == 0 ? a : b, [] { return 512; });
            for (const auto *ch : {&out.l, &out.r}) {
                const double r = rms(kWeight(*ch), 9600);
                power += r * r;
            }
            aether_engine_destroy(e);
        }
        levels[idx++] = 10.0 * std::log10(power);
    }
    for (int i = 1; i < count; ++i)
        CHECK(std::fabs(levels[i] - levels[0]) < 0.5, "case %d (mode %d, %.0f°/%.0f°) is %.2f dB vs bypass", i,
              cases[i].mode, cases[i].left, cases[i].right, levels[i] - levels[0]);
    std::printf("    K-weighted level vs bypass: crossfeed %+.2f, reference %+.2f, custom %+.2f dB\n",
                levels[1] - levels[0], levels[2] - levels[0], levels[3] - levels[0]);
    std::printf("    custom L60°/R20° %+.2f, rear 150° %+.2f, swapped 270°/90° %+.2f dB\n", levels[4] - levels[0],
                levels[5] - levels[0], levels[6] - levels[0]);
    std::printf("    left speaker off %+.2f, right off + fold %+.2f dB\n", levels[7] - levels[0], levels[8] - levels[0]);
}

void testHeadroomCorpus() {
    const double fs = 48000;
    const std::size_t n = std::size_t(fs * 4);
    const float peak = std::pow(10.f, -1.f / 20.f); // −1 dBFS sample-peak masters
    struct Item {
        const char *name;
        std::vector<float> l, r;
    };
    std::vector<Item> corpus;
    corpus.push_back({"pink stereo", pinkNoise(n, 20, peak), pinkNoise(n, 21, peak)});
    {
        auto p = pinkNoise(n, 22, peak);
        corpus.push_back({"pink mono", p, p});
        corpus.push_back({"pink hard-left", p, std::vector<float>(n, 0.f)});
        auto q = p;
        for (float &v : q) v = -v;
        corpus.push_back({"pink anti-phase", p, q});
    }
    {
        std::vector<float> s(n);
        double ph = 0;
        for (std::size_t i = 0; i < n; ++i) {
            const double f = 20.0 * std::pow(1000.0, double(i) / double(n));
            ph += 2 * 3.14159265358979 * f / fs;
            s[i] = float(peak * std::sin(ph));
        }
        corpus.push_back({"sweep mono", s, s});
    }
    for (int mode : {AETHER_MODE_CROSSFEED, AETHER_MODE_REFERENCE}) {
        for (const Item &it : corpus) {
            aether_engine *e = makeEngine(fs, config(mode));
            process(e, it.l, it.r, [] { return 512; });
            aether_meters m;
            aether_engine_read_meters(e, &m, 0);
            const double tp = db(m.out_true_peak_max);
            CHECK(tp <= -1.0, "mode %d %s: true peak %.2f dBTP", mode, it.name, tp);
            std::printf("    mode %d %-16s TP %+.2f dBTP\n", mode, it.name, tp);
            aether_engine_destroy(e);
        }
    }
}

void testTruePeakMeter() {
    const double fs = 48000;
    aether_engine *e = makeEngine(fs, config(AETHER_MODE_BYPASS));
    const std::size_t n = 48000;
    std::vector<float> x(n);
    for (std::size_t i = 0; i < n; ++i) x[i] = float(std::sin(2 * 3.14159265358979 * 0.25 * double(i) + 3.14159265358979 / 4));
    process(e, x, x, [] { return 512; });
    aether_meters m;
    aether_engine_read_meters(e, &m, 0);
    CHECK(std::fabs(db(m.out_peak[0]) + 3.01) < 0.05, "sample peak %.2f dBFS", db(m.out_peak[0]));
    CHECK(std::fabs(db(m.out_true_peak[0])) < 0.3, "true peak %.2f dBTP (expected ≈ 0)", db(m.out_true_peak[0]));
    aether_engine_destroy(e);
}

void testLatencyAlignment() {
    for (double fs : kRates) {
        for (int mode : {AETHER_MODE_BYPASS, AETHER_MODE_CROSSFEED, AETHER_MODE_REFERENCE}) {
            aether_config c = config(mode);
            c.headroom_db = 0;
            aether_engine *e = makeEngine(fs, c);
            const std::size_t n = std::size_t(fs * 0.2), at = 1234;
            std::vector<float> l(n, 0.f), r(n, 0.f);
            l[at] = r[at] = 0.5f; // centred impulse
            const Run out = process(e, l, r, [] { return 300; });
            const std::size_t expected = at + aether_engine_latency_frames(e);
            if (mode == AETHER_MODE_REFERENCE) {
                // HRTF paths are referenced to the head centre: ipsilateral arrives early,
                // contralateral late. The energy centroid of the direct part sits at the latency.
                const std::size_t win = std::size_t(0.001 * fs);
                double m0 = 0, m1 = 0;
                for (std::size_t i = expected - win; i <= expected + win; ++i) {
                    const double p = double(out.l[i]) * out.l[i];
                    m0 += p;
                    m1 += p * (double(i) - double(expected));
                }
                const double centroidMs = 1000.0 * (m1 / m0) / fs;
                CHECK(std::fabs(centroidMs) < 0.1, "fs=%.0f: direct-sound centroid %.3f ms from latency", fs, centroidMs);
            } else {
                std::size_t arg = 0;
                for (std::size_t i = 0; i < n; ++i)
                    if (std::fabs(out.l[i]) > std::fabs(out.l[arg])) arg = i;
                const long delta = long(arg) - long(expected);
                CHECK(std::labs(delta) <= 1, "fs=%.0f mode %d: arrival %ld samples from declared latency", fs, mode, delta);
            }
            aether_engine_destroy(e);
        }
    }
}

void testAllRatesAndModes() {
    for (double fs : kRates) {
        for (int mode = AETHER_MODE_BYPASS; mode <= AETHER_MODE_CUSTOM; ++mode) {
            aether_config c = config(mode);
            c.room_level = 1.f;
            c.room_size = AETHER_ROOM_LARGE;
            c.iem_enabled = 1;
            aether_engine *e = makeEngine(fs, c);
            const std::size_t n = std::size_t(fs * 0.3);
            const auto l = pinkNoise(n, 30, 0.5f), r = pinkNoise(n, 31, 0.5f);
            Rng rng(uint64_t(fs) + uint64_t(mode));
            const Run out = process(e, l, r, [&] { return rng.range(1, 4096); });
            bool finite = true;
            for (std::size_t i = 0; i < n; ++i) finite &= std::isfinite(out.l[i]) && std::isfinite(out.r[i]);
            aether_engine_info info;
            aether_engine_get_info(e, &info);
            CHECK(finite && rms(out.l, n / 2) > 1e-3, "fs=%.0f mode %d", fs, mode);
            CHECK(info.latency_frames > 0 && info.latency_frames < fs * 0.02, "latency %u", info.latency_frames);
            aether_engine_destroy(e);
        }
    }
}

void testConfigValidation() {
    aether_engine *e = makeEngine(48000, config(AETHER_MODE_REFERENCE));
    aether_engine_info before, after;
    aether_engine_get_info(e, &before);
    aether_config bad = config(AETHER_MODE_CUSTOM);
    bad.width = NAN;
    CHECK(aether_engine_submit_config(e, &bad) == AETHER_ERR_INVALID_CONFIG, "NaN accepted");
    bad = config(AETHER_MODE_CUSTOM);
    bad.mode = 9;
    CHECK(aether_engine_submit_config(e, &bad) == AETHER_ERR_INVALID_CONFIG, "bad mode accepted");
    bad = config(AETHER_MODE_CUSTOM);
    bad.struct_size = 12;
    CHECK(aether_engine_submit_config(e, &bad) == AETHER_ERR_INVALID_ARGUMENT, "bad struct size accepted");
    aether_engine_get_info(e, &after);
    CHECK(before.generation == after.generation, "rejected config changed generation");
    CHECK(aether_engine_prepare(e, 1.0) == AETHER_ERR_UNSUPPORTED_RATE, "bad rate accepted");
    aether_engine_destroy(e);
}

void testWidthStage() {
    const double fs = 48000;
    auto run = [&](float w, const std::vector<float> &l, const std::vector<float> &r) {
        aether_config c = config(AETHER_MODE_CUSTOM);
        c.width = w;
        aether_engine *e = makeEngine(fs, c);
        Run out = process(e, l, r, [] { return 512; });
        aether_engine_destroy(e);
        return out;
    };
    const auto mono = pinkNoise(48000, 40, 0.4f);
    const Run a = run(1.f, mono, mono), b = run(1.25f, mono, mono);
    double maxDiff = 0;
    for (std::size_t i = 0; i < mono.size(); ++i) maxDiff = std::max(maxDiff, double(std::fabs(a.l[i] - b.l[i])));
    CHECK(maxDiff < 1e-5, "width changed a mono signal by %.3g", maxDiff);
    auto anti = mono;
    for (float &v : anti) v = -v;
    const Run c = run(1.f, mono, anti), d = run(1.25f, mono, anti);
    const double gain = db(rms(d.l, 4800) / rms(c.l, 4800));
    CHECK(std::fabs(gain - db(1.25)) < 0.1, "side gain %.2f dB (expected %.2f)", gain, db(1.25));
}

void testRoomModel() {
    aether_config c = config(AETHER_MODE_REFERENCE);
    aether_reflection refl[128];
    aether_room_summary s;
    const int n = aether_describe_room(&c, refl, 128, &s);
    CHECK(n > 4, "reference room has %d reflections", n);
    bool inRange = true, interaural = false;
    for (int i = 0; i < n && i < 128; ++i) {
        inRange &= refl[i].delay_ms >= 5.f && refl[i].delay_ms <= 45.f && refl[i].gain < 0.5f;
        interaural |= std::fabs(refl[i].azimuth_deg) > 1.f;
    }
    CHECK(inRange, "reflection outside 5–45 ms or too loud");
    CHECK(interaural, "reflections should arrive from lateral directions");
    CHECK(s.direct_to_reflected_db > 3.f, "direct sound should dominate (DRR %.1f dB)", s.direct_to_reflected_db);
    std::printf("    reference room: %d reflections, %.1f–%.1f ms, DRR %+.1f dB\n", n, s.first_delay_ms,
                s.last_delay_ms, s.direct_to_reflected_db);
    c = config(AETHER_MODE_CUSTOM);
    c.room_level = 0;
    CHECK(aether_describe_room(&c, nullptr, 0, nullptr) == 0, "dry room should have no reflections");
}

void testIemDesign() {
    float eq[AETHER_EQ_POINTS];
    CHECK(aether_design_user_eq(4.f, 0.f, 0.f, eq) == AETHER_OK, "user eq");
    CHECK(std::fabs(eq[0] - 4.f) < 0.5f, "bass shelf at 20 Hz = %.2f", eq[0]);
    int i1k = 0;
    for (int i = 0; i < AETHER_EQ_POINTS; ++i)
        if (std::fabs(aether_eq_frequency(i) - 1000.f) < std::fabs(aether_eq_frequency(i1k) - 1000.f)) i1k = i;
    CHECK(std::fabs(eq[i1k]) < 0.6f, "bass shelf leaks %.2f dB at 1 kHz", eq[i1k]);

    // Synthetic measurement: +8 dB bass, +10 dB peak at 6 kHz, −25 dB narrow notch at 8.5 kHz.
    std::vector<float> mh, md;
    for (int i = 0; i < 600; ++i) {
        const double f = 20.0 * std::pow(1000.0, i / 599.0);
        double d = 8.0 / (1.0 + std::pow(f / 150.0, 2.0));
        d += 10.0 * std::exp(-std::pow(std::log2(f / 6000.0) / 0.25, 2.0));
        d -= 25.0 * std::exp(-std::pow(std::log2(f / 8500.0) / 0.03, 2.0));
        mh.push_back(float(f));
        md.push_back(float(d + 90.0));
    }
    const float th[2] = {20.f, 20000.f}, td[2] = {0.f, 0.f};
    std::vector<float> th4 = {20.f, 200.f, 2000.f, 20000.f}, td4 = {0.f, 0.f, 0.f, 0.f};
    aether_correction_report rep;
    CHECK(aether_design_correction(mh.data(), md.data(), int(mh.size()), th4.data(), td4.data(), 4, 10000.f, eq,
                                   &rep) == AETHER_OK, "correction design");
    float mx = -100, mn = 100;
    for (float v : eq) {
        mx = std::max(mx, v);
        mn = std::min(mn, v);
    }
    CHECK(mx <= 6.0f + 1e-4f && mn >= -12.0f - 1e-4f, "correction out of bounds [%.2f, %.2f]", mn, mx);
    int i6k = 0, i85 = 0, i20 = 0;
    for (int i = 0; i < AETHER_EQ_POINTS; ++i) {
        if (std::fabs(aether_eq_frequency(i) - 6000.f) < std::fabs(aether_eq_frequency(i6k) - 6000.f)) i6k = i;
        if (std::fabs(aether_eq_frequency(i) - 8500.f) < std::fabs(aether_eq_frequency(i85) - 8500.f)) i85 = i;
        if (std::fabs(aether_eq_frequency(i) - 20.f) < std::fabs(aether_eq_frequency(i20) - 20.f)) i20 = i;
    }
    CHECK(eq[i6k] < -4.f, "6 kHz peak not reduced (%.2f dB)", eq[i6k]);
    CHECK(eq[i85] < 3.f, "narrow notch inverted (%.2f dB)", eq[i85]);
    CHECK(eq[i20] < -4.f, "bass excess not reduced (%.2f dB)", eq[i20]);
    std::printf("    correction: 20 Hz %.1f dB, 6 kHz %.1f dB, 8.5 kHz notch %.1f dB, offset %.1f dB\n", eq[i20],
                eq[i6k], eq[i85], rep.level_offset_db);

    // Hostile input is rejected.
    float badHz[4] = {100.f, 50.f, 200.f, 300.f}, badDb[4] = {0, 0, 0, 0};
    CHECK(aether_design_correction(badHz, badDb, 4, th, td, 2, 10000.f, eq, nullptr) != AETHER_OK,
          "non-monotonic frequencies accepted");
}

void testDeterminism() {
    aether_config c = config(AETHER_MODE_CUSTOM);
    c.room_level = 0.5f;
    const auto l = pinkNoise(20000, 50, 0.5f), r = pinkNoise(20000, 51, 0.5f);
    aether_engine *a = makeEngine(96000, c), *b = makeEngine(96000, c);
    const Run ra = process(a, l, r, [] { return 128; }), rb = process(b, l, r, [] { return 128; });
    CHECK(ra.l == rb.l && ra.r == rb.r, "two engines with identical input diverged");
    aether_engine_destroy(a);
    aether_engine_destroy(b);
}

// Frequency response of one FIR of a designed matrix.
std::complex<double> firResponse(const std::vector<double> &h, double f, double fs) {
    std::complex<double> acc(0.0, 0.0);
    const std::complex<double> step = std::polar(1.0, -2.0 * 3.14159265358979 * f / fs);
    std::complex<double> z(1.0, 0.0);
    for (double v : h) {
        acc += v * z;
        z *= step;
    }
    return acc;
}

// ⅓-octave power of the loudness convention (ears × {correlated, uncorrelated}), in dB.
double conventionPowerDb(const aether::DesignedMatrix &m, double f, double fs) {
    double p = 0;
    int n = 0;
    for (double x = f * std::pow(2.0, -1.0 / 6.0); x <= f * std::pow(2.0, 1.0 / 6.0); x *= std::pow(2.0, 1.0 / 24.0)) {
        for (int e = 0; e < 2; ++e) {
            const auto a = firResponse(m.h[e][0], x, fs), b = firResponse(m.h[e][1], x, fs);
            p += 0.25 * (std::norm(a + b) + std::norm(a) + std::norm(b));
        }
        ++n;
    }
    return 10.0 * std::log10(p / n);
}

// Mean of conventionPowerDb over ⅓-octave centres in [lo, hi].
double bandMeanDb(const aether::DesignedMatrix &m, double lo, double hi, double fs) {
    double acc = 0;
    int n = 0;
    for (double f = lo; f <= hi * 1.001; f *= std::pow(2.0, 1.0 / 3.0)) {
        acc += conventionPowerDb(m, f, fs);
        ++n;
    }
    return acc / n;
}

// Interaural level difference of source s, ⅓-octave around f, in dB (ipsilateral first).
double ildDb(const aether::DesignedMatrix &m, int s, double f, double fs) {
    double a = 0, b = 0;
    for (double x = f * std::pow(2.0, -1.0 / 6.0); x <= f * std::pow(2.0, 1.0 / 6.0); x *= std::pow(2.0, 1.0 / 24.0)) {
        a += std::norm(firResponse(m.h[s][s], x, fs));
        b += std::norm(firResponse(m.h[1 - s][s], x, fs));
    }
    return 10.0 * std::log10(a / b);
}

void testClarity() {
    const double fs = 48000;
    const aether::EngineGeometry geo = aether::geometryFor(fs);
    aether_config c = config(AETHER_MODE_CUSTOM);
    c.headroom_db = 0;
    c.clarity = 0;
    const aether::DesignedMatrix raw = aether::designMatrix(aether::resolve(c), geo);
    c.clarity = 1;
    const aether::DesignedMatrix clear = aether::designMatrix(aether::resolve(c), geo);
    const aether::DesignedMatrix ref = aether::designMatrix(aether::resolve(config(AETHER_MODE_REFERENCE)), geo);

    const double tiltRaw = bandMeanDb(raw, 100, 400, fs) - bandMeanDb(raw, 8000, 16000, fs);
    const double tiltClear = bandMeanDb(clear, 100, 400, fs) - bandMeanDb(clear, 8000, 16000, fs);
    const double holeRaw = conventionPowerDb(raw, 6300, fs) - bandMeanDb(raw, 100, 16000, fs);
    CHECK(tiltRaw > 1.5 && holeRaw < -2.5, "uncorrected render should be dull (tilt %.2f dB, 6.3 kHz %.2f dB)",
          tiltRaw, holeRaw);
    CHECK(std::fabs(tiltClear) < 1.0, "clarity left a %.2f dB bass/treble tilt", tiltClear);

    // Clarity 1 (and the Reference preset): every ⅓-octave band 100 Hz – 16 kHz within
    // ±1.5 dB of the mean, i.e. the tonal balance of bypass.
    for (const aether::DesignedMatrix *m : {&clear, &ref}) {
        const double mean = bandMeanDb(*m, 100, 16000, fs);
        double worst = 0, worstF = 0;
        for (double f = 100; f <= 16001; f *= std::pow(2.0, 1.0 / 3.0)) {
            const double d = conventionPowerDb(*m, f, fs) - mean;
            if (std::fabs(d) > std::fabs(worst)) worst = d, worstF = f;
        }
        CHECK(std::fabs(worst) <= 1.5, "band at %.0f Hz is %+.2f dB from flat", worstF, worst);
        if (m == &ref) std::printf("    reference: worst ⅓-octave band %+.2f dB at %.0f Hz\n", worst, worstF);
    }
    std::printf("    bass/treble tilt: %.2f dB uncorrected → %.2f dB with clarity\n", tiltRaw, tiltClear);

    // The correction is common to both ears, so interaural level differences are kept.
    double worstIld = 0;
    auto ildAt = [&](const aether::DesignedMatrix &m, int s, double f) {
        return 20.0 * std::log10(std::abs(firResponse(m.h[s][s], f, fs)) / std::abs(firResponse(m.h[1 - s][s], f, fs)));
    };
    for (double f : {300.0, 1000.0, 3000.0, 6000.0, 10000.0})
        for (int s = 0; s < 2; ++s) worstIld = std::max(worstIld, std::fabs(ildAt(clear, s, f) - ildAt(raw, s, f)));
    CHECK(worstIld < 0.1, "clarity changed an ILD by %.3f dB", worstIld);
    std::printf("    uncorrected 6.3 kHz band %.1f dB · largest ILD change %.3f dB\n", holeRaw, worstIld);
}

void testFreeSpeakerPlacement() {
    const double fs = 48000;
    const aether::EngineGeometry geo = aether::geometryFor(fs);
    auto design = [&](float left, float right, float room = 0.f, float clarity = 1.f) {
        aether_config c = config(AETHER_MODE_CUSTOM);
        c.speaker_left_deg = left;
        c.speaker_right_deg = right;
        c.room_level = room;
        c.clarity = clarity;
        return aether::designMatrix(aether::resolve(c), geo);
    };

    // Angles wrap: 390° ≡ 30°, −30° ≡ 330°.
    const auto a = design(390, 30), b = design(30, 30), c1 = design(-30, 30), c2 = design(330, 30);
    CHECK(a.h[0][0] == b.h[0][0] && a.h[1][0] == b.h[1][0], "390° should equal 30°");
    CHECK(c1.h[0][0] == c2.h[0][0] && c1.h[1][0] == c2.h[1][0], "−30° should equal 330°");

    // Independent sides: a wider left speaker gives the left channel larger interaural cues.
    const auto asym = design(60, 20);
    const double ildL = ildDb(asym, 0, 4000, fs), ildR = ildDb(asym, 1, 4000, fs);
    CHECK(ildL > ildR + 2.0, "left at 60° should be more lateral than right at 20° (ILD %.1f vs %.1f dB)", ildL, ildR);

    // Full circle: left speaker at 270° sits beside the right ear.
    const auto swapped = design(270, 30);
    CHECK(ildDb(swapped, 0, 4000, fs) < -6.0, "left speaker at 270° should favour the right ear (ILD %.1f dB)",
          ildDb(swapped, 0, 4000, fs));

    // Engine path: ITD sign follows the side the speaker is on.
    for (float left : {60.f, 270.f}) {
        aether_config cfg = config(AETHER_MODE_CUSTOM);
        cfg.speaker_left_deg = left;
        cfg.room_level = 0;
        aether_engine *e = makeEngine(fs, cfg);
        const auto l = pinkNoise(48000, 21, 0.5f);
        const std::vector<float> silent(l.size(), 0.f);
        const Run out = process(e, l, silent, [] { return 256; });
        const int lag = bestLag(out.l, out.r, 48, 4800);
        if (left < 180) CHECK(lag > 0, "left at %.0f°: right ear should lag (lag %d)", left, lag);
        else CHECK(lag < 0, "left at %.0f°: left ear should lag (lag %d)", left, lag);
        aether_engine_destroy(e);
    }

    // Rear placement keeps a darker timbre than the mirrored front placement, at full clarity.
    const auto front = design(30, 30), rear = design(150, 150);
    const double tiltFront = bandMeanDb(front, 200, 1000, fs) - bandMeanDb(front, 8000, 16000, fs);
    const double tiltRear = bandMeanDb(rear, 200, 1000, fs) - bandMeanDb(rear, 8000, 16000, fs);
    CHECK(tiltRear > tiltFront + 2.0, "rear speakers should be darker than front (%.2f vs %.2f dB)", tiltRear,
          tiltFront);
    std::printf("    L60°/R20° ILD at 4 kHz: %.1f / %.1f dB · rear vs front treble: −%.1f dB\n", ildL, ildR,
                tiltRear - tiltFront);
}

void testSpeakerDisable() {
    const double fs = 48000;
    const aether::EngineGeometry geo = aether::geometryFor(fs);
    aether_config c = config(AETHER_MODE_CUSTOM);
    c.room_level = 0.5f;

    // Both off is rejected; the previous configuration stays.
    c.speaker_enabled[0] = c.speaker_enabled[1] = 0;
    CHECK(aether_config_validate(&c) == AETHER_ERR_INVALID_CONFIG, "both speakers off must be rejected");

    // Left off, no fold: the left channel is not heard at all; the right still is.
    c.speaker_enabled[0] = 0;
    c.speaker_enabled[1] = 1;
    {
        aether_engine *e = makeEngine(fs, c);
        const auto x = pinkNoise(48000, 31, 0.5f);
        const std::vector<float> silent(x.size(), 0.f);
        const Run leftOnly = process(e, x, silent, [] { return 512; });
        const Run rightOnly = process(e, silent, x, [] { return 512; });
        const double leak = std::max(rms(leftOnly.l, 4800), rms(leftOnly.r, 4800));
        CHECK(leak == 0.0, "left channel leaked with its speaker off (rms %.3g)", leak);
        CHECK(rms(rightOnly.r, 4800) > 0.01 && rms(rightOnly.r, 4800) > rms(rightOnly.l, 4800),
              "right speaker should still play, louder at the right ear");
        aether_engine_destroy(e);
    }

    // Reflections of a switched-off speaker are not rendered.
    aether_config both = config(AETHER_MODE_CUSTOM);
    both.room_level = 0.5f;
    const int nBoth = aether_describe_room(&both, nullptr, 0, nullptr);
    const int nOne = aether_describe_room(&c, nullptr, 0, nullptr);
    aether_reflection refl[128];
    const int nr = aether_describe_room(&c, refl, 128, nullptr);
    bool onlyRight = true;
    for (int i = 0; i < nr && i < 128; ++i) onlyRight &= refl[i].speaker == 1;
    CHECK(nOne > 0 && nOne < nBoth && onlyRight, "reflections: %d with one speaker vs %d with two", nOne, nBoth);

    // Fold: both channels reach the remaining speaker identically (−3 dB each).
    c.fold_disabled = 1;
    const aether::DesignedMatrix m = aether::designMatrix(aether::resolve(c), geo);
    CHECK(m.h[0][0] == m.h[0][1] && m.h[1][0] == m.h[1][1], "fold should feed both channels to the right speaker");
    const double ild = 20.0 * std::log10(std::abs(firResponse(m.h[1][0], 4000, fs)) /
                                         std::abs(firResponse(m.h[0][0], 4000, fs)));
    CHECK(ild > 4.0, "folded left channel should come from the right speaker (ILD %.1f dB)", ild);
    std::printf("    one speaker: %d of %d reflections · folded left channel ILD %.1f dB toward the right\n", nOne,
                nBoth, ild);
}

} // namespace

int main() {
    struct T {
        const char *name;
        void (*fn)();
    };
    const T tests[] = {
        {"DSP bypass is exact after declared latency (all rates)", testBypassExact},
        {"Output independent of host buffer chunking", testChunkInvariance},
        {"Partitioned convolution matches float64 direct convolution", testAgainstOfflineReference},
        {"Deterministic output", testDeterminism},
        {"Non-finite input sanitised and counted", testNonFiniteInput},
        {"Non-finite internal result latches safety bypass", testSafetyBypass},
        {"Centre mono stays centred", testCentreMonoStaysCentred},
        {"Hard-panned input not swapped; ILD/ITD present", testHardPanNotSwapped},
        {"Mode transitions are click-free", testClickFreeTransitions},
        {"Processing modes are level-matched", testLevelMatchedModes},
        {"Default headroom keeps corpus ≤ −1 dBTP", testHeadroomCorpus},
        {"True-peak meter reads inter-sample peaks", testTruePeakMeter},
        {"All modes aligned to declared latency (all rates)", testLatencyAlignment},
        {"All rates × modes run finite", testAllRatesAndModes},
        {"Invalid configuration rejected, previous kept", testConfigValidation},
        {"Width stage: mid untouched, side scaled", testWidthStage},
        {"Room model: bounded, lateral, direct-dominant", testRoomModel},
        {"IEM correction design bounded and regularised", testIemDesign},
        {"Clarity restores bypass timbre, keeps interaural cues", testClarity},
        {"Speakers placed independently anywhere on the circle", testFreeSpeakerPlacement},
        {"A speaker can be switched off, with optional fold-in", testSpeakerDisable},
    };
    std::printf("%s\n", aether_version_string());
    for (const T &t : tests) {
        const int before = g_failures;
        std::printf("• %s\n", t.name);
        t.fn();
        std::printf("  %s\n", g_failures == before ? "ok" : "FAILED");
    }
    std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
