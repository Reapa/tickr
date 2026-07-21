import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/brand.dart';
import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../auth/data/auth_repository.dart';
import '../../market/data/market_repository.dart';
import '../../market/domain/asset.dart';
import '../../trading/data/trading_repository.dart';
import '../data/profile_repository.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    final classes = ref.watch(assetClassesProvider).value ?? const <AssetClass>[];
    final unlocked = ref.watch(unlockedClassesProvider).value ?? const <String>{};

    return Scaffold(
      appBar: tickrAppBar(
        title: 'Profile',
        actions: [
          IconButton(
            icon: const Icon(Icons.storefront_outlined),
            tooltip: 'Store',
            onPressed: () => context.go('/profile/store'),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => ref.read(authRepositoryProvider).signOut(),
          ),
        ],
      ),
      body: profile == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 28,
                          child: Text(
                            profile.displayName.substring(0, 1).toUpperCase(),
                            style: const TextStyle(fontSize: 22),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      profile.displayName,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.edit, size: 16),
                                    onPressed: () =>
                                        _editName(context, ref, profile.displayName),
                                  ),
                                ],
                              ),
                              Text('Level ${profile.level} · ${profile.xp} XP'),
                              const SizedBox(height: 4),
                              LinearProgressIndicator(
                                  value: profile.levelProgress),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _Stat('Net worth', Fmt.money(profile.netWorth)),
                        _Stat('Cash', Fmt.money(profile.cashBalance)),
                        _Stat('Gems', '${profile.premiumBalance}'),
                      ],
                    ),
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

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
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
