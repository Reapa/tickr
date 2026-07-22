import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../data/market_repository.dart';
import '../domain/market_event.dart';

/// One news item. Sentiment is shown, the numeric impact never is — reading
/// severity from headlines is part of the game. Tapping opens an article
/// quick-view that links straight to the affected market.
class EventTile extends StatelessWidget {
  const EventTile({super.key, required this.event, this.symbol});

  final MarketEvent event;
  final String? symbol;

  (IconData, Color) get _sentiment => switch (event.sentiment) {
        'positive' => (Icons.trending_up, AppTheme.up),
        'negative' => (Icons.trending_down, AppTheme.down),
        _ => (Icons.horizontal_rule, Colors.grey),
      };

  String? get _scopeLabel => switch (event.scope) {
        'asset' => symbol,
        'sector' => event.sector?.toUpperCase(),
        _ => 'MARKET',
      };

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _sentiment;
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(event.headline),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${_scopeLabel != null ? '$_scopeLabel · ' : ''}'
            '${Fmt.timeAgo(event.startsAt)}'
            '${event.isLive ? ' · still moving prices' : ''}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () => _openArticle(context),
      ),
    );
  }

  void _openArticle(BuildContext context) {
    final router = GoRouter.of(context);
    final (icon, color) = _sentiment;
    final sentimentWord = switch (event.sentiment) {
      'positive' => 'Bullish',
      'negative' => 'Bearish',
      _ => 'Neutral',
    };
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        maxChildSize: 0.9,
        minChildSize: 0.35,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Masthead: source + scope + sentiment chip.
              Row(
                children: [
                  const Text('TICKR NEWSWIRE',
                      style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.5,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.accent)),
                  const Spacer(),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(icon, size: 13, color: color),
                      const SizedBox(width: 4),
                      Text(sentimentWord,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: color)),
                    ]),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(event.headline,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800, height: 1.2)),
              const SizedBox(height: 6),
              Text(
                '${_scopeLabel != null ? '$_scopeLabel · ' : ''}'
                '${Fmt.timeAgo(event.startsAt)}'
                '${event.isLive ? ' · still moving prices' : ''}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
              ),
              const Divider(height: 24),
              Text(event.body,
                  style: const TextStyle(fontSize: 15, height: 1.45)),
              const SizedBox(height: 20),
              if (event.assetId != null)
                FilledButton.icon(
                  style:
                      FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  icon: const Icon(Icons.candlestick_chart, size: 18),
                  label: Text('View ${symbol ?? 'market'}'),
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    router.go('/market/asset/${event.assetId}');
                  },
                )
              else
                OutlinedButton(
                  style:
                      OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  child: const Text('Close'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "+2.31%" badge against the 24h-ago price, colored up/down.
class ChangeBadge extends ConsumerWidget {
  const ChangeBadge({
    super.key,
    required this.assetId,
    required this.currentPrice,
  });

  final String assetId;
  final double currentPrice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final opening = ref.watch(openingPriceProvider(assetId)).value;
    if (opening == null || opening == 0) return const SizedBox.shrink();
    final change = currentPrice / opening - 1;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.changeColor(change).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        Fmt.pct(change),
        style: TextStyle(
          color: AppTheme.changeColor(change),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
