import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../data/market_repository.dart';
import '../domain/market_event.dart';

/// One news item. Sentiment is shown, the numeric impact never is — reading
/// severity from headlines is part of the game.
class EventTile extends StatelessWidget {
  const EventTile({super.key, required this.event, this.symbol});

  final MarketEvent event;
  final String? symbol;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (event.sentiment) {
      'positive' => (Icons.trending_up, AppTheme.up),
      'negative' => (Icons.trending_down, AppTheme.down),
      _ => (Icons.horizontal_rule, Colors.grey),
    };
    final scopeLabel = switch (event.scope) {
      'asset' => symbol,
      'sector' => event.sector?.toUpperCase(),
      _ => 'MARKET',
    };
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(event.headline),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${scopeLabel != null ? '$scopeLabel · ' : ''}'
            '${Fmt.timeAgo(event.startsAt)}'
            '${event.isLive ? ' · still moving prices' : ''}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        onTap: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(event.headline),
            content: Text(event.body),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
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
