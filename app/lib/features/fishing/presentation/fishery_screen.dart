import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/back_or_home.dart';
import '../../../core/feedback.dart';
import '../../../core/format.dart';
import '../../../core/sound.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/celebration.dart';
import '../../../core/widgets/countdown.dart';
import '../../crates/data/crates_repository.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../profile/data/profile_repository.dart';
import '../data/fishing_repository.dart';
import '../domain/fishery.dart';
import 'encounter_panel.dart';
import 'fight_panel.dart';
import 'sea.dart';

/// The Fishery.
///
/// Two loops share one screen and they are deliberately different jobs:
///
///   IDLE   the boat fills a capped hold while you are away. Come back, sell.
///   TRIP   the active game. Pick a spot, and every cast is a fight you can
///          lose. Fish land in a live well that is not yours until you bank it,
///          and the haul bonus grows with every fish you land in a row — so the
///          real decision of the session is when to stop.
class FisheryScreen extends ConsumerStatefulWidget {
  const FisheryScreen({super.key});

  @override
  ConsumerState<FisheryScreen> createState() => _FisheryScreenState();
}

class _FisheryScreenState extends ConsumerState<FisheryScreen> {
  Hookup? _hookup;
  LandResult? _lastResult;
  bool _busy = false;

  /// Encounter ids already dealt with as abandoned. Without this a resolve that
  /// fails (it was already gone, the network dropped) would be retried on every
  /// rebuild, because the provider still reports the same open encounter.
  final Set<String> _clearedHooks = <String>{};

  void _refresh() {
    ref.invalidate(fisheryProvider);
    ref.invalidate(fisheryHoldProvider);
    ref.invalidate(fishLogProvider);
  }

