import 'dart:async';

import 'package:flutter/foundation.dart';

import '../benchmark/stt_benchmark.dart';
import '../diagnostics/stt_transcript_trace.dart';
import '../services/audio_input.dart';
import '../services/microphone_capture_service.dart';
import '../services/microphone_permission_service.dart';
import '../services/stt_websocket_service.dart';
import '../translation/translation_domain.dart';
import '../translation/translation_presentation.dart';
import 'live_session_state.dart';
import 'session_timer.dart';

typedef RetryDelay = Future<void> Function(Duration duration);
typedef SystemAudioSupportQuery = Future<bool> Function();

class LiveSessionController extends ChangeNotifier {
  LiveSessionController({
    required MicrophonePermissionGateway permissionGateway,
    required SttSessionTransport transport,
    MobileMicrophoneCapture? microphoneCapture,
    MobileAudioInput? systemAudioInput,
    SystemAudioSupportQuery? systemAudioSupportQuery,
    SessionClock? clock,
    SessionTicker? ticker,
    LiveSessionBenchmark? benchmark,
    this.transcriptTrace = const DisabledSttTranscriptTrace(),
    this.maxReconnectAttempts = 3,
    this.reconnectDelay = const Duration(milliseconds: 500),
    this.translationEnabled = true,
    RetryDelay? retryDelay,
  }) : _permissionGateway = permissionGateway,
       _transport = transport,
       _microphoneCapture = microphoneCapture ?? DebugNoopMicrophoneCapture(),
       _systemAudioInput = systemAudioInput,
       _systemAudioSupportQuery = systemAudioSupportQuery,
       _clock = clock ?? StopwatchSessionClock(),
       _ticker = ticker ?? PeriodicSessionTicker(),
       _benchmark = benchmark ?? const DisabledLiveSessionBenchmark(),
       _retryDelay = retryDelay ?? Future<void>.delayed,
       assert(maxReconnectAttempts > 0) {
    _eventSubscription = _transport.events.listen(_handleTransportEvent);
    audioSourceSupportReady = _loadSystemAudioSupport();
  }

  final MicrophonePermissionGateway _permissionGateway;
  final SttSessionTransport _transport;
  final MobileMicrophoneCapture _microphoneCapture;
  final MobileAudioInput? _systemAudioInput;
  final SystemAudioSupportQuery? _systemAudioSupportQuery;
  final SessionClock _clock;
  final SessionTicker _ticker;
  final LiveSessionBenchmark _benchmark;
  final SttTranscriptTrace transcriptTrace;
  final RetryDelay _retryDelay;
  final int maxReconnectAttempts;
  final Duration reconnectDelay;
  final bool translationEnabled;
  late final StreamSubscription<SttSessionEvent> _eventSubscription;
  late final Future<void> audioSourceSupportReady;
  StreamSubscription<Uint8List>? _audioSubscription;
  Future<void>? _audioSendFuture;

  LiveSessionState _state = LiveSessionState.ready;
  String? _errorMessage;
  bool _canOpenAppSettings = false;
  bool _canRetry = false;
  LiveSessionRetryKind? _retryKind;
  bool _restorePausedAfterReconnect = false;
  Duration _accumulatedElapsed = Duration.zero;
  Duration? _listeningStartedAt;
  final Map<TranscriptSegmentIdentity, LiveTranscriptSegment>
  _transcriptSegments = {};
  TranslationTargetLanguage _selectedTranslationTarget =
      defaultTranslationTarget;
  TranslationState _translationState = const TranslationState();
  String? _activeTranslationStreamId;
  int _operationGeneration = 0;
  int _freshRetryGeneration = 0;
  Future<void>? _stopFuture;
  Future<void>? _freshRetryFuture;
  Future<void>? _microphonePauseFuture;
  Future<void>? _microphoneFailureCleanupFuture;
  bool _forwardAudio = false;
  bool _microphonePaused = false;
  bool _hasStoppedSession = false;
  bool _isDisposed = false;
  MobileAudioSource _selectedAudioSource = MobileAudioSource.microphone;
  MobileAudioInput? _activeAudioInput;
  bool _isSystemAudioSupported = false;

