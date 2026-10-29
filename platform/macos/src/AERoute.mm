// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
// Aether macOS route. See AERoute.h for the topology.
//
// Real-time rules in AetherIOProc: no Objective-C messaging, no allocation, no locks,
// no logging. Everything it touches is preallocated in RTContext before AudioDeviceStart.
#import "AERoute.h"

#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#include <mach/mach_time.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <atomic>
#include <cstring>
#include <vector>

static NSString *const kAERouteErrorDomain = @"Aether.Route";
static NSString *const kAggregatePrefix = @"com.ambarishmallick.aether.route.";

// ---------------------------------------------------------------------------
#pragma mark - Core Audio helpers

static NSString *AEStatusString(OSStatus s) {
    const uint32_t v = uint32_t(s);
    char c[5] = {char(v >> 24), char(v >> 16), char(v >> 8), char(v), 0};
    for (int i = 0; i < 4; ++i)
        if (c[i] < 32 || c[i] > 126) return [NSString stringWithFormat:@"%d", int(s)];
    return [NSString stringWithFormat:@"'%s'", c];
}

static NSError *AEError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kAERouteErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

template <typename T>
static OSStatus AEGet(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope, T &out) {
    AudioObjectPropertyAddress addr{sel, scope, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(T);
    return AudioObjectGetPropertyData(obj, &addr, 0, nullptr, &size, &out);
}

static NSString *AEGetString(AudioObjectID obj, AudioObjectPropertySelector sel,
                             AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    CFStringRef s = nullptr;
    if (AEGet(obj, sel, scope, s) != noErr || !s) return @"";
    return (__bridge_transfer NSString *)s;
}

static std::vector<AudioObjectID> AEGetIDs(AudioObjectID obj, AudioObjectPropertySelector sel,
                                           AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    AudioObjectPropertyAddress addr{sel, scope, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(obj, &addr, 0, nullptr, &size) != noErr || size == 0) return {};
    std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
    if (AudioObjectGetPropertyData(obj, &addr, 0, nullptr, &size, ids.data()) != noErr) return {};
    ids.resize(size / sizeof(AudioObjectID));
    return ids;
}

// Per-buffer channel counts of a device's stream configuration.
static std::vector<UInt32> AEBufferChannels(AudioObjectID dev, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress addr{kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &addr, 0, nullptr, &size) != noErr || size == 0) return {};
    std::vector<uint8_t> raw(size);
    auto *list = reinterpret_cast<AudioBufferList *>(raw.data());
    if (AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, list) != noErr) return {};
    std::vector<UInt32> out;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) out.push_back(list->mBuffers[i].mNumberChannels);
    return out;
}

static UInt32 AEChannelCount(AudioObjectID dev, AudioObjectPropertyScope scope) {
    UInt32 n = 0;
    for (UInt32 c : AEBufferChannels(dev, scope)) n += c;
    return n;
}

static AudioObjectID AEDeviceForUID(NSString *uid) {
    AudioObjectPropertyAddress addr{kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    CFStringRef cf = (__bridge CFStringRef)uid;
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof dev;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, sizeof cf, &cf, &size, &dev) != noErr)
        return kAudioObjectUnknown;
    return dev;
}

static NSString *AETransportName(UInt32 t, BOOL *wireless) {
    *wireless = NO;
    switch (t) {
    case kAudioDeviceTransportTypeBuiltIn: return @"Built-in";
    case kAudioDeviceTransportTypeUSB: return @"USB";
    case kAudioDeviceTransportTypeThunderbolt: return @"Thunderbolt";
    case kAudioDeviceTransportTypePCI: return @"PCI";
    case kAudioDeviceTransportTypeFireWire: return @"FireWire";
    case kAudioDeviceTransportTypeHDMI: return @"HDMI";
    case kAudioDeviceTransportTypeDisplayPort: return @"DisplayPort";
    case kAudioDeviceTransportTypeVirtual: return @"Virtual";
    case kAudioDeviceTransportTypeAggregate:
    case kAudioDeviceTransportTypeAutoAggregate: return @"Aggregate";
    case kAudioDeviceTransportTypeBluetooth:
    case kAudioDeviceTransportTypeBluetoothLE: *wireless = YES; return @"Bluetooth";
    case kAudioDeviceTransportTypeAirPlay: *wireless = YES; return @"AirPlay";
    case kAudioDeviceTransportTypeContinuityCaptureWireless: *wireless = YES; return @"Continuity";
    default: return @"Other";
    }
}

