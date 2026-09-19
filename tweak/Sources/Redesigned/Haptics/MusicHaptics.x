// Vibrations > Music Haptics: the Taptic Engine playing along with the song, taps on the drums and a
// rumble under the bass, the way Apple Music's Music Haptics feels, worked out live from the sound.
//
// Spotify plays through Core Audio units of its own (AudioUnitDriver2 in the binary: converter, EQ, mixer
// and a RemoteIO output unit, started with AudioOutputUnitStart(_outputUnit)), with no Objective-C
// method between it and the unit. So Spotify's import of AudioOutputUnitStart is rebound
// (Core/SGRebind.h), and every RemoteIO unit it starts gets a render notify: after each render, the
// buffer bound for the speaker is mixed to mono and handed to the analyzer (SGRMusicAnalyzer.h) on
// the render thread, which puts what it hears into a ring of events. The render timestamp says when
// that buffer reaches the output; AVAudioSession's output latency (large over Bluetooth) is added, so
// a tap lands when its drum is heard. A thread of this file's own takes the events off the ring and
// schedules them with Core Haptics at those times: each hit a transient, the rumble one looping
// continuous event whose intensity follows the level.
//
// The rebinding and the notify are in place while Redesigned UI is on, so the switch works at once;
// with the switch off the notify returns straight away. Listening is tied to Spotify's output rather
// than UIApplication active state, so playback can continue to drive haptics after the screen locks.
// Sound that is not Spotify's own output (Connect, AirPlay to another device, video) never passes the
// unit, and plays no haptics.
//
// Threading: the notify runs on the render thread and only touches atomics, the analyzer and the
// ring; the Core Haptics objects belong to the player thread; the switch and the app's state are set
// on the main thread.
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreHaptics/CoreHaptics.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <stdatomic.h>
#import "Core/SGCore.h"
#import "Core/SGRebind.h"
#import "Haptics.h"
#import "SGRMusicAnalyzer.h"

// Core Haptics takes about this long from a scheduled time to the Taptic Engine's peak.
static const double kHapticLead = 0.012;
// A tap this late is left out rather than played off the beat.
static const double kLatestTap = 0.05;
// Feed Core Haptics above its normalized range so every analyzer event reaches the strongest value
// Core Haptics accepts after MIN(1, ...). Quiet events still remain quiet through their source level.
static const float kTapGain = 2.0f, kRumbleGain = 2.0f;
// The rumble starts over this level and stops once it has stayed under the other this long.
static const float kRumbleStart = 0.05f, kRumbleStop = 0.02f;
static const double kRumbleStopAfter = 0.3;
// A level closer than this to the last one sent is skipped, unless it moved by more than kRumbleStep.
static const double kRumbleInterval = 0.025;
static const float kRumbleStep = 0.08f;
static const NSTimeInterval kRumbleLength = 30;
// Without events for this long, or for this many IO buffers if that is longer, the rumble goes quiet (the
// output stopped rendering), and after the longer wait the engine is stopped.
static const double kQuietAfter = 0.1, kQuietAfterBuffers = 2.5, kEngineStopAfter = 5;
// An engine that would not start is not asked again for this long.
static const double kStartRetryAfter = 2;

enum { kRingSize = 1024, kMonoFrames = 4096 };

#pragma mark - shared between the threads

static atomic_bool sg_enabled, sg_listening;
static atomic_uint sg_generation;
static atomic_uint_fast64_t sg_latencyBits;
static atomic_uint sg_formatFlags, sg_lastFrames;
static atomic_uint_fast64_t sg_sampleRateBits;

static SGRMusicEvent sg_ring[kRingSize];
static atomic_uint sg_head, sg_tail;   // head moved by the render thread, tail by the player thread
static dispatch_semaphore_t sg_wake;

static double sg_secondsPerTick;

static void storeDouble(atomic_uint_fast64_t *slot, double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof bits);
    atomic_store(slot, bits);
}

