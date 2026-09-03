import 'dart:async';

import 'package:ai_live_translator_mobile/services/audio_input.dart';
import 'package:ai_live_translator_mobile/services/system_audio_input.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('support query delegates to the native bridge', () async {
    final platform = _FakeSystemAudioPlatformBridge()..supported = true;
    final input = SystemAudioInput(platform: platform);

    expect(await input.isSupported(), isTrue);
    expect(platform.supportCalls, 1);

    await input.dispose();
  });

  test(
    'start invokes native capture and forwards each PCM event once',
    () async {
      final platform = _FakeSystemAudioPlatformBridge();
      final input = SystemAudioInput(platform: platform);
      final stream = await input.start();
      final received = <Uint8List>[];
      final subscription = stream.listen(received.add);

      final pcm = Uint8List.fromList([0, 1, 2, 3]);
      platform.emit({'type': 'pcm', 'data': pcm});
      await Future<void>.delayed(Duration.zero);

      expect(platform.startCalls, 1);
      expect(received, [same(pcm)]);

      await subscription.cancel();
      await input.dispose();
    },
  );

  test(
    'pause drops PCM until resume without stopping native capture',
    () async {
      final platform = _FakeSystemAudioPlatformBridge();
      final input = SystemAudioInput(platform: platform);
      final stream = await input.start();
      final received = <Uint8List>[];
      final subscription = stream.listen(received.add);

      await input.pause();
      platform.emit({
        'type': 'pcm',
        'data': Uint8List.fromList([1, 0]),
      });
      await input.resume();
      final resumedPcm = Uint8List.fromList([2, 0]);
      platform.emit({'type': 'pcm', 'data': resumedPcm});
      await Future<void>.delayed(Duration.zero);

      expect(received, [same(resumedPcm)]);
      expect(platform.stopCalls, 0);

      await subscription.cancel();
      await input.dispose();
    },
  );

  test('capture-ended closes the active PCM stream', () async {
    final platform = _FakeSystemAudioPlatformBridge();
    final input = SystemAudioInput(platform: platform);
    final stream = await input.start();
    final done = Completer<void>();
    final subscription = stream.listen((_) {}, onDone: done.complete);

    platform.emit({'type': 'ended', 'reason': 'projection_stopped'});

    await done.future;
    await subscription.cancel();
    await input.dispose();
  });

  test(
    'capture ending during start fails before a stream is returned',
    () async {
      final platform = _FakeSystemAudioPlatformBridge();
      platform.onStart = () {
        platform.emit({'type': 'ended', 'reason': 'projection_stopped'});
      };
      final input = SystemAudioInput(platform: platform);

      await expectLater(
        input.start(),
        throwsA(
          isA<AudioInputException>()
              .having((value) => value.code, 'code', 'projection_stopped')
              .having(
                (value) => value.message,
                'message',
                'System Audio sharing stopped unexpectedly.',
              ),
        ),
      );

      await input.dispose();
    },
  );

  test('native controlled error is mapped to an audio input error', () async {
    final platform = _FakeSystemAudioPlatformBridge();
    final input = SystemAudioInput(platform: platform);
    final stream = await input.start();
    final error = Completer<Object>();
    final subscription = stream.listen((_) {}, onError: error.complete);

    platform.emit({'type': 'error', 'code': 'audio_record_failed'});

    await expectLater(
      error.future,
      completion(
        isA<AudioInputException>()
            .having((value) => value.code, 'code', 'audio_record_failed')
            .having(
              (value) => value.message,
              'message',
              'Unable to start System Audio capture.',
            ),
      ),
    );
    await subscription.cancel();
    await input.dispose();
  });

  test('permission cancellation from start is sanitized', () async {
    final platform = _FakeSystemAudioPlatformBridge()
      ..startError = PlatformException(code: 'projection_cancelled');
    final input = SystemAudioInput(platform: platform);

    await expectLater(
      input.start(),
      throwsA(
        isA<AudioInputException>()
            .having((value) => value.code, 'code', 'projection_cancelled')
            .having(
              (value) => value.message,
              'message',
              'System Audio permission was cancelled.',
            ),
      ),
    );

    await input.dispose();
  });

  test(
    'unsupported capture format from start is preserved as controlled error',
    () async {
      final platform = _FakeSystemAudioPlatformBridge()
        ..startError = PlatformException(code: 'unsupported_capture_format');
      final input = SystemAudioInput(platform: platform);

      await expectLater(
        input.start(),
        throwsA(
          isA<AudioInputException>()
              .having(
                (value) => value.code,
                'code',
                'unsupported_capture_format',
              )
              .having(
                (value) => value.message,
                'message',
                'This device cannot provide 16 kHz mono System Audio.',
              ),
        ),
      );

      await input.dispose();
    },
  );

  test('repeated stop is safe and invokes native cleanup once', () async {
    final platform = _FakeSystemAudioPlatformBridge();
    final input = SystemAudioInput(platform: platform);
    await input.start();

    await Future.wait([input.stop(), input.stop()]);
    await input.stop();

    expect(platform.stopCalls, 1);
    await input.dispose();
  });

  test(
    'SystemAudioInput implements the shared MobileAudioInput contract',
    () async {
      final input = SystemAudioInput(
        platform: _FakeSystemAudioPlatformBridge(),
      );

      expect(input, isA<MobileAudioInput>());

      await input.dispose();
    },
  );
}

class _FakeSystemAudioPlatformBridge implements SystemAudioPlatformBridge {
  final StreamController<Object?> _events = StreamController<Object?>.broadcast(
    sync: true,
  );
  bool supported = true;
  Object? startError;
  void Function()? onStart;
  int supportCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Stream<Object?> get events => _events.stream;

  void emit(Object? event) => _events.add(event);

  @override
  Future<bool> isSupported() async {
    supportCalls++;
    return supported;
  }

  @override
  Future<void> start() async {
    startCalls++;
    onStart?.call();
    final error = startError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}
