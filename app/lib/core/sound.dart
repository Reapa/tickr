import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'platform/audio.dart';
import 'platform/audio.dart' if (dart.library.js_interop) 'platform/audio_web.dart'
    as engine;
import 'prefs.dart';

/// Player toggle for sound. Persisted, and deliberately DEFAULTS OFF: a web app
/// that starts making noise the moment you open it on a phone in public is a
/// bad experience, and audio is the one thing players expect to opt into.
/// Everything in [Sfx] no-ops when this is false.
class SoundEnabledNotifier extends Notifier<bool> {
  static const _key = 'sound.enabled';

  @override
  bool build() => ref.read(sharedPreferencesProvider).getBool(_key) ?? false;

  void set(bool value) {
    ref.read(sharedPreferencesProvider).setBool(_key, value);
    // Turning it on is itself a user gesture, which is exactly when a browser
    // will let us start the audio context.
    if (value) engine.unlockAudio();
    state = value;
  }

  void toggle() => set(!state);
}

final soundEnabledProvider =
    NotifierProvider<SoundEnabledNotifier, bool>(SoundEnabledNotifier.new);

/// The app's sound palette, synthesized rather than sampled (see
/// `platform/audio_web.dart` for why).
///
/// House style: short, dry, and pitched — nothing longer than a second, nothing
/// that competes with a podcast playing in another tab. Wins rise in pitch,
/// losses fall, and rarity is signalled by how many notes stack up.
abstract final class Sfx {
  static bool _enabled = false;

  /// Kept in sync by [SoundGate] so the widget tree doesn't have to pass a
  /// WidgetRef into every call site.
  static void setEnabled(bool value) => _enabled = value;

  static void _play(List<Voice> voices, {double gain = 0.6}) {
    if (!_enabled) return;
    engine.playVoices(voices, gain);
  }

  /// Browsers gate audio behind a user gesture; call this from the first tap.
  static void unlock() => engine.unlockAudio();

  // --- Fishing -------------------------------------------------------------

  /// Line going out: a rising whoosh of filtered noise.
  static void cast() => _play(const [
        Voice(wave: 'noise', freq: 0, duration: 0.28, gain: 0.16, filterHz: 900),
        Voice(
            wave: 'sine',
            freq: 220,
            endFreq: 660,
            duration: 0.22,
            gain: 0.06,
            attack: 0.02),
      ]);

  /// The hook lands. Low noise thump plus a quick water plink.
  static void splash() => _play(const [
        Voice(wave: 'noise', freq: 0, duration: 0.18, gain: 0.22, filterHz: 500),
        Voice(
            wave: 'sine',
            freq: 900,
            endFreq: 300,
            duration: 0.14,
            gain: 0.10,
            delay: 0.03),
      ]);

  /// Something heavy breaking the surface. Bigger and wetter than [splash] —
  /// this is the bite committing, and the fish coming over the gunwale.
  static void splashBig() => _play(const [
        Voice(wave: 'noise', freq: 0, duration: 0.34, gain: 0.30, filterHz: 700),
        Voice(
            wave: 'noise',
            freq: 0,
            duration: 0.42,
            gain: 0.16,
            filterHz: 2400,
            delay: 0.05),
        Voice(
            wave: 'sine',
            freq: 420,
            endFreq: 90,
            duration: 0.26,
            gain: 0.12,
            attack: 0.01),
      ]);

  /// Line peeling off the spool: the drag screaming while the fish runs. The
  /// one sound in the fight that means "let go".
  static void drag() => _play(const [
        Voice(
            wave: 'sawtooth',
            freq: 130,
            endFreq: 320,
            duration: 0.45,
            gain: 0.07,
            attack: 0.04),
        Voice(
            wave: 'noise', freq: 0, duration: 0.45, gain: 0.10, filterHz: 1800),
      ]);

  /// The line parting. A hard crack and then nothing — deliberately abrupt,
  /// because that is exactly how it feels.
  static void snap() => _play(const [
        Voice(wave: 'noise', freq: 0, duration: 0.07, gain: 0.34, filterHz: 5200),
        Voice(
            wave: 'square',
            freq: 900,
            endFreq: 70,
            duration: 0.20,
            gain: 0.14,
            attack: 0.001),
      ]);

  /// A routine catch — two friendly ascending notes.
  static void catchCommon() => _play(const [
        Voice(wave: 'triangle', freq: 523, duration: 0.10, gain: 0.14),
        Voice(wave: 'triangle', freq: 784, duration: 0.16, gain: 0.14, delay: 0.09),
      ]);

  /// Something good. A brighter, longer arpeggio.
  static void catchRare() => _play(const [
        Voice(wave: 'triangle', freq: 659, duration: 0.10, gain: 0.15),
        Voice(wave: 'triangle', freq: 880, duration: 0.10, gain: 0.15, delay: 0.09),
        Voice(wave: 'triangle', freq: 1319, duration: 0.28, gain: 0.15, delay: 0.18),
        Voice(wave: 'sine', freq: 1760, duration: 0.34, gain: 0.05, delay: 0.18),
      ]);