static double loadDouble(atomic_uint_fast64_t *slot) {
    uint64_t bits = atomic_load(slot);
    double value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

#pragma mark - the render thread

static SGRMusicAnalyzer sg_analyzer;
static float sg_mono[kMonoFrames];

static void pushEvent(const SGRMusicEvent *event, void *context) {
    unsigned head = atomic_load_explicit(&sg_head, memory_order_relaxed);
    unsigned tail = atomic_load_explicit(&sg_tail, memory_order_relaxed);
    if (head - tail >= kRingSize) return;
    sg_ring[head & (kRingSize - 1)] = *event;
    atomic_store_explicit(&sg_head, head + 1, memory_order_relaxed);
}

static inline float sampleAt(const AudioBuffer *buffer, UInt32 index, UInt32 bytes, BOOL isFloat, UInt32 fraction) {
    const void *data = buffer->mData;
    if (bytes == 4) {
        if (isFloat) return ((const float *)data)[index];
        int32_t value = ((const int32_t *)data)[index];
        return fraction ? (float)((double)value / (double)(1u << fraction)) : (float)(value / 2147483648.0);
    }
    if (bytes == 2) return ((const int16_t *)data)[index] / 32768.0f;
    if (bytes == 8 && isFloat) return (float)((const double *)data)[index];
    return 0;
}

// Spotify's own format is float, non-interleaved stereo coming out of its EQ, but the unit's format is
// read rather than assumed: what the buffers look like decides how they are read.
static OSStatus rendered(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                         UInt32 frames, AudioBufferList *data) {
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || !data || !data->mNumberBuffers || !frames) return noErr;
    if (!atomic_load_explicit(&sg_listening, memory_order_relaxed)) return noErr;
    if (*flags & kAudioUnitRenderAction_OutputIsSilence) return noErr;

    double sampleRate = loadDouble(&sg_sampleRateBits);
    static double analyzedRate;
    static unsigned analyzedGeneration;
    unsigned generation = atomic_load_explicit(&sg_generation, memory_order_relaxed);
    if (sampleRate <= 0) return noErr;
    if (sampleRate != analyzedRate || generation != analyzedGeneration) {
        SGRMusicAnalyzerReset(&sg_analyzer, sampleRate, 1 / sg_secondsPerTick);
        analyzedRate = sampleRate;
        analyzedGeneration = generation;
    }
    atomic_store_explicit(&sg_lastFrames, frames, memory_order_relaxed);

    UInt32 formatFlags = atomic_load_explicit(&sg_formatFlags, memory_order_relaxed);
    BOOL isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0;
    UInt32 fraction = (formatFlags & kLinearPCMFormatFlagsSampleFractionMask) >> kLinearPCMFormatFlagsSampleFractionShift;
    const AudioBuffer *first = &data->mBuffers[0];
    BOOL split = data->mNumberBuffers > 1;
    UInt32 channels = split ? 1 : MAX(first->mNumberChannels, 1u);
    if (!first->mData || first->mDataByteSize < frames * channels) return noErr;
    UInt32 bytes = first->mDataByteSize / (frames * channels);
    const AudioBuffer *second = split && data->mBuffers[1].mData && data->mBuffers[1].mDataByteSize >= frames * bytes ? &data->mBuffers[1] : NULL;

    uint64_t hostTime = (timestamp->mFlags & kAudioTimeStampHostTimeValid) ? timestamp->mHostTime : mach_absolute_time();
    unsigned headBefore = atomic_load_explicit(&sg_head, memory_order_relaxed);
    for (UInt32 done = 0; done < frames;) {
        UInt32 count = MIN(frames - done, (UInt32)kMonoFrames);
        for (UInt32 i = 0; i < count; i++) {
            UInt32 frame = done + i;
            float left, right;
            if (split) {
                left = sampleAt(first, frame, bytes, isFloat, fraction);
                right = second ? sampleAt(second, frame, bytes, isFloat, fraction) : left;
            } else {
                left = sampleAt(first, frame * channels, bytes, isFloat, fraction);
                right = channels > 1 ? sampleAt(first, frame * channels + 1, bytes, isFloat, fraction) : left;
            }
            sg_mono[i] = 0.5f * (left + right);
        }
        uint64_t chunkTime = hostTime + (uint64_t)(done / sampleRate / sg_secondsPerTick);
        SGRMusicAnalyzerProcess(&sg_analyzer, sg_mono, count, chunkTime, pushEvent, NULL);
        done += count;
    }
    if (atomic_load_explicit(&sg_head, memory_order_relaxed) != headBefore) dispatch_semaphore_signal(sg_wake);
    return noErr;
}