  void _toast(String message, {Color? background, bool good = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: background ?? (good ? AppTheme.up : null),
      content: Text(
        message,
        style: good
            ? const TextStyle(
                color: Colors.black, fontWeight: FontWeight.w700)
            : null,
      ),
    ));
  }

  // --------------------------------------------------------------------------
  // Trip
  // --------------------------------------------------------------------------

  Future<void> _startTrip(FishingSpot spot) async {
    if (_busy) return;
    setState(() => _busy = true);
    Sfx.unlock();
    try {
      final result =
          await ref.read(fishingRepositoryProvider).startTrip(spot.code);
      if (result['status'] != 'started') {
        Sfx.nope();
        _toast('${result['reason'] ?? 'Cannot sail'}');
      } else {
        Sfx.cast();
        setState(() => _lastResult = null);
      }
      _refresh();
    } catch (error) {
      _toast('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cast() async {
    if (_busy || _hookup != null) return;
    setState(() {
      _busy = true;
      _lastResult = null;
    });
    Sfx.unlock();
    Sfx.cast();
    try {
      final hookup = await ref.read(fishingRepositoryProvider).cast();
      if (!mounted) return;
      if (!hookup.isHooked) {
        Sfx.nope();
        _toast(hookup.reason ?? 'Nothing biting.');
        _refresh();
        return;
      }
      setState(() => _hookup = hookup);
    } catch (error) {
      _toast('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The fight is over; tell the server how it went and let it price it.
  Future<void> _resolve(bool landed, double score) async {
    final hookup = _hookup;
    if (hookup?.encounterId == null) return;
    try {
      final result = await ref.read(fishingRepositoryProvider).resolve(
            encounterId: hookup!.encounterId!,
            landed: landed,
            score: score,
          );
      if (!mounted) return;
      setState(() {
        _hookup = null;
        _lastResult = result;
      });

      if (result.isCatch) {
        switch (result.rarity) {
          case FishRarity.legendary:
            Sfx.catchLegendary();
          case FishRarity.epic:
          case FishRarity.rare:
            Sfx.catchRare();
          default:
            Sfx.catchCommon();
        }
        if (result.rarity.isSpecial && ref.read(feedbackEnabledProvider)) {
          showCelebration(
            context,
            title: result.rarity == FishRarity.legendary
                ? 'LEGENDARY CATCH!'
                : 'What a catch!',
            subtitle: '${result.name} · ${Fmt.weight(result.weightKg)}',
            emoji: result.rarity == FishRarity.legendary ? '🏆' : '🎣',
          );
        }
        if (result.rarity.isSpecial) ref.invalidate(unopenedCratesProvider);
      } else if (result.saved) {
        _toast('Your spare line held. The run survives.', good: true);
      } else if (result.spilled) {
        _toast(result.reason ?? 'It took a fish with it.');
      }
      _refresh();
    } catch (error) {
      if (mounted) {
        setState(() => _hookup = null);
        _toast('$error');
        _refresh();
      }
    }
  }

  /// A fight interrupted by a reload is a lost fish, resolved the moment the
  /// screen comes back. Leaving it open would block casting until it timed out,
  /// and — worse — would let a bad fight be retried by refreshing the page.
  Future<void> _clearStaleHook(Hookup stale) async {
    final id = stale.encounterId!;
    if (!_clearedHooks.add(id)) return;
    try {
      await ref.read(fishingRepositoryProvider).resolve(
            encounterId: id,
            landed: false,
            score: 0,
          );
      if (mounted) {
        _toast('You left one on the line, and it got away.');
        _refresh();
      }
    } catch (_) {
      // Nothing to do: the server expires it on its own clock regardless.
    }
  }

  Future<void> _bank() async {
    if (_busy) return;
    setState(() => _busy = true);
    Sfx.unlock();
    try {
      final result = await ref.read(fishingRepositoryProvider).bankHaul();
      if (!mounted) return;
      if (!result.isBanked) {
        Sfx.nope();
        _toast(result.reason ?? 'Nothing to bank.');
        return;
      }
      Sfx.reel();
      setState(() => _lastResult = null);
      _refresh();
      if (result.count == 0) {
        _toast('Back at the dock with nothing. It happens.');
      } else {
        _toast(
          'Haul stowed: ${result.count} fish, ${Fmt.money(result.total)}'
          '${result.haulBonus > 1 ? ' (×${result.haulBonus.toStringAsFixed(2)} bonus)' : ''}',
          good: true,
        );
      }
    } catch (error) {
      _toast('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sell() async {
    if (_busy) return;
    setState(() => _busy = true);
    Sfx.unlock();
    try {
      final result = await ref.read(fishingRepositoryProvider).sell();
      if (!mounted) return;
      if (!result.isSold) {
        Sfx.nope();
        _toast('Nothing in the hold yet.');
        return;
      }
      Sfx.reel();
      await Future<void>.delayed(const Duration(milliseconds: 220));
      if (!mounted) return;
      Sfx.cash();
      _refresh();
      ref.invalidate(myProfileProvider);
      ref.invalidate(recentOrdersProvider);
      _toast(
        'Sold ${result.count} fish for ${Fmt.money(result.total)}'
        '${result.bestName != null ? ' — best: ${result.bestName} '
            '(${Fmt.weight(result.bestKg)})' : ''}',
        good: true,
      );
    } catch (error) {
      _toast('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _useSupply(FishingSupply supply) async {
    try {
      final result =
          await ref.read(fishingRepositoryProvider).useSupply(supply.code);
      if (!mounted) return;
      if (result['status'] == 'used') {
        Sfx.tick();
        _toast('${supply.name} aboard.', good: true);
      } else {
        Sfx.nope();
        _toast('${result['reason'] ?? 'Cannot use that'}');
      }
      _refresh();
    } catch (error) {
      _toast('$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(fisheryProvider);
    // A fight takes the whole screen, chrome included. It is the one part of
    // the fishery that is a game rather than a page, and sharing the frame with
    // an app bar and a scroll view was what made it read as a widget.
    final fighting = _hookup?.fight != null;

    return Scaffold(
      appBar: fighting
          ? null
          : AppBar(
              leading: const BackOrHome(home: '/arcade'),
              title: const Text('The Fishery'),
              actions: [
                IconButton(
                  tooltip: 'Catch log',
                  icon: const Icon(Icons.menu_book_outlined),
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => const _CatchLogSheet(),
                  ),
                ),
                const _SoundToggle(),
              ],
            ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not open the fishery.\n$error',
                textAlign: TextAlign.center),
          ),
        ),
        data: (fishery) {
          // A hook the server still has open but this screen knows nothing
          // about can only be a reload mid-fight.
          final stale = fishery.hookup;
          if (_hookup == null && stale?.encounterId != null) {
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _clearStaleHook(stale!));
          }

          final fight = _hookup?.fight;
          if (fight != null) {
            // A server that describes a reading contest gets the new fight; an
            // encounter rolled before it existed keeps the old one, so there is
            // never a moment where a hooked fish has no way to be played out.
            final encounter = fight.encounter;
            if (encounter != null) {
              return EncounterPanel(
                key: ValueKey(_hookup!.encounterId),
                fight: fight,
                profile: encounter,
                spotName: fishery.trip?.spotName ?? '',
                spotCode: fishery.trip?.spotCode,
                onFinished: _resolve,
              );
            }
            return FightPanel(
              key: ValueKey(_hookup!.encounterId),
              fight: fight,
              spotName: fishery.trip?.spotName ?? '',
              spotCode: fishery.trip?.spotCode,
              onFinished: _resolve,
            );
          }

          return RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                if (fishery.isOnTrip)
                  _DeckPanel(fishery: fishery, result: _lastResult)
                else
                  _HarbourPanel(fishery: fishery),
                const SizedBox(height: 16),
                if (fishery.isOnTrip) ...[
                  _TripCard(
                    fishery: fishery,
                    busy: _busy,
                    fighting: _hookup != null,
                    onCast: _cast,
                    onBank: _bank,
                    onUseSupply: _useSupply,
                  ),
                  const SizedBox(height: 16),
                ] else ...[
                  _SpotPicker(
                    fishery: fishery,
                    busy: _busy,
                    onPick: _startTrip,
                  ),
                  const SizedBox(height: 16),
                ],
                _HoldCard(fishery: fishery, busy: _busy, onSell: _sell),
                const SizedBox(height: 16),
                _StoresCard(fishery: fishery, onBought: _refresh),
                const SizedBox(height: 16),
                _GearCard(fishery: fishery, onBought: _refresh),
                const SizedBox(height: 16),
                _LifetimeCard(fishery: fishery),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Scenes
// ---------------------------------------------------------------------------

/// Tied up at the dock: the idle boat, and whatever it has been doing without
/// you. This is the "come back later" half of the game.
class _HarbourPanel extends StatelessWidget {
  const _HarbourPanel({required this.fishery});

  final Fishery fishery;

  @override
  Widget build(BuildContext context) {
    return SeaFrame(
      height: 210,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              fishery.boatName.toUpperCase(),
              style: TextStyle(
                letterSpacing: 2,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: Colors.white.withValues(alpha: 0.55),
                shadows: const [Shadow(blurRadius: 8, color: Colors.black87)],
              ),
            ),
            const Spacer(),
            Text(
              fishery.holdIsFull
                  ? 'The hold is full. Sell the catch to make room.'
                  : 'Moored up. Your boat fishes on its own while you are '
                      'away — or pick a spot and go out.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                height: 1.45,
                shadows: const [Shadow(blurRadius: 10, color: Colors.black)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Out on the water between casts, showing the last fish you landed.
class _DeckPanel extends StatelessWidget {
  const _DeckPanel({required this.fishery, required this.result});

  final Fishery fishery;
  final LandResult? result;

  @override
  Widget build(BuildContext context) {
    final trip = fishery.trip!;
    final r = result;
    // Out on the water: the boat is under you, not in front of you, so it is
    // not in shot.
    return SeaFrame(
      height: 230,
      palette: SeaPalette.open,
      showBoat: false,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 14,
            child: Text(
              trip.spotName.toUpperCase(),
              textAlign: TextAlign.center,
              style: TextStyle(
                letterSpacing: 2,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: Colors.white.withValues(alpha: 0.55),
                shadows: const [Shadow(blurRadius: 8, color: Colors.black87)],
              ),
            ),
          ),
          Positioned.fill(
            child: Center(
              child: r == null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Text(
                        trip.isSpent
                            ? 'That is the whole trip. Bank the haul.'
                            : 'Lines in the water. Cast when you are ready.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.82),
                          height: 1.5,
                          shadows: const [
                            Shadow(blurRadius: 10, color: Colors.black)
                          ],
                        ),
                      ),
                    )
                  : r.isCatch
                      ? _CatchCard(result: r)
                      : _LossCard(result: r),
            ),
          ),
        ],
      ),
    );
  }
}

/// The reveal. Everything on this card was decided by the server at cast time;
/// the fight only decided whether you got to see it.
class _CatchCard extends StatelessWidget {
  const _CatchCard({required this.result});

  final LandResult result;

  @override
  Widget build(BuildContext context) {
    final color = result.rarity.color;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.8), width: 1.5),
        boxShadow: result.rarity.isSpecial
            ? [BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 24)]
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            result.rarity.label.toUpperCase(),
            style: TextStyle(
              color: color,
              fontSize: 10,
              letterSpacing: 2,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            result.name ?? 'Catch',
            style: const TextStyle(
                color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            '${Fmt.weight(result.weightKg)} · ${Fmt.money(result.value)}',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.85)),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            alignment: WrapAlignment.center,
            children: [
              if (result.perfect)
                const _Chip(label: 'CLEAN FIGHT +25%', color: AppTheme.up),
              if (result.isPersonalBest)
                const _Chip(label: 'PERSONAL BEST', color: AppTheme.gold),
              if (result.streak >= 2)
                _Chip(label: '${result.streak} IN A ROW', color: color),
            ],
          ),
        ],
      ),
    );
  }
}

class _LossCard extends StatelessWidget {
  const _LossCard({required this.result});

  final LandResult result;

  @override
  Widget build(BuildContext context) {
    final color = result.saved ? AppTheme.gold : AppTheme.down;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.7), width: 1.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(result.saved ? 'SAVED' : 'IT GOT AWAY',
              style: TextStyle(
                  color: color,
                  fontSize: 10,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          Text(
            result.reason ?? 'The line went slack.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.85)),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: TextStyle(
                color: color,
                fontSize: 9,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w900)),
      );
}

// ---------------------------------------------------------------------------
// Choosing where to fish
// ---------------------------------------------------------------------------

/// The spot list. Locked water stays visible with the boat it wants, because a
/// ladder you cannot see is not a ladder.
class _SpotPicker extends ConsumerWidget {
  const _SpotPicker({
    required this.fishery,
    required this.busy,
    required this.onPick,
  });

  final Fishery fishery;
  final bool busy;
  final void Function(FishingSpot) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spots = ref.watch(fishingSpotsProvider).value ?? const <FishingSpot>[];
    if (spots.isEmpty) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Where to?', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'A trip is a fixed run of casts. Land fish in a row to build the '
              'haul bonus, and bank it before you lose one.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (fishery.holdIsFull) ...[
              const SizedBox(height: 10),
              Text(
                'The hold is full — sell your catch before sailing.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppTheme.gold),
              ),
            ],
            const SizedBox(height: 12),
            for (final spot in spots)
              _SpotRow(
                spot: spot,
                unlocked: fishery.boatTier >= spot.minBoatTier,
                last: fishery.lastSpotCode == spot.code,
                onTap: busy ||
                        fishery.boatTier < spot.minBoatTier ||
                        fishery.holdIsFull
                    ? null
                    : () => onPick(spot),
              ),
          ],
        ),
      ),
    );
  }
}

