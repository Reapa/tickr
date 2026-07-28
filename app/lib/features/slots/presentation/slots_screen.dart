import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/feedback.dart';
import '../../../core/format.dart';
import '../../../core/sound.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/celebration.dart';
import '../../profile/data/profile_repository.dart';
import '../data/slots_repository.dart';

/// The slot machine.
///
/// The reels are decided entirely by the server before the animation starts —
/// what spins on screen is a replay of a result that already exists, never a
/// client-side roll. The odds are published in full on this screen, because a
/// game that hides its payout table is a different kind of product.
class SlotsScreen extends ConsumerStatefulWidget {
  const SlotsScreen({super.key});

  @override
  ConsumerState<SlotsScreen> createState() => _SlotsScreenState();
}

class _SlotsScreenState extends ConsumerState<SlotsScreen> {
  static const _betSteps = [10.0, 50.0, 100.0, 500.0, 1000.0, 5000.0];

  double _bet = 100;
  bool _spinning = false;
  SpinResult? _result;

  /// What each reel currently shows. During a spin these cycle; as each reel
  /// stops it locks to the server's answer.
  final List<String?> _shown = [null, null, null];
  final _stopped = [true, true, true];
  Timer? _tumble;

  @override
  void dispose() {
    _tumble?.cancel();
    super.dispose();
  }

  Future<void> _spin() async {
    if (_spinning) return;
    final symbols = ref.read(slotOddsProvider).value?.symbols ?? const [];
    if (symbols.isEmpty) return;

    Sfx.unlock();
    setState(() {
      _spinning = true;
      _result = null;
      _stopped.setAll(0, [false, false, false]);
    });
    Sfx.slotSpin();

    // Tumble the reels while we wait on the server.
    final rng = math.Random();
    _tumble = Timer.periodic(const Duration(milliseconds: 70), (_) {
      if (!mounted) return;
      setState(() {
        for (var i = 0; i < 3; i++) {
          if (!_stopped[i]) {
            _shown[i] = symbols[rng.nextInt(symbols.length)].code;
          }
        }
      });
    });

    SpinResult result;
    try {
      result = await ref.read(slotsRepositoryProvider).spin(_bet);
    } catch (error) {
      _tumble?.cancel();
      if (!mounted) return;
      setState(() => _spinning = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
      return;
    }

    if (!mounted) return;
    if (!result.isSpun) {
      _tumble?.cancel();
      Sfx.nope();
      setState(() {
        _spinning = false;
        _stopped.setAll(0, [true, true, true]);
      });
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.reason ?? 'Could not spin.')));
      return;
    }

    // Stop the reels left to right. The stagger is the entire drama of a slot
    // machine: two matching reels and one still spinning is the whole game.
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration(milliseconds: i == 0 ? 620 : 520));
      if (!mounted) return;
      setState(() {
        _shown[i] = result.reels[i];
        _stopped[i] = true;
      });
      Sfx.slotStop(i);
    }

    _tumble?.cancel();
    if (!mounted) return;
    setState(() {
      _spinning = false;
      _result = result;
    });

    ref.invalidate(myProfileProvider);
    ref.invalidate(arcadeStatsProvider);

    await Future<void>.delayed(const Duration(milliseconds: 160));
    if (!mounted) return;
    if (result.isJackpot) {
      Sfx.slotJackpot();
      if (ref.read(feedbackEnabledProvider)) {
        showCelebration(
          context,
          title: 'JACKPOT!',
          subtitle: '${result.multiplier.toStringAsFixed(0)}× — '
              '${Fmt.money(result.payout)}',
          emoji: '🎰',
        );
      }
    } else if (result.isWin) {
      // Louder for bigger multipliers.
      Sfx.slotWin(result.multiplier >= 20 ? 6 : 3);
      if (result.multiplier >= 20 && ref.read(feedbackEnabledProvider)) {
        showCelebration(
          context,
          title: 'Big win!',
          subtitle: '${result.multiplier.toStringAsFixed(0)}× — '
              '${Fmt.money(result.payout)}',
          emoji: '💰',
        );
      }
    } else {
      Sfx.slotLose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final odds = ref.watch(slotOddsProvider).value;
    final cash = ref.watch(myProfileProvider).value?.cashBalance ?? 0;
    final stats = ref.watch(arcadeStatsProvider).value ?? ArcadeStats.empty;
    final canSpin = !_spinning && odds != null && cash >= _bet;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Slots'),
        actions: [
          IconButton(
            tooltip: 'Odds & payouts',
            icon: const Icon(Icons.info_outline),
            onPressed: odds == null
                ? null
                : () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => _OddsSheet(odds: odds),
                    ),
          ),
          const _SoundToggle(),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _Cabinet(shown: _shown, spinning: _spinning, result: _result),
          const SizedBox(height: 14),
          _ResultLine(result: _result, spinning: _spinning),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('Bet', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Text('Cash ${Fmt.money(cash)}',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final step in _betSteps)
                if (odds == null ||
                    (step >= odds.minBet && step <= odds.maxBet))
                  ChoiceChip(
                    label: Text(Fmt.moneyCompact(step)),
                    selected: _bet == step,
                    onSelected: _spinning
                        ? null
                        : (_) {
                            Sfx.tick();
                            setState(() => _bet = step);
                          },
                  ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.gold,
              foregroundColor: Colors.black,
              minimumSize: const Size.fromHeight(56),
            ),
            onPressed: canSpin ? _spin : null,
            child: Text(
              _spinning
                  ? 'Spinning…'
                  : cash < _bet
                      ? 'Not enough cash'
                      : 'SPIN  ·  ${Fmt.money(_bet)}',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 1),
            ),
          ),
          const SizedBox(height: 18),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _Stat(label: 'Spins', value: '${stats.spins}'),
                      _Stat(
                          label: 'Best win',
                          value: Fmt.moneyCompact(stats.biggestWin)),
                      _Stat(
                        label: 'Net',
                        value:
                            '${stats.netPnl >= 0 ? '+' : ''}${Fmt.moneyCompact(stats.netPnl)}',
                        color: AppTheme.changeColor(stats.netPnl),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Slots pays real cash, but your arcade result is kept off '
                    'the season leaderboard — win or lose, your season return '
                    'is your trading only.'
                    '${odds == null ? '' : ' The house edge is '
                        '${odds.housePct.toStringAsFixed(1)}%, so over time '
                        'this costs money. That is the deal.'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The three reels.
class _Cabinet extends ConsumerWidget {
  const _Cabinet({
    required this.shown,
    required this.spinning,
    required this.result,
  });

  final List<String?> shown;
  final bool spinning;
  final SpinResult? result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final symbols = ref.watch(slotSymbolsByCodeProvider);
    final won = result?.isWin ?? false;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3B1F5C), Color(0xFF1B0E2B)],
        ),
        border: Border.all(
          color: won
              ? AppTheme.gold
              : Colors.white.withValues(alpha: 0.12),
          width: won ? 2 : 1,
        ),
        boxShadow: (result?.isJackpot ?? false)
            ? [BoxShadow(color: AppTheme.gold.withValues(alpha: 0.5), blurRadius: 30)]
            : null,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (var i = 0; i < 3; i++)
            _Reel(symbol: symbols[shown[i]], spinning: spinning),
        ],
      ),
    );
  }
}

