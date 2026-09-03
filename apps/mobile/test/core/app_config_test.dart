import 'package:ai_live_translator_mobile/core/app_config.dart';
import 'package:ai_live_translator_mobile/core/stt_session_id.dart';
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

  test('STT transcript trace defaults to disabled', () {
    expect(AppConfig.sttTranscriptTrace, isFalse);
  });

  test('STT session ID defaults to absent', () {
    expect(AppConfig.sttSessionId, isNull);
  });

  test('blank STT session IDs are treated as absent', () {
    expect(normalizeSttSessionId('  '), isNull);
  });

  test('valid STT session IDs are trimmed and preserved', () {
    const validIds = ['demo-001', 'session_123', 'abc.def', 'A1'];

    for (final sessionId in validIds) {
      expect(normalizeSttSessionId(' $sessionId '), sessionId);
    }
  });

  test('invalid STT session IDs fail validation', () {
    final tooLong = 'a' * 65;

    expect(() => normalizeSttSessionId('bad session'), throwsFormatException);
    expect(() => normalizeSttSessionId('-invalid'), throwsFormatException);
    expect(() => normalizeSttSessionId(tooLong), throwsFormatException);
  });
}
