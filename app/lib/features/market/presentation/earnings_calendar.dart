import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../data/market_repository.dart';
import '../domain/asset.dart';
import '../domain/market_event.dart';

/// The "📅 Upcoming" earnings section for the News tab: every announced-but-
/// unresolved event with a live countdown. The outcome is a secret — you get a
/// window to form a thesis and position before it resolves into real news.
class UpcomingEarningsSection extends ConsumerWidget {
  const UpcomingEarningsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final upcoming = ref.watch(upcomingEventsProvider).value ?? const [];
    if (upcoming.isEmpty) return const SizedBox.shrink();
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final symbolById = {for (final a in assets) a.id: a.symbol};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Row(
            children: [
              Text('📅 Upcoming earnings',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Position before the result — the beat/miss is a surprise.',
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey.shade500),
                ),
              ),
            ],
          ),
        ),
        for (final e in upcoming)
          _UpcomingTile(event: e, symbol: symbolById[e.assetId]),
        const Divider(height: 24),
      ],
    );
  }
}

class _UpcomingTile extends StatelessWidget {
  const _UpcomingTile({required this.event, this.symbol});

  final ScheduledEvent event;
  final String? symbol;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        dense: true,
        leading: const CircleAvatar(
          radius: 16,
          backgroundColor: Color(0x2247B0FF),
          child: Icon(Icons.event_note, size: 18, color: AppTheme.accent),
        ),
        title: Text(event.headline,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: const Text('Tap to position before the report'),
        trailing: _Countdown(
          target: event.resolvesAt,
          builder: (remaining) => _CountdownPill(remaining: remaining),
        ),
        onTap: () => context.go('/market/asset/${event.assetId}'),
      ),
    );
  }
}

/// A banner on an asset's page when it has an earnings report coming up.
class AssetEarningsBanner extends ConsumerWidget {
  const AssetEarningsBanner({super.key, required this.assetId});

  final String assetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final event = (ref.watch(upcomingEventsProvider).value ?? const [])
        .where((e) => e.assetId == assetId)
        .firstOrNull;
    if (event == null) return const SizedBox.shrink();
    return Card(
      color: AppTheme.accent.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.event_note, color: AppTheme.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${event.quarter ?? ''} earnings ahead'.trim(),
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text('The result is hidden until it lands — take your view.',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade400)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _Countdown(
              target: event.resolvesAt,
              builder: (remaining) => _CountdownPill(remaining: remaining),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountdownPill extends StatelessWidget {
  const _CountdownPill({required this.remaining});

  final Duration remaining;

  @override
  Widget build(BuildContext context) {
    final soon = remaining.inSeconds <= 30;
    final color = soon ? AppTheme.gold : AppTheme.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            remaining.inSeconds <= 0 ? 'resolving…' : Fmt.countdown(remaining),
            style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }
}

/// Rebuilds once a second to drive a live countdown to [target].
class _Countdown extends StatefulWidget {
  const _Countdown({required this.target, required this.builder});

  final DateTime target;
  final Widget Function(Duration remaining) builder;

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.target.difference(DateTime.now());
    return widget.builder(remaining.isNegative ? Duration.zero : remaining);
  }
}
