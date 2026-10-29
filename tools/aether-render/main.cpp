// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
// aether-render: offline reference renderer. Reads a WAV file, runs it through the
// same DSP core the app uses, writes a latency-compensated 32-bit float WAV.
#include "aether/aether_core.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct Audio {
    double rate = 0;
    std::vector<float> l, r;
};

uint32_t rd32(const unsigned char *p) { return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24; }
uint16_t rd16(const unsigned char *p) { return uint16_t(p[0] | p[1] << 8); }

bool readWav(const char *path, Audio &a, std::string &err) {
    FILE *f = std::fopen(path, "rb");
    if (!f) { err = "cannot open input"; return false; }
    std::vector<unsigned char> d;
    unsigned char buf[65536];
    size_t n;
    while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) d.insert(d.end(), buf, buf + n);
    std::fclose(f);
    if (d.size() < 12 || std::memcmp(d.data(), "RIFF", 4) || std::memcmp(d.data() + 8, "WAVE", 4)) {
        err = "not a RIFF/WAVE file";
        return false;
    }
    uint16_t fmt = 0, ch = 0, bits = 0;
    uint32_t rate = 0;
    const unsigned char *data = nullptr;
    size_t dataLen = 0;
    for (size_t p = 12; p + 8 <= d.size();) {
        const uint32_t len = rd32(&d[p + 4]);
        if (p + 8 + len > d.size()) { err = "truncated chunk"; return false; }
        if (!std::memcmp(&d[p], "fmt ", 4) && len >= 16) {
            fmt = rd16(&d[p + 8]);
            ch = rd16(&d[p + 10]);
            rate = rd32(&d[p + 12]);
            bits = rd16(&d[p + 22]);
            if (fmt == 0xFFFE && len >= 40) fmt = rd16(&d[p + 32]); // extensible subformat
        } else if (!std::memcmp(&d[p], "data", 4)) {
            data = &d[p + 8];
            dataLen = len;
        }
        p += 8 + len + (len & 1);
    }
    if (!data || !ch || !rate) { err = "missing fmt or data chunk"; return false; }
    if (ch > 2) { err = "only mono or stereo input is supported"; return false; }
    if (!((fmt == 1 && (bits == 16 || bits == 24 || bits == 32)) || (fmt == 3 && (bits == 32 || bits == 64)))) {
        err = "unsupported sample format";
        return false;
    }
    const size_t bps = bits / 8, frames = dataLen / (bps * ch);
    a.rate = rate;
    a.l.resize(frames);
    a.r.resize(frames);
    for (size_t i = 0; i < frames; ++i)
        for (uint16_t c = 0; c < 2; ++c) {
            const unsigned char *s = data + (i * ch + (ch == 1 ? 0 : c)) * bps;
            double v = 0;
            if (fmt == 1 && bits == 16) v = int16_t(rd16(s)) / 32768.0;
            else if (fmt == 1 && bits == 24) v = double(int32_t(uint32_t(s[0]) << 8 | uint32_t(s[1]) << 16 | uint32_t(s[2]) << 24) >> 8) / 8388608.0;
            else if (fmt == 1 && bits == 32) v = int32_t(rd32(s)) / 2147483648.0;
            else if (bits == 32) { float x; std::memcpy(&x, s, 4); v = x; }
            else { double x; std::memcpy(&x, s, 8); v = x; }
            (c == 0 ? a.l : a.r)[i] = float(v);
        }
    return true;
}

bool writeWav(const char *path, const Audio &a) {
    FILE *f = std::fopen(path, "wb");
    if (!f) return false;
    const uint32_t frames = uint32_t(a.l.size()), dataLen = frames * 8, rate = uint32_t(a.rate);
    auto w32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, f); };
    auto w16 = [&](uint16_t v) { std::fwrite(&v, 2, 1, f); };
    std::fwrite("RIFF", 1, 4, f); w32(36 + dataLen); std::fwrite("WAVE", 1, 4, f);
    std::fwrite("fmt ", 1, 4, f); w32(16); w16(3); w16(2); w32(rate); w32(rate * 8); w16(8); w16(32);
    std::fwrite("data", 1, 4, f); w32(dataLen);
    for (uint32_t i = 0; i < frames; ++i) {
        std::fwrite(&a.l[i], 4, 1, f);
        std::fwrite(&a.r[i], 4, 1, f);
    }
    return std::fclose(f) == 0;
}

void usage() {
    std::fprintf(stderr,
                 "usage: aether-render IN.wav OUT.wav [options]\n"
                 "  --mode bypass|crossfeed|reference|custom   (default reference)\n"
                 "  --azimuth DEG      custom angle for both speakers, 0–360 (30)\n"
                 "  --left DEG --right DEG   custom angle per speaker, from the front toward its own side\n"
                 "  --clarity C        custom timbre compensation, 0–1 (1)\n"
                 "  --off left|right   custom: switch one speaker off\n"
                 "  --fold 0|1         custom: mix the switched-off speaker's channel into the other (0)\n"
                 "  --room LEVEL       custom room level, 0–1 (0.3)\n"
                 "  --room-size small|medium|large\n"
                 "  --width W          custom mid/side width, 0.75–1.25 (1.0)\n"
                 "  --headroom DB      pre-gain in processing modes, −18–0 (−6)\n"
                 "  --xf-level DB --xf-cutoff HZ --xf-delay MS   crossfeed tuning\n"
                 "  --iem BASS,PRESENCE,TREBLE   user-tuned IEM EQ in dB (±6 each)\n");
}

