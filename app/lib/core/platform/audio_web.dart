/// Web implementation of the sound engine.
///
/// Every sound in the app is SYNTHESIZED here at runtime from oscillators and
/// filtered noise — there are no audio files, so there is nothing to download,
/// nothing to license and nothing to attribute, and the whole sound design adds
/// zero bytes to the bundle. It also means a sound can be tuned by editing a
/// number instead of re-cutting a sample.
///
/// If real recorded samples are ever preferred, only this file and the `Voice`
/// list in `sound.dart` need to change; every call site stays as it is.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'audio.dart' show Voice;

web.AudioContext? _ctx;

bool get audioSupported => true;

web.AudioContext? _context() {
  try {
    return _ctx ??= web.AudioContext();
  } catch (_) {
    // Some embedded browsers refuse to construct one. Stay silent, don't crash.
    return null;
  }
}

/// Browsers refuse to start an AudioContext until the user has interacted with
/// the page, so the first tap has to resume it explicitly or every later sound
/// is silently dropped.
void unlockAudio() {
  final ctx = _context();
  if (ctx == null) return;
  if (ctx.state == 'suspended') ctx.resume();
}

void playVoices(List<Voice> voices, double masterGain) {
  final ctx = _context();
  if (ctx == null) return;
  if (ctx.state == 'suspended') ctx.resume();

  final now = ctx.currentTime;
  final master = ctx.createGain();
  master.gain.value = masterGain;
  master.connect(ctx.destination);

  for (final v in voices) {
    final start = now + v.delay;
    final stop = start + v.duration;

    final env = ctx.createGain();
    // Ramp in over `attack`, then decay exponentially to near-silence. A true
    // zero can't be reached exponentially, hence the 0.0001 floor.
    env.gain.setValueAtTime(0.0001, start);
    env.gain.exponentialRampToValueAtTime(v.gain, start + v.attack);
    env.gain.exponentialRampToValueAtTime(0.0001, stop);

    web.AudioNode tail = env;
    if (v.filterHz != null) {
      final filter = ctx.createBiquadFilter();
      filter.type = 'lowpass';
      filter.frequency.value = v.filterHz!;
      env.connect(filter);
      tail = filter;
    }
    tail.connect(master);

    if (v.wave == 'noise') {
      // Water, reel clatter and machine noise are all shaped white noise.
      final frames = (ctx.sampleRate * v.duration).ceil();
      final buffer = ctx.createBuffer(1, frames, ctx.sampleRate);
      final data = buffer.getChannelData(0).toDart;
      var seed = 22695477;
      for (var i = 0; i < frames; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        data[i] = (seed / 0x3fffffff) - 1.0;
      }
      final src = ctx.createBufferSource();
      src.buffer = buffer;
      src.connect(env);
      src.start(start);
      src.stop(stop);
    } else {
      final osc = ctx.createOscillator();
      osc.type = v.wave;
      osc.frequency.setValueAtTime(v.freq, start);
      if (v.endFreq != null) {
        osc.frequency.exponentialRampToValueAtTime(v.endFreq!, stop);
      }
      osc.connect(env);
      osc.start(start);
      osc.stop(stop);
    }
  }
}
