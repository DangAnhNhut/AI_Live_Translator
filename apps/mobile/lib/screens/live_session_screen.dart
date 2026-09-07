import 'dart:async';

import 'package:flutter/material.dart';

import '../services/audio_input.dart';
import '../services/debug_stt_session_transport.dart';
import '../services/transcript_file_saver.dart';
import '../session/live_session_controller.dart';
import '../session/live_session_state.dart';
import '../theme/app_theme.dart';
import '../widgets/audio_source_selector.dart';
import '../widgets/bilingual_transcript_block.dart';
import '../widgets/translation_language_selector.dart';

class LiveSessionScreen extends StatelessWidget {
  const LiveSessionScreen({
    super.key,
    required this.controller,
    this.debugControls,
    this.transcriptSaver,
  });

  final LiveSessionController controller;
  final DebugSttSessionControls? debugControls;
  final TranscriptFileSaver? transcriptSaver;

  static final TranscriptFileSaver _defaultTranscriptSaver =
      SystemTranscriptFileSaver();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (controller.hasPendingBenchmarkTranscriptRender) {
          final transcriptRevision =
              controller.latestBenchmarkTranscriptRevision;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            controller.recordBenchmarkTranscriptRendered(transcriptRevision);
          });
        }
        final isStoppedSession = controller.hasStoppedSession;
        final isLiveActive = !isStoppedSession &&
            (controller.state == LiveSessionState.listening ||
                controller.state == LiveSessionState.paused);
        final isSessionActive = controller.state != LiveSessionState.ready;

        return PopScope(
          canPop: !isSessionActive,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) {
              if (controller.hasStoppedSession) {
                controller.resetToReady();
              }
              return;
            }
            await _handleBackNavigation(context);
          },
          child: Scaffold(
            backgroundColor: AppColors.background,
            appBar: AppBar(
              title: const Text('Live Session'),
              centerTitle: true,
            ),
            body: SafeArea(
              top: false,
              child: Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      key: const Key('live_session_scroll_view'),
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (isStoppedSession) ...[
                          _SessionIntro(controller: controller),
                          const SizedBox(height: 20),
                          _TranscriptSection(controller: controller),
                        ] else ...[
                          if (!isLiveActive) ...[
                            _SessionIntro(controller: controller),
                            const SizedBox(height: 16),
                          ],
                          _SessionStateCard(controller: controller),
                          if (controller.state == LiveSessionState.error &&
                              controller.errorMessage != null) ...[
                            const SizedBox(height: 16),
                            _ErrorCard(message: controller.errorMessage!),
                          ],
                          if (controller.translationWarning != null) ...[
                            const SizedBox(height: 12),
                            _TranslationWarning(
                              message: controller.translationWarning!,
                            ),
                          ],
                          if (isLiveActive) ...[
                            const SizedBox(height: 16),
                            _TranscriptSection(controller: controller),
                            const SizedBox(height: 24),
                            AudioSourceSelector(
                              selectedSource: controller.selectedAudioSource,
                              systemAudioSupported:
                                  controller.isSystemAudioSupported,
                              enabled: controller.state ==
                                  LiveSessionState.ready,
                              onSelected: controller.selectAudioSource,
                            ),
                            if (controller.translationEnabled) ...[
                              const SizedBox(height: 16),
                              Text(
                                'Translation Target',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 12),
                              TranslationLanguageSelector(
                                selectedTarget:
                                    controller.selectedTranslationTarget,
                                enabled: controller.state ==
                                    LiveSessionState.ready,
                                onChanged: controller.selectTranslationTarget,
                              ),
                            ],
                          ] else ...[
                            const SizedBox(height: 24),
                            AudioSourceSelector(
                              selectedSource: controller.selectedAudioSource,
                              systemAudioSupported:
                                  controller.isSystemAudioSupported,
                              enabled: controller.state ==
                                  LiveSessionState.ready,
                              onSelected: controller.selectAudioSource,
                            ),
                            if (controller.translationEnabled) ...[
                              const SizedBox(height: 16),
                              Text(
                                'Translation Target',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 12),
                              TranslationLanguageSelector(
                                selectedTarget:
                                    controller.selectedTranslationTarget,
                                enabled: controller.state ==
                                    LiveSessionState.ready,
                                onChanged: controller.selectTranslationTarget,
                              ),
                            ],
                            const SizedBox(height: 28),
                            _TranscriptSection(controller: controller),
                          ],
                          if (debugControls != null) ...[
                            const SizedBox(height: 20),
                            _DebugVerificationPanel(
                              controller: controller,
                              controls: debugControls!,
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
                _SessionControls(
                  controller: controller,
                  onSaveTranscript: () => _saveTranscript(context),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

  Future<void> _saveTranscript(BuildContext context) async {
    final transcript = controller.finalTranscript;
    if (transcript.isEmpty) {
      return;
    }
    final outcome = await (transcriptSaver ?? _defaultTranscriptSaver).save(
      transcript,
    );
    if (!context.mounted || outcome == TranscriptSaveOutcome.cancelled) {
      return;
    }
    final message = outcome == TranscriptSaveOutcome.success
        ? 'Transcript saved successfully'
        : 'Unable to save transcript';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _handleBackNavigation(BuildContext context) async {
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        title: Text(
          'End live session?',
          style: Theme.of(dialogContext).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: AppColors.text,
          ),
        ),
        content: Text(
          'End live session and return home?',
          style: Theme.of(dialogContext).textTheme.bodyMedium?.copyWith(
            color: AppColors.secondaryText,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(
                color: AppColors.secondaryText,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('End Session'),
          ),
        ],
      ),
    );

    if (shouldExit == true) {
      await controller.stop();
      controller.resetToReady();
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    }
  }
}

class _SessionIntro extends StatelessWidget {
  const _SessionIntro({required this.controller});

  final LiveSessionController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.hasStoppedSession) {
      final hasFinalTranscript = controller.finalTranscript.isNotEmpty;
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
        decoration: _cardDecoration(),
        child: Column(
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.28),
                    blurRadius: 24,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Icon(
                Icons.check_rounded,
                color: Colors.white,
                size: 38,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Session complete',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: AppColors.primaryStrong,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hasFinalTranscript
                  ? 'Your final transcript remains available below.'
                  : 'No final transcript was captured.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.secondaryText,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          controller.state == LiveSessionState.ready
              ? 'Ready to go live?'
              : 'Live translation',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            color: AppColors.primaryStrong,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          controller.state == LiveSessionState.ready
              ? 'Choose an audio source and translation target, then start.'
              : 'Speech and translation stay connected to the current session.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: AppColors.secondaryText),
        ),
      ],
    );
  }
}

class _SessionStateCard extends StatelessWidget {
  const _SessionStateCard({required this.controller});

  final LiveSessionController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final status = _statusText(controller);
    final statusColor = _statusColor(state);
    final loading =
        state == LiveSessionState.permission ||
        state == LiveSessionState.connecting ||
        state == LiveSessionState.reconnecting;

    return Container(
      key: const Key('session_state_card'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: _cardDecoration(),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _statusIcon(state, controller.selectedAudioSource),
              color: statusColor,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        status,
                        key: const Key('session_status'),
                        style: Theme.of(
                          context,
                        ).textTheme.titleMedium?.copyWith(
                          color: statusColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (state == LiveSessionState.listening) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2.5,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.live.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DecoratedBox(
                              key: Key('live_status_indicator'),
                              decoration: BoxDecoration(
                                color: AppColors.live,
                                shape: BoxShape.circle,
                              ),
                              child: SizedBox.square(dimension: 6),
                            ),
                            SizedBox(width: 4),
                            Text(
                              'LIVE',
                              key: Key('live_status_badge'),
                              style: TextStyle(
                                color: AppColors.liveStrong,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      const _SpeechBars(),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _stateDescription(controller),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading) ...[
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                _formatDuration(controller.elapsed),
                key: const Key('session_timer'),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: AppColors.text,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('session_error_card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.errorSoft.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.errorSoft),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: AppColors.error,
            size: 21,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              key: const Key('session_error'),
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
  }
}

class _TranslationWarning extends StatelessWidget {
  const _TranslationWarning({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('translation_session_warning'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.errorSoft.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: AppColors.error),
      ),
    );
  }
}

class _TranscriptSection extends StatelessWidget {
  const _TranscriptSection({required this.controller});

  final LiveSessionController controller;

  @override
  Widget build(BuildContext context) {
    final title =
        controller.hasStoppedSession ? 'Transcript Preview' : 'Transcript';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            if (controller.translationEnabled)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.lavenderSoft,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'VI \u2192 ${controller.selectedTranslationTarget.code.toUpperCase()}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AppColors.primaryStrong,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _TranscriptContent(controller: controller),
      ],
    );
  }
}

class _TranscriptContent extends StatelessWidget {
  const _TranscriptContent({required this.controller});

  final LiveSessionController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.usesBilingualPresentation) {
      return _TranscriptEmptyOrText(
        text: controller.transcript,
        emptyText: 'No transcript received yet.',
      );
    }
    final presentation = controller.translationPresentation;
    if (presentation.utterances.isEmpty &&
        presentation.liveSpeechSegments.isEmpty) {
      return const _TranscriptEmptyOrText(
        text: '',
        emptyText: 'No transcript received yet.',
      );
    }
    return Column(
      key: const Key('session_transcript'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final utterance in presentation.utterances)
          BilingualTranscriptBlock(
            key: ValueKey(
              '${utterance.identity.streamId}\u0000${utterance.identity.utteranceId}',
            ),
            utterance: utterance,
            sessionEnded: controller.hasStoppedSession,
          ),
        if (presentation.liveSpeechSegments.isNotEmpty)
          Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const _SpeechBars(),
                    const SizedBox(width: 9),
                    Text(
                      'Live Speech',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.9,
                      ),
                    ),
                    Text(
                      ' \u00b7 VI',
                      style: Theme.of(
                        context,
                      ).textTheme.labelSmall?.copyWith(color: AppColors.accent),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                for (final segment in presentation.liveSpeechSegments)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5, left: 27),
                    child: Text(
                      segment.text,
                      key: ValueKey(
                        'live-${segment.streamId ?? ''}-${segment.segmentId}',
                      ),
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: AppColors.text.withValues(alpha: 0.8),
                        fontStyle: segment.isFinal
                            ? FontStyle.normal
                            : FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _TranscriptEmptyOrText extends StatelessWidget {
  const _TranscriptEmptyOrText({required this.text, required this.emptyText});

  final String text;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final empty = text.isEmpty;
    return Container(
      key: const Key('session_transcript'),
      constraints: const BoxConstraints(minHeight: 132),
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (empty) ...[
            const Icon(
              Icons.graphic_eq_rounded,
              size: 30,
              color: AppColors.accent,
            ),
            const SizedBox(height: 10),
          ],
          Text(
            empty ? emptyText : text,
            textAlign: empty ? TextAlign.center : TextAlign.start,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: empty ? AppColors.secondaryText : AppColors.text,
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionControls extends StatelessWidget {
  const _SessionControls({
    required this.controller,
    required this.onSaveTranscript,
  });

  final LiveSessionController controller;
  final VoidCallback onSaveTranscript;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('session_controls'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      decoration: const BoxDecoration(
        color: AppColors.card,
        border: Border(top: BorderSide(color: AppColors.border)),
        boxShadow: [
          BoxShadow(
            color: Color(0x0A3444CD),
            blurRadius: 20,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: _controlsForState(),
    );
  }

  Widget _controlsForState() {
    switch (controller.state) {
      case LiveSessionState.ready:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => unawaited(controller.start()),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Start'),
              ),
            ),
            if (controller.hasStoppedSession) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: controller.finalTranscript.isEmpty
                      ? null
                      : onSaveTranscript,
                  icon: const Icon(Icons.save_alt_rounded),
                  label: const Text('Save Transcript'),
                ),
              ),
            ],
          ],
        );
      case LiveSessionState.permission:
        return const SizedBox.shrink();
      case LiveSessionState.connecting:
      case LiveSessionState.reconnecting:
        return SizedBox(
          width: double.infinity,
          child: _StopButton(controller: controller),
        );
      case LiveSessionState.listening:
        return Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.card,
                  foregroundColor: AppColors.primaryStrong,
                  side: const BorderSide(color: AppColors.primary, width: 1.5),
                  elevation: 0,
                ),
                onPressed: () => unawaited(controller.pause()),
                icon: const Icon(Icons.pause_rounded),
                label: const Text('Pause'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: _StopButton(controller: controller)),
          ],
        );
      case LiveSessionState.paused:
        return Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => unawaited(controller.resume()),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Resume'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: _StopButton(controller: controller)),
          ],
        );
      case LiveSessionState.error:
        final actions = <Widget>[
          if (controller.canRetry)
            FilledButton.icon(
              onPressed: () => unawaited(controller.retry()),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          if (controller.canOpenAppSettings)
            FilledButton.icon(
              onPressed: () => unawaited(controller.openAppSettings()),
              icon: const Icon(Icons.settings_rounded),
              label: const Text('Open Settings'),
            ),
          _StopButton(controller: controller),
        ];
        if (actions.length > 2) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < actions.length; index++) ...[
                SizedBox(width: double.infinity, child: actions[index]),
                if (index < actions.length - 1) const SizedBox(height: 10),
              ],
            ],
          );
        }
        return Row(
          children: [
            for (var index = 0; index < actions.length; index++) ...[
              Expanded(child: actions[index]),
              if (index < actions.length - 1) const SizedBox(width: 12),
            ],
          ],
        );
    }
  }
}

