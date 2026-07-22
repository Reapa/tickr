import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'format.dart';
import 'prefs.dart';
import 'widgets/celebration.dart';

/// Player toggle for sensory feedback (haptics + win celebrations). Persisted;
/// defaults on. Everything in [Juice] no-ops when this is false, so the whole
/// feel layer is one switch in settings.
class FeedbackEnabledNotifier extends Notifier<bool> {
  static const _key = 'feedback.enabled';

  @override
  bool build() => ref.read(sharedPreferencesProvider).getBool(_key) ?? true;

  void set(bool value) {
    ref.read(sharedPreferencesProvider).setBool(_key, value);
    state = value;
  }
}

final feedbackEnabledProvider =
    NotifierProvider<FeedbackEnabledNotifier, bool>(FeedbackEnabledNotifier.new);

/// Magnitude-scaled sensory feedback ("juice"). Feedback intensity tracks the
/// outcome — a small scalp gets a haptic tap, a big win gets a full-screen
/// celebration — so the feedback itself becomes part of the reward.
///
/// Haptics are a no-op on web/desktop (the platform simply ignores them), so
/// these are safe to call everywhere without a platform check.
abstract final class Juice {
  /// A light tap for a routine action — an order placed, a position opened.
  static void fill(WidgetRef ref) {
    if (ref.read(feedbackEnabledProvider)) HapticFeedback.lightImpact();
  }

  /// Feedback for a closed position, scaled by the realized profit/loss.
  /// Wins ≥ [_bigWin] (or ≥12% return) get a confetti celebration; smaller
  /// wins a medium haptic; losses a soft tap. Returns true if it celebrated.
  static const double _bigWin = 500;
  static const double _hugeWin = 2000;

  static bool close(
    BuildContext context,
    WidgetRef ref, {
    required double pnl,
    double? ret,
    required String symbol,
    String? headline,
  }) {
    if (!ref.read(feedbackEnabledProvider)) return false;
    if (pnl <= 0) {
      HapticFeedback.lightImpact();
      return false;
    }
    final big = pnl >= _bigWin || (ret != null && ret >= 0.12);
    if (!big) {
      HapticFeedback.mediumImpact();
      return false;
    }
    HapticFeedback.heavyImpact();
    final huge = pnl >= _hugeWin || (ret != null && ret >= 0.30);
    showCelebration(
      context,
      title: headline ?? (huge ? 'Massive win!' : 'Sharp trade!'),
      subtitle: '+${Fmt.money(pnl)} on $symbol'
          '${ret != null ? ' · ${Fmt.pct(ret)}' : ''}',
      emoji: huge ? '🚀' : '🎯',
    );
    return true;
  }
}
