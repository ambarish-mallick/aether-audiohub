// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
// Aether macOS route: system audio → private Core Audio process tap → DSP core →
// selected physical output, all inside one private aggregate device so the tap and
// the DAC share a clock (Core Audio performs tap drift compensation).
//
// A project by Ambarish Mallick.
#import <Foundation/Foundation.h>

#include <aether/aether_core.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AERouteState) {
    AERouteStateStopped = 0,
    AERouteStateRunning = 1,
    AERouteStateFailed = 2,
};

@interface AEOutputDevice : NSObject
@property (nonatomic, readonly, copy) NSString *uid;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *transport;   // "USB", "Built-in", "Bluetooth", …
@property (nonatomic, readonly) BOOL isWireless;              // Bluetooth / AirPlay / continuity
@property (nonatomic, readonly) BOOL isSystemDefault;
@property (nonatomic, readonly) double nominalSampleRate;
@property (nonatomic, readonly) uint32_t outputChannels;
@end

@interface AERouteSnapshot : NSObject
@property (nonatomic, readonly) AERouteState state;
@property (nonatomic, readonly, copy) NSString *message;

@property (nonatomic, readonly) double tapSampleRate;
@property (nonatomic, readonly) uint32_t tapChannels;
@property (nonatomic, readonly) double routeSampleRate;      // aggregate (= DSP) rate
@property (nonatomic, readonly) BOOL tapRateConverted;       // tap rate ≠ route rate

@property (nonatomic, readonly, copy) NSString *deviceUID;
@property (nonatomic, readonly, copy) NSString *deviceName;
@property (nonatomic, readonly, copy) NSString *deviceTransport;
@property (nonatomic, readonly) BOOL deviceIsWireless;
@property (nonatomic, readonly, copy) NSString *physicalFormat; // e.g. "24-bit integer"
@property (nonatomic, readonly) uint32_t deviceChannels;
@property (nonatomic, readonly) uint32_t leftChannel, rightChannel; // 1-based device channels

@property (nonatomic, readonly) uint32_t bufferFrames;
@property (nonatomic, readonly) uint32_t deviceLatencyFrames;  // device + stream + safety offset
@property (nonatomic, readonly) uint32_t dspLatencyFrames;
@property (nonatomic, readonly) double estimatedAddedLatencyMs; // DSP + one route buffer (estimate)

@property (nonatomic, readonly) uint64_t callbacks;
@property (nonatomic, readonly) uint64_t overloads;
@property (nonatomic, readonly) uint64_t tapMissing;           // callbacks without tap input
@property (nonatomic, readonly) double loadAverage;            // DSP time / buffer period
@property (nonatomic, readonly) double loadPeak;
@property (nonatomic, readonly) double secondsSinceLastCallback;

@property (nonatomic, readonly) BOOL deviceHoggedByOtherProcess;
@property (nonatomic, readonly, copy) NSString *systemDefaultOutputName;
@end

@protocol AERouteDelegate <NSObject>
/// Device list or system default output changed (always delivered on the main queue).
- (void)routeDevicesDidChange;
/// The route stopped itself (device vanished, tap died). Main queue.
- (void)routeDidStopWithReason:(NSString *)reason;
/// The route's format changed (sample rate, tap format); the owner should restart it. Main queue.
- (void)routeNeedsRestart:(NSString *)reason;
@end

@interface AERoute : NSObject

@property (nonatomic, weak, nullable) id<AERouteDelegate> delegate;
@property (nonatomic, readonly) AERouteState state;

+ (NSArray<AEOutputDevice *> *)outputDevices;
+ (nullable NSString *)systemDefaultOutputUID;

/// Builds the tap, aggregate device and IOProc and starts audio. Main thread.
- (BOOL)startWithOutputUID:(NSString *)uid error:(NSError *_Nullable *_Nullable)error;
/// Tears everything down; system audio returns to its normal path immediately. Main thread.
- (void)stop;

/// Builds and publishes a new filter bank (crossfaded). May be called from any one
/// serial background queue; returns an AETHER_* code.
- (int)submitConfig:(const aether_config *)config;

- (aether_meters)readMetersReset:(BOOL)reset;
- (aether_engine_info)engineInfo;
- (AERouteSnapshot *)snapshot;

@end

NS_ASSUME_NONNULL_END