class _StopButton extends StatelessWidget {
  const _StopButton({required this.controller});

  final LiveSessionController controller;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        backgroundColor: AppColors.error,
        foregroundColor: Colors.white,
        side: const BorderSide(color: AppColors.error),
      ),
      onPressed: () => unawaited(controller.stop()),
      icon: const Icon(Icons.stop_rounded),
      label: const Text('Stop'),
    );
  }
}

class _DebugVerificationPanel extends StatelessWidget {
  const _DebugVerificationPanel({
    required this.controller,
    required this.controls,
  });

  final LiveSessionController controller;
  final DebugSttSessionControls controls;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('debug_verification_panel'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.deepOrange.withValues(alpha: 0.05),
        border: Border.all(color: Colors.deepOrange),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'DEBUG VERIFICATION MODE',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.deepOrange,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (controller.state == LiveSessionState.listening) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () {
                controls.configureNextReconnectToWait();
                unawaited(controls.simulateUnexpectedDisconnect());
              },
              child: const Text('Simulate Disconnect'),
            ),
            OutlinedButton(
              onPressed: () {
                controls.configureReconnectsToFail();
                unawaited(controls.simulateUnexpectedDisconnect());
              },
              child: const Text('Fail Reconnects'),
            ),
          ],
          if (controller.state == LiveSessionState.reconnecting &&
              controls.hasPendingReconnect) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: controls.completeReconnectSuccessfully,
              child: const Text('Complete Reconnect'),
            ),
          ],
        ],
      ),
    );
  }
}

