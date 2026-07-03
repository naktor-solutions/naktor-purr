import Accelerate

// Deterministic per-utterance audio cleanup before the ASR engine sees it.
//
// Two passes, both standard in NeMo's training-time audio pipeline and
// therefore *expected* by the conformer at inference:
//
//   1. DC-offset removal. Subtract the per-utterance mean so the waveform
//      sits centred on zero. Cheap hardware (and AVAudioEngine on some
//      Bluetooth aggregate devices) introduces a small constant bias that
//      shows up in the model's mel-spectrogram frontend as a DC bin
//      anomaly and degrades the encoder's framing on short clips.
//   2. Peak normalisation toward -3 dBFS. Quiet inputs (mic gain low,
//      far-field microphone, soft speaker) are the single most reliable
//      cause of "full-utterance hallucination" on Parakeet TDT - the
//      conformer was trained on broadcast-loud speech and the joint
//      network's logit margins collapse when the signal-to-noise ratio
//      drops. Bringing peak up to ~0.707 floats restores the level the
//      model was tuned for without changing the spectral content.
//
// Sub-millisecond on M-series for any single hotkey-press utterance. No
// pre-emphasis filter here - FluidAudio's CoreML preprocessor already does
// its own mel-spectrogram pre-emphasis internally, and applying it twice
// shifts the spectrum away from the training distribution.
enum AudioPreprocessor {
    // Below this peak we treat the buffer as silence and pass it through
    // unchanged - amplifying noise to "speech level" produces fake
    // formants the model will happily transcribe as words.
    static let silenceThresholdDbFS: Float = -60

    // Target peak after normalisation. -3 dBFS leaves headroom for any
    // downstream filter inside FluidAudio's preprocessor without clipping.
    static let targetPeakDbFS: Float = -3

    struct Result {
        let samples: [Float]
        // Peak of the *original* signal in dBFS, before any normalisation.
        // The coordinator uses this to flag "mic too quiet" to the user.
        let originalPeakDbFS: Float
    }

    static func normalize(_ samples: [Float]) -> Result {
        guard !samples.isEmpty else {
            return Result(samples: samples, originalPeakDbFS: -.infinity)
        }

        var out = samples

        // Pass 1: DC offset removal.
        var mean: Float = 0
        vDSP_meanv(out, 1, &mean, vDSP_Length(out.count))
        if mean != 0 {
            var negMean = -mean
            vDSP_vsadd(out, 1, &negMean, &out, 1, vDSP_Length(out.count))
        }

        // Pass 2: peak normalisation. dBFS = 20 * log10 of the linear ratio
        // against full scale (1.0 for Float32 PCM).
        var peak: Float = 0
        vDSP_maxmgv(out, 1, &peak, vDSP_Length(out.count))
        let originalPeakDbFS = peak > 0 ? 20 * log10f(peak) : -.infinity

        if originalPeakDbFS > silenceThresholdDbFS {
            let targetLinear = powf(10, targetPeakDbFS / 20)
            var gain = targetLinear / peak
            // Only boost; don't attenuate already-healthy signals. A signal
            // that's already peaking above -3 dBFS is fine and pulling it
            // down can make borderline-quiet syllables fall below the
            // model's effective noise floor.
            if gain > 1 {
                vDSP_vsmul(out, 1, &gain, &out, 1, vDSP_Length(out.count))
            }
        }

        return Result(samples: out, originalPeakDbFS: originalPeakDbFS)
    }
}
