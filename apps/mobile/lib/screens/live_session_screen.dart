import 'dart:async';

import 'package:flutter/material.dart';

import '../services/debug_stt_session_transport.dart';
import '../session/live_session_controller.dart';
import '../session/live_session_state.dart';

class LiveSessionScreen extends StatelessWidget {
  const LiveSessionScreen({
    super.key,
    required this.controller,
    this.debugControls,
  });

  final LiveSessionController controller;
  final DebugSttSessionControls? debugControls;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Live Translator')),
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Live Session',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 32),
                  Text(
                    switch (controller.state) {
                      LiveSessionState.ready => 'Ready',
                      LiveSessionState.permission =>
                        'Requesting microphone permission',
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
                      controller.state == LiveSessionState.reconnecting) ...[
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
                        child: Text(
                          controller.transcript.isEmpty
                              ? 'No transcript received yet.'
                              : controller.transcript,
                          key: const Key('session_transcript'),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (controller.state == LiveSessionState.ready)
                    FilledButton(
                      onPressed: () => unawaited(controller.start()),
                      child: const Text('Start'),
                    ),
                  if (controller.state == LiveSessionState.listening)
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: controller.pause,
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
                            onPressed: controller.resume,
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
                              onPressed: () => unawaited(controller.retry()),
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
                                debugControls!.configureNextReconnectToWait();
                                unawaited(
                                  debugControls!.simulateUnexpectedDisconnect(),
                                );
                              },
                              child: const Text('Simulate Disconnect'),
                            ),
                            OutlinedButton(
                              onPressed: () {
                                debugControls!.configureReconnectsToFail();
                                unawaited(
                                  debugControls!.simulateUnexpectedDisconnect(),
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
                              onPressed:
                                  debugControls!.completeReconnectSuccessfully,
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
}
