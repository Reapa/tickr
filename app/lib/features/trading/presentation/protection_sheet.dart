import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../market/domain/asset.dart';
import '../../missions/data/missions_repository.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../portfolio/domain/holding.dart';
import '../data/trading_repository.dart';

/// Opens the take-profit / stop-loss sheet for a held position.
Future<void> showProtectionSheet(
  BuildContext context,
  Asset asset,
  Holding holding,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ProtectionSheet(asset: asset, holding: holding),
    ),
  );
}

class ProtectionSheet extends ConsumerStatefulWidget {
  const ProtectionSheet({super.key, required this.asset, required this.holding});

  final Asset asset;
  final Holding holding;

  @override
  ConsumerState<ProtectionSheet> createState() => _ProtectionSheetState();
}

class _ProtectionSheetState extends ConsumerState<ProtectionSheet> {
  var _tpEnabled = true;
  var _slEnabled = true;
  var _tpPercent = true; // percent vs fixed price
  var _slPercent = true;
  var _slTrailing = false; // stop-loss trails the price
  final _tp = TextEditingController(text: '10');
  final _sl = TextEditingController(text: '5');
  var _busy = false;

  @override
  void dispose() {
    _tp.dispose();
    _sl.dispose();
    super.dispose();
  }

  double? get _tpPrice {
    final v = double.tryParse(_tp.text);
    if (v == null || v <= 0) return null;
    return _tpPercent ? widget.asset.currentPrice * (1 + v / 100) : v;
  }

  double? get _slPrice {
    final v = double.tryParse(_sl.text);
    if (v == null || v <= 0) return null;
    return _slPercent ? widget.asset.currentPrice * (1 - v / 100) : v;
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    final holding = widget.holding;
    final existing = (ref.watch(openOrdersProvider).value ?? const <OpenOrder>[])
        .where((o) => o.assetId == asset.id)
        .toList();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Protect ${asset.symbol}',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            '${Fmt.quantity(holding.quantity)} units @ ${Fmt.money(holding.avgCost)} avg '
            '· now ${Fmt.money(asset.currentPrice)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (existing.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final order in existing)
              Row(
                children: [
                  Icon(
                    order.isTakeProfit
                        ? Icons.flag
                        : order.isTrailingStop
                            ? Icons.trending_up
                            : Icons.shield,
                    size: 16,
                    color: order.isTakeProfit ? AppTheme.up : AppTheme.down,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${order.kindLabel} active @ ${Fmt.money(order.limitPrice)}'
                      '${order.isTrailingStop ? ' (trails ${order.trailLabel})' : ''}'
                      ' (saving replaces it)',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => _cancel(order),
                  ),
                ],
              ),
          ],
          const Divider(height: 24),
          _TriggerEditor(
            label: 'Take profit',
            hint: 'Sell automatically when the price rises to lock in gains.',
            color: AppTheme.up,
            enabled: _tpEnabled,
            isPercent: _tpPercent,
            controller: _tp,
            quickPercents: const [5, 10, 25],
            resultPrice: _tpPrice,
            asset: asset,
            holding: holding,
            onEnabled: (v) => setState(() => _tpEnabled = v),
            onMode: (v) => setState(() => _tpPercent = v),
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 16),
          _TriggerEditor(
            label: 'Stop loss',
            hint: 'Sell automatically when the price falls to cap your loss.',
            color: AppTheme.down,
            enabled: _slEnabled,
            isPercent: _slPercent,
            controller: _sl,
            quickPercents: const [5, 10, 20],
            resultPrice: _slPrice,
            asset: asset,
            holding: holding,
            trailing: _slTrailing,
            onTrailing: (v) => setState(() => _slTrailing = v),
            onEnabled: (v) => setState(() => _slEnabled = v),
            onMode: (v) => setState(() => _slPercent = v),
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: _busy || (!_tpEnabled && !_slEnabled) ? null : _save,
            child: _busy
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Set protection'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final repo = ref.read(tradingRepositoryProvider);
    final assetId = widget.asset.id;

    final tp = _tpEnabled ? _tpPrice : null;
    final trailing = _slEnabled && _slTrailing;
    final sl = (_slEnabled && !_slTrailing) ? _slPrice : null;
    if (tp == null && sl == null && !trailing) return;
    setState(() => _busy = true);
    try {
      final labels = <String>[];
      // A take-profit and/or a fixed stop-loss go through position protection.
      if (tp != null || sl != null) {
        final result = await repo.setPositionProtection(
            assetId: assetId, takeProfit: tp, stopLoss: sl);
        if (result['status'] != 'protected') {
          messenger.showSnackBar(SnackBar(content: Text('${result['reason']}')));
          return;
        }
        if (tp != null) labels.add('🎯 TP @ ${Fmt.money(tp)}');
        if (sl != null) labels.add('🛡 SL @ ${Fmt.money(sl)}');
      }
      // A trailing stop is a separate call (it replaces any fixed stop-loss).
      if (trailing) {
        final raw = double.tryParse(_sl.text) ?? 0;
        final trail = _slPercent ? raw / 100 : raw;
        final result = await repo.setTrailingStop(
            assetId: assetId, trail: trail, isPercent: _slPercent);
        if (result['status'] != 'protected') {
          messenger.showSnackBar(SnackBar(content: Text('${result['reason']}')));
          return;
        }
        labels.add('🛡 Trailing SL '
            '${_slPercent ? '${raw.toStringAsFixed(0)}%' : Fmt.money(raw)}');
      }
      ref.invalidate(openOrdersProvider);
      ref.invalidate(missionsProvider);
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(labels.join(' · '))));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(OpenOrder order) async {
    try {
      await ref.read(tradingRepositoryProvider).cancelPendingOrder(order.id);
      ref.invalidate(openOrdersProvider);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }
}

class _TriggerEditor extends StatelessWidget {
  const _TriggerEditor({
    required this.label,
    required this.hint,
    required this.color,
    required this.enabled,
    required this.isPercent,
    required this.controller,
    required this.quickPercents,
    required this.resultPrice,
    required this.asset,
    required this.holding,
    required this.onEnabled,
    required this.onMode,
    required this.onChanged,
    this.trailing = false,
    this.onTrailing,
  });