static NSString *AEPhysicalFormat(AudioObjectID dev) {
    const auto streams = AEGetIDs(dev, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
    if (streams.empty()) return @"—";
    AudioStreamBasicDescription asbd{};
    if (AEGet(streams[0], kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, asbd) != noErr)
        return @"—";
    if (asbd.mFormatID != kAudioFormatLinearPCM) return @"Encoded";
    const BOOL isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    return [NSString stringWithFormat:@"%u-bit %@", unsigned(asbd.mBitsPerChannel), isFloat ? @"float" : @"integer"];
}

static double AERate(AudioObjectID dev) {
    Float64 r = 0;
    AEGet(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, r);
    return r;
}

static float AEBitsToFloat(uint32_t b) {
    float f;
    std::memcpy(&f, &b, sizeof f);
    return f;
}

static uint32_t AEFloatToBits(float f) {
    uint32_t b;
    std::memcpy(&b, &f, sizeof b);
    return b;
}

// ---------------------------------------------------------------------------
#pragma mark - Real-time context

namespace {

constexpr UInt32 kMaxChunk = 8192;

struct RTContext {
    aether_engine *engine = nullptr;
    UInt32 tapBuffers = 1;      // buffers at the end of the input list that belong to the tap
    int outBufL = -1, outOffL = 0, outBufR = -1, outOffR = 0;
    double sampleRate = 48000;
    double ticksToSeconds = 0;
    float scratchL[kMaxChunk];
    float scratchR[kMaxChunk];
    float loadEma = 0;          // audio-thread private
    std::atomic<uint64_t> callbacks{0}, tapMissing{0}, lastHostTime{0};
    std::atomic<uint32_t> loadAvgBits{0}, loadPeakBits{0};
};

OSStatus AetherIOProc(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *inData, const AudioTimeStamp *,
                      AudioBufferList *outData, const AudioTimeStamp *, void *client) {
    RTContext *ctx = static_cast<RTContext *>(client);
    const uint64_t t0 = mach_absolute_time();
    if (!outData) return noErr;
    for (UInt32 b = 0; b < outData->mNumberBuffers; ++b)
        if (outData->mBuffers[b].mData) std::memset(outData->mBuffers[b].mData, 0, outData->mBuffers[b].mDataByteSize);
    if (ctx->outBufL < 0 || ctx->outBufR < 0 || UInt32(ctx->outBufL) >= outData->mNumberBuffers ||
        UInt32(ctx->outBufR) >= outData->mNumberBuffers)
        return noErr;
    AudioBuffer &bl = outData->mBuffers[ctx->outBufL];
    AudioBuffer &br = outData->mBuffers[ctx->outBufR];
    const UInt32 strideL = bl.mNumberChannels, strideR = br.mNumberChannels;
    if (!bl.mData || !br.mData || strideL == 0 || strideR == 0) return noErr;
    const UInt32 frames =
        std::min(bl.mDataByteSize / UInt32(sizeof(float) * strideL), br.mDataByteSize / UInt32(sizeof(float) * strideR));

    const float *inL = nullptr, *inR = nullptr;
    size_t inStride = 1;
    if (inData && inData->mNumberBuffers >= ctx->tapBuffers) {
        const UInt32 first = inData->mNumberBuffers - ctx->tapBuffers;
        const AudioBuffer &a = inData->mBuffers[first];
        if (ctx->tapBuffers == 1 && a.mData && a.mNumberChannels > 0 &&
            a.mDataByteSize / (sizeof(float) * a.mNumberChannels) >= frames) {
            inStride = a.mNumberChannels;
            inL = static_cast<const float *>(a.mData);
            inR = inStride > 1 ? inL + 1 : inL;
        } else if (ctx->tapBuffers >= 2) {
            const AudioBuffer &b = inData->mBuffers[first + 1];
            if (a.mData && b.mData && a.mDataByteSize / sizeof(float) >= frames &&
                b.mDataByteSize / sizeof(float) >= frames) {
                inL = static_cast<const float *>(a.mData);
                inR = static_cast<const float *>(b.mData);
            }
        }
    }
    if (!inL) ctx->tapMissing.fetch_add(1, std::memory_order_relaxed);

    float *dl = static_cast<float *>(bl.mData) + ctx->outOffL;
    float *dr = static_cast<float *>(br.mData) + ctx->outOffR;
    for (UInt32 done = 0; done < frames;) {
        const UInt32 n = std::min(frames - done, kMaxChunk);
        aether_engine_process(ctx->engine, inL ? inL + done * inStride : nullptr,
                              inR ? inR + done * inStride : nullptr, inStride, ctx->scratchL, ctx->scratchR, 1, n);
        for (UInt32 i = 0; i < n; ++i) {
            dl[(done + i) * strideL] = ctx->scratchL[i];
            dr[(done + i) * strideR] = ctx->scratchR[i];
        }
        done += n;
    }

    const uint64_t t1 = mach_absolute_time();
    ctx->callbacks.fetch_add(1, std::memory_order_relaxed);
    ctx->lastHostTime.store(t1, std::memory_order_relaxed);
    if (frames > 0) {
        const float load = float(double(t1 - t0) * ctx->ticksToSeconds / (double(frames) / ctx->sampleRate));
        ctx->loadEma += 0.05f * (load - ctx->loadEma);
        ctx->loadAvgBits.store(AEFloatToBits(ctx->loadEma), std::memory_order_relaxed);
        uint32_t cur = ctx->loadPeakBits.load(std::memory_order_relaxed);
        const uint32_t nb = AEFloatToBits(load);
        while (nb > cur && !ctx->loadPeakBits.compare_exchange_weak(cur, nb, std::memory_order_relaxed)) {
        }
    }
    return noErr;
}

struct Listener {
    AudioObjectID object;
    AudioObjectPropertyAddress address;
    AudioObjectPropertyListenerBlock block;
};

} // namespace

// ---------------------------------------------------------------------------
#pragma mark - Value objects

@interface AEOutputDevice ()
@property (nonatomic, readwrite, copy) NSString *uid, *name, *transport;
@property (nonatomic, readwrite) BOOL isWireless, isSystemDefault;
@property (nonatomic, readwrite) double nominalSampleRate;
@property (nonatomic, readwrite) uint32_t outputChannels;
@end
@implementation AEOutputDevice
@end

@interface AERouteSnapshot ()
@property (nonatomic, readwrite) AERouteState state;
@property (nonatomic, readwrite, copy) NSString *message;
@property (nonatomic, readwrite) double tapSampleRate, routeSampleRate;
@property (nonatomic, readwrite) uint32_t tapChannels;
@property (nonatomic, readwrite) BOOL tapRateConverted;
@property (nonatomic, readwrite, copy) NSString *deviceUID, *deviceName, *deviceTransport, *physicalFormat;
@property (nonatomic, readwrite) BOOL deviceIsWireless;
@property (nonatomic, readwrite) uint32_t deviceChannels, leftChannel, rightChannel;
@property (nonatomic, readwrite) uint32_t bufferFrames, deviceLatencyFrames, dspLatencyFrames;
@property (nonatomic, readwrite) double estimatedAddedLatencyMs;
@property (nonatomic, readwrite) uint64_t callbacks, overloads, tapMissing;
@property (nonatomic, readwrite) double loadAverage, loadPeak, secondsSinceLastCallback;
@property (nonatomic, readwrite) BOOL deviceHoggedByOtherProcess;
@property (nonatomic, readwrite, copy) NSString *systemDefaultOutputName;
@end
@implementation AERouteSnapshot
@end

// ---------------------------------------------------------------------------
#pragma mark - Route

@implementation AERoute {
    aether_engine *_engine;
    RTContext *_rt;
    AudioObjectID _tap;
    AudioObjectID _aggregate;
    AudioObjectID _device;
    AudioDeviceIOProcID _procID;
    std::vector<Listener> _routeListeners;
    std::vector<Listener> _systemListeners;
    AERouteState _state;
    NSString *_message;
    NSString *_deviceUID, *_deviceName, *_deviceTransport, *_physicalFormat;
    BOOL _deviceWireless;
    double _tapRate, _routeRate;
    uint32_t _tapChannels, _deviceChannels, _leftChannel, _rightChannel;
    uint32_t _bufferFrames, _deviceLatency;
    uint64_t _overloads;
    double _ticksToSeconds;
}

+ (NSArray<AEOutputDevice *> *)outputDevices {
    NSMutableArray *out = [NSMutableArray array];
    NSString *def = [self systemDefaultOutputUID];
    for (AudioObjectID dev : AEGetIDs(kAudioObjectSystemObject, kAudioHardwarePropertyDevices)) {
        const UInt32 ch = AEChannelCount(dev, kAudioObjectPropertyScopeOutput);
        if (ch == 0) continue;
        NSString *uid = AEGetString(dev, kAudioDevicePropertyDeviceUID);
        if (uid.length == 0 || [uid hasPrefix:kAggregatePrefix]) continue;
        UInt32 transport = 0;
        AEGet(dev, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, transport);
        AEOutputDevice *d = [AEOutputDevice new];
        BOOL wireless = NO;
        d.uid = uid;
        d.name = AEGetString(dev, kAudioObjectPropertyName);
        d.transport = AETransportName(transport, &wireless);
        d.isWireless = wireless;
        d.isSystemDefault = [uid isEqualToString:def];
        d.nominalSampleRate = AERate(dev);
        d.outputChannels = ch;
        [out addObject:d];
    }
    return out;
}

+ (nullable NSString *)systemDefaultOutputUID {
    AudioObjectID dev = kAudioObjectUnknown;
    if (AEGet(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal,
              dev) != noErr ||
        dev == kAudioObjectUnknown)
        return nil;
    NSString *uid = AEGetString(dev, kAudioDevicePropertyDeviceUID);
    return uid.length ? uid : nil;
}

- (instancetype)init {
    if ((self = [super init])) {
        _engine = aether_engine_create();
        aether_config cfg;
        aether_config_default(&cfg);
        aether_engine_submit_config(_engine, &cfg);
        _tap = _aggregate = _device = kAudioObjectUnknown;
        _state = AERouteStateStopped;
        _message = @"Stopped";
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        _ticksToSeconds = double(tb.numer) / double(tb.denom) * 1e-9;
        [self installSystemListeners];
    }
    return self;
}

- (void)dealloc {
    [self stop];
    for (Listener &l : _systemListeners)
        AudioObjectRemovePropertyListenerBlock(l.object, &l.address, dispatch_get_main_queue(), l.block);
    aether_engine_destroy(_engine);
}

- (AERouteState)state {
    return _state;
}

// ---- listeners ----

- (void)addListener:(AudioObjectID)obj
           selector:(AudioObjectPropertySelector)sel
              scope:(AudioObjectPropertyScope)scope
               into:(std::vector<Listener> &)list
              block:(void (^)(void))handler {
    Listener l{obj, {sel, scope, kAudioObjectPropertyElementMain}, nil};
    l.block = ^(UInt32, const AudioObjectPropertyAddress *) {
      handler();
    };
    if (AudioObjectAddPropertyListenerBlock(obj, &l.address, dispatch_get_main_queue(), l.block) == noErr)
        list.push_back(l);
}

- (void)installSystemListeners {
    __weak AERoute *weakSelf = self;
    auto changed = ^{
      AERoute *s = weakSelf;
      if (!s) return;
      [s checkDevicePresence];
      [s.delegate routeDevicesDidChange];
    };
    [self addListener:kAudioObjectSystemObject selector:kAudioHardwarePropertyDevices
                scope:kAudioObjectPropertyScopeGlobal into:_systemListeners block:changed];
    [self addListener:kAudioObjectSystemObject selector:kAudioHardwarePropertyDefaultOutputDevice
                scope:kAudioObjectPropertyScopeGlobal into:_systemListeners block:changed];
}

- (void)checkDevicePresence {
    if (_state != AERouteStateRunning || !_deviceUID) return;
    const AudioObjectID dev = AEDeviceForUID(_deviceUID);
    UInt32 alive = 0;
    if (dev == kAudioObjectUnknown ||
        AEGet(dev, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, alive) != noErr || !alive) {
        NSString *name = _deviceName;
        [self stop];
        _message = [NSString stringWithFormat:@"%@ disconnected", name];
        [self.delegate routeDidStopWithReason:_message];
    }
}

- (void)installRouteListeners {
    __weak AERoute *weakSelf = self;
    [self addListener:_device selector:kAudioDevicePropertyDeviceIsAlive scope:kAudioObjectPropertyScopeGlobal
                 into:_routeListeners block:^{ [weakSelf checkDevicePresence]; }];
    auto restart = ^(NSString *why) {
      return ^{
        AERoute *s = weakSelf;
        if (s && s->_state == AERouteStateRunning) [s.delegate routeNeedsRestart:why];
      };
    };
    [self addListener:_device selector:kAudioDevicePropertyNominalSampleRate scope:kAudioObjectPropertyScopeGlobal
                 into:_routeListeners block:restart(@"Output sample rate changed")];
    [self addListener:_tap selector:kAudioTapPropertyFormat scope:kAudioObjectPropertyScopeGlobal
                 into:_routeListeners block:restart(@"System audio format changed")];
    [self addListener:_aggregate selector:kAudioDeviceProcessorOverload scope:kAudioObjectPropertyScopeGlobal
                 into:_routeListeners block:^{
                   AERoute *s = weakSelf;
                   if (s) s->_overloads += 1;
                 }];
}

// ---- lifecycle ----

- (BOOL)fail:(NSString *)message code:(NSInteger)code error:(NSError **)error {
    [self teardown];
    _state = AERouteStateFailed;
    _message = message;
    if (error) *error = AEError(code, message);
    return NO;
}

- (BOOL)startWithOutputUID:(NSString *)uid error:(NSError **)error {
    [self stop];

    _device = AEDeviceForUID(uid);
    if (_device == kAudioObjectUnknown) return [self fail:@"The selected output device is not connected." code:1 error:error];
    if (AEChannelCount(_device, kAudioObjectPropertyScopeOutput) < 2)
        return [self fail:@"Aether needs a stereo output device." code:2 error:error];
    pid_t hog = -1;
    if (AEGet(_device, kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeOutput, hog) == noErr && hog != -1 &&
        hog != getpid())
        return [self fail:[NSString stringWithFormat:@"Another app (pid %d) is using this device exclusively, so "
                                                     @"Aether cannot render to it.", hog]
                     code:3 error:error];

    _deviceUID = [uid copy];
    _deviceName = AEGetString(_device, kAudioObjectPropertyName);
    UInt32 transport = 0;
    AEGet(_device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, transport);
    _deviceTransport = AETransportName(transport, &_deviceWireless);
    _physicalFormat = AEPhysicalFormat(_device);
    _deviceChannels = AEChannelCount(_device, kAudioObjectPropertyScopeOutput);

    // 1. Private process tap of all system audio except Aether itself, muted at the
    //    original destination only while Aether is reading it.
    AudioObjectID selfObject = kAudioObjectUnknown;
    {
        AudioObjectPropertyAddress addr{kAudioHardwarePropertyTranslatePIDToProcessObject,
                                        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        pid_t pid = getpid();
        UInt32 size = sizeof selfObject;
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, sizeof pid, &pid, &size, &selfObject);
    }
    NSArray<NSNumber *> *exclude = selfObject != kAudioObjectUnknown ? @[ @(selfObject) ] : @[];
    CATapDescription *desc = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:exclude];
    desc.name = @"Aether system audio";
    desc.UUID = [NSUUID UUID];
    desc.privateTap = YES;
    desc.muteBehavior = CATapMutedWhenTapped;
    OSStatus st = AudioHardwareCreateProcessTap(desc, &_tap);
    if (st != noErr || _tap == kAudioObjectUnknown) {
        _tap = kAudioObjectUnknown;
        return [self fail:[NSString stringWithFormat:@"macOS refused to create the system-audio tap (%@). Aether needs "
                                                     @"macOS 14.4 or later and permission under Privacy & Security → "
                                                     @"Screen & System Audio Recording.", AEStatusString(st)]
                     code:4 error:error];
    }
    AudioStreamBasicDescription tapFormat{};
    AEGet(_tap, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, tapFormat);
    _tapRate = tapFormat.mSampleRate;
    _tapChannels = tapFormat.mChannelsPerFrame;

    // 2. Private aggregate: the DAC is the clock (main) device; the tap is drift-compensated.
    NSString *aggUID = [kAggregatePrefix stringByAppendingString:[NSUUID UUID].UUIDString];
    NSDictionary *composition = @{
        @kAudioAggregateDeviceNameKey : @"Aether Route",
        @kAudioAggregateDeviceUIDKey : aggUID,
        @kAudioAggregateDeviceMainSubDeviceKey : uid,
        @kAudioAggregateDeviceIsPrivateKey : @YES,
        @kAudioAggregateDeviceIsStackedKey : @NO,
        @kAudioAggregateDeviceTapAutoStartKey : @NO,
        @kAudioAggregateDeviceSubDeviceListKey : @[ @{@kAudioSubDeviceUIDKey : uid} ],
        @kAudioAggregateDeviceTapListKey : @[ @{
            @kAudioSubTapUIDKey : desc.UUID.UUIDString,
            @kAudioSubTapDriftCompensationKey : @YES,
        } ],
    };
    st = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition, &_aggregate);
    if (st != noErr || _aggregate == kAudioObjectUnknown) {
        _aggregate = kAudioObjectUnknown;
        return [self fail:[NSString stringWithFormat:@"Could not build the audio route (%@).", AEStatusString(st)]
                     code:5 error:error];
    }

    // 3. Formats and channel mapping.
    _routeRate = AERate(_aggregate);
    if (_routeRate <= 0) _routeRate = AERate(_device);
    for (AudioObjectID s : AEGetIDs(_aggregate, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)) {
        AudioStreamBasicDescription v{};
        AEGet(s, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, v);
        if (v.mFormatID != kAudioFormatLinearPCM || !(v.mFormatFlags & kAudioFormatFlagIsFloat) || v.mBitsPerChannel != 32)
            return [self fail:@"The output device does not offer a 32-bit float stream." code:6 error:error];
    }
    const auto inStreams = AEGetIDs(_aggregate, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);
    UInt32 tapBuffers = 1;
    if (!inStreams.empty()) {
        AudioStreamBasicDescription v{};
        AEGet(inStreams.back(), kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, v);
        if (v.mFormatFlags & kAudioFormatFlagIsNonInterleaved) tapBuffers = std::max<UInt32>(1, v.mChannelsPerFrame);
    }
    const std::vector<UInt32> outBuffers = AEBufferChannels(_aggregate, kAudioObjectPropertyScopeOutput);
    UInt32 stereo[2] = {1, 2};
    {
        AudioObjectPropertyAddress addr{kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput,
                                        kAudioObjectPropertyElementMain};
        UInt32 size = sizeof stereo;
        if (AudioObjectGetPropertyData(_device, &addr, 0, nullptr, &size, stereo) != noErr || stereo[0] == 0 ||
            stereo[1] == 0 || stereo[0] > _deviceChannels || stereo[1] > _deviceChannels) {
            stereo[0] = 1;
            stereo[1] = 2;
        }
    }
    _leftChannel = stereo[0];
    _rightChannel = stereo[1];
    auto locate = [&](UInt32 channel, int &buf, int &off) {
        UInt32 base = 0;
        for (size_t b = 0; b < outBuffers.size(); ++b) {
            if (channel >= base + 1 && channel <= base + outBuffers[b]) {
                buf = int(b);
                off = int(channel - base - 1);
                return true;
            }
            base += outBuffers[b];
        }
        return false;
    };

    _rt = new RTContext;
    _rt->engine = _engine;
    _rt->tapBuffers = tapBuffers;
    _rt->sampleRate = _routeRate;
    _rt->ticksToSeconds = _ticksToSeconds;
    if (!locate(stereo[0], _rt->outBufL, _rt->outOffL) || !locate(stereo[1], _rt->outBufR, _rt->outOffR))
        return [self fail:@"Could not map the device's stereo channels." code:7 error:error];

    // 4. Prepare the DSP for this rate (rebuilds the active filter bank) before audio starts.
    if (aether_engine_prepare(_engine, _routeRate) != AETHER_OK)
        return [self fail:[NSString stringWithFormat:@"Unsupported sample rate %.0f Hz.", _routeRate] code:8 error:error];

    AEGet(_aggregate, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, _bufferFrames);
    {
        UInt32 lat = 0, safety = 0, streamLat = 0;
        AEGet(_device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, lat);
        AEGet(_device, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, safety);
        const auto outStreams = AEGetIDs(_device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
        if (!outStreams.empty()) AEGet(outStreams[0], kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, streamLat);
        _deviceLatency = lat + safety + streamLat;
    }

    // 5. Start.
    st = AudioDeviceCreateIOProcID(_aggregate, AetherIOProc, _rt, &_procID);
    if (st != noErr || !_procID) {
        _procID = nullptr;
        return [self fail:[NSString stringWithFormat:@"Could not attach the audio callback (%@).", AEStatusString(st)]
                     code:9 error:error];
    }
    st = AudioDeviceStart(_aggregate, _procID);
    if (st != noErr)
        return [self fail:[NSString stringWithFormat:@"The audio route did not start (%@).", AEStatusString(st)]
                     code:10 error:error];

    [self installRouteListeners];
    _overloads = 0;
    _state = AERouteStateRunning;
    _message = @"Running";
    return YES;
}

