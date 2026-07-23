import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter/services.dart';

import '../../../core/feedback.dart';
import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/celebration.dart';
import '../../../core/widgets/price_flash.dart';
import '../../market/data/market_repository.dart';
import '../../market/domain/asset.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../portfolio/domain/holding.dart';
import '../data/income_repository.dart';
import '../domain/user_income.dart';

/// Real days that make up one game-year (mirrors the server's
/// seconds_per_game_year = 14 days). Passive yields are annual, so per-day
/// income is the annual figure spread across this many real days.
const double _gameYearRealDays = 14;

/// Portfolio card for passive income: what's waiting to be collected, the
/// projected daily earn rate, and a Collect button. This is the "check what I
/// made while I was away" moment.
class IncomeCard extends ConsumerWidget {
  const IncomeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final income = ref.watch(incomeProvider).value ?? UserIncome.empty;
    final holdings = ref.watch(holdingsProvider).value ?? const <Holding>[];
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final assetById = {for (final a in assets) a.id: a};

    // Annualised passive income from current holdings → per real day.
    var annual = 0.0;
    for (final h in holdings) {
      final a = assetById[h.assetId];
      if (a != null && a.paysIncome) {
        annual += h.quantity * a.currentPrice * a.incomeYield;
      }
    }
    final perDay = annual / _gameYearRealDays;
    final earning = annual > 0;

    // Nothing to show and nothing earning: keep the portfolio uncluttered, but
    // still nudge once so players learn the mechanic exists.
    if (!earning && !income.hasPending && income.lifetimeIncome == 0) {
      return const _IncomeHint();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.savings_outlined,
                    size: 18, color: AppTheme.gold),
                const SizedBox(width: 8),
                Text('PASSIVE INCOME',
                    style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade400)),
                const Spacer(),
                if (earning)
                  Text('~${Fmt.money(perDay)}/day',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.up)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        income.hasPending
                            ? 'Ready to collect'
                            : 'Collected so far',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 2),
                      AnimatedMoney(
                        value: income.hasPending
                            ? income.pendingTotal
                            : income.lifetimeIncome,
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: income.hasPending
                                    ? AppTheme.gold
                                    : null),
                      ),
                      if (income.hasPending)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            _breakdown(income),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        income.hasPending ? AppTheme.gold : null,
                    foregroundColor:
                        income.hasPending ? Colors.black : null,
                  ),
                  icon: const Icon(Icons.account_balance_wallet, size: 16),
                  onPressed:
                      income.hasPending ? () => _collect(context, ref) : null,
                  label: const Text('Collect'),
                ),
              ],
            ),
            if (income.hasPending && income.lifetimeIncome > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Lifetime income ${Fmt.money(income.lifetimeIncome)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _collectedSubtitle(IncomeCollected r) {
    final parts = <String>[
      if (r.dividends > 0) '${Fmt.money(r.dividends)} dividends',
      if (r.rent > 0) '${Fmt.money(r.rent)} rent',
      if (r.business > 0) '${Fmt.money(r.business)} business',
    ];
    return parts.isEmpty ? Fmt.money(r.total) : parts.join(' + ');
  }

  static String _breakdown(UserIncome income) {
    final parts = <String>[
      if (income.pendingDividends > 0)
        'Dividends ${Fmt.money(income.pendingDividends)}',
      if (income.pendingRent > 0) 'Rent ${Fmt.money(income.pendingRent)}',
      if (income.pendingBusiness > 0)
        'Business ${Fmt.money(income.pendingBusiness)}',
    ];
    return parts.join('  ·  ');
  }

  Future<void> _collect(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await ref.read(incomeRepositoryProvider).collect();
      if (!context.mounted) return;
      if (result.collected) {
        if (ref.read(feedbackEnabledProvider)) {
          HapticFeedback.mediumImpact();
          showCelebration(
            context,
            title: 'Income collected',
            subtitle: _collectedSubtitle(result),
            emoji: '💰',
          );
        }
        messenger.showSnackBar(SnackBar(
          content: Text('Collected ${Fmt.money(result.total)} passive income'),
          backgroundColor: AppTheme.up.withValues(alpha: 0.9),
        ));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

/// First-run nudge for players not yet earning any passive income.
class _IncomeHint extends StatelessWidget {
  const _IncomeHint();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.savings_outlined,
                size: 20, color: AppTheme.gold),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Earn while you sleep: dividend stocks (like XOFF) and real-'
                'estate REITs pay passive income you can collect here.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