#pragma mark - the output unit

static OSStatus (*sg_startOutput)(AudioUnit unit);

static NSString *fourCC(UInt32 code) {
    char text[5] = {(char)(code >> 24), (char)(code >> 16), (char)(code >> 8), (char)code, 0};
    return @(text);
}

static void listenTo(AudioUnit unit) {
    AudioComponentDescription description = {0};
    if (AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit), &description) != noErr) return;
    static int logged;
    if (description.componentType != kAudioUnitType_Output || description.componentSubType != kAudioUnitSubType_RemoteIO) {
        if (logged++ < 8) SGLog(@"music haptics: a started unit is not RemoteIO ('%@' '%@'), not listened to", fourCC(description.componentType), fourCC(description.componentSubType));
        return;
    }
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof(format);
    OSStatus status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, &size);
    if (status != noErr || format.mFormatID != kAudioFormatLinearPCM || format.mSampleRate <= 0) {
        if (logged++ < 8) SGLog(@"music haptics: the output's format is not linear PCM (%d, '%@'), not listened to", (int)status, fourCC(format.mFormatID));
        return;
    }
    atomic_store(&sg_formatFlags, format.mFormatFlags);
    storeDouble(&sg_sampleRateBits, format.mSampleRate);
    AudioUnitRemoveRenderNotify(unit, rendered, NULL);
    status = AudioUnitAddRenderNotify(unit, rendered, NULL);
    if (logged++ < 8) SGLog(@"music haptics: listening to Spotify's output, %.0f Hz, %u channels, %u bits, flags 0x%x (status %d)", format.mSampleRate, (unsigned)format.mChannelsPerFrame, (unsigned)format.mBitsPerChannel, (unsigned)format.mFormatFlags, (int)status);
}

static OSStatus startOutput(AudioUnit unit) {
    if (unit) listenTo(unit);
    return sg_startOutput(unit);
}

#pragma mark - the player thread

static CHHapticEngine *sg_engine;
static BOOL sg_engineRunning;
static atomic_bool sg_engineStopped;
static id<CHHapticAdvancedPatternPlayer> sg_rumble;
static BOOL sg_rumbling;
static double sg_rumbleSentAt, sg_quietSince;
static float sg_rumbleSent;

// Core Haptics can stop or reset while iOS moves Spotify between the foreground and its
// lock-screen audio state.  Only the player thread touches the engine; these callbacks merely
// mark it stale and wake that thread so it can tear down and start a fresh session safely.
static void requestEngineRestart(void) {
    atomic_store_explicit(&sg_engineStopped, true, memory_order_relaxed);
    if (sg_wake) dispatch_semaphore_signal(sg_wake);
}

typedef struct {
    NSUInteger taps, late, levels;
    double leadSum, leadMin;
} Stats;
static Stats sg_stats;

static void stopEngine(void);

static double hostSeconds(uint64_t ticks) {
    return ticks * sg_secondsPerTick;
}

