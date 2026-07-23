import 'dart:async';

import 'package:flutter/material.dart';

/// Rebuilds once a second to drive a live countdown to [target]. The [builder]
/// receives the clamped remaining duration (never negative).
class Countdown extends StatefulWidget {
  const Countdown({super.key, required this.target, required this.builder});

  final DateTime target;
  final Widget Function(Duration remaining) builder;

  @override
  State<Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<Countdown> {
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
