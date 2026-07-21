import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/education.dart';
import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/concept_chip.dart';
import '../../market/domain/asset.dart';
import '../../missions/data/missions_repository.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../portfolio/domain/portfolio_math.dart';
import '../../profile/data/profile_repository.dart';
import '../data/trading_repository.dart';

/// Opens the buy/sell ticket. The client only collects (asset, side, qty) —
/// the server prices and validates everything.
Future<void> showOrderTicket(BuildContext context, Asset asset, String side) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: OrderTicket(asset: asset, side: side),
    ),
  );
}

class OrderTicket extends ConsumerStatefulWidget {
  const OrderTicket({super.key, required this.asset, required this.side});

  final Asset asset;
  final String side;

  @override
  ConsumerState<OrderTicket> createState() => _OrderTicketState();
}

class _OrderTicketState extends ConsumerState<OrderTicket> {
  final _quantity = TextEditingController(text: '1');
  var _busy = false;

  @override
  void dispose() {
    _quantity.dispose();
    super.dispose();
  }

  double get _qty => double.tryParse(_quantity.text) ?? 0;

  bool get _isBuy => widget.side == 'buy';

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    final profile = ref.watch(myProfileProvider).value;
    final holding = ref
        .watch(holdingsProvider)
        .value
        ?.where((h) => h.assetId == asset.id)
        .firstOrNull;

    final estPrice = _isBuy ? asset.askPrice : asset.bidPrice;
    final estNotional = estPrice * _qty;
    final cash = profile?.cashBalance ?? 0;
    final maxQty = _isBuy
        ? PortfolioMath.maxAffordable(cash, asset.askPrice)
        : (holding?.quantity ?? 0);

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '${_isBuy ? 'Buy' : 'Sell'} ${asset.symbol}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              const ConceptChip(Concepts.marketOrder),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _isBuy
                ? 'Cash available: ${Fmt.money(cash)}'
                : 'You hold: ${Fmt.quantity(holding?.quantity ?? 0)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _quantity,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Quantity',
              suffixIcon: TextButton(
                onPressed: maxQty <= 0
                    ? null
                    : () => setState(
                        () => _quantity.text = Fmt.quantity(maxQty)
                            .replaceAll(',', '')),
                child: const Text('Max'),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Estimated ${_isBuy ? 'ask' : 'bid'} price'),
              Text(Fmt.money(estPrice)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Estimated ${_isBuy ? 'cost' : 'proceeds'}'),
              Text(
                Fmt.money(estNotional),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Market orders fill at the live server price — it may differ '
            'slightly from this estimate if the market ticks.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _isBuy ? AppTheme.up : AppTheme.down,
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: _busy || _qty <= 0 ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    '${_isBuy ? 'Buy' : 'Sell'} ${Fmt.quantity(_qty)} ${asset.symbol}'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final receipt = await ref.read(tradingRepositoryProvider).placeMarketOrder(
            assetId: widget.asset.id,
            side: widget.side,
            quantity: _qty,
          );
      if (receipt.isFilled) {
        // Holdings/profile update via their live streams; refresh the rest.
        ref.invalidate(missionsProvider);
        ref.invalidate(recentOrdersProvider);
        ref.invalidate(ledgerProvider);
        navigator.pop();
        messenger.showSnackBar(SnackBar(
          content: Text(
            '${_isBuy ? 'Bought' : 'Sold'} ${Fmt.quantity(receipt.quantity ?? 0)} '
            '${widget.asset.symbol} @ ${Fmt.money(receipt.price ?? 0)} '
            '(${Fmt.money(receipt.notional ?? 0)})',
          ),
        ));
      } else {
        messenger.showSnackBar(SnackBar(
          content: Text('Order rejected: ${receipt.reason ?? 'unknown'}'),
        ));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Order failed: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