class _SpeechBars extends StatelessWidget {
  const _SpeechBars();

  @override
  Widget build(BuildContext context) {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SpeechBar(height: 10),
        SizedBox(width: 2.5),
        _SpeechBar(height: 16),
        SizedBox(width: 2.5),
        _SpeechBar(height: 12),
      ],
    );
  }
}

class _SpeechBar extends StatelessWidget {
  const _SpeechBar({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

BoxDecoration _cardDecoration() {
  return BoxDecoration(
    color: AppColors.card,
    borderRadius: BorderRadius.circular(AppRadii.card),
    border: Border.all(color: AppColors.border),
    boxShadow: const [
      BoxShadow(color: Color(0x0A3444CD), blurRadius: 20, offset: Offset(0, 4)),
    ],
  );
}

String _statusText(LiveSessionController controller) {
  return switch (controller.state) {
    LiveSessionState.ready => 'Ready',
    LiveSessionState.permission =>
      controller.selectedAudioSource == MobileAudioSource.microphone
          ? 'Requesting microphone permission'
          : 'Requesting System Audio permission',
    LiveSessionState.connecting => 'Connecting',
    LiveSessionState.listening => 'Listening',
    LiveSessionState.paused => 'Paused',
    LiveSessionState.reconnecting => 'Reconnecting',
    LiveSessionState.error => 'Error',
  };
}

String _stateDescription(LiveSessionController controller) {
  return switch (controller.state) {
    LiveSessionState.ready =>
      controller.hasStoppedSession
          ? controller.finalTranscript.isNotEmpty
                ? 'Transcript preserved'
                : 'No final transcript captured'
          : 'Ready for Vietnamese speech',
    LiveSessionState.permission => 'Waiting for device access',
    LiveSessionState.connecting => 'Opening the realtime session',
    LiveSessionState.listening =>
      '${_audioSourceName(controller.selectedAudioSource)} active',
    LiveSessionState.paused => 'Audio capture is paused',
    LiveSessionState.reconnecting => 'Restoring the realtime connection',
    LiveSessionState.error => 'The session needs attention',
  };
}

String _audioSourceName(MobileAudioSource source) {
  return switch (source) {
    MobileAudioSource.microphone => 'Microphone',
    MobileAudioSource.systemAudio => 'System Audio',
  };
}

Color _statusColor(LiveSessionState state) {
  return switch (state) {
    LiveSessionState.listening => AppColors.liveStrong,
    LiveSessionState.error => AppColors.error,
    LiveSessionState.paused => AppColors.accent,
    _ => AppColors.primaryStrong,
  };
}

IconData _statusIcon(
  LiveSessionState state,
  MobileAudioSource selectedAudioSource,
) {
  return switch (state) {
    LiveSessionState.ready => Icons.check_circle_outline_rounded,
    LiveSessionState.permission => Icons.security_rounded,
    LiveSessionState.connecting => Icons.link_rounded,
    LiveSessionState.listening => switch (selectedAudioSource) {
      MobileAudioSource.microphone => Icons.mic_rounded,
      MobileAudioSource.systemAudio => Icons.computer_rounded,
    },
    LiveSessionState.paused => Icons.pause_circle_outline_rounded,
    LiveSessionState.reconnecting => Icons.sync_rounded,
    LiveSessionState.error => Icons.error_outline_rounded,
  };
}

String _formatDuration(Duration duration) {
  final minutes = duration.inMinutes.toString().padLeft(2, '0');
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
