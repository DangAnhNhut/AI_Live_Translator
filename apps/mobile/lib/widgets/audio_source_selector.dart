import 'package:flutter/material.dart';

import '../services/audio_input.dart';
import '../theme/app_theme.dart';

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
    final microphone = _AudioSourceOption(
      semanticsKey: const Key('audio_source_microphone'),
      title: 'Microphone',
      description: 'Capture speech from your microphone.',
      icon: Icons.mic_rounded,
      selected: selectedSource == MobileAudioSource.microphone,
      enabled: enabled,
      onTap: () => onSelected(MobileAudioSource.microphone),
    );
    final systemAudio = _AudioSourceOption(
      semanticsKey: const Key('audio_source_system_audio'),
      title: 'System Audio',
      description: 'Capture audio from supported apps.',
      icon: Icons.computer_rounded,
      selected: selectedSource == MobileAudioSource.systemAudio,
      enabled: enabled,
      onTap: () => onSelected(MobileAudioSource.systemAudio),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Audio Source', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        if (!systemAudioSupported)
          microphone
        else
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 320) {
                return Column(
                  children: [
                    microphone,
                    const SizedBox(height: 12),
                    systemAudio,
                  ],
                );
              }
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: microphone),
                    const SizedBox(width: 12),
                    Expanded(child: systemAudio),
                  ],
                ),
              );
            },
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
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadii.card),
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(AppRadii.card),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              constraints: const BoxConstraints(minHeight: 132),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.card),
                border: Border.all(
                  color: selected ? AppColors.primary : AppColors.border,
                  width: selected ? 2 : 1,
                ),
                color: selected
                    ? AppColors.primary.withValues(alpha: 0.055)
                    : AppColors.card,
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x083444CD),
                    blurRadius: 16,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  if (selected)
                    const Positioned(
                      top: 0,
                      right: 0,
                      child: _ListeningBars(),
                    ),
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          icon,
                          size: 32,
                          color: selected
                              ? AppColors.primaryStrong
                              : AppColors.secondaryText,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          description,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
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

class _ListeningBars extends StatelessWidget {
  const _ListeningBars();

  @override
  Widget build(BuildContext context) {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Bar(height: 9),
        SizedBox(width: 2.5),
        _Bar(height: 16),
        SizedBox(width: 2.5),
        _Bar(height: 11),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
