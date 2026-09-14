#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C wrapper around a NeuralAmpModelerCore `nam::DSP` model.
/// Import this from Swift via the bridging header (see docs/setup-ios.md, M2).
///
/// Threading contract:
///   - `loadModelFromPath:error:` and `prepareWithSampleRate:maxBlockSize:` allocate and
///     prewarm the model, so they MUST be called OFF the audio render thread (during setup).
///   - `processInput:output:frames:` is the ONLY method safe to call on the audio thread;
///     once prepared it performs no allocation.
@interface NAMModel : NSObject

/// Load a `.nam` model file. Returns NO and fills `error` on failure (unsupported version, bad file…).
- (BOOL)loadModelFromPath:(NSString *)path error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(loadModel(fromPath:));

/// Allocate scratch buffers and reset/prewarm the model. Call after loading, off the audio thread.
/// `maxBlockSize` MUST be >= the largest render block ever passed to `processInput:`.
- (void)prepareWithSampleRate:(double)sampleRate maxBlockSize:(int)maxBlockSize
    NS_SWIFT_NAME(prepare(withSampleRate:maxBlockSize:));

/// Process one mono block. Real-time safe once prepared. `input` and `output` may alias.
/// If the model isn't ready (or `frames` exceeds maxBlockSize) the input is passed through clean.
- (void)processInput:(const float *)input output:(float *)output frames:(int)frames
    NS_SWIFT_NAME(process(input:output:frames:));

/// YES once a model is successfully loaded.
@property (nonatomic, readonly, getter=isLoaded) BOOL loaded;

/// The sample rate the loaded model expects (commonly 48000), or -1 if unknown.
@property (nonatomic, readonly) double expectedSampleRate;

/// Trainer-measured loudness (dB) for a standardized input, or NAN if the file lacks it.
/// Use it to level-match models without amplifying their noise floor.
@property (nonatomic, readonly) double loudness;

/// Calibrated input level (dBu RMS ≙ 0 dBFS peak @ 1 kHz), or NAN if unknown.
@property (nonatomic, readonly) double inputLevelDbu;

/// Calibrated output level (dBu), or NAN if unknown.
@property (nonatomic, readonly) double outputLevelDbu;

@end

NS_ASSUME_NONNULL_END
