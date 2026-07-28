/// Non-web stub for the sound engine. On web this is replaced by
/// `audio_web.dart` through the conditional import in `sound.dart`, so the
/// Dart VM (analyzer, tests) never touches `dart:js_interop` / `package:web`.
///
/// Tickr ships as a web app, so silence off-web is the correct behaviour
/// rather than a missing feature.
library;

/// A single synthesized voice: an oscillator (or noise burst) shaped by an
/// attack/decay envelope and an optional pitch sweep.
class Voice {
  const Voice({
    required this.wave,
    required this.freq,
    required this.duration,
    this.endFreq,
    this.gain = 0.2,
    this.attack = 0.005,
    this.delay = 0,
    this.filterHz,
  });

  /// 'sine' | 'square' | 'sawtooth' | 'triangle' | 'noise'
  final String wave;
  final double freq;
  final double? endFreq;
  final double duration;
  final double gain;
  final double attack;
  final double delay;
  final double? filterHz;
}

bool get audioSupported => false;

void unlockAudio() {}

void playVoices(List<Voice> voices, double masterGain) {}
