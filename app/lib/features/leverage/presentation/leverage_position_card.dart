import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../market/domain/asset.dart';
import '../data/leverage_repository.dart';
import '../domain/leveraged_position.dart';

/// One leveraged position: side/leverage badge, live P&L on margin, a
/// danger meter toward the liquidation price, and close/protect actions.
class LeveragePositionCard extends ConsumerWidget {
  const LeveragePositionCard({
    super.key,
    required this.position,
    required this.asset,
  });

  final LeveragedPosition position;
  final Asset? asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = asset;
    if (a == null) return const SizedBox.shrink();
    final sideColor = position.isLong ? AppTheme.up : AppTheme.down;

    if (!position.isOpen) {
      final pnl = position.realizedPnl ?? 0;
      return Card(
        child: ListTile(
          dense: true,
          leading: Icon(
            position.status == 'liquidated'
                ? Icons.local_fire_department
                : Icons.flag_circle_outlined,
            color: position.status == 'liquidated'
                ? AppTheme.down
                : AppTheme.changeColor(pnl),
          ),
          title: Text(
              '${position.isLong ? 'LONG' : 'SHORT'} ${position.leverage}x '
              '${a.symbol} — ${position.closeReason?.replaceAll('_', ' ')}'),
          subtitle: Text(
            '${pnl >= 0 ? '+' : ''}${Fmt.money(pnl)} on ${Fmt.money(position.margin)} margin',
            style: TextStyle(color: AppTheme.changeColor(pnl)),
          ),
        ),
      );
    }

    final mark = position.isLong ? a.bidPrice : a.askPrice;
    final pnl = position.pnlAt(mark);
    final rom = position.returnOnMarginAt(mark);
    final danger = position.liquidationProgressAt(mark);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: sideColor.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${position.isLong ? '▲ LONG' : '▼ SHORT'} ${position.leverage}x',
                    style: TextStyle(
                        color: sideColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                Text(a.symbol,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${pnl >= 0 ? '+' : ''}${Fmt.money(pnl)}',
                      style: TextStyle(
                          color: AppTheme.changeColor(pnl),
                          fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${Fmt.pct(rom)} on margin',
                      style: TextStyle(
                          fontSize: 11, color: AppTheme.changeColor(pnl)),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Entry ${Fmt.money(position.entryPrice)} · now ${Fmt.money(mark)} '
              '· margin ${Fmt.money(position.margin)}'
              '${position.takeProfit != null ? ' · 🎯 ${Fmt.money(position.takeProfit!)}' : ''}'
              '${position.stopLoss != null ? ' · 🛡 ${Fmt.money(position.stopLoss!)}' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: danger,
                      minHeight: 5,
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      color: danger > 0.75
                          ? AppTheme.down
                          : danger > 0.4
                              ? Colors.orange
                              : AppTheme.up,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'liq ${Fmt.money(position.liquidationPrice)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: danger > 0.75 ? AppTheme.down : Colors.grey,
                  ),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => _protect(context, ref, mark),
                  child: const Text('Protect'),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: AppTheme.down),
                  onPressed: () => _close(context, ref, pnl),
                  child: const Text('Close'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _close(BuildContext context, WidgetRef ref, double pnl) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Close position?'),
        content: Text(
            'Realize ${pnl >= 0 ? 'a profit of ' : 'a loss of '}${Fmt.money(pnl.abs())} '
            'and return your margin${pnl < 0 ? ' minus the loss' : ''}.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Close position')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final result = await ref
          .read(leverageRepositoryProvider)
          .closePosition(position.id);
      messenger.showSnackBar(SnackBar(
          content: Text('Closed: ${Fmt.money(
              (result['proceeds'] as num?)?.toDouble() ?? 0)} returned')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _protect(
      BuildContext context, WidgetRef ref, double mark) async {
    // Prices are USD internally but typed/shown in the display currency.
    String disp(double usd) =>
        (usd * Fmt.rate).toStringAsFixed(Fmt.current.decimals);
    double? toUsdOrNull(String s) {
      final v = double.tryParse(s);
      return v == null ? null : Fmt.toUsd(v).toDouble();
    }

    final tp = TextEditingController(
        text: disp(position.takeProfit ??
            (position.isLong ? mark * 1.05 : mark * 0.95)));
    final sl = TextEditingController(
        text: disp(position.stopLoss ??
            (position.isLong ? mark * 0.97 : mark * 1.03)));
    final trail = TextEditingController(text: '5');
    var useTrailing = false;
    final messenger = ScaffoldMessenger.of(context);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Protect position'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: tp,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: 'Take profit price',
                    prefixText: '${Fmt.symbol} '),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Checkbox(
                      value: useTrailing,
                      visualDensity: VisualDensity.compact,
                      onChanged: (v) =>
                          setState(() => useTrailing = v ?? false)),
                  const Expanded(child: Text('Trailing stop (follows the price)')),
                ],
              ),
              useTrailing
                  ? TextField(
                      controller: trail,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Trail distance',
                        suffixText: '%',
                        helperText: 'Ratchets toward profit, never back.',
                      ),
                    )
                  : TextField(
                      controller: sl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: 'Stop loss price',
                        prefixText: '${Fmt.symbol} ',
                        helperText:
                            'Must stay inside liq ${Fmt.money(position.liquidationPrice)}',
                      ),
                    ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (saved != true) return;
    try {
      final repo = ref.read(leverageRepositoryProvider);
      final Map<String, dynamic> result;
      if (useTrailing) {
        final raw = double.tryParse(trail.text) ?? 0;
        result = await repo.setTrailingStop(
          positionId: position.id,
          trail: raw / 100,
          isPercent: true,
        );
      } else {
        result = await repo.setProtection(
          positionId: position.id,
          takeProfit: toUsdOrNull(tp.text),
          stopLoss: toUsdOrNull(sl.text),
        );
      }
      messenger.showSnackBar(SnackBar(
          content: Text(result['status'] == 'protected'
              ? 'Protection set'
              : '${result['reason']}')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}
