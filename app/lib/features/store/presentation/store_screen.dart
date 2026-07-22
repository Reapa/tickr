import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cosmetics.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/trader_avatar.dart';
import '../../profile/data/profile_repository.dart';
import '../data/store_repository.dart';

/// The cosmetic store. Everything here is strictly visual — gems can never
/// buy cash, assets, or any trading advantage (enforced by database CHECK
/// constraints, not just this UI). Real payments are stubbed in v1.
class StoreScreen extends ConsumerWidget {
  const StoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    final cosmetics = ref.watch(cosmeticsProvider);
    final owned = ref.watch(ownedCosmeticsProvider).value ?? const <String>{};

    return Scaffold(
      appBar: AppBar(
        title: const Text('Store'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Row(
                children: [
                  const Icon(Icons.diamond_outlined,
                      size: 18, color: AppTheme.accent),
                  const SizedBox(width: 4),
                  Text('${profile?.premiumBalance ?? 0}'),
                ],
              ),
            ),
          ),
        ],
      ),
      body: AsyncView(
        value: cosmetics,
        builder: (list) {
          final slots = <String, List<Cosmetic>>{};
          for (final c in list) {
            slots.putIfAbsent(c.slot, () => []).add(c);
          }
          return ListView(
            children: [
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Cosmetics only. Gems never buy cash or trading power — '
                    'that is a database rule, not a promise.',
                  ),
                ),
              ),
              _GemPackages(onBuy: (package) => _buyGems(context, ref, package)),
              for (final entry in slots.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    entry.key.replaceAll('_', ' ').toUpperCase(),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                for (final cosmetic in entry.value)
                  _CosmeticTile(
                    cosmetic: cosmetic,
                    owned: owned.contains(cosmetic.code),
                    equipped:
                        profile?.equipped[cosmetic.slot] == cosmetic.code,
                  ),
              ],
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Future<void> _buyGems(
      BuildContext context, WidgetRef ref, String package) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result =
          await ref.read(storeRepositoryProvider).stubPurchasePremium(package);
      messenger.showSnackBar(SnackBar(
          content: Text('+${result['amount']} gems (stub purchase — free '
              'in v1, real IAP later)')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

class _GemPackages extends StatelessWidget {
  const _GemPackages({required this.onBuy});

  final void Function(String package) onBuy;

  static const _packages = [
    (id: 'small', gems: 100, price: r'$0.99'),
    (id: 'medium', gems: 550, price: r'$4.99'),
    (id: 'large', gems: 1200, price: r'$9.99'),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          for (final p in _packages)
            Expanded(
              child: Card(
                child: InkWell(
                  onTap: () => onBuy(p.id),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        const Icon(Icons.diamond, color: AppTheme.accent),
                        Text('${p.gems}'),
                        Text(p.price,
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CosmeticTile extends ConsumerWidget {
  const _CosmeticTile({
    required this.cosmetic,
    required this.owned,
    required this.equipped,
  });

  final Cosmetic cosmetic;
  final bool owned;
  final bool equipped;

  static const _rarityColors = {
    'common': Colors.grey,
    'rare': AppTheme.accent,
    'epic': Colors.purpleAccent,
    'legendary': Colors.amber,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rarity = _rarityColors[cosmetic.rarity] ?? Colors.grey;
    final rare = cosmetic.rarity == 'epic' || cosmetic.rarity == 'legendary';
    return Card(
      // Owned/rare items get a rarity-tinted border and glow.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        side: BorderSide(
            color: rarity.withValues(alpha: owned || rare ? 0.55 : 0.18)),
      ),
      shadowColor: rarity,
      elevation: rare ? 6 : 0,
      child: ListTile(
        leading: _preview(rarity),
        title: Row(
          children: [
            Flexible(child: Text(cosmetic.name, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 6),
            Text(cosmetic.rarity.toUpperCase(),
                style: TextStyle(
                    fontSize: 8,
                    letterSpacing: 0.5,
                    fontWeight: FontWeight.w800,
                    color: rarity)),
          ],
        ),
        subtitle: Text(
          cosmetic.isSeasonReward
              ? '${cosmetic.description}\nSeason reward — cannot be bought'
              : cosmetic.description,
        ),
        isThreeLine: cosmetic.isSeasonReward,
        trailing: _action(context, ref),
      ),
    );
  }

  /// A live preview of the cosmetic itself, so the store shows what you're
  /// buying instead of a generic icon.
  Widget _preview(Color rarity) {
    switch (cosmetic.slot) {
      case 'avatar_frame':
        return TraderAvatar(
            name: '★', equipped: {'avatar_frame': cosmetic.code}, radius: 18);
      case 'profile_badge':
        return CircleAvatar(
          radius: 21,
          backgroundColor: rarity.withValues(alpha: 0.16),
          child: Text(badgeEmoji(cosmetic.code) ?? '🎖',
              style: const TextStyle(fontSize: 20)),
        );
      case 'chart_theme':
        final t = chartTheme(cosmetic.code);
        return _Swatch(colors: [t.up, t.down, t.line]);
      case 'ticker_skin':
        final s = tickerSkin(cosmetic.code);
        return _Swatch(colors: [
          s.background ?? Colors.black,
          s.accent ?? rarity,
          s.text ?? Colors.white,
        ]);
      default:
        return Icon(Icons.auto_awesome, color: rarity);
    }
  }

  Widget _action(BuildContext context, WidgetRef ref) {
    if (equipped) {
      return TextButton(
        onPressed: () => _equip(context, ref, null),
        child: const Text('Unequip'),
      );
    }
    if (owned) {
      return FilledButton.tonal(
        onPressed: () => _equip(context, ref, cosmetic.code),
        child: const Text('Equip'),
      );
    }
    if (cosmetic.pricePremium == null) {
      return const Icon(Icons.lock_outline);
    }
    return FilledButton(
      onPressed: () => _purchase(context, ref),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.diamond_outlined, size: 16),
          const SizedBox(width: 4),
          Text('${cosmetic.pricePremium}'),
        ],
      ),
    );
  }

  Future<void> _purchase(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await ref
          .read(storeRepositoryProvider)
          .purchaseCosmetic(cosmetic.code);
      if (result['status'] == 'purchased') {
        ref.invalidate(ownedCosmeticsProvider);
        messenger.showSnackBar(
            SnackBar(content: Text('${cosmetic.name} is yours!')));
      } else {
        messenger
            .showSnackBar(SnackBar(content: Text('${result['reason']}')));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _equip(
      BuildContext context, WidgetRef ref, String? code) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(storeRepositoryProvider).equipCosmetic(cosmetic.slot, code);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

/// A little colour-band chip previewing a chart theme / ticker skin.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.colors});

  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        children: [for (final c in colors) Expanded(child: Container(color: c))],
      ),
    );
  }
}