  LiveSessionState get state => _state;
  MobileAudioSource get selectedAudioSource => _selectedAudioSource;
  bool get isSystemAudioSupported => _isSystemAudioSupported;
  Duration get elapsed =>
      _accumulatedElapsed +
      (_listeningStartedAt == null
          ? Duration.zero
          : _clock.now - _listeningStartedAt!);
  String? get errorMessage => _errorMessage;
  bool get canOpenAppSettings => _canOpenAppSettings;
  bool get canRetry => _canRetry;
  bool get hasStoppedSession => _hasStoppedSession;
  String get transcript =>
      _transcriptSegments.values.map((segment) => segment.text).join('\n');
  String get finalTranscript => _transcriptSegments.values
      .where((segment) => segment.isFinal)
      .map((segment) => segment.text)
      .join('\n');
  TranslationTargetLanguage get selectedTranslationTarget =>
      _selectedTranslationTarget;
  TranslationState get translationState => _translationState;
  TranslationPresentation get translationPresentation =>
      buildTranslationPresentation(
        _transcriptSegments.values.toList(growable: false),
        _translationState.utterances,
      );
  bool get usesBilingualPresentation =>
      translationEnabled ||
      _translationState.configurations.isNotEmpty ||
      _translationState.utterances.isNotEmpty ||
      _translationState.sessionErrors.isNotEmpty;
  String? get translationWarning {
    final activeStreamId = _activeTranslationStreamId;
    if (activeStreamId == null) {
      return null;
    }
    return _translationState.sessionErrors.any(
          (error) => error.streamId == activeStreamId,
        )
        ? translationUnavailableWarning
        : null;
  }

  bool get benchmarkEnabled => _benchmark.enabled;
  bool get hasPendingBenchmarkTranscriptRender => _benchmark.hasPendingUiRender;
  int get latestBenchmarkTranscriptRevision =>
      _benchmark.latestTranscriptRevision;

  bool selectAudioSource(MobileAudioSource source) {
    if (_isDisposed || _state != LiveSessionState.ready) {
      return false;
    }
    if (source == MobileAudioSource.systemAudio && !_isSystemAudioSupported) {
      return false;
    }
    if (_selectedAudioSource == source) {
      return true;
    }
    _selectedAudioSource = source;
    _notifyListeners();
    return true;
  }

  bool selectTranslationTarget(TranslationTargetLanguage target) {
    if (_isDisposed || _state != LiveSessionState.ready) {
      return false;
    }
    if (_selectedTranslationTarget == target) {
      return true;
    }
    _selectedTranslationTarget = target;
    _notifyListeners();
    return true;
  }

  SttSessionStartOptions get _startOptions => SttSessionStartOptions(
    translationTarget: translationEnabled ? _selectedTranslationTarget : null,
  );

  Future<void> _loadSystemAudioSupport() async {
    final query = _systemAudioSupportQuery;
    var supported = false;
    if (_systemAudioInput != null && query != null) {
      try {
        supported = await query();
      } catch (_) {
        supported = false;
      }
    }
    if (_isDisposed) {
      return;
    }
    _isSystemAudioSupported = supported;
    if (!supported && _selectedAudioSource == MobileAudioSource.systemAudio) {
      _selectedAudioSource = MobileAudioSource.microphone;
    }
    _notifyListeners();
  }

  void recordBenchmarkTranscriptRendered(int transcriptRevision) {
    _benchmark.recordUiRendered(transcriptRevision);
  }