double db(float v) { return 20.0 * std::log10(std::max(1e-12f, v)); }

} // namespace

int main(int argc, char **argv) {
    if (argc < 3) { usage(); return 2; }
    aether_config cfg;
    aether_config_default(&cfg);
    for (int i = 3; i < argc; ++i) {
        const std::string k = argv[i];
        if (i + 1 >= argc) { usage(); return 2; }
        const char *v = argv[++i];
        if (k == "--mode") {
            const std::string m = v;
            cfg.mode = m == "bypass" ? AETHER_MODE_BYPASS : m == "crossfeed" ? AETHER_MODE_CROSSFEED
                     : m == "custom" ? AETHER_MODE_CUSTOM : AETHER_MODE_REFERENCE;
        } else if (k == "--azimuth") cfg.speaker_left_deg = cfg.speaker_right_deg = std::strtof(v, nullptr);
        else if (k == "--left") cfg.speaker_left_deg = std::strtof(v, nullptr);
        else if (k == "--right") cfg.speaker_right_deg = std::strtof(v, nullptr);
        else if (k == "--clarity") cfg.clarity = std::strtof(v, nullptr);
        else if (k == "--off") cfg.speaker_enabled[!std::strcmp(v, "right") ? 1 : 0] = 0;
        else if (k == "--fold") cfg.fold_disabled = std::atoi(v) != 0;
        else if (k == "--room") cfg.room_level = std::strtof(v, nullptr);
        else if (k == "--room-size") cfg.room_size = !std::strcmp(v, "small") ? AETHER_ROOM_SMALL : !std::strcmp(v, "large") ? AETHER_ROOM_LARGE : AETHER_ROOM_MEDIUM;
        else if (k == "--width") cfg.width = std::strtof(v, nullptr);
        else if (k == "--headroom") cfg.headroom_db = std::strtof(v, nullptr);
        else if (k == "--xf-level") cfg.crossfeed_level_db = std::strtof(v, nullptr);
        else if (k == "--xf-cutoff") cfg.crossfeed_cutoff_hz = std::strtof(v, nullptr);
        else if (k == "--xf-delay") cfg.crossfeed_delay_ms = std::strtof(v, nullptr);
        else if (k == "--iem") {
            float b = 0, p = 0, t = 0;
            if (std::sscanf(v, "%f,%f,%f", &b, &p, &t) != 3) { usage(); return 2; }
            float eq[AETHER_EQ_POINTS];
            aether_design_user_eq(b, p, t, eq);
            aether_config_set_iem_curve(&cfg, 0, eq, AETHER_EQ_POINTS);
            aether_config_set_iem_curve(&cfg, 1, eq, AETHER_EQ_POINTS);
            cfg.iem_enabled = 1;
        } else { usage(); return 2; }
    }
    Audio in;
    std::string err;
    if (!readWav(argv[1], in, err)) { std::fprintf(stderr, "error: %s\n", err.c_str()); return 1; }

    aether_engine *e = aether_engine_create();
    if (aether_engine_submit_config(e, &cfg) != AETHER_OK || aether_engine_prepare(e, in.rate) != AETHER_OK) {
        std::fprintf(stderr, "error: invalid configuration or sample rate\n");
        return 1;
    }
    aether_engine_info info;
    aether_engine_get_info(e, &info);
    const size_t lat = info.latency_frames, tail = info.filter_taps;
    const size_t total = in.l.size() + lat + tail;
    in.l.resize(total, 0.f);
    in.r.resize(total, 0.f);
    std::vector<float> ol(total), orr(total);
    aether_engine_process(e, in.l.data(), in.r.data(), 1, ol.data(), orr.data(), 1, uint32_t(total));
    Audio out;
    out.rate = in.rate;
    out.l.assign(ol.begin() + long(lat), ol.end());
    out.r.assign(orr.begin() + long(lat), orr.end());
    if (!writeWav(argv[2], out)) { std::fprintf(stderr, "error: cannot write output\n"); return 1; }
    aether_meters m;
    aether_engine_read_meters(e, &m, 0);
    std::printf("%s\n%.0f Hz · %u-tap matrix · latency %zu frames (compensated)\n", aether_version_string(),
                in.rate, info.filter_taps, lat);
    std::printf("input peak  L %+.2f  R %+.2f dBFS\n", db(m.in_peak[0]), db(m.in_peak[1]));
    std::printf("output peak L %+.2f  R %+.2f dBFS · true peak %+.2f dBTP%s\n", db(m.out_peak[0]), db(m.out_peak[1]),
                db(m.out_true_peak_max), m.out_true_peak_max > 0.891f ? "  (above −1 dBTP: lower --headroom)" : "");
    if (m.nonfinite_input_samples) std::printf("sanitised %llu non-finite input samples\n", (unsigned long long)m.nonfinite_input_samples);
    aether_engine_destroy(e);
    return 0;
}