class _SpotRow extends StatelessWidget {
  const _SpotRow({
    required this.spot,
    required this.unlocked,
    required this.last,
    required this.onTap,
  });

  final FishingSpot spot;
  final bool unlocked;
  final bool last;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: unlocked ? 1 : 0.45,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(unlocked ? Icons.sailing : Icons.lock_outline, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(spot.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800)),
                            if (last) ...[
                              const SizedBox(width: 6),
                              Text('last trip',
                                  style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ],
                        ),
                        Text(spot.blurb,
                            style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: 2),
                        Text(
                          unlocked
                              ? '${spot.tripCasts} casts · up to '
                                  '×${spot.haulCap.toStringAsFixed(1)} haul bonus'
                              : 'Needs a tier-${spot.minBoatTier} boat',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: unlocked ? AppTheme.up : AppTheme.gold,
                                  fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                  if (onTap != null) const Icon(Icons.chevron_right, size: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The trip itself
// ---------------------------------------------------------------------------

/// Everything the decision needs in one card: what is in the well, what the
/// bonus is worth right now, and how many casts are left to risk it on.
class _TripCard extends ConsumerWidget {
  const _TripCard({
    required this.fishery,
    required this.busy,
    required this.fighting,
    required this.onCast,
    required this.onBank,
    required this.onUseSupply,
  });

  final Fishery fishery;
  final bool busy;
  final bool fighting;
  final VoidCallback onCast;
  final VoidCallback onBank;
  final void Function(FishingSupply) onUseSupply;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trip = fishery.trip!;
    final supplies =
        ref.watch(fishingSuppliesProvider).value ?? const <FishingSupply>[];
    final next = fishery.nextBaitAt;
    final bonus = trip.haulBonus;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(trip.spotName,
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Text('${trip.castsLeft} casts left',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _TripStat(
                    label: 'In the well',
                    value: '${trip.wellCount}',
                    sub: Fmt.money(trip.wellValue),
                  ),
                ),
                Expanded(
                  child: _TripStat(
                    label: 'Haul bonus',
                    value: '×${bonus.toStringAsFixed(2)}',
                    sub: trip.streak > 0
                        ? '${trip.streak} in a row'
                        : 'land fish to build it',
                    highlight: bonus > 1,
                  ),
                ),
                Expanded(
                  child: _TripStat(
                    label: 'Lost',
                    value: '${trip.lost}',
                    sub: trip.spareLines > 0
                        ? '${trip.spareLines} spare line'
                        : 'no spare line',
                  ),
                ),
              ],
            ),
            if (trip.chumCasts > 0 || trip.baitCasts > 0) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                children: [
                  if (trip.chumCasts > 0)
                    _Chip(
                        label: 'CHUM · ${trip.chumCasts} CASTS',
                        color: AppTheme.up),
                  if (trip.baitCasts > 0)
                    _Chip(
                        label: 'LIVE BAIT · ${trip.baitCasts} CASTS',
                        color: AppTheme.gold),
                ],
              ),
            ],
            const SizedBox(height: 14),
            FilledButton.icon(
              style:
                  FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: busy || fighting || !fishery.canCast ? null : onCast,
              icon: const Icon(Icons.phishing),
              label: Text(
                trip.isSpent
                    ? 'Trip over — bank the haul'
                    : fishery.holdIsFull
                        ? 'Hold full'
                        : !fishery.hasBait
                            ? 'Out of bait'
                            : 'Cast a line  ·  1 bait',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.bug_report_outlined,
                    size: 16, color: Theme.of(context).colorScheme.outline),
                const SizedBox(width: 6),
                Text('Bait ${fishery.bait}/${fishery.baitCap}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                if (next != null)
                  Countdown(
                    target: next,
                    builder: (remaining) => Text(
                      'next in ${Fmt.countdown(remaining)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                else
                  Text('Full', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fishery.baitCap == 0 ? 0 : fishery.bait / fishery.baitCap,
                minHeight: 5,
              ),
            ),
            // Supplies are committed mid-trip, before you know what is down
            // there — which is what makes carrying them a decision.
            if (fishery.supplies.values.any((q) => q > 0)) ...[
              const SizedBox(height: 14),
              Text('Load from stores',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in supplies)
                    if ((fishery.supplies[s.code] ?? 0) > 0)
                      ActionChip(
                        avatar: Icon(s.icon, size: 16),
                        label:
                            Text('${s.name}  ×${fishery.supplies[s.code]}'),
                        onPressed: fighting ? null : () => onUseSupply(s),
                      ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: trip.wellCount > 0 ? AppTheme.up : null,
              ),
              onPressed: busy || fighting ? null : onBank,
              icon: const Icon(Icons.anchor),
              label: Text(
                trip.wellCount == 0
                    ? 'Head back empty-handed'
                    : 'Bank the haul  ·  ${Fmt.money(trip.wellValue * bonus)}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Nothing in the well is yours until you bank it. Lose a fight and '
              'the bonus resets and the smallest fish goes over the side.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _TripStat extends StatelessWidget {
  const _TripStat({
    required this.label,
    required this.value,
    required this.sub,
    this.highlight = false,
  });

  final String label;
  final String value;
  final String sub;
  final bool highlight;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          Text(value,
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: highlight ? AppTheme.up : null)),
          Text(sub,
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis),
        ],
      );
}

// ---------------------------------------------------------------------------
// Hold, stores, gear
// ---------------------------------------------------------------------------

class _HoldCard extends ConsumerWidget {
  const _HoldCard({
    required this.fishery,
    required this.busy,
    required this.onSell,
  });

  final Fishery fishery;
  final bool busy;
  final VoidCallback onSell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hold = ref.watch(fisheryHoldProvider).value ?? const <HoldItem>[];
    final species = ref.watch(fishSpeciesByCodeProvider);
    final full = fishery.holdIsFull;
    final toFull = fishery.timeToFull;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Hold', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Text('${fishery.stowedCount} / ${fishery.holdCapacity}',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: full ? AppTheme.gold : null)),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fishery.holdFraction,
                minHeight: 7,
                color: full ? AppTheme.gold : AppTheme.up,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              full
                  ? 'Full. Your boat has stopped fishing until you sell.'
                  : toFull == null
                      ? 'Your boat is not catching anything right now.'
                      : 'Full in about ${_humanDuration(toFull)} — '
                          '${fishery.catchPerHour.toStringAsFixed(0)} fish/hour.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (fishery.isOnTrip && (fishery.trip?.wellCount ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${fishery.trip!.wellCount} more in the live well, not '
                  'sellable until the trip is banked.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppTheme.gold),
                ),
              ),
            if (hold.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final item in (hold.toList()
                    ..sort((a, b) => b.value.compareTo(a.value)))
                  .take(5))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: (species[item.speciesCode]?.rarity ??
                                  FishRarity.common)
                              .color,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          species[item.speciesCode]?.name ?? item.speciesCode,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(Fmt.weight(item.weightKg),
                          style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(width: 10),
                      Text(Fmt.money(item.value),
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              if (hold.length > 5)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('+ ${hold.length - 5} more aboard',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
            ],
            const SizedBox(height: 14),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.up,
                foregroundColor: Colors.black,
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: busy || fishery.holdCount == 0 ? null : onSell,
              icon: const Icon(Icons.sell_outlined),
              label: Text(
                fishery.holdCount == 0
                    ? 'Nothing to sell'
                    : 'Sell the catch  ·  ${Fmt.money(fishery.holdValue)}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The ship's stores. Unlike gear, this money is burned — which is exactly why
/// it is here: a fully-upgraded fishery still needs somewhere to spend.
class _StoresCard extends ConsumerWidget {
  const _StoresCard({required this.fishery, required this.onBought});

  final Fishery fishery;
  final VoidCallback onBought;

  Future<void> _buy(
      BuildContext context, WidgetRef ref, FishingSupply supply) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result =
          await ref.read(fishingRepositoryProvider).buySupply(supply.code);
      if (result['status'] == 'bought') {
        Sfx.purchase();
        ref.invalidate(myProfileProvider);
        onBought();
        messenger.showSnackBar(SnackBar(
          backgroundColor: AppTheme.up,
          content: Text('${supply.name} stowed.',
              style: const TextStyle(
                  color: Colors.black, fontWeight: FontWeight.w700)),
        ));
      } else {
        Sfx.nope();
        messenger.showSnackBar(
            SnackBar(content: Text('${result['reason'] ?? 'Not available'}')));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supplies =
        ref.watch(fishingSuppliesProvider).value ?? const <FishingSupply>[];
    if (supplies.isEmpty) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Ship's stores",
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Consumables, carried onto a trip and burned. This spend does not '
              'come back as equity the way a boat does.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            for (final s in supplies)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(s.icon, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(s.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                              if ((fishery.supplies[s.code] ?? 0) > 0) ...[
                                const SizedBox(width: 6),
                                Text('×${fishery.supplies[s.code]}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        color: AppTheme.up)),
                              ],
                            ],
                          ),
                          Text(s.description,
                              style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () => _buy(context, ref, s),
                      child: Text(Fmt.moneyCompact(s.price)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GearCard extends ConsumerWidget {
  const _GearCard({required this.fishery, required this.onBought});

  final Fishery fishery;
  final VoidCallback onBought;

  Future<void> _buy(
      BuildContext context, WidgetRef ref, FishingGear gear) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result =
          await ref.read(fishingRepositoryProvider).buyGear(gear.code);
      if (result['status'] == 'bought') {
        Sfx.purchase();
        ref.invalidate(myProfileProvider);
        onBought();
        messenger.showSnackBar(SnackBar(
          backgroundColor: AppTheme.up,
          content: Text('${gear.name} acquired.',
              style: const TextStyle(
                  color: Colors.black, fontWeight: FontWeight.w700)),
        ));
      } else {
        Sfx.nope();
        messenger.showSnackBar(
            SnackBar(content: Text('${result['reason'] ?? 'Not available'}')));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gear = ref.watch(fishingGearProvider).value ?? const <FishingGear>[];
    if (gear.isEmpty) return const SizedBox.shrink();

    final nextBoat = gear
        .where((g) => g.isBoat && g.tier == fishery.boatTier + 1)
        .firstOrNull;
    final nextRod =
        gear.where((g) => !g.isBoat && g.tier == fishery.rodTier + 1).firstOrNull;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Gear', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Boats and rods are capital: what you spend moves into your '
              'business net worth, the same as a property. The top tiers also '
              'need a licence, which only the catch log can earn.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _GearRow(
              label: 'Boat',
              owned: fishery.boatName,
              detail: '${fishery.catchPerHour.toStringAsFixed(0)} fish/hr · '
                  'hold ${fishery.holdCapacity}',
              next: nextBoat,
              licence: fishery.licence,
              onBuy:
                  nextBoat == null ? null : () => _buy(context, ref, nextBoat),
            ),
            const Divider(height: 24),
            _GearRow(
              label: 'Rod',
              owned: fishery.rodName,
              detail: 'Better rods find rarer fish — and tame bigger ones',
              next: nextRod,
              licence: fishery.licence,
              onBuy: nextRod == null ? null : () => _buy(context, ref, nextRod),
            ),
          ],
        ),
      ),
    );
  }
}

class _GearRow extends StatelessWidget {
  const _GearRow({
    required this.label,
    required this.owned,
    required this.detail,
    required this.next,
    required this.licence,
    required this.onBuy,
  });

