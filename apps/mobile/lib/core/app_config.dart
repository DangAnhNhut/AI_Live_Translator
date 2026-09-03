import 'stt_session_id.dart';

class AppConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );
  static const String wsBaseUrl = String.fromEnvironment(
    'WS_BASE_URL',
    defaultValue: 'ws://127.0.0.1:8000',
  );
  static const bool liveSessionDebugTransport = bool.fromEnvironment(
    'LIVE_SESSION_DEBUG_TRANSPORT',
    defaultValue: false,
  );
  static const bool sttBenchmark = bool.fromEnvironment(
    'STT_BENCHMARK',
    defaultValue: false,
  );
  static const bool sttTranscriptTrace = bool.fromEnvironment(
    'STT_TRANSCRIPT_TRACE',
    defaultValue: false,
  );
  static const String _rawSttSessionId = String.fromEnvironment(
    'STT_SESSION_ID',
    defaultValue: '',
  );
  static final String? sttSessionId = normalizeSttSessionId(_rawSttSessionId);
}