  Future<void> start() async {
    if (_isDisposed || _state != LiveSessionState.ready) {
      return;
    }
    final selectedSource = _selectedAudioSource;
    final selectedInput = selectedSource == MobileAudioSource.microphone
        ? _microphoneCapture
        : _systemAudioInput;
    if (selectedInput == null ||
        (selectedSource == MobileAudioSource.systemAudio &&
            !_isSystemAudioSupported)) {
      _errorMessage = 'System Audio is unavailable on this device.';
      _canRetry = false;
      _retryKind = null;
      _state = LiveSessionState.error;
      _notifyListeners();
      return;
    }
    _activeAudioInput = selectedInput;
    _transcriptSegments.clear();
    _translationState = const TranslationState();
    _activeTranslationStreamId = null;
    _hasStoppedSession = false;
    final operationGeneration = ++_operationGeneration;
    _benchmark.sessionStartRequested();

    _errorMessage = null;
    _canOpenAppSettings = false;
    _canRetry = false;
    _retryKind = null;
    _restorePausedAfterReconnect = false;
    _state = LiveSessionState.permission;
    _notifyListeners();

    late final MicrophonePermissionResult permission;
    try {
      permission = await _permissionGateway.requestPermission();
    } catch (_) {
      if (operationGeneration != _operationGeneration ||
          _state != LiveSessionState.permission) {
        return;
      }
      _errorMessage = selectedSource == MobileAudioSource.microphone
          ? 'Unable to request microphone permission.'
          : 'Unable to request audio capture permission.';
      _benchmark.recordError();
      _canRetry = true;
      _retryKind = LiveSessionRetryKind.freshStart;
      _state = LiveSessionState.error;
      _notifyListeners();
      return;
    }
    if (operationGeneration != _operationGeneration ||
        _state != LiveSessionState.permission) {
      return;
    }
    if (permission != MicrophonePermissionResult.granted) {
      _canOpenAppSettings =
          permission == MicrophonePermissionResult.permanentlyDenied;
      _canRetry = true;
      _retryKind = LiveSessionRetryKind.freshStart;
      _errorMessage = switch ((selectedSource, permission)) {
        (MobileAudioSource.microphone, MicrophonePermissionResult.denied) =>
          'Microphone permission is required to start a live session.',
        (MobileAudioSource.microphone, _) =>
          'Microphone permission is permanently denied. Open app settings to enable it.',
        (MobileAudioSource.systemAudio, MicrophonePermissionResult.denied) =>
          'Audio capture permission is required to use System Audio.',
        (MobileAudioSource.systemAudio, _) =>
          'Audio capture permission is permanently denied. Open app settings to enable it.',
      };
      _benchmark.recordError();
      _state = LiveSessionState.error;
      _notifyListeners();
      return;
    }

    if (selectedSource == MobileAudioSource.systemAudio) {
      final captureStarted = await _startAudioInput(
        input: selectedInput,
        source: selectedSource,
        operationGeneration: operationGeneration,
        expectedState: LiveSessionState.permission,
        disconnectTransportOnFailure: false,
      );
      if (!captureStarted) {
        return;
      }
    }

    _state = LiveSessionState.connecting;
    _notifyListeners();

    _benchmark.connectStarted();
    try {
      await _transport.connect(options: _startOptions);
    } catch (error) {
      if (selectedSource == MobileAudioSource.systemAudio) {
        await _cancelAudioSubscription();
        await _stopMicrophoneSafely();
      }
      if (operationGeneration != _operationGeneration ||
          _state != LiveSessionState.connecting) {
        return;
      }
      _errorMessage = error is SttSessionException
          ? error.message
          : 'WebSocket connection failed. Check that the backend is available.';
      _benchmark.recordError();
      _canRetry = error is SttSessionException ? error.recoverable : true;
      _retryKind = _canRetry ? LiveSessionRetryKind.freshStart : null;
      _state = LiveSessionState.error;
      _notifyListeners();
      return;
    }
    if (operationGeneration != _operationGeneration ||
        _state != LiveSessionState.connecting) {
      return;
    }
    _benchmark.websocketReady();

    if (selectedSource == MobileAudioSource.microphone) {
      final captureStarted = await _startAudioInput(
        input: selectedInput,
        source: selectedSource,
        operationGeneration: operationGeneration,
        expectedState: LiveSessionState.connecting,
        disconnectTransportOnFailure: true,
      );
      if (!captureStarted) {
        return;
      }
    }

    _microphonePaused = false;
    _forwardAudio = true;
    _state = LiveSessionState.listening;
    _retryKind = null;
    _restorePausedAfterReconnect = false;
    _startTimer();
    _benchmark.listeningStarted();
    _notifyListeners();
  }

