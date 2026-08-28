import 'package:ai_live_translator_mobile/core/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('apiBaseUrl has localhost fallback when dart-define is absent', () {
    expect(AppConfig.apiBaseUrl, 'http://127.0.0.1:8000');
  });
  test(
  'wsBaseUrl has localhost fallback when dart-define is absent',
  () {
    expect(
      AppConfig.wsBaseUrl,
      'ws://127.0.0.1:8000',
    );
  },
);

  test('STT benchmark instrumentation defaults to disabled', () {
    expect(AppConfig.sttBenchmark, isFalse);
  });
}
