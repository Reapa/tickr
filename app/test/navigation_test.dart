import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:trading_game/core/widgets/back_or_home.dart';

/// Two navigation bugs shipped to a live tester on 2026-07-28, both invisible
/// to the unit tests because they are about how routes and dialogs are wired
/// rather than about any calculation.
void main() {
  group('BackOrHome', () {
    testWidgets('pops when there is somewhere to go back to', (tester) async {
      final router = GoRouter(
        initialLocation: '/a',
        routes: [
          GoRoute(
            path: '/a',
            builder: (_, _) => const Scaffold(body: Text('A')),
            routes: [
              GoRoute(
                path: 'b',
                builder: (_, _) => Scaffold(
                  appBar: AppBar(leading: const BackOrHome()),
                  body: const Text('B'),
                ),
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      router.push('/a/b');
      await tester.pumpAndSettle();
      expect(find.text('B'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('offers a way home when the stack is empty beneath it',
        (tester) async {
      // Reloading the page on a deep link lands here with nothing to pop.
      // Without a fallback the app bar draws no button and the player is stuck.
      final router = GoRouter(
        initialLocation: '/arcade',
        routes: [
          GoRoute(
            path: '/market',
            builder: (_, _) => const Scaffold(body: Text('Market')),
          ),
          GoRoute(
            path: '/arcade',
            builder: (_, _) => Scaffold(
              appBar: AppBar(leading: const BackOrHome()),
              body: const Text('Arcade'),
            ),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      expect(find.text('Arcade'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      expect(find.byIcon(Icons.home_outlined), findsOneWidget);

      await tester.tap(find.byIcon(Icons.home_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Market'), findsOneWidget);
    });
  });

  group('confirm dialogs', () {
    // The property/company buy dialogs used `builder: (_) => AlertDialog(...)`
    // and then popped with the CALLER's context. showDialog pushes onto the
    // root navigator, but the caller's context resolves to the nested shell
    // navigator — so confirming a purchase popped the page out from under the
    // player instead of closing the dialog. Result: a blank screen and no
    // purchase.
    Widget harness({required bool popWithDialogContext}) {
      return MaterialApp(
        home: Navigator(
          // Stands in for go_router's shell-branch navigator.
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (inner) => Scaffold(
              body: Builder(
                builder: (buttonContext) => Center(
                  child: ElevatedButton(
                    child: const Text('Buy'),
                    onPressed: () => showDialog<bool>(
                      context: buttonContext,
                      builder: (dialogContext) => AlertDialog(
                        content: const Text('Confirm?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(
                                popWithDialogContext
                                    ? dialogContext
                                    : buttonContext,
                                true),
                            child: const Text('Yes'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('popping with the caller context destroys the page — the bug',
        (tester) async {
      await tester.pumpWidget(harness(popWithDialogContext: false));
      await tester.tap(find.text('Buy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();

      // The underlying page is gone; the dialog took the wrong route with it.
      expect(find.text('Buy'), findsNothing);
    });

    testWidgets('popping with the dialog context closes only the dialog',
        (tester) async {
      await tester.pumpWidget(harness(popWithDialogContext: true));
      await tester.tap(find.text('Buy'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm?'), findsOneWidget);

      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm?'), findsNothing);
      expect(find.text('Buy'), findsOneWidget, reason: 'the page survives');
    });
  });
}