- (void)teardown {
    for (Listener &l : _routeListeners)
        AudioObjectRemovePropertyListenerBlock(l.object, &l.address, dispatch_get_main_queue(), l.block);
    _routeListeners.clear();
    if (_aggregate != kAudioObjectUnknown && _procID) {
        AudioDeviceStop(_aggregate, _procID);
        AudioDeviceDestroyIOProcID(_aggregate, _procID);
    }
    _procID = nullptr;
    if (_aggregate != kAudioObjectUnknown) AudioHardwareDestroyAggregateDevice(_aggregate);
    _aggregate = kAudioObjectUnknown;
    if (_tap != kAudioObjectUnknown) AudioHardwareDestroyProcessTap(_tap);
    _tap = kAudioObjectUnknown;
    delete _rt; // safe: the IOProc has been stopped and destroyed above
    _rt = nullptr;
}

- (void)stop {
    if (_state == AERouteStateStopped && !_rt && _tap == kAudioObjectUnknown && _aggregate == kAudioObjectUnknown) return;
    [self teardown];
    _state = AERouteStateStopped;
    _message = @"Stopped";
}

// ---- DSP control & telemetry ----

- (int)submitConfig:(const aether_config *)config {
    return aether_engine_submit_config(_engine, config);
}

- (aether_meters)readMetersReset:(BOOL)reset {
    aether_meters m;
    aether_engine_read_meters(_engine, &m, reset ? 1 : 0);
    return m;
}

