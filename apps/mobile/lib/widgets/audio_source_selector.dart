import 'package:flutter/material.dart';

import '../services/audio_input.dart';

const _primaryIndigo = Color(0xFF4F5FE7);
const _textPrimary = Color(0xFF111827);
const _textSecondary = Color(0xFF64748B);
const _border = Color(0xFFE2E8F0);

class AudioSourceSelector extends StatelessWidget {
  const AudioSourceSelector({
    super.key,
    required this.selectedSource,
    required this.systemAudioSupported,
    required this.enabled,
    required this.onSelected,
  });

  final MobileAudioSource selectedSource;
  final bool systemAudioSupported;
  final bool enabled;
  final ValueChanged<MobileAudioSource> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Audio Source',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: _textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _AudioSourceOption(
                semanticsKey: const Key('audio_source_microphone'),
                title: 'Microphone',
                description: "Capture speech from this device's microphone.",
                icon: Icons.mic_none_rounded,
                selected: selectedSource == MobileAudioSource.microphone,
                enabled: enabled,
                onTap: () => onSelected(MobileAudioSource.microphone),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _AudioSourceOption(
                semanticsKey: const Key('audio_source_system_audio'),
                title: 'System Audio',
                description: systemAudioSupported
                    ? 'Capture playback audio from supported apps.'
                    : 'Requires Android 10 or later',
                icon: Icons.graphic_eq_rounded,
                selected: selectedSource == MobileAudioSource.systemAudio,
                enabled: enabled && systemAudioSupported,
                onTap: () => onSelected(MobileAudioSource.systemAudio),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _AudioSourceOption extends StatelessWidget {
  const _AudioSourceOption({
    required this.semanticsKey,
    required this.title,
    required this.description,
    required this.icon,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final Key semanticsKey;
  final String title;
  final String description;
  final IconData icon;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: semanticsKey,
      button: true,
      selected: selected,
      enabled: enabled,
      label: '$title audio source',
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: enabled ? 1 : 0.58,
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(12),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              constraints: const BoxConstraints(minHeight: 112),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected ? _primaryIndigo : _border,
                  width: selected ? 2 : 1,
                ),
                color: selected
                    ? _primaryIndigo.withValues(alpha: 0.06)
                    : Colors.white,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 21, color: _primaryIndigo),
                      const Spacer(),
                      Icon(
                        selected
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 20,
                        color: selected ? _primaryIndigo : _textSecondary,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    title,
                    style: const TextStyle(
                      color: _textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: const TextStyle(
                      color: _textSecondary,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