  Future<bool> _startAudioInput({
    required MobileAudioInput input,
    required MobileAudioSource source,
    required int operationGeneration,
    required LiveSessionState expectedState,
    required bool disconnectTransportOnFailure,
  }) async {
    try {
      final audioStream = await input.start();
      if (operationGeneration != _operationGeneration ||
          _state != expectedState ||
          _isDisposed) {
        await _stopMicrophoneSafely();
        return false;
      }
      _benchmark.microphoneStarted();
      _audioSubscription = audioStream.listen(
        _handleAudioChunk,
        onError: _handleAudioStreamError,
        onDone: _handleAudioStreamDone,
      );
      return true;
    } catch (error) {
      _forwardAudio = false;
      await _stopMicrophoneSafely();
      if (disconnectTransportOnFailure) {
        await _disconnectTransportSafely();
      }
      if (operationGeneration != _operationGeneration ||
          _state != expectedState ||
          _isDisposed) {
        return false;
      }
      _errorMessage = error is AudioInputException
          ? error.message
          : source == MobileAudioSource.microphone
          ? 'Unable to start microphone capture.'
          : 'Unable to start System Audio capture.';
      _benchmark.recordError();
      _canRetry = error is AudioInputException ? error.recoverable : true;
      _retryKind = _canRetry ? LiveSessionRetryKind.freshStart : null;
      _state = LiveSessionState.error;
      _notifyListeners();
      return false;
    }
  }

  Future<bool> openAppSettings() async {
    if (!_canOpenAppSettings) {
      return false;
    }
    return _permissionGateway.openAppSettings();
  }

  Future<void> retry() {
    final retryKind = _retryKind;
    if (_state != LiveSessionState.error || !_canRetry || retryKind == null) {
      return Future<void>.value();
    }
    if (retryKind == LiveSessionRetryKind.activeSessionReconnect) {
      _activeTranslationStreamId = null;
      _errorMessage = null;
      _canOpenAppSettings = false;
      _canRetry = false;
      _retryKind = null;
      _state = LiveSessionState.reconnecting;
      _benchmark.reconnectStarted();
      _notifyListeners();
      final operationGeneration = ++_operationGeneration;
      return _pauseThenReconnect(operationGeneration);
    }
    final activeRetry = _freshRetryFuture;
    if (activeRetry != null) {
      return activeRetry;
    }
    final freshRetryGeneration = ++_freshRetryGeneration;
    late final Future<void> sharedRetry;
    sharedRetry = _retryFresh(freshRetryGeneration).whenComplete(() {
      if (identical(_freshRetryFuture, sharedRetry)) {
        _freshRetryFuture = null;
      }
    });
    _freshRetryFuture = sharedRetry;
    return sharedRetry;
  }

  Future<void> _retryFresh(int freshRetryGeneration) async {
    await _stopSession();
    if (freshRetryGeneration != _freshRetryGeneration) {
      return;
    }
    await start();
  }

  Future<void> pause() async {
    if (_isDisposed || _state != LiveSessionState.listening) {
      return;
    }

    _forwardAudio = false;
    _freezeTimer();
    _state = LiveSessionState.paused;
    _benchmark.paused();
    _notifyListeners();
    await _pauseMicrophone();
  }

  Future<void> resume() async {
    if (_isDisposed || _state != LiveSessionState.paused) {
      return;
    }

    final operationGeneration = _operationGeneration;
    final activeAudioInput = _activeAudioInput;
    if (activeAudioInput == null) {
      return;
    }
    try {
      await activeAudioInput.resume();
    } catch (_) {
      return;
    }
    if (_isDisposed ||
        operationGeneration != _operationGeneration ||
        _state != LiveSessionState.paused) {
      return;
    }
    _microphonePaused = false;
    _forwardAudio = true;
    _state = LiveSessionState.listening;
    _startTimer();
    _benchmark.resumed();
    _notifyListeners();
  }

