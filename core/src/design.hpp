// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
// Off-audio-thread filter design (float64). Every processing mode compiles to
// one immutable 2×2 FIR matrix G[ear][source] that already contains the width
// stage, the spatial renderer (HRTF + early room, or crossfeed), the optional
// per-ear IEM correction and the headroom gain.
#pragma once

#include "aether/aether_core.h"

#include <complex>
#include <vector>

namespace aether {

// Fixed per-rate engine geometry.
struct EngineGeometry {
    double fs = 0;
    int block = 0;      // partition size B (power of two)
    int bulkDelay = 0;  // D0: common alignment delay inside every filter (incl. bypass)
    int maxTaps = 0;    // upper bound on FIR length (multiple of B)
};
EngineGeometry geometryFor(double fs);

// Configuration after preset resolution and clamping.
struct ResolvedConfig {
    int mode = AETHER_MODE_REFERENCE;
    double leftDeg = 30, rightDeg = 30; // from the front toward each speaker's own side
    double clarity = 1;
    bool enabled[2] = {true, true};
    bool fold = false;
    double roomLevel = 0.3;
    int roomSize = AETHER_ROOM_MEDIUM;
    double width = 1;
    double xfLevelDb = -9, xfCutoffHz = 700, xfDelayMs = 0.3;
    double headroomDb = -6;
    bool levelMatchBypass = false;
    bool iemEnabled = false;
    double iemDb[2][AETHER_EQ_POINTS] = {};
    // Azimuth clockwise from the front (right positive) of speaker s (0 = left, 1 = right).
    double speakerAzimuth(int s) const { return s == 0 ? -leftDeg : rightDeg; }
};
ResolvedConfig resolve(const aether_config &cfg);

struct RoomGeometry {
    double width, depth, height, speakerDistance, listenerY, earHeight;
};
RoomGeometry roomGeometry(int roomSize);

struct Reflection {
    int speaker = 0;
    int order = 0;
    double azDeg = 0, elDeg = 0;
    double delay = 0;      // seconds after the direct sound
    double gain = 0;       // linear, before frequency-dependent damping
    double distance = 0;   // metres, image source to listener
    double dampHz[2] = {0, 0}; // per-bounce one-pole high-frequency damping corners (0 = none)
};
// Image-source early reflections (orders 1–2) for the resolved virtual-speaker setup.
std::vector<Reflection> computeReflections(const ResolvedConfig &rc);

struct DesignedMatrix {
    int mode = AETHER_MODE_BYPASS;
    bool identity = false;  // pure delayed copy × gain
    double gain = 1;
    int taps = 0;
    std::vector<double> h[2][2]; // [ear][source], length taps
};
DesignedMatrix designMatrix(const ResolvedConfig &rc, const EngineGeometry &geo);

// Brown–Duda style structural HRTF for one ear, without the bulk delay.
// Exposed for tests.
std::complex<double> modelHrtf(double hz, double azDeg, double elDeg, int ear);
double diffuseFieldGainDb(double hz);

double eqFrequency(int index);

int designUserEq(double bassDb, double presenceDb, double trebleDb, float *outDb);
int designCorrection(const float *measHz, const float *measDb, int measCount,
                     const float *targetHz, const float *targetDb, int targetCount,
                     double reliableHighHz, float *outDb, aether_correction_report *report);

} // namespace aether
