/*
 * Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
 *
 * Aether — IEM soundstage spatializer
 * Portable DSP core, versioned C ABI.
 *
 * A project by Ambarish Mallick.
 *
 * Threading contract
 *   - Control thread (one at a time): create, prepare, submit_config, destroy.
 *     These may allocate and take a private mutex. prepare() must not run
 *     concurrently with process().
 *   - Audio thread (one): process(). Allocation-free, lock-free, exception-free,
 *     bounded time. Arbitrary frame counts are accepted.
 *   - Any thread: read_meters, latency/info queries (atomics only).
 *
 * Signal contract
 *   - Stereo float32 in, stereo float32 out, at the prepared sample rate.
 *   - Every mode — including DSP bypass — has the same fixed latency
 *     (aether_engine_latency_frames), so switches stay time-aligned.
 *   - DSP bypass is unity gain, channel preserving and bit-exact after the
 *     declared latency (unless level-matched bypass is explicitly enabled).
 *   - Non-finite input samples are replaced with 0 and counted. A non-finite
 *     internal result latches a safety bypass that fades in from silence.
 *   - Output is not clipped or compressed; meters report sample peak and
 *     estimated true peak so the host can warn.
 */
#ifndef AETHER_CORE_H
#define AETHER_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AETHER_ABI_VERSION 2u
#define AETHER_EQ_POINTS 64

/* Return codes */
#define AETHER_OK 0
#define AETHER_ERR_INVALID_ARGUMENT (-1)
#define AETHER_ERR_INVALID_CONFIG (-2)
#define AETHER_ERR_NOT_PREPARED (-3)
#define AETHER_ERR_UNSUPPORTED_RATE (-4)

typedef enum aether_mode {
    AETHER_MODE_BYPASS = 0,    /* DSP bypass: unity, delay-compensated */
    AETHER_MODE_CROSSFEED = 1, /* gentle shelving crossfeed */
    AETHER_MODE_REFERENCE = 2, /* virtual speakers ±30°, low room, width 1.0, full clarity */
    AETHER_MODE_CUSTOM = 3     /* virtual speakers with user parameters */
} aether_mode;

typedef enum aether_room_size {
    AETHER_ROOM_SMALL = 0,
    AETHER_ROOM_MEDIUM = 1,
    AETHER_ROOM_LARGE = 2
} aether_room_size;

typedef struct aether_config {
    uint32_t struct_size;        /* sizeof(aether_config); set by aether_config_default */
    int32_t mode;                /* aether_mode */

    /* Virtual-speaker parameters (used by CUSTOM; REFERENCE uses fixed values).
       Each speaker angle is measured from straight ahead toward that speaker's
       own side, 0 … 360° (wrapped): 0 = front centre, 90 = beside its ear,
       180 = directly behind, 270 = beside the opposite ear. Equal angles give
       the usual symmetric ±θ layout. */
    float speaker_left_deg;
    float speaker_right_deg;
    float room_level;            /* 0 (dry) … 1 */
    int32_t room_size;           /* aether_room_size */
    float width;                 /* mid/side width w, 0.75 … 1.25 (1 = unchanged) */
    float clarity;               /* timbre compensation 0 … 1: restores the bypass
                                    tonal balance common to both ears (1 = full) */
    int32_t speaker_enabled[2];  /* nonzero: that speaker plays (0 = left, 1 = right);
                                    at least one must be enabled */
    int32_t fold_disabled;       /* nonzero: a disabled speaker's channel is mixed into
                                    the remaining speaker (−3 dB each, mono fold-down);
                                    zero: that channel is not heard */

    /* Crossfeed parameters (used by CROSSFEED) */
    float crossfeed_level_db;    /* cross-path gain, −15 … −3 dB */
    float crossfeed_cutoff_hz;   /* cross-path low-pass corner, 500 … 2000 Hz */
    float crossfeed_delay_ms;    /* cross-path delay, 0.1 … 0.6 ms */

    /* Gain staging */
    float headroom_db;           /* pre-gain in processing modes, −18 … 0 dB */
    int32_t level_match_bypass;  /* nonzero: bypass also applies headroom_db (not unity) */

    /* Optional per-ear IEM correction, dB at aether_eq_frequency(i). Clamped
       to [−12, +6] dB and realised as a minimum-phase filter. */
    int32_t iem_enabled;
    float iem_db[2][AETHER_EQ_POINTS];
} aether_config;

