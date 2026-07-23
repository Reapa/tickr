import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../profile/data/profile_repository.dart';
import '../data/properties_repository.dart';
import '../domain/property.dart';

/// Property ownership on the Real Estate tab (above the REIT list): your owned
/// properties + a catalog to buy from. Gated behind the real-estate unlock.
class PropertiesSection extends ConsumerWidget {
  const PropertiesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unlocked =
        ref.watch(unlockedClassesProvider).value?.contains('real_estate') ?? false;
    final owned = ref.watch(myPropertiesProvider).value ?? const <Property>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              const Icon(Icons.home_work_outlined, size: 18, color: AppTheme.gold),
              const SizedBox(width: 8),
              Text('Own property',
                  style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
        ),
        if (!unlocked) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Unlock Real Estate (below) to buy properties outright — they earn '
              'rent and build your net worth, separate from your season score.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          const _PropertyCatalog(locked: true),
        ] else ...[
          for (final p in owned) _PropertyCard(property: p),
          const _PropertyCatalog(),
        ],
        const Divider(height: 20),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('REIT funds',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ),
      ],
    );
  }
}

class _PropertyCard extends ConsumerWidget {
  const _PropertyCard({required this.property});

  final Property property;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perDay = property.effectiveRent / 14; // seconds_per_game_year = 14 days
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(property.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15)),
                ),
                Text(property.typeId.toUpperCase(),
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _Stat(label: 'Value', value: Fmt.moneyCompact(property.value)),
                const SizedBox(width: 20),
                _Stat(
                    label: 'Rent',
                    value: '${Fmt.moneyCompact(property.rentRate)}/yr',
                    color: AppTheme.up),
                const SizedBox(width: 20),
                _Stat(label: 'Income', value: '~${Fmt.money(perDay)}/day'),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => _confirmSell(context, ref),
                child: const Text('Sell'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmSell(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Sell ${property.name}?'),
        content: const Text(
            'Sell the property for cash at roughly its value (a 5% liquidity '
            'haircut applies). You lose the rent.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sell')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final res = await ref.read(propertiesRepositoryProvider).sell(property.id);
      if (res['status'] == 'sold') {
        messenger.showSnackBar(SnackBar(
            content: Text('Sold ${property.name} for '
                '${Fmt.money((res['proceeds'] as num).toDouble())}')));
      } else {
        messenger.showSnackBar(
            SnackBar(content: Text('Sale failed: ${res['status']}')));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

class _PropertyCatalog extends ConsumerWidget {
  const _PropertyCatalog({this.locked = false});

  /// Preview mode when real estate isn't unlocked — shows the catalog but the
  /// buy is gated, so players see what they're working toward.
  final bool locked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listings = ref.watch(propertyListingsProvider);
    return listings.when(
      loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator())),
      error: (e, _) =>
          Padding(padding: const EdgeInsets.all(16), child: Text('$e')),
      data: (rows) {
        if (rows.isEmpty) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('No properties on the market right now — check back soon.'),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('On the market',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ),
            for (final l in rows) _ListingTile(listing: l, locked: locked),
          ],
        );
      },
    );
  }
}

class _ListingTile extends ConsumerWidget {
  const _ListingTile({required this.listing, this.locked = false});

  final PropertyListing listing;
  final bool locked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cash = ref.watch(myProfileProvider).value?.cashBalance ?? 0;
    final canAfford = cash >= listing.value;
    return Card(
      child: ListTile(
        title: Text(listing.name,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text('${listing.typeId.toUpperCase()} · '
            '${Fmt.moneyCompact(listing.rentRate)}/yr rent'),
        trailing: locked
            ? Chip(
                label: Text(Fmt.moneyCompact(listing.value)),
                visualDensity: VisualDensity.compact)
            : FilledButton(
                onPressed: canAfford ? () => _buy(context, ref) : null,
                child: Text(Fmt.moneyCompact(listing.value)),
              ),
      ),
    );
  }

  Future<void> _buy(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Buy ${listing.name}?'),
        content: Text('Purchase for ${Fmt.money(listing.value)}. It starts '
            'earning ${Fmt.money(listing.rentRate)}/yr in rent immediately.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Buy')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final res = await ref.read(propertiesRepositoryProvider).buy(listing.id);
      ref.invalidate(propertyListingsProvider);
      if (res['status'] == 'bought') {
        messenger.showSnackBar(
            SnackBar(content: Text('Bought ${listing.name}!')));
      } else {
        messenger.showSnackBar(
            SnackBar(content: Text('Purchase failed: ${res['status']}')));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(value,
            style: TextStyle(fontWeight: FontWeight.w700, color: color)),
      ],
    );
  }
}
