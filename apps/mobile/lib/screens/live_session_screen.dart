import 'dart:async';

import 'package:flutter/material.dart';

import '../services/debug_stt_session_transport.dart';
import '../services/audio_input.dart';
import '../services/transcript_file_saver.dart';
import '../session/live_session_controller.dart';
import '../session/live_session_state.dart';
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
    return Scaffold(
      appBar: AppBar(title: const Text('AI Live Translator')),
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          if (controller.hasPendingBenchmarkTranscriptRender) {
            final transcriptRevision =
                controller.latestBenchmarkTranscriptRevision;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              controller.recordBenchmarkTranscriptRendered(transcriptRevision);
            });
          }
          return SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 40,
                  ),
                  child: IntrinsicHeight(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Live Session',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 20),
                        AudioSourceSelector(
                          selectedSource: controller.selectedAudioSource,
                          systemAudioSupported:
                              controller.isSystemAudioSupported,
                          enabled: controller.state == LiveSessionState.ready,
                          onSelected: controller.selectAudioSource,
                        ),
                        if (controller.translationEnabled) ...[
                          const SizedBox(height: 12),
                          TranslationLanguageSelector(
                            selectedTarget:
                                controller.selectedTranslationTarget,
                            enabled: controller.state == LiveSessionState.ready,
                            onChanged: controller.selectTranslationTarget,
                          ),
                        ],
                        const SizedBox(height: 24),
                        Text(
                          switch (controller.state) {
                            LiveSessionState.ready => 'Ready',
                            LiveSessionState.permission =>
                              controller.selectedAudioSource ==
                                      MobileAudioSource.microphone
                                  ? 'Requesting microphone permission'
                                  : 'Requesting System Audio permission',
                            LiveSessionState.connecting => 'Connecting',
                            LiveSessionState.listening => 'Listening',
                            LiveSessionState.paused => 'Paused',
                            LiveSessionState.reconnecting => 'Reconnecting',
                            LiveSessionState.error => 'Error',
                          },
                          key: const Key('session_status'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 16),
                        if (controller.state == LiveSessionState.permission ||
                            controller.state == LiveSessionState.connecting ||
                            controller.state ==
                                LiveSessionState.reconnecting) ...[
                          const Center(child: CircularProgressIndicator()),
                          const SizedBox(height: 16),
                        ],
                        Text(
                          _formatDuration(controller.elapsed),
                          key: const Key('session_timer'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.displaySmall,
                        ),
                        if (controller.state == LiveSessionState.error &&
                            controller.errorMessage != null) ...[
                          const SizedBox(height: 24),
                          Text(
                            controller.errorMessage!,
                            key: const Key('session_error'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        if (controller.translationWarning != null) ...[
                          const SizedBox(height: 16),
                          Container(
                            key: const Key('translation_session_warning'),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .errorContainer
                                  .withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(controller.translationWarning!),
                          ),
                        ],
                        const SizedBox(height: 24),
                        Text(
                          'Transcript',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: Card(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(16),
                              child: _TranscriptContent(controller: controller),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        if (controller.state == LiveSessionState.ready) ...[
                          FilledButton(
                            onPressed: () => unawaited(controller.start()),
                            child: const Text('Start'),
                          ),
                          if (controller.hasStoppedSession) ...[
                            const SizedBox(height: 12),
                            OutlinedButton(
                              onPressed: controller.finalTranscript.isEmpty
                                  ? null
                                  : () => unawaited(_saveTranscript(context)),
                              child: const Text('Save Transcript'),
                            ),
                          ],
                        ],
                        if (controller.state == LiveSessionState.listening)
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton(
                                  onPressed: () =>
                                      unawaited(controller.pause()),
                                  child: const Text('Pause'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => unawaited(controller.stop()),
                                  child: const Text('Stop'),
                                ),
                              ),
                            ],
                          ),
                        if (controller.state == LiveSessionState.paused)
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton(
                                  onPressed: () =>
                                      unawaited(controller.resume()),
                                  child: const Text('Resume'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => unawaited(controller.stop()),
                                  child: const Text('Stop'),
                                ),
                              ),
                            ],
                          ),
                        if (controller.state == LiveSessionState.connecting ||
                            controller.state == LiveSessionState.reconnecting)
                          OutlinedButton(
                            onPressed: () => unawaited(controller.stop()),
                            child: const Text('Stop'),
                          ),
                        if (controller.state == LiveSessionState.error)
                          Row(
                            children: [
                              if (controller.canRetry) ...[
                                Expanded(
                                  child: FilledButton(
                                    onPressed: () =>
                                        unawaited(controller.retry()),
                                    child: const Text('Retry'),
                                  ),
                                ),
                                const SizedBox(width: 12),
                              ],
                              if (controller.canOpenAppSettings) ...[
                                Expanded(
                                  child: FilledButton(
                                    onPressed: () =>
                                        unawaited(controller.openAppSettings()),
                                    child: const Text('Open Settings'),
                                  ),
                                ),
                                const SizedBox(width: 12),
                              ],
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => unawaited(controller.stop()),
                                  child: const Text('Stop'),
                                ),
                              ),
                            ],
                          ),
                        if (debugControls != null) ...[
                          const SizedBox(height: 16),
                          Container(
                            key: const Key('debug_verification_panel'),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
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
                                if (controller.state ==
                                    LiveSessionState.listening) ...[
                                  const SizedBox(height: 8),
                                  OutlinedButton(
                                    onPressed: () {
                                      debugControls!
                                          .configureNextReconnectToWait();
                                      unawaited(
                                        debugControls!
                                            .simulateUnexpectedDisconnect(),
                                      );
                                    },
                                    child: const Text('Simulate Disconnect'),
                                  ),
                                  OutlinedButton(
                                    onPressed: () {
                                      debugControls!
                                          .configureReconnectsToFail();
                                      unawaited(
                                        debugControls!
                                            .simulateUnexpectedDisconnect(),
                                      );
                                    },
                                    child: const Text('Fail Reconnects'),
                                  ),
                                ],
                                if (controller.state ==
                                        LiveSessionState.reconnecting &&
                                    debugControls!.hasPendingReconnect) ...[
                                  const SizedBox(height: 8),
                                  OutlinedButton(
                                    onPressed: debugControls!
                                        .completeReconnectSuccessfully,
                                    child: const Text('Complete Reconnect'),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
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
}

class _TranscriptContent extends StatelessWidget {
  const _TranscriptContent({required this.controller});

  final LiveSessionController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.usesBilingualPresentation) {
      return Text(
        controller.transcript.isEmpty
            ? 'No transcript received yet.'
            : controller.transcript,
        key: const Key('session_transcript'),
      );
    }
    final presentation = controller.translationPresentation;
    if (presentation.utterances.isEmpty &&
        presentation.liveSpeechSegments.isEmpty) {
      return const Text(
        'No transcript received yet.',
        key: Key('session_transcript'),
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
          ),
        if (presentation.liveSpeechSegments.isNotEmpty) ...[
          Text('Live Speech', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          for (final segment in presentation.liveSpeechSegments)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                segment.text,
                key: ValueKey(
                  'live-${segment.streamId ?? ''}-${segment.segmentId}',
                ),
                style: segment.isFinal
                    ? null
                    : const TextStyle(fontStyle: FontStyle.italic),
              ),
            ),
        ],
      ],
    );
  }
}
