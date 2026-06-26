#import "NAMModel.h"

#include <exception>
#include <filesystem>
#include <memory>
#include <vector>

// NAM's C++ headers use NO/YES as enum identifiers (nam::Supported), which collide with
// Objective-C's YES/NO macros in this .mm. Undef around the engine includes, then restore
// them (this file still uses YES/NO below in its BOOL returns).
#pragma push_macro("YES")
#pragma push_macro("NO")
#undef YES
#undef NO
#include "dsp.h"     // nam::DSP, NAM_SAMPLE
#include "get_dsp.h" // nam::get_dsp
#pragma pop_macro("NO")
#pragma pop_macro("YES")

@implementation NAMModel {
  std::unique_ptr<nam::DSP> _model;
  std::vector<NAM_SAMPLE> _inScratch;  // float(CoreAudio) -> NAM_SAMPLE staging
  std::vector<NAM_SAMPLE> _outScratch; // NAM_SAMPLE -> float staging
  int _maxBlockSize;
}

- (instancetype)init {
  if ((self = [super init])) {
    _maxBlockSize = 0;
  }
  return self;
}

- (BOOL)loadModelFromPath:(NSString *)path error:(NSError *_Nullable *_Nullable)error {
  try {
    std::filesystem::path p{path.UTF8String};
    _model = nam::get_dsp(p); // throws std::exception on failure
  } catch (const std::exception &e) {
    _model.reset();
    if (error) {
      *error = [NSError errorWithDomain:@"NAMModel"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey : @(e.what())}];
    }
    return NO;
  }
  return _model != nullptr;
}

- (void)prepareWithSampleRate:(double)sampleRate maxBlockSize:(int)maxBlockSize {
  if (!_model) return;
  _maxBlockSize = maxBlockSize;
  _inScratch.assign((size_t)maxBlockSize, (NAM_SAMPLE)0);
  _outScratch.assign((size_t)maxBlockSize, (NAM_SAMPLE)0);
  // Reset() updates SR + max buffer size AND prewarms by default. Prewarm is expensive,
  // which is exactly why this method must run off the audio thread.
  _model->Reset(sampleRate, maxBlockSize);
}

- (void)processInput:(const float *)input output:(float *)output frames:(int)frames {
  // Guard: not ready, or a block bigger than we sized for — pass clean signal, never glitch.
  if (!_model || frames > _maxBlockSize) {
    if (output != input) {
      for (int i = 0; i < frames; ++i) output[i] = input[i];
    }
    return;
  }

  // float (Core Audio) -> NAM_SAMPLE
  for (int i = 0; i < frames; ++i) _inScratch[(size_t)i] = (NAM_SAMPLE)input[i];

  NAM_SAMPLE *inChans[1] = {_inScratch.data()};   // mono: one channel
  NAM_SAMPLE *outChans[1] = {_outScratch.data()};
  _model->process(inChans, outChans, frames);

  // NAM_SAMPLE -> float
  for (int i = 0; i < frames; ++i) output[i] = (float)_outScratch[(size_t)i];
}

- (BOOL)isLoaded {
  return _model != nullptr;
}

- (double)expectedSampleRate {
  return _model ? _model->GetExpectedSampleRate() : -1.0;
}

@end
