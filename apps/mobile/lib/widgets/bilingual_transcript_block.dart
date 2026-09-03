import 'package:flutter/material.dart';

import '../translation/translation_domain.dart';
import '../translation/translation_presentation.dart';

class BilingualTranscriptBlock extends StatelessWidget {
  const BilingualTranscriptBlock({super.key, required this.utterance});

  final TranslationUtterance utterance;

  @override
  Widget build(BuildContext context) {
    final view = buildBilingualTranscriptBlockView(utterance);
    final colors = Theme.of(context).colorScheme;
    final failed = view.status == TranslationStatus.failed;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionLabel(view.sourceLabel),
                const SizedBox(height: 6),
                Text(
                  view.sourceText,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ],
            ),
          ),
          Container(
            key: failed ? const Key('translation_failed_surface') : null,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            color: failed
                ? colors.errorContainer.withValues(alpha: 0.45)
                : colors.primaryContainer.withValues(alpha: 0.3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionLabel(view.translationLabel),
                const SizedBox(height: 6),
                Text(
                  view.translationText,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: failed ? colors.error : colors.primary,
                    fontStyle: view.status == TranslationStatus.pending
                        ? FontStyle.italic
                        : FontStyle.normal,
                  ),
                ),
                if (view.secondaryHint != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    view.secondaryHint!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 0.7,
      ),
    );
  }
}