  Future<void> stop() {
    _forwardAudio = false;
    _freshRetryGeneration++;
    return _stopSession();
  }

  Future<void> _stopSession() {
    final activeStop = _stopFuture;
    if (activeStop != null) {
      return activeStop;
    }
    if (_state == LiveSessionState.ready) {
      return Future<void>.value();
    }
    late final Future<void> sharedStop;
    sharedStop = _performStop().whenComplete(() {
      if (identical(_stopFuture, sharedStop)) {
        _stopFuture = null;
      }
    });
    _stopFuture = sharedStop;
    return sharedStop;
  }

  Future<void> _performStop() async {
    _operationGeneration++;
    _forwardAudio = false;

    final shouldSendStop =
        _state == LiveSessionState.listening ||
        _state == LiveSessionState.paused ||
        _state == LiveSessionState.reconnecting ||
        (_state == LiveSessionState.error &&
            _retryKind == LiveSessionRetryKind.activeSessionReconnect);
    _freezeTimer();

    await _waitForMicrophoneFailureCleanup();
    await _cancelAudioSubscription();
    await _stopMicrophoneSafely();
    _activeAudioInput = null;
    await _waitForAudioSend();

    try {
      if (shouldSendStop) {
        await _transport.stop();
      }
    } catch (_) {
      // Local cleanup must still complete when the remote session is gone.
    } finally {
      try {
        await _transport.disconnect();
      } catch (_) {
        // Stop remains deterministic even if transport cleanup reports failure.
      }
    }

    _accumulatedElapsed = Duration.zero;
    _transcriptSegments.removeWhere((_, segment) => !segment.isFinal);
    _errorMessage = null;
    _canOpenAppSettings = false;
    _canRetry = false;
    _retryKind = null;
    _restorePausedAfterReconnect = false;
    _activeTranslationStreamId = null;
    _benchmark.stopped();
    _hasStoppedSession = true;
    _state = LiveSessionState.ready;
    _notifyListeners();
  }

  void _handleAudioChunk(Uint8List audio) {
    if (_isDisposed || !_forwardAudio || _state != LiveSessionState.listening) {
      return;
    }

    if (_benchmark.enabled) {
      _benchmark.recordOutgoingPcm(audio);
    }

    final operationGeneration = _operationGeneration;
    final previousSend = _audioSendFuture;
    final sendFuture = previousSend == null
        ? _sendAudioIfCurrent(audio, operationGeneration)
        : previousSend.then(
            (_) => _sendAudioIfCurrent(audio, operationGeneration),
          );

    late final Future<void> sharedSend;
    sharedSend = sendFuture
        .catchError((Object _, StackTrace _) {})
        .whenComplete(() {
          if (!identical(_audioSendFuture, sharedSend)) {
            return;
          }
          _audioSendFuture = null;
        });
    _audioSendFuture = sharedSend;
  }

  Future<void> _sendAudioIfCurrent(Uint8List audio, int operationGeneration) {
    if (_isDisposed ||
        !_forwardAudio ||
        operationGeneration != _operationGeneration ||
        _state != LiveSessionState.listening) {
      return Future<void>.value();
    }
    try {
      return _transport.sendAudio(audio);
    } catch (_) {
      // A synchronous socket failure is contained like an asynchronous one.
      return Future<void>.value();
    }
  }

  void _handleAudioStreamDone() {
    _audioSubscription = null;
    _handleUnexpectedMicrophoneEnd();
  }

  void _handleAudioStreamError(Object _, StackTrace _) {
    final subscription = _audioSubscription;
    _audioSubscription = null;
    final cancelFuture = subscription?.cancel();
    _handleUnexpectedMicrophoneEnd(cancelFuture: cancelFuture);
  }

