import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// The Fishery — the idle mini-game.
///
/// Two loops share one screen: the boat fills a capped hold while you're away
/// (come back and sell), and casting by hand spends bait you can't buy (the
/// thing to actually do while a market is closed).
class FisheryScreen extends ConsumerStatefulWidget {
  const FisheryScreen({super.key});

  @override
  ConsumerState<FisheryScreen> createState() => _FisheryScreenState();
}

class _FisheryScreenState extends ConsumerState<FisheryScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rod = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );
  CastResult? _lastCatch;
  bool _busy = false;

  @override
  void dispose() {
    _rod.dispose();
    super.dispose();
  }

  void _refresh() {
    ref.invalidate(fisheryProvider);
    ref.invalidate(fisheryHoldProvider);
    ref.invalidate(fishLogProvider);
  }

  Future<void> _cast() async {
    if (_busy) return;
    setState(() => _busy = true);
    // The browser only lets audio start from inside a user gesture.
    Sfx.unlock();
    Sfx.cast();
    _rod.forward(from: 0);

    try {
      final result = await ref.read(fishingRepositoryProvider).cast();
      if (!mounted) return;

      if (!result.isCatch) {
        Sfx.nope();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.reason ?? 'Nothing biting.')),
        );
        _refresh();
        return;
      }

      // Let the line land before the fish appears — the tiny pause is what
      // makes it read as a catch rather than a database write.
      await Future<void>.delayed(const Duration(milliseconds: 380));
      if (!mounted) return;
      Sfx.splash();
      await Future<void>.delayed(const Duration(milliseconds: 140));
      if (!mounted) return;

      switch (result.rarity) {
        case FishRarity.legendary:
          Sfx.catchLegendary();
        case FishRarity.epic:
          Sfx.catchRare();
        case FishRarity.rare:
          Sfx.catchRare();
        default:
          Sfx.catchCommon();
      }

      setState(() => _lastCatch = result);
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
      if (result.rarity.isSpecial) {
        // Epic and legendary catches drop a reward crate server-side.
        ref.invalidate(unopenedCratesProvider);
      }
      _refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nothing in the hold yet.')),
        );
        return;
      }
      Sfx.reel();
      await Future<void>.delayed(const Duration(milliseconds: 220));
      if (!mounted) return;
      Sfx.cash();
      setState(() => _lastCatch = null);
      _refresh();
      ref.invalidate(myProfileProvider);
      ref.invalidate(recentOrdersProvider);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppTheme.up,
        content: Text(
          'Sold ${result.count} fish for ${Fmt.money(result.total)}'
          '${result.bestName != null ? ' — best: ${result.bestName} '
              '(${Fmt.weight(result.bestKg)})' : ''}',
          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700),
        ),
      ));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(fisheryProvider);

    return Scaffold(
      appBar: AppBar(
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
        data: (fishery) => RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _WaterPanel(
                fishery: fishery,
                rod: _rod,
                lastCatch: _lastCatch,
              ),
              const SizedBox(height: 16),
              _CastBar(
                fishery: fishery,
                busy: _busy,
                onCast: _cast,
              ),
              const SizedBox(height: 16),
              _HoldCard(fishery: fishery, busy: _busy, onSell: _sell),
              const SizedBox(height: 16),
              _GearCard(fishery: fishery, onBought: _refresh),
              const SizedBox(height: 16),
              _LifetimeCard(fishery: fishery),
            ],
          ),
        ),
      ),
    );
  }
}

/// The scene: water, a boat, and the last thing you pulled out of it.
class _WaterPanel extends StatelessWidget {
  const _WaterPanel({
    required this.fishery,
    required this.rod,
    required this.lastCatch,
  });

  final Fishery fishery;
  final AnimationController rod;
  final CastResult? lastCatch;

