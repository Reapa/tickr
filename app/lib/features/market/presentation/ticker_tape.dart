import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../data/market_repository.dart';
import '../domain/asset.dart';

/// An endlessly scrolling exchange-floor ticker tape of live prices.
/// Pure garnish — and exactly the kind of garnish that makes it feel
/// like a trading floor.
class TickerTape extends ConsumerStatefulWidget {
  const TickerTape({super.key});

  @override
  ConsumerState<TickerTape> createState() => _TickerTapeState();
}

class _TickerTapeState extends ConsumerState<TickerTape> {
  final _controller = ScrollController();
  Timer? _scroller;

  @override
  void initState() {
    super.initState();
    _scroller = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_controller.hasClients) {
        _controller.jumpTo(_controller.offset + 1.2);
      }
    });
  }

  @override
  void dispose() {
    _scroller?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    if (assets.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 34,
      child: ListView.builder(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        // Effectively infinite; items repeat modulo the asset list.
        itemBuilder: (context, index) {
          final asset = assets[index % assets.length];
          return InkWell(
            onTap: () => context.go('/market/asset/${asset.id}'),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Text(
                    asset.symbol,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 12),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    Fmt.money(asset.currentPrice),
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(width: 6),
                  _TapeChange(asset: asset),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TapeChange extends ConsumerWidget {
  const _TapeChange({required this.asset});

  final Asset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final opening = ref.watch(openingPriceProvider(asset.id)).value;
    if (opening == null || opening == 0) return const SizedBox.shrink();
    final change = asset.currentPrice / opening - 1;
    return Text(
      '${change >= 0 ? '▲' : '▼'}${Fmt.pct(change)}',
      style: TextStyle(
        fontSize: 11,
        color: AppTheme.changeColor(change),
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