- (aether_engine_info)engineInfo {
    aether_engine_info info;
    aether_engine_get_info(_engine, &info);
    return info;
}

- (AERouteSnapshot *)snapshot {
    AERouteSnapshot *s = [AERouteSnapshot new];
    s.state = _state;
    s.message = _message ?: @"";
    s.tapSampleRate = _tapRate;
    s.tapChannels = _tapChannels;
    s.routeSampleRate = _routeRate;
    s.tapRateConverted = _tapRate > 0 && _routeRate > 0 && std::fabs(_tapRate - _routeRate) > 0.5;
    s.deviceUID = _deviceUID ?: @"";
    s.deviceName = _deviceName ?: @"";
    s.deviceTransport = _deviceTransport ?: @"";
    s.deviceIsWireless = _deviceWireless;
    s.physicalFormat = _physicalFormat ?: @"—";
    s.deviceChannels = _deviceChannels;
    s.leftChannel = _leftChannel;
    s.rightChannel = _rightChannel;
    s.bufferFrames = _bufferFrames;
    s.deviceLatencyFrames = _deviceLatency;
    s.dspLatencyFrames = aether_engine_latency_frames(_engine);
    s.estimatedAddedLatencyMs =
        _routeRate > 0 ? 1000.0 * double(s.dspLatencyFrames + _bufferFrames) / _routeRate : 0;
    s.overloads = _overloads;
    if (_rt) {
        s.callbacks = _rt->callbacks.load(std::memory_order_relaxed);
        s.tapMissing = _rt->tapMissing.load(std::memory_order_relaxed);
        s.loadAverage = AEBitsToFloat(_rt->loadAvgBits.load(std::memory_order_relaxed));
        s.loadPeak = AEBitsToFloat(_rt->loadPeakBits.exchange(0, std::memory_order_relaxed));
        const uint64_t last = _rt->lastHostTime.load(std::memory_order_relaxed);
        s.secondsSinceLastCallback = last ? double(mach_absolute_time() - last) * _ticksToSeconds : 1e9;
    } else {
        s.secondsSinceLastCallback = 1e9;
    }
    if (_device != kAudioObjectUnknown) {
        pid_t hog = -1;
        if (AEGet(_device, kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeOutput, hog) == noErr)
            s.deviceHoggedByOtherProcess = hog != -1 && hog != getpid();
    }
    AudioObjectID def = kAudioObjectUnknown;
    if (AEGet(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal,
              def) == noErr && def != kAudioObjectUnknown)
        s.systemDefaultOutputName = AEGetString(def, kAudioObjectPropertyName);
    else
        s.systemDefaultOutputName = @"";
    return s;
}

@end