static BOOL startEngine(void) {
    static BOOL supported, checked;
    static double retryAt;
    if (!checked) {
        checked = YES;
        supported = CHHapticEngine.capabilitiesForHardware.supportsHaptics;
        if (!supported) SGLog(@"music haptics: this device has no Taptic Engine for Core Haptics");
    }
    if (!supported) return NO;
    NSError *error = nil;
    if (!sg_engine) {
        // Attach to Spotify's already-active playback session.  A standalone engine can compete
        // with Spotify's audio session during the lock-screen transition and interrupt playback.
        sg_engine = [[CHHapticEngine alloc] initWithAudioSession:AVAudioSession.sharedInstance error:&error];
        if (!sg_engine) {
            SGLog(@"music haptics: no haptic engine: %@", error);
            return NO;
        }
        sg_engine.playsHapticsOnly = YES;
        sg_engine.autoShutdownEnabled = NO;
        sg_engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
            requestEngineRestart();
            SGLog(@"music haptics: the engine stopped (reason %ld)", (long)reason);
        };
        sg_engine.resetHandler = ^{
            requestEngineRestart();
            SGLog(@"music haptics: the engine was reset");
        };
    }
    if (atomic_exchange(&sg_engineStopped, false)) {
        stopEngine();
        retryAt = 0;
    }
    if (sg_engineRunning) return YES;
    double now = hostSeconds(mach_absolute_time());
    if (now < retryAt) return NO;
    if (![sg_engine startAndReturnError:&error]) {
        retryAt = now + kStartRetryAfter;
        static int logged;
        if (logged++ < 3) SGLog(@"music haptics: the engine did not start: %@", error);
        return NO;
    }
    sg_engineRunning = YES;
    return YES;
}

static void stopEngine(void) {
    [sg_rumble stopAtTime:CHHapticTimeImmediate error:nil];
    sg_rumble = nil;
    sg_rumbling = NO;
    if (sg_engineRunning) [sg_engine stopWithCompletionHandler:nil];
    sg_engineRunning = NO;
}

// When `hostTime`'s sound is heard, in the engine's clock; `lead` is how far ahead of now that is.
static NSTimeInterval engineTime(uint64_t hostTime, double *lead) {
    double now = hostSeconds(mach_absolute_time());
    double heard = hostSeconds(hostTime) + loadDouble(&sg_latencyBits) - kHapticLead;
    *lead = heard - now;
    return sg_engine.currentTime + MAX(0, *lead);
}

static CHHapticEventParameter *parameter(CHHapticEventParameterID identifier, float value) {
    return [[CHHapticEventParameter alloc] initWithParameterID:identifier value:value];
}

static void playTap(const SGRMusicEvent *event) {
    double lead;
    NSTimeInterval at = engineTime(event->hostTime, &lead);
    if (lead < -kLatestTap) {
        sg_stats.late++;
        return;
    }
    CHHapticEvent *hit = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient parameters:@[
        parameter(CHHapticEventParameterIDHapticIntensity, MIN(1, event->intensity * kTapGain)),
        parameter(CHHapticEventParameterIDHapticSharpness, event->sharpness),
    ] relativeTime:0];
    NSError *error = nil;
    CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[hit] parameters:@[] error:&error];
    id<CHHapticPatternPlayer> player = pattern ? [sg_engine createPlayerWithPattern:pattern error:&error] : nil;
    if (!player || ![player startAtTime:at error:&error]) {
        static int logged;
        if (logged++ < 3) SGLog(@"music haptics: a tap did not play: %@", error);
        if (error.code == CHHapticErrorCodeEngineNotRunning || error.code == CHHapticErrorCodeServerInterrupted) requestEngineRestart();
        return;
    }
    sg_stats.taps++;
    sg_stats.leadSum += lead;
    sg_stats.leadMin = sg_stats.taps == 1 ? lead : MIN(sg_stats.leadMin, lead);
}

static void stopRumble(NSTimeInterval at) {
    if (!sg_rumbling) return;
    [sg_rumble stopAtTime:at error:nil];
    sg_rumbling = NO;
}