  /// The whole point of the mini-game. A full fanfare with a shimmer on top.
  static void catchLegendary() => _play(const [
        Voice(wave: 'square', freq: 523, duration: 0.12, gain: 0.10),
        Voice(wave: 'square', freq: 659, duration: 0.12, gain: 0.10, delay: 0.11),
        Voice(wave: 'square', freq: 784, duration: 0.12, gain: 0.10, delay: 0.22),
        Voice(wave: 'square', freq: 1047, duration: 0.45, gain: 0.12, delay: 0.33),
        Voice(wave: 'sine', freq: 1568, duration: 0.55, gain: 0.07, delay: 0.33),
        Voice(wave: 'sine', freq: 2093, duration: 0.60, gain: 0.05, delay: 0.40),
      ]);

  /// The reel clicking as the hold empties into cash.
  static void reel() => _play(const [
        Voice(wave: 'noise', freq: 0, duration: 0.05, gain: 0.10, filterHz: 2600),
        Voice(
            wave: 'noise',
            freq: 0,
            duration: 0.05,
            gain: 0.10,
            filterHz: 2600,
            delay: 0.06),
        Voice(
            wave: 'noise',
            freq: 0,
            duration: 0.05,
            gain: 0.10,
            filterHz: 2600,
            delay: 0.12),
      ]);

  /// Money in. Bright, coin-like, unmistakably a payout.
  static void cash() => _play(const [
        Voice(wave: 'square', freq: 1319, duration: 0.07, gain: 0.09),
        Voice(wave: 'square', freq: 1760, duration: 0.07, gain: 0.09, delay: 0.06),
        Voice(wave: 'square', freq: 2093, duration: 0.22, gain: 0.08, delay: 0.12),
      ]);

  /// Gear bought — a solid, confirming thunk.
  static void purchase() => _play(const [
        Voice(wave: 'sine', freq: 180, duration: 0.10, gain: 0.20),
        Voice(wave: 'triangle', freq: 440, duration: 0.16, gain: 0.10, delay: 0.05),
        Voice(wave: 'triangle', freq: 660, duration: 0.20, gain: 0.10, delay: 0.13),
      ]);

  // --- Generic -------------------------------------------------------------

  /// Nothing happened / not allowed. Short, low, unmistakably a "no".
  static void nope() => _play(const [
        Voice(wave: 'square', freq: 200, endFreq: 120, duration: 0.16, gain: 0.10),
      ]);

  /// A light UI tick for repeated actions.
  static void tick() => _play(const [
        Voice(wave: 'sine', freq: 1200, duration: 0.03, gain: 0.06),
      ]);

  // --- Slots ---------------------------------------------------------------

  /// The reels spinning up: a rattling loop of short noise clicks.
  static void slotSpin() => _play([
        for (var i = 0; i < 14; i++)
          Voice(
              wave: 'noise',
              freq: 0,
              duration: 0.03,
              gain: 0.07,
              filterHz: 3200,
              delay: i * 0.055),
      ]);

  /// A reel coming to rest. Pitched up per reel so a three-reel stop rises.
  static void slotStop(int index) => _play([
        Voice(
            wave: 'square',
            freq: 320.0 + index * 110,
            duration: 0.06,
            gain: 0.12),
        const Voice(
            wave: 'noise', freq: 0, duration: 0.05, gain: 0.09, filterHz: 1400),
      ]);

  /// A win, scaled: bigger multipliers get a longer, higher run of notes.
  static void slotWin(int notes) => _play([
        for (var i = 0; i < notes.clamp(2, 8); i++)
          Voice(
              wave: 'triangle',
              freq: 523.0 * (1 + i * 0.22),
              duration: 0.14,
              gain: 0.13,
              delay: i * 0.075),
      ]);

  /// Jackpot. The loudest thing the app is allowed to do.
  static void slotJackpot() => _play(const [
        Voice(wave: 'square', freq: 784, duration: 0.10, gain: 0.12),
        Voice(wave: 'square', freq: 1047, duration: 0.10, gain: 0.12, delay: 0.10),
        Voice(wave: 'square', freq: 1319, duration: 0.10, gain: 0.12, delay: 0.20),
        Voice(wave: 'square', freq: 1568, duration: 0.10, gain: 0.12, delay: 0.30),
        Voice(wave: 'square', freq: 2093, duration: 0.70, gain: 0.13, delay: 0.40),
        Voice(wave: 'sine', freq: 3136, duration: 0.80, gain: 0.06, delay: 0.40),
        Voice(wave: 'triangle', freq: 1047, duration: 0.80, gain: 0.07, delay: 0.40),
      ]);

  /// A losing spin. Two descending notes — disappointing, never punishing.
  static void slotLose() => _play(const [
        Voice(wave: 'triangle', freq: 392, duration: 0.10, gain: 0.09),
        Voice(wave: 'triangle', freq: 294, duration: 0.20, gain: 0.09, delay: 0.09),
      ]);
}

/// Keeps [Sfx]'s cached flag in sync with the persisted setting. Mount once,
/// high in the tree.
class SoundGate extends ConsumerWidget {
  const SoundGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Sfx.setEnabled(ref.watch(soundEnabledProvider));
    return child;
  }
}