  final String label;
  final String hint;
  final Color color;
  final bool enabled;
  final bool isPercent;
  final TextEditingController controller;
  final List<int> quickPercents;
  final double? resultPrice;
  final Asset asset;
  final Holding holding;
  final ValueChanged<bool> onEnabled;
  final ValueChanged<bool> onMode;
  final VoidCallback onChanged;

  /// When [onTrailing] is provided this editor offers a trailing-stop toggle.
  final bool trailing;
  final ValueChanged<bool>? onTrailing;

  @override
  Widget build(BuildContext context) {
    final trailVal = double.tryParse(controller.text) ?? 0;
    // A trailing stop starts a distance below the current price, then follows.
    final trailStart = isPercent
        ? asset.currentPrice * (1 - trailVal / 100)
        : asset.currentPrice - trailVal;
    final pnlAtTrigger = resultPrice == null
        ? null
        : holding.quantity * (resultPrice! - holding.avgCost);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Switch(value: enabled, onChanged: onEnabled),
            const SizedBox(width: 4),
            Text(label,
                style:
                    TextStyle(color: color, fontWeight: FontWeight.w700)),
            const Spacer(),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('%')),
                ButtonSegment(value: false, label: Text(r'$')),
              ],
              selected: {isPercent},
              onSelectionChanged: (s) => onMode(s.first),
              style: const ButtonStyle(
                  visualDensity: VisualDensity.compact),
            ),
          ],
        ),
        if (enabled) ...[
          if (onTrailing != null)
            Row(
              children: [
                Checkbox(
                    value: trailing,
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) => onTrailing!(v ?? false)),
                Expanded(
                  child: Text('Trailing — follow the price up, never down',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ],
            ),
          Text(
              trailing
                  ? 'Sets the stop $trailVal${isPercent ? '%' : r'$'} below the '
                      'peak; it ratchets up as the price rises to lock in gains.'
                  : hint,
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: 110,
                child: TextField(
                  controller: controller,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixText: isPercent ? null : r'$ ',
                    suffixText: isPercent ? '%' : null,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => onChanged(),
                ),
              ),
              const SizedBox(width: 8),
              if (isPercent)
                for (final p in quickPercents)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ActionChip(
                      label: Text('$p%', style: const TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        controller.text = '$p';
                        onChanged();
                      },
                    ),
                  ),
            ],
          ),
          if (trailing && trailVal > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Starts around ${Fmt.money(trailStart)} and climbs with the price.',
                style: TextStyle(fontSize: 12, color: color),
              ),
            )
          else if (!trailing && resultPrice != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Triggers at ${Fmt.money(resultPrice!)}'
                '${pnlAtTrigger != null ? ' → ${pnlAtTrigger >= 0 ? '+' : ''}${Fmt.money(pnlAtTrigger)} vs your avg cost' : ''}',
                style: TextStyle(fontSize: 12, color: color),
              ),
            ),
        ],
      ],
    );
  }
}
