// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
// CPU cost of the DSP core: share of one core needed for real time, per mode and rate.
#include "aether/aether_core.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <vector>

int main() {
    const double rates[] = {44100, 48000, 96000, 192000};
    struct Case {
        const char *name;
        int mode;
        float room;
        int iem;
    };
    const Case cases[] = {{"crossfeed", AETHER_MODE_CROSSFEED, 0, 0},
                          {"reference", AETHER_MODE_REFERENCE, 0.3f, 0},
                          {"custom large room + IEM", AETHER_MODE_CUSTOM, 1.f, 1}};
    const uint32_t hostBlock = 512;
    std::printf("%s — host buffer %u frames, 10 s of audio per case\n", aether_version_string(), hostBlock);
    std::printf("%-26s %8s %8s %10s %12s\n", "mode", "rate", "taps", "latency", "core load");
    for (const Case &c : cases) {
        for (double fs : rates) {
            aether_config cfg;
            aether_config_default(&cfg);
            cfg.mode = c.mode;
            cfg.room_level = c.room;
            cfg.room_size = AETHER_ROOM_LARGE;
            cfg.iem_enabled = c.iem;
            aether_engine *e = aether_engine_create();
            aether_engine_submit_config(e, &cfg);
            aether_engine_prepare(e, fs);
            std::vector<float> in(hostBlock * 2), out(hostBlock * 2);
            for (uint32_t i = 0; i < hostBlock * 2; ++i) in[i] = 0.1f * std::sin(0.01f * float(i));
            const auto blocks = uint64_t(fs * 10.0 / hostBlock);
            const auto t0 = std::chrono::steady_clock::now();
            for (uint64_t b = 0; b < blocks; ++b)
                aether_engine_process(e, in.data(), in.data() + 1, 2, out.data(), out.data() + 1, 2, hostBlock);
            const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
            aether_engine_info info;
            aether_engine_get_info(e, &info);
            const double audio = double(blocks * hostBlock) / fs;
            std::printf("%-26s %8.0f %8u %8.2f ms %11.2f%%\n", c.name, fs, info.filter_taps,
                        1000.0 * info.latency_frames / fs, 100.0 * secs / audio);
            aether_engine_destroy(e);
        }
    }
    return 0;
}