  @override
  Widget build(BuildContext context) {
    final result = lastCatch;
    return Container(
      height: 210,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0E3A5C), Color(0xFF061E30)],
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: rod,
              builder: (context, _) =>
                  CustomPaint(painter: _WaterPainter(rod.value)),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 14,
            child: Text(
              fishery.boatName.toUpperCase(),
              textAlign: TextAlign.center,
              style: TextStyle(
                letterSpacing: 2,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            ),
          ),
          if (result != null)
            Positioned.fill(
              child: Center(
                child: _CatchCard(result: result),
              ),
            )
          else
            Positioned.fill(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    fishery.holdIsFull
                        ? 'The hold is full. Sell the catch to make room.'
                        : 'Your ${fishery.boatName.toLowerCase()} is fishing.\n'
                            'Cast a line, or come back later.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.72),
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Gentle parallax swells, disturbed briefly when a line goes out.
class _WaterPainter extends CustomPainter {
  _WaterPainter(this.cast);

  final double cast;

  @override
  void paint(Canvas canvas, Size size) {
    for (var layer = 0; layer < 3; layer++) {
      final paint = Paint()
        ..color = Colors.white.withValues(alpha: 0.05 + layer * 0.03)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      final path = Path();
      final baseY = size.height * (0.55 + layer * 0.13);
      // A ripple that swells while the cast animation plays, then settles.
      final amplitude = 4.0 + layer * 2 + math.sin(cast * math.pi) * 7;
      path.moveTo(0, baseY);
      for (double x = 0; x <= size.width; x += 6) {
        final y = baseY +
            math.sin((x / size.width * 4 * math.pi) + layer * 1.3 + cast * 6) *
                amplitude;
        path.lineTo(x, y);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_WaterPainter old) => old.cast != cast;
}

/// The reveal: what you just landed, coloured by rarity.
class _CatchCard extends StatelessWidget {
  const _CatchCard({required this.result});

  final CastResult result;

  @override
  Widget build(BuildContext context) {
    final color = result.rarity.color;
    return AnimatedScale(
      scale: 1,
      duration: const Duration(milliseconds: 220),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
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
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 2),
            Text(
              '${Fmt.weight(result.weightKg)} · ${Fmt.money(result.value)}',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.85)),
            ),
            if (result.isPersonalBest) ...[
              const SizedBox(height: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.gold.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('PERSONAL BEST',
                    style: TextStyle(
                        color: AppTheme.gold,
                        fontSize: 9,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w900)),
              ),
            ],
            if (result.blurb.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                result.blurb,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 11,
                    fontStyle: FontStyle.italic),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Cast button plus the bait budget that gates it.
class _CastBar extends StatelessWidget {
  const _CastBar({
    required this.fishery,
    required this.busy,
    required this.onCast,
  });

  final Fishery fishery;
  final bool busy;
  final VoidCallback onCast;

  @override
  Widget build(BuildContext context) {
    final next = fishery.nextBaitAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: busy || !fishery.canCast ? null : onCast,
          icon: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.phishing),
          label: Text(
            fishery.holdIsFull
                ? 'Hold full — sell your catch'
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
      ],
    );
  }
}

/// The hold: how full it is, what it's worth, and the sell button.
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
                Text('${fishery.holdCount} / ${fishery.holdCapacity}',
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
            if (hold.isNotEmpty) ...[
              const SizedBox(height: 12),
              // The five best fish aboard: the reason to feel good about a
              // week away, without listing three hundred sardines.
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

/// Boat and rod upgrades.
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

    // Only ever the next rung of each ladder: an upgrade path, not a shop wall.
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
              'business net worth, the same as a property.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _GearRow(
              label: 'Boat',
              owned: fishery.boatName,
              detail: '${fishery.catchPerHour.toStringAsFixed(0)} fish/hr · '
                  'hold ${fishery.holdCapacity}',
              next: nextBoat,
              onBuy: nextBoat == null
                  ? null
                  : () => _buy(context, ref, nextBoat),
            ),
            const Divider(height: 24),
            _GearRow(
              label: 'Rod',
              owned: fishery.rodName,
              detail: 'Better rods find rarer fish',
              next: nextRod,
              onBuy:
                  nextRod == null ? null : () => _buy(context, ref, nextRod),
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
    required this.onBuy,
  });

  final String label;
  final String owned;
  final String detail;
  final FishingGear? next;
  final VoidCallback? onBuy;

  @override
  Widget build(BuildContext context) {
    final upgrade = next;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('$label: ',
                style: Theme.of(context).textTheme.bodySmall),
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
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(upgrade.name,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
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
                  onPressed: onBuy,
                  child: Text(Fmt.moneyCompact(upgrade.price)),
                ),
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
            _Stat(
                label: 'Lifetime earned',
                value: Fmt.moneyCompact(fishery.lifetimeValue)),
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
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w800)),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}

/// The permanent record — every species, whether you've landed one, and your
/// personal best. The completionist's reason to keep upgrading the boat.
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
          const SizedBox(height: 12),
          for (final s in species)
            _LogRow(species: s, entry: byCode[s.code]),
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
      // Unfound species stay listed but dimmed — you can see what's out there
      // and which boat you'd need for it.
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
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

/// Sound is off by default, so it needs to be one obvious tap away from the
/// games that use it.
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
