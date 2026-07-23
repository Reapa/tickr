import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cosmetics.dart';
import '../../../core/theme.dart';
import '../../profile/data/profile_repository.dart';
import '../data/crates_repository.dart';
import '../domain/crate.dart';

Color _rarityColor(String? rarity) => switch (rarity) {
      'legendary' => AppTheme.gold,
      'epic' => const Color(0xFFB05CFF),
      'rare' => const Color(0xFF3EA6FF),
      _ => Colors.grey.shade400,
    };

String _tierEmoji(String tier) => switch (tier) {
      'legendary' => '🏆',
      'rare' => '🎁',
      _ => '📦',
    };

/// A card for the Profile screen: shows how many crates are waiting and opens
/// them one at a time with the reveal animation. Invisible when there are none.
class CratesCard extends ConsumerWidget {
  const CratesCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final crates = ref.watch(unopenedCratesProvider).value ?? const <Crate>[];
    if (crates.isEmpty) return const SizedBox.shrink();
    final next = crates.first;
    final color = _rarityColor(next.tier == 'legendary'
        ? 'legendary'
        : next.tier == 'rare'
            ? 'rare'
            : 'common');
    return Card(
      color: color.withValues(alpha: 0.12),
      child: ListTile(
        leading: Text(_tierEmoji(next.tier), style: const TextStyle(fontSize: 30)),
        title: Text(
            crates.length == 1
                ? '1 reward crate to open'
                : '${crates.length} reward crates to open',
            style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text('Tap to reveal — cosmetics & XP inside',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
        trailing: FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: color, foregroundColor: Colors.black),
          onPressed: () => openAndReveal(context, ref, next),
          child: const Text('Open'),
        ),
        onTap: () => openAndReveal(context, ref, next),
      ),
    );
  }
}

/// Open [crate] on the server and play the reveal. Refreshes profile + crate
/// inventory afterward so the new XP / cosmetic and remaining count are current.
Future<void> openAndReveal(
    BuildContext context, WidgetRef ref, Crate crate) async {
  final future = ref.read(cratesRepositoryProvider).openCrate(crate.id);
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CrateRevealDialog(tier: crate.tier, reward: future),
  );
  ref.invalidate(myProfileProvider);
  ref.invalidate(unopenedCratesProvider);
}

class _CrateRevealDialog extends StatefulWidget {
  const _CrateRevealDialog({required this.tier, required this.reward});

  final String tier;
  final Future<CrateReward> reward;

  @override
  State<_CrateRevealDialog> createState() => _CrateRevealDialogState();
}

class _CrateRevealDialogState extends State<_CrateRevealDialog>
    with TickerProviderStateMixin {
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  )..repeat(reverse: true);
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  CrateReward? _reward;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    // Hold suspense for at least ~1.2s even if the server replies instantly.
    final results = await Future.wait(
        [widget.reward, Future<void>.delayed(const Duration(milliseconds: 1200))]);
    if (!mounted) return;
    _shake.stop();
    setState(() => _reward = results.first as CrateReward);
    _pop.forward(from: 0);
    HapticFeedback.heavyImpact();
  }

  @override
  void dispose() {
    _shake.dispose();
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reward = _reward;
    final revealed = reward != null && reward.status == 'opened';
    final failed = reward != null && reward.status != 'opened';
    final glow = revealed
        ? _rarityColor(reward.isCosmetic ? reward.rarity : widget.tier)
        : Colors.grey;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(28),
      child: GestureDetector(
        onTap: reward == null ? null : () => Navigator.of(context).pop(),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          decoration: BoxDecoration(
            color: AppTheme.surfaceHigh,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: glow.withValues(alpha: 0.6), width: 1.5),
            boxShadow: [
              BoxShadow(color: glow.withValues(alpha: 0.35), blurRadius: 44, spreadRadius: 2),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (reward == null)
                _suspense()
              else if (failed)
                _failure(reward)
              else
                _revealCard(reward, glow),
            ],
          ),
        ),
      ),
    );
  }

  Widget _suspense() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _shake,
          builder: (context, child) => Transform.rotate(
            angle: (_shake.value - 0.5) * 0.32,
            child: child,
          ),
          child: Text(_tierEmoji(widget.tier), style: const TextStyle(fontSize: 76)),
        ),
        const SizedBox(height: 16),
        const Text('Opening…',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      ],
    );
  }

  Widget _failure(CrateReward r) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, size: 48, color: Colors.orange),
        const SizedBox(height: 12),
        Text(r.reason ?? 'Could not open this crate',
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
        const Text('Tap to close',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  Widget _revealCard(CrateReward r, Color glow) {
    return ScaleTransition(
      scale: CurvedAnimation(parent: _pop, curve: Curves.elasticOut),
      child: FadeTransition(
        opacity: _pop,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 108,
              height: 108,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [glow.withValues(alpha: 0.35), Colors.transparent],
                ),
              ),
              child: _RewardVisual(reward: r),
            ),
            const SizedBox(height: 10),
            if (r.isCosmetic) ...[
              Text((r.rarity ?? '').toUpperCase(),
                  style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w800,
                      color: glow)),
              const SizedBox(height: 2),
              Text(r.name ?? 'Cosmetic',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
              const SizedBox(height: 2),
              Text('New ${_slotLabel(r.slot)} — equip it in the Store',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
            ] else ...[
              Text('+${r.xp} XP',
                  style: TextStyle(
                      fontSize: 28, fontWeight: FontWeight.w900, color: glow)),
              const SizedBox(height: 2),
              Text('Straight to your level progress',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
            ],
            const SizedBox(height: 16),
            const Text('Tap to continue',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  static String _slotLabel(String? slot) => switch (slot) {
        'avatar_frame' => 'avatar frame',
        'profile_badge' => 'badge',
        'chart_theme' => 'chart theme',
        'ticker_skin' => 'ticker skin',
        _ => 'cosmetic',
      };
}

/// Renders the won cosmetic (or an XP burst) at the centre of the reveal.
class _RewardVisual extends StatelessWidget {
  const _RewardVisual({required this.reward});

  final CrateReward reward;

  @override
  Widget build(BuildContext context) {
    if (!reward.isCosmetic) {
      return const Text('⭐', style: TextStyle(fontSize: 52));
    }
    switch (reward.slot) {
      case 'profile_badge':
        return Text(badgeEmoji(reward.code) ?? '🎖',
            style: const TextStyle(fontSize: 52));
      case 'avatar_frame':
        final style = frameStyle(reward.code);
        return Container(
          width: 72,
          height: 72,
          padding: EdgeInsets.all(style?.width ?? 3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(
                colors: style?.colors ?? [Colors.white70, Colors.white24]),
          ),
          child: const DecoratedBox(
            decoration: BoxDecoration(
                shape: BoxShape.circle, color: AppTheme.surface),
            child: Center(child: Icon(Icons.person, size: 30)),
          ),
        );
      case 'chart_theme':
        final t = chartTheme(reward.code);
        return _Swatch(colors: [t.up, t.line, t.down]);
      case 'ticker_skin':
        final s = tickerSkin(reward.code);
        return _Swatch(colors: [
          s.background ?? AppTheme.surface,
          s.accent ?? AppTheme.brand,
          s.text ?? Colors.white,
        ]);
      default:
        return const Icon(Icons.auto_awesome, size: 48);
    }
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.colors});

  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      height: 48,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [for (final c in colors) Expanded(child: ColoredBox(color: c))],
      ),
    );
  }
}