static void playLevel(const SGRMusicEvent *event) {
    sg_stats.levels++;
    double lead;
    NSTimeInterval at = engineTime(event->hostTime, &lead);
    double heard = hostSeconds(event->hostTime);
    float level = MIN(1, event->intensity * kRumbleGain);

    if (level < kRumbleStop) {
        if (!sg_quietSince) sg_quietSince = heard;
        if (heard - sg_quietSince >= kRumbleStopAfter) stopRumble(at);
    } else {
        sg_quietSince = 0;
    }
    if (!sg_rumbling && level < kRumbleStart) return;
    if (sg_rumbling && heard - sg_rumbleSentAt < kRumbleInterval && fabsf(level - sg_rumbleSent) < kRumbleStep) return;

    NSError *error = nil;
    if (!sg_rumble) {
        // Sharpness 0 under a control that adds the level's own.
        CHHapticEvent *hum = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
            parameter(CHHapticEventParameterIDHapticIntensity, 1),
            parameter(CHHapticEventParameterIDHapticSharpness, 0),
        ] relativeTime:0 duration:kRumbleLength];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[hum] parameters:@[] error:&error];
        sg_rumble = pattern ? [sg_engine createAdvancedPlayerWithPattern:pattern error:&error] : nil;
        sg_rumble.loopEnabled = YES;
        if (!sg_rumble) {
            static int logged;
            if (logged++ < 3) SGLog(@"music haptics: no rumble: %@", error);
            return;
        }
    }
    NSArray<CHHapticDynamicParameter *> *controls = @[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:level relativeTime:0],
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:event->sharpness relativeTime:0],
    ];
    if (!sg_rumbling) {
        [sg_rumble sendParameters:controls atTime:CHHapticTimeImmediate error:nil];
        if (![sg_rumble startAtTime:at error:&error]) {
            static int logged;
            if (logged++ < 3) SGLog(@"music haptics: the rumble did not start: %@", error);
            sg_rumble = nil;
            return;
        }
        sg_rumbling = YES;
    } else {
        [sg_rumble sendParameters:controls atTime:at error:nil];
    }
    sg_rumbleSentAt = heard;
    sg_rumbleSent = level;
}

static void report(void) {
    static double lastReport;
    static int reports;
    double now = hostSeconds(mach_absolute_time());
    if (!lastReport) lastReport = now;
    if (now - lastReport < 30 || reports >= 4 || !sg_stats.levels) return;
    lastReport = now;
    reports++;
    SGLog(@"music haptics: %lu taps (%lu too late), lead %.0f ms on average and %.0f ms at the least, %lu levels, rumble %@, buffers of %u frames, output latency %.0f ms",
          (unsigned long)sg_stats.taps, (unsigned long)sg_stats.late, sg_stats.taps ? sg_stats.leadSum / sg_stats.taps * 1000 : 0, sg_stats.leadMin * 1000,
          (unsigned long)sg_stats.levels, sg_rumbling ? @"on" : @"off", atomic_load(&sg_lastFrames), loadDouble(&sg_latencyBits) * 1000);
    sg_stats = (Stats){0};
}

static double quietAfter(void) {
    double rate = loadDouble(&sg_sampleRateBits);
    double buffer = rate > 0 ? atomic_load(&sg_lastFrames) / rate : 0;
    return MAX(kQuietAfter, kQuietAfterBuffers * buffer);
}