  void _handleUnexpectedMicrophoneEnd({Future<void>? cancelFuture}) {
    final captureWasActive =
        _state == LiveSessionState.permission ||
        _state == LiveSessionState.connecting ||
        _state == LiveSessionState.listening ||
        _state == LiveSessionState.paused ||
        _state == LiveSessionState.reconnecting;
    if (_isDisposed || !captureWasActive) {
      return;
    }

    _forwardAudio = false;
    _operationGeneration++;
    _freezeTimer();
    _errorMessage = _selectedAudioSource == MobileAudioSource.microphone
        ? 'Microphone capture stopped unexpectedly.'
        : 'System Audio capture stopped unexpectedly.';
    _benchmark.recordError();
    _canOpenAppSettings = false;
    _canRetry = true;
    _retryKind = LiveSessionRetryKind.freshStart;
    _restorePausedAfterReconnect = false;
    _state = LiveSessionState.error;
    _notifyListeners();

    late final Future<void> sharedCleanup;
    sharedCleanup = _cleanupUnexpectedMicrophoneEnd(cancelFuture).whenComplete(
      () {
        if (identical(_microphoneFailureCleanupFuture, sharedCleanup)) {
          _microphoneFailureCleanupFuture = null;
        }
      },
    );
    _microphoneFailureCleanupFuture = sharedCleanup;
  }

  Future<void> _cleanupUnexpectedMicrophoneEnd(
    Future<void>? cancelFuture,
  ) async {
    if (cancelFuture != null) {
      try {
        await cancelFuture;
      } catch (_) {
        // Continue cleanup even if the failed stream cannot be cancelled.
      }
    }
    await _stopMicrophoneSafely();
    await _waitForAudioSend();
    await _disconnectTransportSafely();
  }

  Future<void> _waitForMicrophoneFailureCleanup() async {
    final cleanupFuture = _microphoneFailureCleanupFuture;
    if (cleanupFuture == null) {
      return;
    }
    try {
      await cleanupFuture;
    } catch (_) {
      // Cleanup helpers already sanitize platform and transport failures.
    }
  }

  Future<void> _pauseMicrophone() {
    if (_microphonePaused) {
      return Future<void>.value();
    }
    final activePause = _microphonePauseFuture;
    if (activePause != null) {
      return activePause;
    }
    final activeAudioInput = _activeAudioInput;
    if (activeAudioInput == null) {
      return Future<void>.value();
    }
    late final Future<void> sharedPause;
    sharedPause = activeAudioInput
        .pause()
        .catchError((Object _, StackTrace _) {})
        .whenComplete(() {
          _microphonePaused = true;
          if (identical(_microphonePauseFuture, sharedPause)) {
            _microphonePauseFuture = null;
          }
        });
    _microphonePauseFuture = sharedPause;
    return sharedPause;
  }

  Future<void> _cancelAudioSubscription() async {
    final subscription = _audioSubscription;
    _audioSubscription = null;
    if (subscription == null) {
      return;
    }
    try {
      await subscription.cancel();
    } catch (_) {
      // Remaining local and transport cleanup must still run.
    }
  }

  Future<void> _waitForAudioSend() async {
    final sendFuture = _audioSendFuture;
    if (sendFuture == null) {
      return;
    }
    try {
      await sendFuture;
    } catch (_) {
      // Audio send failures are already normalized by the transport lifecycle.
    }
  }

  Future<void> _stopMicrophoneSafely() async {
    final activeAudioInput = _activeAudioInput;
    if (activeAudioInput == null) {
      _microphonePaused = false;
      return;
    }
    try {
      await activeAudioInput.stop();
    } catch (_) {
      // Remaining transport cleanup must still run.
    }
    _microphonePaused = false;
  }

  Future<void> _disconnectTransportSafely() async {
    try {
      await _transport.disconnect();
    } catch (_) {
      // Local lifecycle transitions must not expose cleanup details.
    }
  }

  void _notifyListeners() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  void _startTimer() {
    if (_listeningStartedAt != null) {
      return;
    }
    _listeningStartedAt = _clock.now;
    _ticker.start(_notifyListeners);
  }

  void _freezeTimer() {
    final listeningStartedAt = _listeningStartedAt;
    if (listeningStartedAt == null) {
      return;
    }
    _accumulatedElapsed += _clock.now - listeningStartedAt;
    _listeningStartedAt = null;
    _ticker.stop();
  }