class _Reel extends StatelessWidget {
  const _Reel({required this.symbol, required this.spinning});

  final SlotSymbol? symbol;
  final bool spinning;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      width: 84,
      height: 96,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: (symbol?.color ?? Colors.white).withValues(alpha: 0.35)),
      ),
      alignment: Alignment.center,
      child: symbol == null
          ? Icon(Icons.question_mark,
              size: 34, color: Colors.white.withValues(alpha: 0.3))
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(symbol!.icon, size: 38, color: symbol!.color),
                const SizedBox(height: 4),
                Text(
                  symbol!.name,
                  style: TextStyle(
                      fontSize: 9,
                      letterSpacing: 0.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white.withValues(alpha: 0.6)),
                ),
              ],
            ),
    );
  }
}

class _ResultLine extends StatelessWidget {
  const _ResultLine({required this.result, required this.spinning});

  final SpinResult? result;
  final bool spinning;

  @override
  Widget build(BuildContext context) {
    if (spinning) {
      return Text('Good luck.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium);
    }
    final r = result;
    if (r == null) {
      return Text('Pick a stake and pull the lever.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall);
    }
    if (!r.isWin) {
      return Text('No match — ${Fmt.money(r.bet)} gone.',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: AppTheme.down));
    }
    return Column(
      children: [
        Text(
          r.isJackpot
              ? 'JACKPOT — ${r.symbolName}!'
              : '${r.symbolName} · ${r.multiplier.toStringAsFixed(0)}×',
          style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
              color: r.isJackpot ? AppTheme.gold : AppTheme.up),
        ),
        Text(
          '+${Fmt.money(r.payout)}  (${r.net >= 0 ? '+' : ''}${Fmt.money(r.net)} net)',
          style: TextStyle(
              fontWeight: FontWeight.w700,
              color: AppTheme.changeColor(r.net)),
        ),
      ],
    );
  }
}

/// The full payout table and the real return-to-player figure.
class _OddsSheet extends StatelessWidget {
  const _OddsSheet({required this.odds});

  final SlotOdds odds;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
        children: [
          Text('Odds & payouts',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            'Payouts are multiples of your stake. Three of a kind pays the '
            'left column; exactly two of the higher symbols pays the right. '
            'Every reel is drawn independently on the server.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(flex: 4, child: Text('Symbol')),
              const Expanded(
                  flex: 2,
                  child: Text('Chance', textAlign: TextAlign.right)),
              const Expanded(
                  flex: 2, child: Text('×3', textAlign: TextAlign.right)),
              const Expanded(
                  flex: 2, child: Text('×2', textAlign: TextAlign.right)),
            ].map((w) => w).toList(),
          ),
          const Divider(),
          for (final s in odds.symbols)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: Row(children: [
                      Icon(s.icon, size: 18, color: s.color),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(s.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600))),
                    ]),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text('${(s.chance * 100).toStringAsFixed(1)}%',
                        textAlign: TextAlign.right,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text('${s.pay3.toStringAsFixed(0)}×',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                        s.pay2 == 0 ? '—' : '${s.pay2.toStringAsFixed(0)}×',
                        textAlign: TextAlign.right,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.down.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Return to player: ${(odds.rtp * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  'For every ${Fmt.money(100)} staked, this machine pays back '
                  '${Fmt.money(odds.rtp * 100)} on average. The house keeps '
                  '${odds.housePct.toStringAsFixed(1)}%. Play it for the '
                  'moments, not the money — it is a losing bet by design, and '
                  'your season score is not affected either way.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w800, color: color)),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
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