  final String label;
  final String owned;
  final String detail;
  final FishingGear? next;
  final Licence licence;
  final VoidCallback? onBuy;

  @override
  Widget build(BuildContext context) {
    final upgrade = next;
    final locked = upgrade != null && !upgrade.licenceMet(licence);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('$label: ', style: Theme.of(context).textTheme.bodySmall),
            Expanded(
              child: Text(owned,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        Text(detail, style: Theme.of(context).textTheme.bodySmall),
        if (upgrade != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(upgrade.name,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          Text(upgrade.description,
                              style: Theme.of(context).textTheme.bodySmall),
                          if (upgrade.isBoat)
                            Text(
                              '${upgrade.catchPerHour.toStringAsFixed(0)} fish/hr · '
                              'hold ${upgrade.holdCapacity}',
                              style: Theme.of(context).textTheme.bodySmall,
                            )
                          else
                            Text('${upgrade.rareBonus}× rare-fish chance',
                                style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: locked ? null : onBuy,
                      child: Text(Fmt.moneyCompact(upgrade.price)),
                    ),
                  ],
                ),
                // A locked rung shows the licence and how far off it is, so the
                // ladder reads as a goal rather than a refusal.
                if (upgrade.hasLicenceGate) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(locked ? Icons.lock_outline : Icons.verified_outlined,
                          size: 14,
                          color: locked ? AppTheme.gold : AppTheme.up),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${upgrade.reqLabel}${locked ? '' : ' — earned'}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: locked ? AppTheme.gold : AppTheme.up,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  if (locked) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: upgrade.licenceProgress(licence),
                        minHeight: 4,
                        color: AppTheme.gold,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ] else ...[
          const SizedBox(height: 6),
          Text('Fully upgraded.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppTheme.gold)),
        ],
      ],
    );
  }
}

class _LifetimeCard extends StatelessWidget {
  const _LifetimeCard({required this.fishery});

