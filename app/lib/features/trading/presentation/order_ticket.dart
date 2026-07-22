import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/education.dart';
import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/concept_chip.dart';
import '../../../core/widgets/tutorial_tip.dart';
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
  final _quantity = TextEditingController();
  final _amount = TextEditingController();
  final _trigger = TextEditingController();
  var _busy = false;

  // 'market' fills now; 'limit' buys the dip; 'stop' buys the breakout.
  // Only buys can be queued — exits use take-profit/stop-loss protection.
  String _orderType = 'market';

  // Default to unit entry so typing a small fractional size (e.g. 0.1 bitcorn)
  // is immediate. "Amount $" is one tap away for dollar-based buys.
  bool _byAmount = false;

  @override
  void initState() {
    super.initState();
    if (!_isBuy) {
      // Selling defaults to your whole position — "sell what I hold" is the
      // common case — so an odd fractional holding like 0.2 is pre-filled and
      // you just trim it down instead of hunting for "Max".
      final held = ref
              .read(holdingsProvider)
              .value
              ?.where((h) => h.assetId == widget.asset.id)
              .firstOrNull
              ?.quantity ??
          0;
      if (held > 0) _setQuantity(held);
    }
  }

  @override
  void dispose() {
    _quantity.dispose();
    _amount.dispose();
    _trigger.dispose();
    super.dispose();
  }

  bool get _isBuy => widget.side == 'buy';

  bool get _isPending => _isBuy && _orderType != 'market';

  double get _fillPrice => _isBuy ? widget.asset.askPrice : widget.asset.bidPrice;

  double? get _triggerPrice {
    final v = double.tryParse(_trigger.text);
    // Typed in the display currency; the engine prices everything in USD.
    return (v == null || v <= 0) ? null : Fmt.toUsd(v).toDouble();
  }

  /// Price used to turn a dollar amount into a quantity: the target price for a
  /// queued order, otherwise the live fill price.
  double get _priceForQty =>
      _isPending ? (_triggerPrice ?? _fillPrice) : _fillPrice;

  /// Quantity the order would use, floored to the server's 4-decimal limit so a
  /// dollar-derived amount can't be rejected as an "invalid quantity".
  double get _qty {
    final p = _priceForQty; // USD
    final raw = _byAmount
        // The amount is typed in the display currency; convert to USD before
        // dividing by the USD fill price.
        ? (p <= 0 ? 0 : Fmt.toUsd(double.tryParse(_amount.text) ?? 0) / p)
        : (double.tryParse(_quantity.text) ?? 0);
    return (raw * 10000).floorToDouble() / 10000;
  }

  void _setQuantity(double q) {
    final v = (q * 10000).floorToDouble() / 10000;
    _quantity.text = v <= 0 ? '' : Fmt.quantity(v).replaceAll(',', '');
  }

  /// [usd] is a USD amount (e.g. a % of cash); shown in the display currency.
  void _setAmount(double usd) {
    final display = usd * Fmt.rate;
    _amount.text =
        display <= 0 ? '' : display.toStringAsFixed(Fmt.current.decimals);
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    final profile = ref.watch(myProfileProvider).value;
    final holding = ref
        .watch(holdingsProvider)
        .value
        ?.where((h) => h.assetId == asset.id)
        .firstOrNull;

    final ask = asset.askPrice;
    final qty = _qty;
    final trigger = _triggerPrice;
    // A queued order estimates against its target price; a market order against
    // the live fill price.
    final estPrice = _isPending ? (trigger ?? _fillPrice) : _fillPrice;
    final estNotional = estPrice * qty;
    final cash = profile?.cashBalance ?? 0;
    final held = holding?.quantity ?? 0;

    // Directionality: a limit buys below market, a stop buys above it.
    final directionOk = !_isPending
        ? true
        : trigger != null &&
            (_orderType == 'limit' ? trigger < ask : trigger > ask);

    // Market orders are affordability-gated now; queued buys are cash-checked
    // by the server at fill time, so they aren't blocked here.
    final canAfford =
        _isBuy ? estNotional <= cash + 0.005 : qty <= held + 1e-9;
    final canSubmit = !_busy &&
        qty > 0 &&
        (_isPending ? directionOk : canAfford);

    // Base value each quick-fill chip scales: cash / holdings value in amount
    // mode, affordable whole units / held units in quantity mode.
    void applyPct(double pct) {
      if (_byAmount) {
        final base = _isBuy ? cash : held * estPrice;
        _setAmount(base * pct);
      } else if (_isBuy) {
        final whole = PortfolioMath.maxAffordable(cash, _priceForQty);
        _setQuantity((whole * pct).floorToDouble());
      } else {
        _setQuantity(held * pct);
      }
      setState(() {});
    }

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
                : 'You hold: ${Fmt.quantity(held)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const TutorialTip(
            id: 'order_ticket',
            text: 'Enter a number of units, or switch to “Amount” to spend a '
                'set cash value. A market order fills at the live price now.',
          ),
          if (_isBuy) ...[
            const SizedBox(height: 12),
            // Market fills now; a limit/stop queues a "future" buy that the
            // engine fills when the price reaches your target.
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'market', label: Text('Market')),
                ButtonSegment(value: 'limit', label: Text('Limit')),
                ButtonSegment(value: 'stop', label: Text('Stop')),
              ],
              selected: {_orderType},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _orderType = s.first),
            ),
          ],
          const SizedBox(height: 12),
          // Enter by units or by dollar value — dollar value is how you buy
          // fractional amounts of high-priced assets.
          SegmentedButton<bool>(
            segments: [
              const ButtonSegment(value: false, label: Text('Quantity')),
              ButtonSegment(value: true, label: Text('Amount ${Fmt.symbol}')),
            ],
            selected: {_byAmount},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _byAmount = s.first),
          ),
          const SizedBox(height: 12),
          _byAmount
              ? TextField(
                  controller: _amount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Amount to spend',
                    prefixText: '${Fmt.symbol} ',
                  ),
                  onChanged: (_) => setState(() {}),
                )
              : TextField(
                  controller: _quantity,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Quantity'),
                  onChanged: (_) => setState(() {}),
                ),
          if (_isPending) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _trigger,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: _orderType == 'limit'
                    ? 'Buy when price falls to'
                    : 'Buy when price rises to',
                prefixText: '${Fmt.symbol} ',
                helperText: 'Now ${Fmt.price(ask)} · fills at the live price then',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              for (final (label, pct) in const [
                ('25%', 0.25),
                ('50%', 0.5),
                ('75%', 0.75),
                ('Max', 1.0),
              ])
                ActionChip(
                  label: Text(label),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => applyPct(pct),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (_byAmount && qty > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Estimated ${asset.symbol}'),
                  Text('≈ ${Fmt.quantity(qty)}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_isPending
                  ? 'Target price'
                  : 'Estimated ${_isBuy ? 'ask' : 'bid'} price'),
              Text(Fmt.price(estPrice)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_isPending
                  ? 'Estimated cost at target'
                  : 'Estimated ${_isBuy ? 'cost' : 'proceeds'}'),
              Text(
                Fmt.money(estNotional),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          if (_isPending && trigger != null && !directionOk) ...[
            const SizedBox(height: 8),
            Text(
              _orderType == 'limit'
                  ? 'A limit buy must sit below the current ${Fmt.price(ask)}.'
                  : 'A stop buy must sit above the current ${Fmt.price(ask)}.',
              style: const TextStyle(color: AppTheme.down, fontSize: 12),
            ),
          ] else if (_isPending && qty > 0 && estNotional > cash) ...[
            const SizedBox(height: 8),
            Text(
              'Heads up: this needs ~${Fmt.money(estNotional)} in cash when it '
              'triggers — you have ${Fmt.money(cash)} now. It cancels if you '
              "can't afford it then.",
              style: TextStyle(color: Colors.amber.shade700, fontSize: 12),
            ),
          ] else if (!_isPending && qty > 0 && !canAfford) ...[
            const SizedBox(height: 8),
            Text(
              _isBuy
                  ? 'That would cost more than your ${Fmt.money(cash)} available.'
                  : 'You only hold ${Fmt.quantity(held)} ${asset.symbol}.',
              style: const TextStyle(color: AppTheme.down, fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            _isPending
                ? 'Queued until the price reaches your target, then fills at the '
                    'live price. Cancel it anytime from the asset page.'
                : 'Market orders fill at the live server price — it may differ '
                    'slightly from this estimate if the market ticks.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _isBuy ? AppTheme.up : AppTheme.down,
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: canSubmit ? _submit : null,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(qty > 0
                    ? (_isPending
                        ? 'Queue ${_orderType == 'limit' ? 'limit' : 'stop'} buy · ${Fmt.quantity(qty)} ${asset.symbol}'
                        : '${_isBuy ? 'Buy' : 'Sell'} ${Fmt.quantity(qty)} ${asset.symbol}')
                    : '${_isBuy ? 'Buy' : 'Sell'} ${asset.symbol}'),
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
      if (_isPending) {
        await _submitPending(messenger, navigator);
        return;
      }
      // Snapshot completed missions so we can celebrate any new ones. Await the
      // provider's future rather than reading `.value` — right after an app
      // restart the list may not be loaded yet, and an empty snapshot would
      // make every already-completed mission look new and re-celebrate.
      final completedBefore = (await ref.read(missionsProvider.future))
          .where((m) => m.completed)
          .map((m) => m.code)
          .toSet();
      final receipt = await ref.read(tradingRepositoryProvider).placeMarketOrder(
            assetId: widget.asset.id,
            side: widget.side,
            quantity: _qty,
          );
      if (receipt.isFilled) {
        // Holdings/profile stream live, but re-pull holdings anyway so the
        // position is correct even if a Realtime event is dropped.
        ref.invalidate(holdingsProvider);
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
        _celebrateNewMissions(messenger, completedBefore);
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

  /// Queue a buy limit/stop ("future") order via the server.
  Future<void> _submitPending(
    ScaffoldMessengerState messenger,
    NavigatorState navigator,
  ) async {
    final trigger = _triggerPrice;
    if (trigger == null) return;
    final receipt = await ref.read(tradingRepositoryProvider).placePendingOrder(
          assetId: widget.asset.id,
          orderType: _orderType,
          quantity: _qty,
          limitPrice: trigger,
        );
    if (receipt.status == 'placed') {
      ref.invalidate(openOrdersProvider);
      navigator.pop();
      messenger.showSnackBar(SnackBar(
        content: Text(
          'Queued ${_orderType == 'limit' ? 'limit' : 'stop'} buy · '
          '${Fmt.quantity(_qty)} ${widget.asset.symbol} @ ${Fmt.money(trigger)}',
        ),
      ));
    } else {
      messenger.showSnackBar(SnackBar(
        content: Text('Order rejected: ${receipt.reason ?? 'unknown'}'),
      ));
    }
  }

  /// If this trade completed a mission server-side, celebrate it.
  Future<void> _celebrateNewMissions(
    ScaffoldMessengerState messenger,
    Set<String> completedBefore,
  ) async {
    try {
      final after = await ref.read(missionsProvider.future);
      for (final mission
          in after.where((m) => m.completed && !completedBefore.contains(m.code))) {
        messenger.showSnackBar(SnackBar(
          backgroundColor: AppTheme.up,
          content: Text(
            '🎓 Mission complete: ${mission.title} '
            '— +${Fmt.money(mission.rewardCash)}, +${mission.rewardXp} XP',
            style: const TextStyle(
                color: Colors.black, fontWeight: FontWeight.w600),
          ),
        ));
      }
    } catch (_) {
      // Celebration is best-effort; the missions screen shows the truth.
    }
  }
}
