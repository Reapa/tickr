import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'prefs.dart';

/// How much hand-holding the player wants. Higher rank = more experience =
/// fewer tips. Chosen once during onboarding, changeable from Profile.
enum SkillLevel {
  beginner('New to trading', 'Teach me everything as I go.', 0),
  intermediate('Some experience', 'I know the basics — just the sharp edges.', 1),
  advanced('Experienced', 'Skip the coaching. I know what I\'m doing.', 2);

  const SkillLevel(this.label, this.blurb, this.rank);

  final String label;
  final String blurb;
  final int rank;
}

/// Onboarding + contextual-tip state. `skillLevel == null` means the player
/// hasn't finished onboarding yet.
class TutorialState {
  const TutorialState({this.skillLevel, this.dismissed = const {}});

  final SkillLevel? skillLevel;
  final Set<String> dismissed;

  bool get onboarded => skillLevel != null;

  /// A tip written for experience "up to" [showUpTo] shows only if the player
  /// is at or below that level and hasn't dismissed it. So beginners see the
  /// most, advanced players see only tips marked for everyone.
  bool showsTip(String id, SkillLevel showUpTo) =>
      onboarded &&
      !dismissed.contains(id) &&
      skillLevel!.rank <= showUpTo.rank;

  TutorialState copyWith({SkillLevel? skillLevel, Set<String>? dismissed}) =>
      TutorialState(
        skillLevel: skillLevel ?? this.skillLevel,
        dismissed: dismissed ?? this.dismissed,
      );
}

class TutorialNotifier extends Notifier<TutorialState> {
  static const _kLevel = 'tutorial.skillLevel';
  static const _kDismissed = 'tutorial.dismissed';

  @override
  TutorialState build() {
    final prefs = ref.read(sharedPreferencesProvider);
    return TutorialState(
      skillLevel: _levelFromName(prefs.getString(_kLevel)),
      dismissed: (prefs.getStringList(_kDismissed) ?? const []).toSet(),
    );
  }

  static SkillLevel? _levelFromName(String? name) {
    for (final level in SkillLevel.values) {
      if (level.name == name) return level;
    }
    return null;
  }

  void setSkillLevel(SkillLevel level) {
    ref.read(sharedPreferencesProvider).setString(_kLevel, level.name);
    state = state.copyWith(skillLevel: level);
  }

  void dismissTip(String id) {
    if (state.dismissed.contains(id)) return;
    final next = {...state.dismissed, id};
    ref.read(sharedPreferencesProvider).setStringList(_kDismissed, next.toList());
    state = state.copyWith(dismissed: next);
  }

  /// Restart the whole tutorial (re-runs onboarding + re-shows every tip).
  void reset() {
    ref.read(sharedPreferencesProvider)
      ..remove(_kLevel)
      ..remove(_kDismissed);
    state = const TutorialState();
  }
}

final tutorialProvider =
    NotifierProvider<TutorialNotifier, TutorialState>(TutorialNotifier.new);