  final Fishery fishery;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _Stat(label: 'Fish landed', value: '${fishery.lifetimeCatches}'),
            _Stat(label: 'Trips', value: '${fishery.tripsCompleted}'),
            _Stat(
                label: 'Best haul',
                value: Fmt.moneyCompact(fishery.bestHaul)),
            _Stat(
                label: 'Gear value',
                value: Fmt.moneyCompact(fishery.gearValue)),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(value,
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}

/// The permanent record — every species, whether you have landed one, and your
/// personal best. Now also the licence board: these rows are what unlock the
/// top of the gear ladder.
class _CatchLogSheet extends ConsumerWidget {
  const _CatchLogSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final species = ref.watch(fishSpeciesProvider).value ?? const <FishSpecies>[];
    final log = ref.watch(fishLogProvider).value ?? const <FishLogEntry>[];
    final byCode = {for (final l in log) l.speciesCode: l};
    final found = species.where((s) => byCode.containsKey(s.code)).length;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
        children: [
          Row(
            children: [
              Text('Catch log', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              Text('$found / ${species.length}',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Species logged here are what earn the licences on the top boats '
            'and rods. No amount of cash substitutes for them.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final s in species) _LogRow(species: s, entry: byCode[s.code]),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.species, required this.entry});

  final FishSpecies species;
  final FishLogEntry? entry;

  @override
  Widget build(BuildContext context) {
    final caught = entry != null;
    final color = species.rarity.color;
    return Opacity(
      opacity: caught ? 1 : 0.42,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: caught ? 0.22 : 0.1),
            border: Border.all(color: color.withValues(alpha: 0.6)),
          ),
          child: Icon(caught ? Icons.set_meal : Icons.help_outline,
              size: 17, color: color),
        ),
        title: Text(caught ? species.name : '???',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          caught
              ? '${entry!.catches} caught · best ${Fmt.weight(entry!.bestKg)}'
              : '${species.rarity.label} · needs a tier-${species.minBoatTier} boat',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: Text(
          species.rarity.label,
          style:
              TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

class _SoundToggle extends ConsumerWidget {
  const _SoundToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(soundEnabledProvider);
    return IconButton(
      tooltip: on ? 'Sound on' : 'Sound off',
      icon: Icon(on ? Icons.volume_up : Icons.volume_off),
      onPressed: () {
        ref.read(soundEnabledProvider.notifier).toggle();
        if (!on) Sfx.tick();
      },
    );
  }
}

String _humanDuration(Duration d) {
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  final hours = d.inMinutes / 60;
  if (hours < 24) return '${hours.toStringAsFixed(hours < 10 ? 1 : 0)} hours';
  return '${(hours / 24).toStringAsFixed(1)} days';
}