typedef struct aether_meters {
    float in_peak[2];            /* linear sample peak since last reset */
    float out_peak[2];           /* linear sample peak since last reset */
    float out_true_peak[2];      /* linear, 4× oversampled estimate since last reset */
    float out_true_peak_max;     /* linear, max since prepare (never reset by reads) */
    uint64_t frames_processed;
    uint64_t nonfinite_input_samples;
    uint64_t nonfinite_output_events;
    uint32_t active_generation;  /* generation of the filter bank being rendered */
    int32_t active_mode;         /* aether_mode actually rendered */
    int32_t crossfading;         /* 1 while a configuration crossfade is running */
    int32_t safety_bypass;       /* 1 if a non-finite result latched safety bypass */
} aether_meters;

typedef struct aether_engine_info {
    double sample_rate;
    uint32_t block_frames;       /* internal partition size */
    uint32_t latency_frames;     /* fixed added latency, all modes */
    uint32_t filter_taps;        /* length of the active 2×2 FIR matrix */
    uint32_t partitions;         /* active convolution partitions */
    uint32_t generation;         /* last submitted generation */
} aether_engine_info;

typedef struct aether_reflection {
    int32_t speaker;             /* 0 = left virtual speaker, 1 = right */
    int32_t order;               /* 1 or 2 */
    float azimuth_deg;           /* clockwise from front, right positive */
    float elevation_deg;
    float delay_ms;              /* after the direct sound */
    float gain;                  /* linear, relative to direct, before damping */
    float distance_m;
} aether_reflection;

typedef struct aether_room_summary {
    int32_t count;
    float first_delay_ms;
    float last_delay_ms;
    float direct_to_reflected_db; /* energy ratio, direct vs. early reflections */
    float room_width_m, room_depth_m, room_height_m, speaker_distance_m;
} aether_room_summary;

typedef struct aether_correction_report {
    float level_offset_db;       /* measurement shift applied to align with target */
    float max_boost_db;
    float max_cut_db;
    float clamped_fraction;      /* share of the table that hit the ±limits */
    float reliable_low_hz;
    float reliable_high_hz;
} aether_correction_report;

/* ---- Version ---- */
uint32_t aether_abi_version(void);
const char *aether_version_string(void);

/* ---- Configuration helpers ---- */
void aether_config_default(aether_config *cfg);              /* Reference preset */
int aether_config_validate(const aether_config *cfg);         /* AETHER_OK or error */
float aether_eq_frequency(int index);                         /* 20 Hz … 20 kHz, log spaced */
void aether_config_set_iem_curve(aether_config *cfg, int ear, const float *db, int count);
void aether_config_get_iem_curve(const aether_config *cfg, int ear, float *db, int count);

/* ---- Engine ---- */
typedef struct aether_engine aether_engine;

aether_engine *aether_engine_create(void);
void aether_engine_destroy(aether_engine *engine);
int aether_engine_prepare(aether_engine *engine, double sample_rate);
int aether_engine_submit_config(aether_engine *engine, const aether_config *cfg);
void aether_engine_process(aether_engine *engine,
                           const float *in_left, const float *in_right, size_t in_stride,
                           float *out_left, float *out_right, size_t out_stride,
                           uint32_t frames);
uint32_t aether_engine_latency_frames(const aether_engine *engine);
void aether_engine_get_info(const aether_engine *engine, aether_engine_info *info);
void aether_engine_read_meters(aether_engine *engine, aether_meters *out, int reset_peaks);

/* ---- Room model description (for visualisation and docs) ---- */
int aether_describe_room(const aether_config *cfg, aether_reflection *out, int max_count,
                         aether_room_summary *summary);

/* ---- IEM profile design (control thread; float64 internally) ---- */
/* User-tuned profile: shelves/peak, NOT a measurement. Writes AETHER_EQ_POINTS values. */
int aether_design_user_eq(float bass_db, float presence_db, float treble_db, float *out_db);
/* Regularised correction from a measured or estimated response toward a target:
   Q = T·|P| / (|P|² + λ), smoothed, limited to the reliable range and to [−12, +6] dB. */
int aether_design_correction(const float *meas_hz, const float *meas_db, int meas_count,
                             const float *target_hz, const float *target_db, int target_count,
                             float reliable_high_hz, float *out_db,
                             aether_correction_report *report);

#ifdef __cplusplus
}
#endif

#endif /* AETHER_CORE_H */
