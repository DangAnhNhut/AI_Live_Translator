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
}