  void _handleTransportEvent(SttSessionEvent event) {
    if (_isDisposed) {
      return;
    }
    if (event is SttTranscriptEvent) {
      if (_benchmark.enabled) {
        _benchmark.recordTranscriptReceived(
          kind: event.kind == SttTranscriptKind.interim
              ? SttBenchmarkTranscriptKind.interim
              : SttBenchmarkTranscriptKind.finalResult,
          segmentId: event.segmentId,
        );
      }
      final identity = TranscriptSegmentIdentity(
        event.streamId,
        event.segmentId,
      );
      final previous = _transcriptSegments[identity];
      final incomingKind = event.kind == SttTranscriptKind.interim
          ? 'interim'
          : 'final';
      if (previous?.isFinal == true) {
        transcriptTrace.segmentApplied(
          segmentId: event.segmentId,
          incomingKind: incomingKind,
          previousText: previous!.text,
          resultingText: previous.text,
          action: TranscriptSegmentAction.ignored,
        );
        return;
      }
      final resulting = LiveTranscriptSegment(
        streamId: event.streamId,
        segmentId: event.segmentId,
        text: event.text,
        isFinal: event.kind == SttTranscriptKind.finalResult,
      );
      _transcriptSegments[identity] = resulting;
      transcriptTrace.segmentApplied(
        segmentId: event.segmentId,
        incomingKind: incomingKind,
        previousText: previous?.text,
        resultingText: resulting.text,
        action: previous == null
            ? TranscriptSegmentAction.inserted
            : resulting.isFinal
            ? TranscriptSegmentAction.finalized
            : TranscriptSegmentAction.revised,
      );
      if (resulting.isFinal) {
        transcriptTrace.finalSegmentSnapshot(
          _transcriptSegments.entries
              .where((entry) => entry.value.isFinal)
              .map(
                (entry) => TranscriptTraceFinalSegment(
                  segmentId: entry.value.segmentId,
                  text: entry.value.text,
                ),
              )
              .toList(),
        );
      }
      _notifyListeners();
      return;
    }
    if (event is SttTranslationEvent) {
      final next = _translationState.apply(event.translation);
      final previousActiveStreamId = _activeTranslationStreamId;
      final activeStreamId = switch (event.translation) {
        TranslationConfiguredEvent value => value.streamId,
        TranslationUtteranceEvent value => value.streamId,
        TranslationSessionErrorEvent value => value.streamId,
      };
      _activeTranslationStreamId = activeStreamId;
      if (identical(next, _translationState) &&
          previousActiveStreamId == activeStreamId) {
        return;
      }
      _translationState = next;
      final translation = event.translation;
      if (translation is TranslationConfiguredEvent) {
        _selectedTranslationTarget = translation.targetLanguage;
      }
      _notifyListeners();
      return;
    }
    if (event is SttSessionErrorEvent &&
        (_state == LiveSessionState.connecting ||
            _state == LiveSessionState.listening ||
            _state == LiveSessionState.paused ||
            _state == LiveSessionState.reconnecting)) {
      final restorePaused =
          _state == LiveSessionState.paused ||
          (_state == LiveSessionState.reconnecting &&
              _restorePausedAfterReconnect);
      final retryKind = _state == LiveSessionState.connecting
          ? LiveSessionRetryKind.freshStart
          : LiveSessionRetryKind.activeSessionReconnect;
      _forwardAudio = false;
      if (_state == LiveSessionState.listening) {
        unawaited(_pauseMicrophone());
      }
      _operationGeneration++;
      _freezeTimer();
      _errorMessage = event.message;
      _benchmark.recordError();
      _canRetry = event.recoverable;
      _retryKind = event.recoverable ? retryKind : null;
      _restorePausedAfterReconnect =
          event.recoverable &&
          retryKind == LiveSessionRetryKind.activeSessionReconnect &&
          restorePaused;
      _state = LiveSessionState.error;
      _notifyListeners();
      return;
    }
    if (event is SttSessionClosedEvent &&
        event.unexpected &&
        (_state == LiveSessionState.listening ||
            _state == LiveSessionState.paused)) {
      _activeTranslationStreamId = null;
      _restorePausedAfterReconnect = _state == LiveSessionState.paused;
      _forwardAudio = false;
      _freezeTimer();
      _state = LiveSessionState.reconnecting;
      _benchmark.reconnectStarted();
      _notifyListeners();
      final operationGeneration = ++_operationGeneration;
      unawaited(_pauseThenReconnect(operationGeneration));
    }
  }

