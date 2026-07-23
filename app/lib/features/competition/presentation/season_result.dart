import 'package:flutter/material.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/celebration.dart';
import '../data/competition_repository.dart';

/// Show the season results reveal. A podium finish (or top 10%) also fires the
/// full-screen confetti celebration behind the card.
void showSeasonResult(BuildContext context, SeasonResult r) {
  if (r.isPodium || r.top10) {
    showCelebration(
      context,
      title: 'Season ${r.seasonNumber} complete',
      subtitle: r.isPodium
          ? 'You finished #${r.rank}!'
          : 'Top ${(r.percentile * 100).ceil()}% — well played',
      emoji: r.rank == 1 ? '🥇' : (r.isPodium ? '🏅' : '🏆'),
    );
  }
  showDialog<void>(
    context: context,
    builder: (_) => _SeasonResultDialog(result: r),
  );
}

class _SeasonResultDialog extends StatelessWidget {
  const _SeasonResultDialog({required this.result});

  final SeasonResult result;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final medal = switch (r.rank) { 1 => '🥇', 2 => '🥈', 3 => '🥉', _ => '🎏' };
    final color = r.isPodium
        ? AppTheme.gold
        : r.top10
            ? const Color(0xFF3EA6FF)
            : Colors.grey.shade400;

    final rewards = <String>[
      if (r.rewardCash > 0) '${Fmt.money(r.rewardCash)} cash',
      if (r.rewardGems > 0) '${r.rewardGems} 💎',
      if (r.rewardCosmetic != null) 'an exclusive frame',
    ];

    return Dialog(
      backgroundColor: AppTheme.surfaceHigh,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('SEASON ${r.seasonNumber} COMPLETE',
                style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w800,
                    color: Colors.grey.shade400)),
            const SizedBox(height: 14),
            Text(medal, style: const TextStyle(fontSize: 56)),
            const SizedBox(height: 6),
            Text('#${r.rank} of ${r.players}',
                style: const TextStyle(
                    fontSize: 28, fontWeight: FontWeight.w900)),
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: color.withValues(alpha: 0.4)),
              ),
              child: Text(
                r.top10
                    ? 'TOP ${(r.percentile * 100).ceil()}%'
                    : 'Top ${(r.percentile * 100).ceil()}%',
                style: TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 12, color: color),
              ),
            ),
            const SizedBox(height: 12),
            Text('${r.pctReturn >= 0 ? '+' : ''}${Fmt.pct(r.pctReturn)} return',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.changeColor(r.pctReturn))),
            if (rewards.isNotEmpty) ...[
              const Divider(height: 26),
              Text('YOU EARNED',
                  style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w700,
                      color: Colors.grey.shade500)),
              const SizedBox(height: 6),
              Text(rewards.join('  ·  '),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700)),
            ],
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Onward'),
            ),
          ],
        ),
      ),
    );
  }
}
