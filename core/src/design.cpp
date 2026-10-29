// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
#include "design.hpp"
#include "fft.hpp"

#include <algorithm>
#include <cmath>

namespace aether {
namespace {

using cplx = std::complex<double>;

constexpr double kPi = 3.14159265358979323846;
constexpr double kTwoPi = 2.0 * kPi;

// Spherical-head constants (Brown & Duda 1998, "A structural model for binaural sound synthesis").
constexpr double kHeadRadius = 0.0875;   // m
constexpr double kSpeedOfSound = 343.0;  // m/s
constexpr double kEarAzimuthDeg = 100.0; // ears slightly behind the interaural axis
constexpr double kAlphaMin = 0.1;
constexpr double kThetaMin = 150.0 * kPi / 180.0;

// Pinna echo model (Brown & Duda, table 1), delays in samples at 44.1 kHz.
// kPinnaDepth tempers the comb structure; a tuned starting value, not a validated optimum.
constexpr double kPinnaDepth = 0.35;
constexpr double kPinnaRho[5] = {0.5, -1.0, 0.5, -0.25, 0.25};
constexpr double kPinnaA[5] = {1, 5, 5, 5, 5};
constexpr double kPinnaB[5] = {2, 4, 7, 11, 13};
constexpr double kPinnaD[5] = {1, 0.5, 0.5, 0.5, 0.5};

// Rear pinna shadow: a first-order high shelf, 0 dB for frontal sources falling to
// −kRearShelfDb above ~2·kRearShelfHz for a source directly behind. It is the model's
// front/back cue (the pinna-echo delays alone are front/back symmetric).
constexpr double kRearShelfDb = 6.0;
constexpr double kRearShelfHz = 2500.0;

// Clarity: ⅙-octave power-domain smoothing and compensation range.
constexpr double kClaritySmoothOct = 1.0 / 6.0;
constexpr double kClarityMaxBoostDb = 10.0;
constexpr double kClarityMaxCutDb = -12.0;

// Room model limits.
constexpr double kReflectionFreeZone = 0.005; // s: earlier reflections are treated as absorbed
constexpr double kMaxReflectionDelay = 0.045; // s

constexpr double kMaxBoostDb = 6.0;
constexpr double kMaxCutDb = -12.0;

double clampd(double v, double lo, double hi) { return std::min(hi, std::max(lo, v)); }
double dbToLin(double db) { return std::pow(10.0, db / 20.0); }
double deg2rad(double d) { return d * kPi / 180.0; }

struct Vec3 {
    double x, y, z;
};

// x right, y front, z up; azimuth clockwise from the front (right positive).
Vec3 direction(double azDeg, double elDeg) {
    const double az = deg2rad(azDeg), el = deg2rad(elDeg);
    return {std::sin(az) * std::cos(el), std::cos(az) * std::cos(el), std::sin(el)};
}

double wrapDeg(double d) {
    double a = std::fmod(d, 360.0);
    if (a < 0) a += 360.0;
    return a;
}

double foldToFront(double azDeg) {
    double a = std::fmod(azDeg + 540.0, 360.0) - 180.0; // (−180, 180]
    if (a > 90.0) a = 180.0 - a;
    if (a < -90.0) a = -180.0 - a;
    return a;
}

struct EarModel {
    double alpha;    // head-shadow zero coefficient
    double itd;      // seconds, relative to head centre (may be negative)
    double pinna[5]; // echo delays, seconds
};

EarModel earModel(double azDeg, double elDeg, int ear) {
    const Vec3 d = direction(azDeg, elDeg);
    const Vec3 a = direction(ear == 0 ? -kEarAzimuthDeg : kEarAzimuthDeg, 0.0);
    const double cosT = clampd(d.x * a.x + d.y * a.y + d.z * a.z, -1.0, 1.0);
    const double theta = std::acos(cosT);
    EarModel m{};
    m.alpha = (1.0 + kAlphaMin / 2.0) + (1.0 - kAlphaMin / 2.0) * std::cos(theta / kThetaMin * kPi);
    const double ac = kHeadRadius / kSpeedOfSound;
    m.itd = theta < kPi / 2 ? -ac * std::cos(theta) : ac * (theta - kPi / 2);
    const double azf = deg2rad(foldToFront(azDeg));
    for (int k = 0; k < 5; ++k) {
        const double samples = kPinnaA[k] * std::cos(azf / 2.0) *
                                   std::sin(deg2rad(kPinnaD[k] * (90.0 - elDeg))) +
                               kPinnaB[k];
        m.pinna[k] = samples / 44100.0;
    }
    return m;
}

cplx headShadow(double hz, double alpha) {
    const double w0 = kSpeedOfSound / kHeadRadius;
    const double x = kTwoPi * hz / (2.0 * w0);
    const double den = 1.0 + x * x;
    return {(1.0 + alpha * x * x) / den, (alpha - 1.0) * x / den};
}

// High-frequency gain of the rear shelf for a direction (1 = frontal hemisphere).
double rearShelfGain(double azDeg, double elDeg) {
    const double rear = clampd(-direction(azDeg, elDeg).y, 0.0, 1.0);
    return dbToLin(-kRearShelfDb * rear);
}

cplx rearShelf(double hz, double gain) {
    if (gain >= 1.0) return {1.0, 0.0};
    const cplx s(0.0, hz / kRearShelfHz);
    return (1.0 + gain * s) / (1.0 + s);
}

// ---- Diffuse-field equalisation of the structural model --------------------
// Average power over directions (cos-elevation weighted), 1/3-octave smoothed,
// limited to ±10 dB. Applied identically to every direction, so interaural and
// direction-dependent cues are preserved while the model's average colouration
// is removed.
struct DiffuseField {
    std::vector<double> logHz, gainDb;
    DiffuseField() {
        const int n = 220;
        const double lo = std::log(20.0), hi = std::log(96000.0);
        std::vector<double> rawDb(n);
        logHz.resize(n);
        for (int i = 0; i < n; ++i) {
            logHz[i] = lo + (hi - lo) * i / (n - 1);
            const double hz = std::exp(logHz[i]);
            double sum = 0, wsum = 0;
            for (int el = -30; el <= 60; el += 30) {
                const double w = std::cos(deg2rad(el));
                for (int az = -180; az < 180; az += 5) {
                    const EarModel m = earModel(az, el, 0);
                    cplx p(1.0, 0.0);
                    for (int k = 0; k < 5; ++k)
                        p += kPinnaDepth * kPinnaRho[k] * std::polar(1.0, -kTwoPi * hz * m.pinna[k]);
                    sum += w * std::norm(headShadow(hz, m.alpha) * p * rearShelf(hz, rearShelfGain(az, el)));
                    wsum += w;
                }
            }
            rawDb[i] = -10.0 * std::log10(sum / wsum);
        }
        gainDb.resize(n);
        const double half = std::log(2.0) / 6.0; // ±1/6 octave → 1/3-octave window
        for (int i = 0; i < n; ++i) {
            double acc = 0;
            int cnt = 0;
            for (int j = 0; j < n; ++j)
                if (std::fabs(logHz[j] - logHz[i]) <= half) {
                    acc += rawDb[j];
                    ++cnt;
                }
            gainDb[i] = clampd(acc / cnt, -10.0, 10.0);
        }
        // Above 20 kHz, hold the 20 kHz value: the model is not meaningful there.
        const double l20k = std::log(20000.0);
        double hold = 0;
        for (int i = 0; i < n; ++i)
            if (logHz[i] <= l20k) hold = gainDb[i];
        for (int i = 0; i < n; ++i)
            if (logHz[i] > l20k) gainDb[i] = hold;
    }
    double at(double hz) const {
        const double l = std::log(std::max(hz, 20.0));
        if (l <= logHz.front()) return gainDb.front();
        if (l >= logHz.back()) return gainDb.back();
        const auto it = std::upper_bound(logHz.begin(), logHz.end(), l);
        const std::size_t j = std::size_t(it - logHz.begin());
        const double t = (l - logHz[j - 1]) / (logHz[j] - logHz[j - 1]);
        return gainDb[j - 1] + t * (gainDb[j] - gainDb[j - 1]);
    }
};

const DiffuseField &diffuseField() {
    static const DiffuseField df;
    return df;
}

// Minimum-phase spectrum (bins 0…N/2) from a magnitude response, via the folded real cepstrum.
std::vector<cplx> minimumPhase(const std::vector<double> &mag, FFT<double> &fft) {
    const std::size_t n = fft.size(), K = n / 2 + 1;
    std::vector<double> re(n), im(n, 0.0);
    for (std::size_t k = 0; k < K; ++k) re[k] = std::log(std::max(mag[k], 1e-9));
    for (std::size_t k = K; k < n; ++k) re[k] = re[n - k];
    fft.inverse(re.data(), im.data());
    for (std::size_t i = 0; i < n; ++i) {
        re[i] /= double(n);
        im[i] = 0.0;
    }
    for (std::size_t i = 1; i < n / 2; ++i) re[i] *= 2.0;
    for (std::size_t i = n / 2 + 1; i < n; ++i) re[i] = 0.0;
    fft.forward(re.data(), im.data());
    std::vector<cplx> out(K);
    for (std::size_t k = 0; k < K; ++k) out[k] = std::exp(cplx(re[k], im[k]));
    return out;
}

// Rotating phasor e^{−j2π·k·df·τ}, resynchronised periodically to bound drift.
struct Phasor {
    cplx cur{1.0, 0.0}, step{1.0, 0.0};
    double tau = 0, df = 0;
    void init(double tauSeconds, double binHz) {
        tau = tauSeconds;
        df = binHz;
        cur = {1.0, 0.0};
        step = std::polar(1.0, -kTwoPi * df * tau);
    }
    void advance(std::size_t nextK) {
        if ((nextK & 511u) == 0) cur = std::polar(1.0, -kTwoPi * df * tau * double(nextK));
        else cur *= step;
    }
};

// Power response of the ITU-R BS.1770 K-weighting (48 kHz reference coefficients:
// high-shelf pre-filter followed by the RLB high-pass). Above 23.9 kHz the value is held.
double kWeightPower(double hz) {
    const double f = std::min(hz, 23900.0);
    const cplx z1 = std::polar(1.0, -kTwoPi * f / 48000.0), z2 = z1 * z1;
    const cplx shelf = (1.53512485958697 - 2.69169618940638 * z1 + 1.19839281085285 * z2) /
                       (1.0 - 1.69065929318241 * z1 + 0.73248077421585 * z2);
    const cplx rlb = (1.0 - 2.0 * z1 + z2) / (1.0 - 1.99004745483398 * z1 + 0.99007225036621 * z2);
    return std::norm(shelf * rlb);
}

double interpLogTable(const double *db, double hz) {
    const double lo = std::log(20.0), hi = std::log(20000.0);
    const double l = std::log(std::max(hz, 1e-3));
    if (l <= lo) return db[0];
    if (l >= hi) return db[AETHER_EQ_POINTS - 1];
    const double pos = (l - lo) / (hi - lo) * (AETHER_EQ_POINTS - 1);
    const int i = int(pos);
    const double t = pos - i;
    return db[i] + t * (db[std::min(i + 1, AETHER_EQ_POINTS - 1)] - db[i]);
}

} // namespace

// ---------------------------------------------------------------------------

EngineGeometry geometryFor(double fs) {
    EngineGeometry g;
    g.fs = fs;
    const int octave = int(std::lround(std::log2(fs / 48000.0)));
    int b = octave >= 0 ? (256 << std::min(octave, 3)) : (256 >> std::min(-octave, 2));
    g.block = std::clamp(b, 64, 2048);
    g.bulkDelay = int(std::lround(0.002 * fs));
    const int need = int(std::ceil(0.125 * fs));
    g.maxTaps = ((need + g.block - 1) / g.block) * g.block;
    return g;
}

double eqFrequency(int index) {
    const int i = std::clamp(index, 0, AETHER_EQ_POINTS - 1);
    return 20.0 * std::pow(1000.0, double(i) / double(AETHER_EQ_POINTS - 1));
}

ResolvedConfig resolve(const aether_config &c) {
    ResolvedConfig r;
    r.mode = std::clamp<int>(c.mode, AETHER_MODE_BYPASS, AETHER_MODE_CUSTOM);
    r.headroomDb = clampd(c.headroom_db, -18.0, 0.0);
    r.levelMatchBypass = c.level_match_bypass != 0;
    r.xfLevelDb = clampd(c.crossfeed_level_db, -15.0, -3.0);
    r.xfCutoffHz = clampd(c.crossfeed_cutoff_hz, 500.0, 2000.0);
    r.xfDelayMs = clampd(c.crossfeed_delay_ms, 0.1, 0.6);
    r.iemEnabled = c.iem_enabled != 0;
    for (int e = 0; e < 2; ++e)
        for (int i = 0; i < AETHER_EQ_POINTS; ++i)
            r.iemDb[e][i] = clampd(c.iem_db[e][i], kMaxCutDb, kMaxBoostDb);
    if (r.mode == AETHER_MODE_CUSTOM) {
        r.leftDeg = std::isfinite(c.speaker_left_deg) ? wrapDeg(c.speaker_left_deg) : 30.0;
        r.rightDeg = std::isfinite(c.speaker_right_deg) ? wrapDeg(c.speaker_right_deg) : 30.0;
        r.roomLevel = clampd(c.room_level, 0.0, 1.0);
        r.roomSize = std::clamp<int>(c.room_size, AETHER_ROOM_SMALL, AETHER_ROOM_LARGE);
        r.width = clampd(c.width, 0.75, 1.25);
        r.clarity = clampd(c.clarity, 0.0, 1.0);
        r.enabled[0] = c.speaker_enabled[0] != 0;
        r.enabled[1] = c.speaker_enabled[1] != 0;
        if (!r.enabled[0] && !r.enabled[1]) r.enabled[0] = r.enabled[1] = true;
        r.fold = c.fold_disabled != 0;
    } else {
        // Reference preset; also the neutral values for crossfeed/bypass.
        r.leftDeg = r.rightDeg = 30.0;
        r.clarity = 1.0;
        r.roomLevel = r.mode == AETHER_MODE_REFERENCE ? 0.3 : 0.0;
        r.roomSize = AETHER_ROOM_MEDIUM;
        r.width = 1.0;
    }
    return r;
}

RoomGeometry roomGeometry(int roomSize) {
    switch (roomSize) {
    case AETHER_ROOM_SMALL: return {4.0, 5.0, 2.6, 1.4, 2.0, 1.2};
    case AETHER_ROOM_LARGE: return {8.0, 10.0, 3.6, 2.8, 4.0, 1.2};
    default: return {5.5, 7.0, 3.0, 2.0, 2.8, 1.2};
    }
}

std::vector<Reflection> computeReflections(const ResolvedConfig &rc) {
    std::vector<Reflection> out;
    if (rc.roomLevel <= 0.0 ||
        (rc.mode != AETHER_MODE_REFERENCE && rc.mode != AETHER_MODE_CUSTOM))
        return out;
    const RoomGeometry g = roomGeometry(rc.roomSize);
    const Vec3 L{g.width / 2.0, g.listenerY, g.earHeight};
    const double dims[3] = {g.width, g.depth, g.height};
    // Walls per axis: [low, high]. Pressure reflection factors and HF damping corners.
    const double refl[3][2] = {{0.75, 0.75}, {0.75, 0.70}, {0.55, 0.65}};
    const double damp[3][2] = {{6000, 6000}, {6000, 6000}, {3000, 5000}};

    for (int s = 0; s < 2; ++s) {
        if (!rc.enabled[s]) continue;
        const double az = rc.speakerAzimuth(s);
        const Vec3 dir = direction(az, 0.0);
        const double S[3] = {L.x + g.speakerDistance * dir.x, L.y + g.speakerDistance * dir.y,
                             L.z + g.speakerDistance * dir.z};
        for (int nx = -2; nx <= 2; ++nx)
            for (int ny = -2; ny <= 2; ++ny)
                for (int nz = -2; nz <= 2; ++nz) {
                    const int n[3] = {nx, ny, nz};
                    const int order = std::abs(nx) + std::abs(ny) + std::abs(nz);
                    if (order < 1 || order > 2) continue;
                    double img[3], gain = 1.0;
                    Reflection r;
                    int bounce = 0;
                    for (int a = 0; a < 3; ++a) {
                        const int k = n[a];
                        img[a] = (k % 2 == 0) ? k * dims[a] + S[a] : k * dims[a] + (dims[a] - S[a]);
                        if (k == -1) { gain *= refl[a][0]; r.dampHz[bounce++] = damp[a][0]; }
                        if (k == 1) { gain *= refl[a][1]; r.dampHz[bounce++] = damp[a][1]; }
                        if (std::abs(k) == 2) {
                            gain *= refl[a][0] * refl[a][1];
                            r.dampHz[bounce++] = damp[a][0];
                            r.dampHz[bounce++] = damp[a][1];
                        }
                    }
                    const double vx = img[0] - L.x, vy = img[1] - L.y, vz = img[2] - L.z;
                    const double dist = std::sqrt(vx * vx + vy * vy + vz * vz);
                    const double delay = (dist - g.speakerDistance) / kSpeedOfSound;
                    if (delay < kReflectionFreeZone || delay > kMaxReflectionDelay) continue;
                    r.speaker = s;
                    r.order = order;
                    r.azDeg = std::atan2(vx, vy) * 180.0 / kPi;
                    r.elDeg = std::atan2(vz, std::sqrt(vx * vx + vy * vy)) * 180.0 / kPi;
                    r.delay = delay;
                    r.distance = dist;
                    r.gain = gain * (g.speakerDistance / dist) * rc.roomLevel;
                    out.push_back(r);
                }
    }
    std::sort(out.begin(), out.end(),
              [](const Reflection &a, const Reflection &b) { return a.delay < b.delay; });
    return out;
}

std::complex<double> modelHrtf(double hz, double azDeg, double elDeg, int ear) {
    const EarModel m = earModel(azDeg, elDeg, ear);
    cplx p(1.0, 0.0);
    for (int k = 0; k < 5; ++k)
        p += kPinnaDepth * kPinnaRho[k] * std::polar(1.0, -kTwoPi * hz * m.pinna[k]);
    return headShadow(hz, m.alpha) * p * rearShelf(hz, rearShelfGain(azDeg, elDeg)) *
           std::polar(1.0, -kTwoPi * hz * m.itd);
}

double diffuseFieldGainDb(double hz) { return diffuseField().at(hz); }

namespace {

// Direct sound and early reflections of both virtual speakers through the structural
// HRTF, bulk delay t0 included, accumulated into H[ear][speaker] (bins 0…N/2).
// Returns the latest reflection delay in seconds.
double renderSpeakers(const ResolvedConfig &rc, double t0, double df, std::vector<cplx> (&H)[2][2]) {
    const std::size_t K = H[0][0].size();
    struct Source {
        int speaker;
        double az, el, delay, gain, damp[2];
    };
    std::vector<Source> sources;
    for (int s = 0; s < 2; ++s)
        if (rc.enabled[s]) sources.push_back({s, rc.speakerAzimuth(s), 0.0, 0.0, 1.0, {0, 0}});
    double maxDelay = 0;
    for (const Reflection &r : computeReflections(rc)) {
        sources.push_back({r.speaker, r.azDeg, r.elDeg, r.delay, r.gain, {r.dampHz[0], r.dampHz[1]}});
        maxDelay = std::max(maxDelay, r.delay);
    }

    for (const Source &src : sources) {
        const double rearGain = rearShelfGain(src.az, src.el);
        for (int e = 0; e < 2; ++e) {
            const EarModel em = earModel(src.az, src.el, e);
            Phasor main, echo[5];
            main.init(t0 + src.delay + em.itd, df);
            for (int k = 0; k < 5; ++k) echo[k].init(em.pinna[k], df);
            std::vector<cplx> &dst = H[e][src.speaker];
            for (std::size_t k = 0; k < K; ++k) {
                const double f = double(k) * df;
                cplx p(1.0, 0.0);
                for (int q = 0; q < 5; ++q) p += (kPinnaDepth * kPinnaRho[q]) * echo[q].cur;
                double damping = 1.0;
                for (double c : src.damp)
                    if (c > 0) damping /= std::sqrt(1.0 + (f / c) * (f / c));
                dst[k] += (src.gain * damping) * headShadow(f, em.alpha) * p * rearShelf(f, rearGain) * main.cur;
                main.advance(k + 1);
                for (auto &ph : echo) ph.advance(k + 1);
            }
        }
    }
    return maxDelay;
}

// Clarity: one magnitude correction, identical for both ears, that returns the rendered
// power response — averaged over ears and over correlated and uncorrelated input, as in
// the loudness convention — to the flat response of bypass after ⅙-octave smoothing.
// Interaural level and time differences are untouched because both ears get the same
// filter. The rear shelf of the enabled speakers is kept in the target, so speakers placed
// behind stay darker than in front (the front/back cue) while every other colouration
// from the separation, pinna model and room is removed. amount ∈ [0, 1] scales the
// correction in dB.
std::vector<double> clarityCorrection(const std::vector<cplx> (&H)[2][2], const ResolvedConfig &rc,
                                      double df, double fs, double amount) {
    const std::size_t K = H[0][0].size();
    std::vector<double> cum(K + 1, 0.0);
    for (std::size_t k = 0; k < K; ++k) {
        double p = 0;
        for (int e = 0; e < 2; ++e)
            p += 0.25 * (std::norm(H[e][0][k] + H[e][1][k]) + std::norm(H[e][0][k]) + std::norm(H[e][1][k]));
        cum[k + 1] = cum[k] + p;
    }
    const double rearGain[2] = {rearShelfGain(rc.speakerAzimuth(0), 0.0), rearShelfGain(rc.speakerAzimuth(1), 0.0)};
    const int active = int(rc.enabled[0]) + int(rc.enabled[1]);
    const double half = std::pow(2.0, kClaritySmoothOct / 2.0);
    auto correctionDb = [&](double f) {
        const std::size_t lo = std::max<std::size_t>(1, std::size_t(std::ceil(f / half / df)));
        const std::size_t hi = std::max(lo, std::min(K - 1, std::size_t(std::floor(f * half / df))));
        const double p = (cum[hi + 1] - cum[lo]) / double(hi - lo + 1);
        double target = 0;
        for (int s = 0; s < 2; ++s)
            if (rc.enabled[s]) target += std::norm(rearShelf(f, rearGain[s])) / active;
        return amount * clampd(10.0 * std::log10(target / std::max(p, 1e-12)), kClarityMaxCutDb, kClarityMaxBoostDb);
    };
    const double fLo = 20.0, fHi = std::min(20000.0, 0.45 * fs);
    const double dbLo = correctionDb(fLo), dbHi = correctionDb(fHi);
    std::vector<double> mag(K);
    for (std::size_t k = 0; k < K; ++k) {
        const double f = double(k) * df;
        mag[k] = dbToLin(f <= fLo ? dbLo : f >= fHi ? dbHi : correctionDb(f));
    }
    return mag;
}

} // namespace

DesignedMatrix designMatrix(const ResolvedConfig &rc, const EngineGeometry &geo) {
    DesignedMatrix m;
    m.mode = rc.mode;
    const double headroom = dbToLin(rc.headroomDb);
    if (rc.mode == AETHER_MODE_BYPASS) {
        m.identity = true;
        m.gain = rc.levelMatchBypass ? headroom : 1.0;
        m.taps = 1;
        return m;
    }

    const double fs = geo.fs;
    const double rs = fs / 48000.0;
    const std::size_t N = nextPow2(std::size_t(2 * geo.maxTaps));
    const std::size_t K = N / 2 + 1;
    const double df = fs / double(N);
    FFT<double> fft;
    fft.init(N);

    std::vector<cplx> H[2][2];
    for (auto &row : H)
        for (auto &v : row) v.assign(K, cplx(0.0, 0.0));

    const double t0 = double(geo.bulkDelay) / fs;
    int tapsNeeded = 0;

    if (rc.mode == AETHER_MODE_CROSSFEED) {
        // Shelving crossfeed: D = (1+g) − g·LP, C = g·LP·z^(−d). Centre-mono sum is
        // flat (D + C ≈ 1 + g) while hard-panned material gains low-passed cross-ear energy.
        const double g = dbToLin(rc.xfLevelDb);
        const double d = rc.xfDelayMs / 1000.0;
        for (std::size_t k = 0; k < K; ++k) {
            const double f = double(k) * df;
            const cplx lp = 1.0 / cplx(1.0, f / rc.xfCutoffHz);
            const cplx direct = (cplx(1.0 + g, 0.0) - g * lp) * std::polar(1.0, -kTwoPi * f * t0);
            const cplx cross = g * lp * std::polar(1.0, -kTwoPi * f * (t0 + d));
            H[0][0][k] = H[1][1][k] = direct;
            H[0][1][k] = H[1][0][k] = cross;
        }
        tapsNeeded = geo.bulkDelay + int(std::ceil(d * fs)) + int(std::lround(256 * rs));
    } else {
        const double maxDelay = renderSpeakers(rc, t0, df, H);
        // Diffuse-field EQ (minimum phase).
        std::vector<double> dfMag(K);
        for (std::size_t k = 0; k < K; ++k) dfMag[k] = dbToLin(diffuseFieldGainDb(double(k) * df));
        const std::vector<cplx> dfmp = minimumPhase(dfMag, fft);
        for (std::size_t k = 0; k < K; ++k)
            for (auto &row : H)
                for (auto &v : row) v[k] *= dfmp[k];
        tapsNeeded = geo.bulkDelay + int(std::ceil(maxDelay * fs)) + int(std::lround(384 * rs));

        // One speaker off: its channel is silent, or with fold both channels feed the
        // remaining speaker at −3 dB each (mono fold-down). H is indexed [ear][channel]
        // from here on.
        if (rc.fold && rc.enabled[0] != rc.enabled[1]) {
            const int on = rc.enabled[0] ? 0 : 1;
            const double k = std::sqrt(0.5);
            for (int e = 0; e < 2; ++e)
                for (std::size_t q = 0; q < K; ++q) {
                    H[e][on][q] *= k;
                    H[e][1 - on][q] = H[e][on][q];
                }
        }

        std::vector<cplx> comp(K, cplx(1.0, 0.0));
        if (rc.clarity > 0.0) {
            comp = minimumPhase(clarityCorrection(H, rc, df, fs, rc.clarity), fft);
            tapsNeeded += int(std::lround(1024 * rs));
        }

        // A raised-cosine taper to zero at Nyquist from 0.45·fs bounds the
        // fractional-delay sinc tails.
        const double taperStart = 0.45 * fs, nyq = 0.5 * fs;
        for (std::size_t k = 0; k < K; ++k) {
            const double f = double(k) * df;
            double taper = 1.0;
            if (f >= taperStart) taper = 0.5 + 0.5 * std::cos(kPi * (f - taperStart) / (nyq - taperStart));
            const cplx w = comp[k] * taper;
            for (auto &row : H)
                for (auto &v : row) v[k] *= w;
        }
    }

    // Loudness reference convention (documented in docs/dsp-math.md): for a pink-spectrum
    // input, the K-weighted (ITU-R BS.1770 pre-filter + RLB) output power over 20 Hz – 20 kHz,
    // averaged over both ears and over two input conditions — fully correlated (centre mono:
    // |H_eL + H_eR|²) and uncorrelated stereo (|H_eL|² + |H_eR|²) — equals that of DSP bypass.
    double num = 0, den = 0;
    for (std::size_t k = 1; k < K; ++k) {
        const double f = double(k) * df;
        if (f < 20.0 || f > 20000.0) continue;
        const double w = kWeightPower(f) / f;
        for (int e = 0; e < 2; ++e) {
            const double corr = std::norm(H[e][0][k] + H[e][1][k]);
            const double unc = std::norm(H[e][0][k]) + std::norm(H[e][1][k]);
            num += w * 0.5 * (corr + unc);
            den += w; // bypass: each ear receives its own channel at unity gain
        }
    }
    const double norm = den > 0 && num > 0 ? std::sqrt(den / num) : 1.0;

    // Width (mid/side): x'L = a·xL + b·xR, x'R = b·xL + a·xR, a = (1+w)/2, b = (1−w)/2.
    const double wa = (1.0 + rc.width) / 2.0, wb = (1.0 - rc.width) / 2.0;

    std::vector<cplx> eq[2];
    if (rc.iemEnabled) {
        for (int e = 0; e < 2; ++e) {
            std::vector<double> mag(K);
            for (std::size_t k = 0; k < K; ++k)
                mag[k] = dbToLin(clampd(interpLogTable(rc.iemDb[e], double(k) * df), kMaxCutDb, kMaxBoostDb));
            eq[e] = minimumPhase(mag, fft);
        }
        tapsNeeded += int(std::lround(2048 * rs));
    }

    const double scale = norm * headroom;
    m.taps = std::min(geo.maxTaps, std::max(tapsNeeded, geo.block));
    const int fade = std::min(m.taps / 4, int(std::lround(128 * rs)));
    std::vector<double> re(N), im(N);
    for (int e = 0; e < 2; ++e) {
        for (int s = 0; s < 2; ++s) {
            for (std::size_t k = 0; k < K; ++k) {
                cplx g = H[e][0][k] * (s == 0 ? wa : wb) + H[e][1][k] * (s == 0 ? wb : wa);
                if (rc.iemEnabled) g *= eq[e][k];
                g *= scale;
                re[k] = g.real();
                im[k] = g.imag();
            }
            im[0] = 0.0;
            im[N / 2] = 0.0;
            for (std::size_t k = K; k < N; ++k) {
                re[k] = re[N - k];
                im[k] = -im[N - k];
            }
            fft.inverse(re.data(), im.data());
            std::vector<double> &h = m.h[e][s];
            h.resize(std::size_t(m.taps));
            for (int i = 0; i < m.taps; ++i) h[std::size_t(i)] = re[std::size_t(i)] / double(N);
            for (int i = 0; i < fade; ++i) {
                const double w = 0.5 + 0.5 * std::cos(kPi * double(i + 1) / double(fade));
                h[std::size_t(m.taps - fade + i)] *= w;
            }
        }
    }
    return m;
}

// ---- IEM profile design ----------------------------------------------------

namespace {

struct Biquad {
    double b0, b1, b2, a0, a1, a2;
    double magDb(double hz, double fs) const {
        const cplx z1 = std::polar(1.0, -kTwoPi * hz / fs);
        const cplx z2 = z1 * z1;
        const cplx h = (b0 + b1 * z1 + b2 * z2) / (a0 + a1 * z1 + a2 * z2);
        return 20.0 * std::log10(std::abs(h));
    }
};

Biquad shelf(double f0, double gainDb, double slope, double fs, bool high) {
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w0 = kTwoPi * f0 / fs, c = std::cos(w0), s = std::sin(w0);
    const double alpha = s / 2.0 * std::sqrt((A + 1.0 / A) * (1.0 / slope - 1.0) + 2.0);
    const double sa = 2.0 * std::sqrt(A) * alpha;
    if (!high)
        return {A * ((A + 1) - (A - 1) * c + sa), 2 * A * ((A - 1) - (A + 1) * c),
                A * ((A + 1) - (A - 1) * c - sa), (A + 1) + (A - 1) * c + sa,
                -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - sa};
    return {A * ((A + 1) + (A - 1) * c + sa), -2 * A * ((A - 1) + (A + 1) * c),
            A * ((A + 1) + (A - 1) * c - sa), (A + 1) - (A - 1) * c + sa,
            2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - sa};
}

Biquad peak(double f0, double gainDb, double q, double fs) {
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w0 = kTwoPi * f0 / fs, c = std::cos(w0), alpha = std::sin(w0) / (2.0 * q);
    return {1 + alpha * A, -2 * c, 1 - alpha * A, 1 + alpha / A, -2 * c, 1 - alpha / A};
}

bool validCurve(const float *hz, const float *db, int n) {
    if (!hz || !db || n < 4 || n > 100000) return false;
    for (int i = 0; i < n; ++i) {
        if (!std::isfinite(hz[i]) || !std::isfinite(db[i]) || hz[i] <= 0.f || std::fabs(db[i]) > 200.f)
            return false;
        if (i > 0 && !(hz[i] > hz[i - 1])) return false;
    }
    return true;
}

double interpCurve(const float *hz, const float *db, int n, double f) {
    const float ff = float(f);
    if (ff <= hz[0]) return db[0];
    if (ff >= hz[n - 1]) return db[n - 1];
    const int j = std::clamp(int(std::upper_bound(hz, hz + n, ff) - hz), 1, n - 1);
    const double l0 = std::log(hz[j - 1]), l1 = std::log(hz[j]);
    const double t = (std::log(f) - l0) / (l1 - l0);
    return db[j - 1] + t * (db[j] - db[j - 1]);
}

} // namespace

int designUserEq(double bassDb, double presenceDb, double trebleDb, float *outDb) {
    if (!outDb || !std::isfinite(bassDb) || !std::isfinite(presenceDb) || !std::isfinite(trebleDb))
        return AETHER_ERR_INVALID_ARGUMENT;
    const double fs = 96000.0;
    const Biquad bq[3] = {shelf(120.0, clampd(bassDb, -6, 6), 0.8, fs, false),
                          peak(3000.0, clampd(presenceDb, -6, 6), 1.0, fs),
                          shelf(8000.0, clampd(trebleDb, -6, 6), 0.8, fs, true)};
    for (int i = 0; i < AETHER_EQ_POINTS; ++i) {
        const double f = eqFrequency(i);
        double db = 0;
        for (const Biquad &b : bq) db += b.magDb(f, fs);
        outDb[i] = float(clampd(db, kMaxCutDb, kMaxBoostDb));
    }
    return AETHER_OK;
}

int designCorrection(const float *measHz, const float *measDb, int measCount,
                     const float *targetHz, const float *targetDb, int targetCount,
                     double reliableHighHz, float *outDb, aether_correction_report *report) {
    if (!outDb || !validCurve(measHz, measDb, measCount) || !validCurve(targetHz, targetDb, targetCount))
        return AETHER_ERR_INVALID_ARGUMENT;
    if (!std::isfinite(reliableHighHz) || reliableHighHz <= 0) reliableHighHz = 10000.0;

    const int G = 480;
    std::vector<double> f(G), P(G), T(G), Ps(G), Ts(G), Q(G);
    const double llo = std::log(20.0), lhi = std::log(20000.0);
    for (int i = 0; i < G; ++i) {
        f[i] = std::exp(llo + (lhi - llo) * i / (G - 1));
        P[i] = interpCurve(measHz, measDb, measCount, f[i]);
        T[i] = interpCurve(targetHz, targetDb, targetCount, f[i]);
    }
    // Variable fractional-octave smoothing in the power domain: 1/6 octave below 2 kHz,
    // widening to 1/3 octave above 6 kHz. Narrow notches are averaged, not inverted.
    auto smooth = [&](const std::vector<double> &in, std::vector<double> &out, bool variable) {
        for (int i = 0; i < G; ++i) {
            double width = 1.0 / 6.0;
            if (variable) {
                if (f[i] > 6000.0) width = 1.0 / 3.0;
                else if (f[i] > 2000.0)
                    width = 1.0 / 6.0 + (1.0 / 6.0) * std::log(f[i] / 2000.0) / std::log(3.0);
            }
            double acc = 0;
            int cnt = 0;
            for (int j = 0; j < G; ++j)
                if (std::fabs(std::log2(f[j] / f[i])) <= width / 2.0) {
                    acc += std::pow(10.0, in[j] / 10.0);
                    ++cnt;
                }
            out[i] = 10.0 * std::log10(acc / cnt);
        }
    };
    smooth(P, Ps, true);
    smooth(T, Ts, false);

    double offset = 0;
    int cnt = 0;
    for (int i = 0; i < G; ++i)
        if (f[i] >= 300.0 && f[i] <= 3000.0) {
            offset += Ts[i] - Ps[i];
            ++cnt;
        }
    offset = cnt ? offset / cnt : 0.0;
    double bandPow = 0;
    cnt = 0;
    for (int i = 0; i < G; ++i)
        if (f[i] >= 300.0 && f[i] <= 3000.0) {
            bandPow += std::pow(10.0, (Ps[i] + offset) / 10.0);
            ++cnt;
        }
    bandPow = cnt ? bandPow / cnt : 1.0;
    const double lambda = 0.01 * bandPow; // −20 dB regularisation floor

    const double relLo = std::max(20.0, double(measHz[0]));
    const double relHi = std::min(reliableHighHz, double(measHz[measCount - 1]));
    int clamped = 0;
    double maxBoost = 0, maxCut = 0;
    for (int i = 0; i < G; ++i) {
        const double pm = std::pow(10.0, (Ps[i] + offset) / 20.0);
        const double tm = std::pow(10.0, Ts[i] / 20.0);
        double q = 20.0 * std::log10(tm * pm / (pm * pm + lambda));
        // Fade to 0 dB over half an octave outside the reliable range.
        double w = 1.0;
        const double below = std::log2(relLo / f[i]), above = std::log2(f[i] / relHi);
        if (below > 0) w = below >= 0.5 ? 0.0 : 0.5 + 0.5 * std::cos(kPi * below / 0.5);
        if (above > 0) w = above >= 0.5 ? 0.0 : 0.5 + 0.5 * std::cos(kPi * above / 0.5);
        q *= w;
        if (q > kMaxBoostDb || q < kMaxCutDb) ++clamped;
        Q[i] = clampd(q, kMaxCutDb, kMaxBoostDb);
        maxBoost = std::max(maxBoost, Q[i]);
        maxCut = std::min(maxCut, Q[i]);
    }
    for (int i = 0; i < AETHER_EQ_POINTS; ++i) {
        const double l = std::log(eqFrequency(i));
        const double pos = (l - llo) / (lhi - llo) * (G - 1);
        const int j = std::clamp(int(pos), 0, G - 2);
        const double t = pos - j;
        outDb[i] = float(Q[j] + t * (Q[j + 1] - Q[j]));
    }
    if (report) {
        report->level_offset_db = float(offset);
        report->max_boost_db = float(maxBoost);
        report->max_cut_db = float(maxCut);
        report->clamped_fraction = float(clamped) / float(G);
        report->reliable_low_hz = float(relLo);
        report->reliable_high_hz = float(relHi);
    }
    return AETHER_OK;
}

} // namespace aether
