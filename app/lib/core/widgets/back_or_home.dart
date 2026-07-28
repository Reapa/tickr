import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// A leading app-bar button that always gets the player out of a screen.
///
/// Normally that is the ordinary back arrow. But this is a web app: reloading
/// the page, or opening a shared link, lands directly on a route with nothing
/// beneath it — and a Scaffold only draws a back button when there is something
/// to pop, so the player is stranded with no way out. In that case this falls
/// back to sending them home instead of showing nothing.
class BackOrHome extends StatelessWidget {
  const BackOrHome({super.key, this.home = '/market'});

  /// Where to go when there is no route to pop back to.
  final String home;

  @override
  Widget build(BuildContext context) {
    final canPop = context.canPop();
    return IconButton(
      tooltip: canPop ? 'Back' : 'Market',
      icon: Icon(canPop ? Icons.arrow_back : Icons.home_outlined),
      onPressed: () => canPop ? context.pop() : context.go(home),
    );
  }
}
