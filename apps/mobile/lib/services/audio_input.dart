import 'dart:typed_data';

enum MobileAudioSource { microphone, systemAudio }

abstract interface class MobileAudioInput {
  Future<Stream<Uint8List>> start();

  Future<void> pause();

  Future<void> resume();

  Future<void> stop();

  Future<void> dispose();
}

class AudioInputException implements Exception {
  const AudioInputException({
    required this.code,
    required this.message,
    this.recoverable = true,
  });

  final String code;
  final String message;
  final bool recoverable;

  @override
  String toString() => 'AudioInputException($code)';
}