static void *playerLoop(void *unused) {
    pthread_setname_np("spotifyglass.music-haptics");
    double lastEvent = 0;
    BOOL idle = YES;
    for (;;) {
        dispatch_time_t wait = idle ? DISPATCH_TIME_FOREVER
                                    : dispatch_time(DISPATCH_TIME_NOW, (int64_t)(quietAfter() * NSEC_PER_SEC));
        dispatch_semaphore_wait(sg_wake, wait);
        @autoreleasepool {
            double now = hostSeconds(mach_absolute_time());
            if (!atomic_load(&sg_listening)) {
                atomic_store(&sg_tail, atomic_load(&sg_head));
                stopEngine();
                idle = YES;
                continue;
            }
            BOOL any = NO;
            unsigned head = atomic_load(&sg_head), tail = atomic_load(&sg_tail);
            // A stopped/reset engine must be rearmed even if the render callback has not queued a
            // new event yet.  This is what makes a screen-lock transition recover without opening
            // Spotify again.
            if ((tail != head || atomic_load_explicit(&sg_engineStopped, memory_order_relaxed)) && startEngine()) {
                for (; tail != head; tail++) {
                    SGRMusicEvent event = sg_ring[tail & (kRingSize - 1)];
                    if (event.kind == SGRMusicEventTap) playTap(&event);
                    else playLevel(&event);
                }
                any = YES;
            }
            atomic_store(&sg_tail, head);
            if (any) {
                lastEvent = now;
                idle = NO;
                report();
                continue;
            }
            if (now - lastEvent >= quietAfter()) stopRumble(CHHapticTimeImmediate);
            if (now - lastEvent >= kEngineStopAfter) {
                stopEngine();
                idle = YES;
            }
        }
    }
    return NULL;
}

#pragma mark - the switch and the app

static void readLatency(void) {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    storeDouble(&sg_latencyBits, session.outputLatency);
    static int logged;
    if (logged++ < 6) SGLog(@"music haptics: output latency %.0f ms, IO buffer %.0f ms, route %@", session.outputLatency * 1000, session.IOBufferDuration * 1000, session.currentRoute.outputs.firstObject.portType);
}

static void updateListening(void) {
    // The RemoteIO render notify is only installed on Spotify's own output unit. Do not gate it on
    // UIApplication active state: Spotify keeps audio alive under the lock screen and the haptic
    // engine can follow that render stream too.
    BOOL listening = atomic_load(&sg_enabled);
    if (atomic_exchange(&sg_listening, listening) == listening) return;
    if (listening) {
        atomic_fetch_add(&sg_generation, 1);
        readLatency();
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            pthread_attr_t attributes;
            pthread_attr_init(&attributes);
            pthread_attr_set_qos_class_np(&attributes, QOS_CLASS_USER_INTERACTIVE, 0);
            pthread_t thread;
            pthread_create(&thread, &attributes, playerLoop, NULL);
            pthread_attr_destroy(&attributes);
        });
    }
    dispatch_semaphore_signal(sg_wake);
}

void SGRSetMusicHapticsEnabled(BOOL on) {
    if (!SGRedesignedUI() || !sg_wake) return;
    atomic_store(&sg_enabled, on);
    updateListening();
}

%ctor {
    if (!SGRedesignedUI()) return;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    sg_secondsPerTick = (double)timebase.numer / timebase.denom / 1e9;
    if (!SGRebindImport("AudioOutputUnitStart", startOutput, (void **)&sg_startOutput) || !sg_startOutput) {
        SGLog(@"music haptics: Spotify does not import AudioOutputUnitStart, Music Haptics is inactive");
        return;
    }
    sg_wake = dispatch_semaphore_create(0);
    atomic_store(&sg_enabled, SGFlag(SGRKeyMusicHaptics, NO));
    atomic_store(&sg_listening, false);
    updateListening();
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        if (atomic_load(&sg_listening)) {
            readLatency();
            requestEngineRestart();
        }
    }];
    [center addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        requestEngineRestart();
        NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
        if (type.integerValue == AVAudioSessionInterruptionTypeEnded) {
            // Give Spotify's playback session a moment to become active again before the retry.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ requestEngineRestart(); });
        }
    }];
    [center addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        requestEngineRestart();
    }];
    [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        requestEngineRestart();
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        requestEngineRestart();
    }];
}
