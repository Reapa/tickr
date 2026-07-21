import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/brand.dart';
import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../market/data/market_repository.dart';
import '../../market/domain/asset.dart';
import '../../trading/data/trading_repository.dart';
import '../data/profile_repository.dart';
import '../domain/profile.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    final classes = ref.watch(assetClassesProvider).value ?? const <AssetClass>[];
    final unlocked = ref.watch(unlockedClassesProvider).value ?? const <String>{};

    return Scaffold(
      appBar: tickrAppBar(title: 'Profile'),
      body: profile == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // Trader card
                Card(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppTheme.radius),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          AppTheme.brand.withValues(alpha: 0.16),
                          AppTheme.surface,
                          AppTheme.accent.withValues(alpha: 0.10),
                        ],
                      ),
                    ),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            _LevelRingAvatar(profile: profile),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(profile.displayName,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleLarge
                                                ?.copyWith(
                                                    fontWeight: FontWeight.w800),
                                            overflow: TextOverflow.ellipsis),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.edit, size: 15),
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () => _editName(
                                            context, ref, profile.displayName),
                                      ),
                                    ],
                                  ),
                                  Text('Level ${profile.level} · ${profile.xp} XP',
                                      style: TextStyle(
                                          color: Colors.grey.shade400,
                                          fontSize: 13)),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      _TinyChip(
                                          icon: Icons.tag,
                                          label: profile.friendCode),
                                      const SizedBox(width: 8),
                                      _TinyChip(
                                          icon: Icons.local_fire_department,
                                          label: '${profile.streakDays}d',
                                          color: AppTheme.gold),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                // Career stat grid
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    children: [
                      Row(children: [
                        _StatTile(label: 'NET WORTH', value: Fmt.moneyCompact(profile.netWorth)),
                        _StatTile(label: 'CASH', value: Fmt.moneyCompact(profile.cashBalance)),
                        _StatTile(label: 'GEMS', value: '${profile.premiumBalance}', color: AppTheme.accent),
                      ]),
                      Row(children: [
                        _StatTile(label: 'STREAK', value: '${profile.streakDays}d', color: AppTheme.gold),
                        _StatTile(label: 'BEST STREAK', value: '${profile.longestStreak}d'),
                        _StatTile(label: 'LEVEL', value: '${profile.level}', color: AppTheme.brand),
                      ]),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text('Progression',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                for (final cls in classes)
                  _ProgressionTile(
                    assetClass: cls,
                    isUnlocked: unlocked.contains(cls.id),
                    cash: profile.cashBalance,
                  ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Future<void> _editName(
      BuildContext context, WidgetRef ref, String current) async {
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Display name'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.trim() == current) return;
    try {
      await ref.read(profileRepositoryProvider).updateDisplayName(name);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }
}

/// Avatar wrapped in a level-progress ring with a level badge.
class _LevelRingAvatar extends StatelessWidget {
  const _LevelRingAvatar({required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context) {
    // Extra height so the level badge sits fully inside the box (no clipping).
    return SizedBox(
      width: 64,
      height: 74,
      child: Stack(
        alignment: Alignment.topCenter,
        clipBehavior: Clip.none,
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: CircularProgressIndicator(
              value: profile.levelProgress,
              strokeWidth: 4,
              backgroundColor: AppTheme.hairline,
              valueColor: const AlwaysStoppedAnimation(AppTheme.brand),
            ),
          ),
          Positioned(
            top: 8,
            child: CircleAvatar(
              radius: 24,
              backgroundColor: AppTheme.brand.withValues(alpha: 0.18),
              child: Text(
                profile.displayName.characters.first.toUpperCase(),
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.brand),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: AppTheme.brand,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.surface, width: 2),
              ),
              child: Text('${profile.level}',
                  style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                      fontSize: 11)),
            ),
          ),
        ],
      ),
    );
  }
}

class _TinyChip extends StatelessWidget {
  const _TinyChip(
      {required this.icon, required this.label, this.color = Colors.grey});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.surfaceHigh,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: AppTheme.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        margin: const EdgeInsets.all(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Column(
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: color,
                      fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(
                      fontSize: 8.5,
                      letterSpacing: 0.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade500)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The earn-then-buy-in progression ladder, with affordability feedback.
class _ProgressionTile extends ConsumerWidget {
  const _ProgressionTile({
    required this.assetClass,
    required this.isUnlocked,
    required this.cash,
  });

  final AssetClass assetClass;
  final bool isUnlocked;
  final double cash;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final affordable = cash >= assetClass.unlockCost;
    return Card(
      child: ListTile(
        leading: Icon(
          isUnlocked ? Icons.lock_open : Icons.lock_outline,
          color: isUnlocked ? AppTheme.up : null,
        ),
        title: Text(assetClass.name),
        subtitle: Text(isUnlocked
            ? assetClass.description
            : assetClass.isEnabled
                ? '${assetClass.description}\n'
                    '${affordable ? 'You can afford this!' : 'Progress: ${Fmt.money(cash)} of ${Fmt.money(assetClass.unlockCost)}'}'
                : 'Coming soon'),
        isThreeLine: !isUnlocked && assetClass.isEnabled,
        trailing: isUnlocked || !assetClass.isEnabled
            ? null
            : FilledButton.tonal(
                onPressed: affordable ? () => _unlock(context, ref) : null,
                child: Text(Fmt.moneyCompact(assetClass.unlockCost)),
              ),
      ),
    );
  }

  Future<void> _unlock(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final receipt = await ref
          .read(tradingRepositoryProvider)
          .purchaseAssetClassUnlock(assetClass.id);
      if (receipt.status == 'unlocked') {
        ref.invalidate(unlockedClassesProvider);
        messenger.showSnackBar(SnackBar(
            content: Text('${assetClass.name} unlocked! New assets are live '
                'on the Market tab.')));
      } else {
        messenger.showSnackBar(
            SnackBar(content: Text(receipt.reason ?? 'Unlock failed')));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}
