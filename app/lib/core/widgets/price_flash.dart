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

/// Flashes a faint green/red wash over [child] when [value] changes — used to
/// pulse a whole market row on a price tick so the list reads as live.
class FlashOnChange extends StatefulWidget {
  const FlashOnChange({
    super.key,
    required this.value,
    required this.child,
    this.borderRadius = 0,
  });

  final double value;
  final Widget child;
  final double borderRadius;

  @override
  State<FlashOnChange> createState() => _FlashOnChangeState();
}

class _FlashOnChangeState extends State<FlashOnChange>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  );
  Color _color = AppTheme.up;

  @override
  void didUpdateWidget(FlashOnChange oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _color = widget.value > oldWidget.value ? AppTheme.up : AppTheme.down;
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
    return AnimatedBuilder(
      animation: _fade,
      builder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(
          color: _color.withValues(alpha: 0.14 * _fade.value),
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// Money that smoothly counts up/down to its target value — the hero number
/// rolling makes growth feel earned.
class AnimatedMoney extends StatelessWidget {
  const AnimatedMoney({
    super.key,
    required this.value,
    this.style,
    this.compact = false,
    this.duration = const Duration(milliseconds: 650),
  });

  final double value;
  final TextStyle? style;
  final bool compact;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      // begin null → TweenAnimationBuilder animates from the previous end to
      // the new end on each rebuild (the count-up), no animation on first show.
      tween: Tween<double>(end: value),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => Text(
        compact ? Fmt.moneyCompact(v) : Fmt.money(v),
        style: (style ?? const TextStyle()).copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
