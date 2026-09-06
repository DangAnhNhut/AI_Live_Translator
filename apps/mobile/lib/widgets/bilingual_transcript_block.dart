import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../translation/translation_domain.dart';
import '../translation/translation_presentation.dart';

class BilingualTranscriptBlock extends StatelessWidget {
  const BilingualTranscriptBlock({
    super.key,
    required this.utterance,
    this.sessionEnded = false,
  });

  final TranslationUtterance utterance;
  final bool sessionEnded;

  @override
  Widget build(BuildContext context) {
    final view = buildBilingualTranscriptBlockView(utterance);
    final unresolvedAtSessionEnd =
        sessionEnded && view.status == TranslationStatus.pending;
    final failed =
        view.status == TranslationStatus.failed || unresolvedAtSessionEnd;
    final pending =
        view.status == TranslationStatus.pending && !unresolvedAtSessionEnd;
    final translationText = unresolvedAtSessionEnd
        ? 'Translation unavailable'
        : view.translationText;
    final secondaryHint = unresolvedAtSessionEnd
        ? 'Original transcript is still available.'
        : view.secondaryHint;

    return Container(
      key: const Key('bilingual_transcript_card'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(
          color: failed ? AppColors.errorSoft : AppColors.border,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A3444CD),
            blurRadius: 20,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TranscriptSection(
            label: view.sourceLabel,
            text: view.sourceText,
            labelColor: AppColors.secondaryText,
            textColor: AppColors.text,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Divider(),
          ),
          Container(
            key: failed ? const Key('translation_failed_surface') : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _SectionLabel(
                        view.translationLabel,
                        color: failed
                            ? AppColors.error
                            : AppColors.primaryStrong,
                      ),
                    ),
                    if (pending)
                      const SizedBox.square(
                        key: Key('translation_pending_indicator'),
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.8),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (failed) ...[
                      const Padding(
                        padding: EdgeInsets.only(top: 2, right: 7),
                        child: Icon(
                          Icons.error_outline_rounded,
                          size: 19,
                          color: AppColors.error,
                        ),
                      ),
                    ],
                    Expanded(
                      child: Text(
                        translationText,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: failed
                              ? AppColors.error
                              : AppColors.primaryStrong,
                          fontWeight: FontWeight.w500,
                          fontStyle: pending
                              ? FontStyle.italic
                              : FontStyle.normal,
                        ),
                      ),
                    ),
                  ],
                ),
                if (secondaryHint != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    secondaryHint,
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

class _TranscriptSection extends StatelessWidget {
  const _TranscriptSection({
    required this.label,
    required this.text,
    required this.labelColor,
    required this.textColor,
  });

  final String label;
  final String text;
  final Color labelColor;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(label, color: labelColor),
        const SizedBox(height: 6),
        Text(
          text,
          style: Theme.of(
            context,
          ).textTheme.bodyLarge?.copyWith(color: textColor),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
      ),
    );
  }
}
