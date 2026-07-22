import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../market/domain/asset.dart';
import '../../missions/data/missions_repository.dart';
import '../../profile/data/profile_repository.dart';
import '../data/leverage_repository.dart';

/// Opens the leveraged-position ticket for an asset.
Future<void> showLeverageSheet(BuildContext context, Asset asset) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: LeverageSheet(asset: asset),
    ),
  );
}

class LeverageSheet extends ConsumerStatefulWidget {
  const LeverageSheet({super.key, required this.asset});

  final Asset asset;

  @override
  ConsumerState<LeverageSheet> createState() => _LeverageSheetState();
}

class _LeverageSheetState extends ConsumerState<LeverageSheet> {
  var _side = 'long';
  var _leverage = 10;
  final _margin = TextEditingController();
  var _busy = false;

  @override
  void initState() {
    super.initState();
    // Default stake ≈ $1000, shown in the player's display currency.
    _margin.text = (1000 * Fmt.rate).toStringAsFixed(0);
  }

  @override
  void dispose() {
    _margin.dispose();
    super.dispose();
  }

  /// The stake in USD — the field is typed in the display currency.
  double get _marginValue =>
      Fmt.toUsd(double.tryParse(_margin.text) ?? 0).toDouble();

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    final profile = ref.watch(myProfileProvider).value;
    final cash = profile?.cashBalance ?? 0;
    final level = profile?.level ?? 1;
    final isLong = _side == 'long';

    final entry = isLong ? asset.askPrice : asset.bidPrice;
    final notional = _marginValue * _leverage;
    final liq = entry * (1 + (isLong ? -1.0 : 1.0) / _leverage);
    final liqMovePct = 100 / _leverage;

    int requiredLevel(int lev) => lev == 100 ? 10 : (lev == 50 ? 5 : 1);

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Leverage ${asset.symbol}',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Control ${_leverage}x your stake. Profit if you call the '
            'direction right — lose your margin if the price moves '
            '${liqMovePct.toStringAsFixed(0)}% against you.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                  value: 'long',
                  label: Text('▲ Long — price goes up')),
              ButtonSegment(
                  value: 'short',
                  label: Text('▼ Short — price goes down')),
            ],
            selected: {_side},
            onSelectionChanged: (s) => setState(() => _side = s.first),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final lev in const [5, 10, 50, 100])
                ChoiceChip(
                  label: Text(level >= requiredLevel(lev)
                      ? '${lev}x'
                      : '${lev}x 🔒 Lv${requiredLevel(lev)}'),
                  selected: _leverage == lev,
                  onSelected: level >= requiredLevel(lev)
                      ? (_) => setState(() => _leverage = lev)
                      : null,
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _margin,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Margin (your stake)',
              prefixText: '${Fmt.symbol} ',
              helperText: 'Cash available: ${Fmt.money(cash)}',
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final frac in const [0.1, 0.25, 0.5])
                ActionChip(
                  label: Text('${(frac * 100).toInt()}%'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _margin.text =
                      (cash * frac * Fmt.rate)
                          .floorToDouble()
                          .toString()),
                ),
            ],
          ),
          const Divider(height: 24),
          _Row('Position size',
              '${Fmt.money(notional)} (${Fmt.quantity(notional / entry)} units)'),
          _Row('Entry (est.)', Fmt.money(entry)),
          _Row('Max loss', Fmt.money(_marginValue),
              color: AppTheme.down),
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.down.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber, color: AppTheme.down, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Liquidation at ${Fmt.money(liq)} — if the price '
                    '${isLong ? 'falls' : 'rises'} '
                    '${liqMovePct.toStringAsFixed(0)}%, this position closes '
                    'automatically and your margin is gone.',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: isLong ? AppTheme.up : AppTheme.down,
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed:
                _busy || _marginValue < 100 || _marginValue > cash ? null : _open,
            child: _busy
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(
                    '${isLong ? 'Long' : 'Short'} ${asset.symbol} ${_leverage}x '
                    'with ${Fmt.money(_marginValue)}'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _open() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final result = await ref.read(leverageRepositoryProvider).openPosition(
            assetId: widget.asset.id,
            side: _side,
            leverage: _leverage,
            margin: _marginValue,
          );
      if (result['status'] == 'opened') {
        ref.invalidate(missionsProvider);
        navigator.pop();
        messenger.showSnackBar(SnackBar(
          content: Text(
              '⚡ ${_side == 'long' ? 'Long' : 'Short'} ${widget.asset.symbol} '
              '${_leverage}x opened — liquidation at '
              '${Fmt.money((result['liquidation_price'] as num).toDouble())}'),
        ));
      } else {
        messenger.showSnackBar(SnackBar(content: Text('${result['reason']}')));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value,
              style: TextStyle(fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}