  Future<void> _pauseThenReconnect(int operationGeneration) async {
    await _pauseMicrophone();
    if (_isDisposed ||
        operationGeneration != _operationGeneration ||
        _state != LiveSessionState.reconnecting) {
      return;
    }
    await _reconnect(operationGeneration);
  }

  Future<void> _reconnect(int operationGeneration) async {
    await _waitForAudioSend();
    if (_isDisposed ||
        operationGeneration != _operationGeneration ||
        _state != LiveSessionState.reconnecting) {
      return;
    }

    for (var attempt = 1; attempt <= maxReconnectAttempts; attempt++) {
      if (operationGeneration != _operationGeneration ||
          _state != LiveSessionState.reconnecting) {
        return;
      }
      try {
        await _transport.disconnect();
        if (operationGeneration != _operationGeneration ||
            _state != LiveSessionState.reconnecting) {
          return;
        }
        await _transport.connect(options: _startOptions);
        if (operationGeneration != _operationGeneration ||
            _state != LiveSessionState.reconnecting) {
          return;
        }
        final restorePaused = _restorePausedAfterReconnect;
        if (!restorePaused) {
          final activeAudioInput = _activeAudioInput;
          if (activeAudioInput == null) {
            throw StateError('No active audio input to resume.');
          }
          await activeAudioInput.resume();
          if (_isDisposed ||
              operationGeneration != _operationGeneration ||
              _state != LiveSessionState.reconnecting) {
            return;
          }
          _microphonePaused = false;
          _forwardAudio = true;
        }
        _state = restorePaused
            ? LiveSessionState.paused
            : LiveSessionState.listening;
        _retryKind = null;
        _restorePausedAfterReconnect = false;
        if (!restorePaused) {
          _startTimer();
        }
        _benchmark.reconnectReady();
        _notifyListeners();
        return;
      } catch (error) {
        if (operationGeneration != _operationGeneration ||
            _state != LiveSessionState.reconnecting) {
          return;
        }
        _benchmark.recordError();
        final terminalProtocolError =
            error is SttSessionException && !error.recoverable;
        if (terminalProtocolError || attempt == maxReconnectAttempts) {
          _benchmark.reconnectFailed();
          _errorMessage = terminalProtocolError
              ? error.message
              : 'Unable to reconnect to the STT session.';
          _canRetry = !terminalProtocolError;
          _retryKind = terminalProtocolError
              ? null
              : LiveSessionRetryKind.activeSessionReconnect;
          if (terminalProtocolError) {
            _restorePausedAfterReconnect = false;
          }
          _state = LiveSessionState.error;
          _notifyListeners();
          return;
        }
        await _retryDelay(reconnectDelay);
      }
    }
  }

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _forwardAudio = false;
    _operationGeneration++;
    _benchmark.stopped();
    _ticker.dispose();
    unawaited(_performDispose());
    super.dispose();
  }

  Future<void> _performDispose() async {
    try {
      await _eventSubscription.cancel();
    } catch (_) {
      // Continue disposal even if the event stream is already gone.
    }
    await _waitForMicrophoneFailureCleanup();
    await _cancelAudioSubscription();
    try {
      await _microphoneCapture.dispose();
    } catch (_) {
      // Transport cleanup must still run.
    }
    final systemAudioInput = _systemAudioInput;
    if (systemAudioInput != null &&
        !identical(systemAudioInput, _microphoneCapture)) {
      try {
        await systemAudioInput.dispose();
      } catch (_) {
        // Transport cleanup must still run.
      }
    }
    _activeAudioInput = null;
    await _waitForAudioSend();
    await _disconnectTransportSafely();
  }
}
