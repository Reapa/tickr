import 'package:flutter/material.dart';

import '../format.dart';
import '../theme.dart';

/// Money text that flashes green/red when the value ticks up/down, then
/// fades back — the classic trading-terminal pulse.
class PriceFlash extends StatefulWidget {
  const PriceFlash({super.key, required this.price, this.style});

  final double price;
  final TextStyle? style;

  @override
  State<PriceFlash> createState() => _PriceFlashState();
}

class _PriceFlashState extends State<PriceFlash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  Color _flashColor = AppTheme.up;

  @override
  void didUpdateWidget(PriceFlash oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.price != widget.price) {
      _flashColor =
          widget.price > oldWidget.price ? AppTheme.up : AppTheme.down;
      _fade
        ..value = 1
        ..animateTo(0, curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    return AnimatedBuilder(
      animation: _fade,
      builder: (context, _) => Text(
        Fmt.money(widget.price),
        style: base.copyWith(
          color: Color.lerp(base.color, _flashColor, _fade.value),
        ),
      ),
    );
  }
}
