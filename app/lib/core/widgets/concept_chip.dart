import 'package:flutter/material.dart';

import '../education.dart';
import '../theme.dart';

/// A small tappable "term ⓘ" chip that opens a plain-language explanation.
/// This is the contextual-tooltip half of the educational layer.
class ConceptChip extends StatelessWidget {
  const ConceptChip(this.concept, {super.key});

  final Concept concept;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(concept.term),
          content: Text(concept.explanation),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Got it'),
            ),
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              concept.term,
              style: const TextStyle(
                color: AppTheme.accent,
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.info_outline, size: 13, color: AppTheme.accent),
          ],
        ),
      ),
    );
  }
}
