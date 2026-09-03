import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_live_translator_mobile/services/transcript_file_saver.dart';
import 'package:flutter_file_saver/flutter_file_saver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('system saver writes UTF-8 text with timestamped filename', () async {
    String? capturedFileName;
    Uint8List? capturedBytes;
    Future<String> captureWrite({
      required String fileName,
      required Uint8List bytes,
    }) async {
      capturedFileName = fileName;
      capturedBytes = bytes;
      return 'content://saved/transcript';
    }

    final saver = SystemTranscriptFileSaver(
      now: () => DateTime(2026, 8, 31, 11, 45, 20),
      writeFile: captureWrite,
    );

    final outcome = await saver.save('Xin chào hôm nay.\nCâu đã chốt.');

    expect(outcome, TranscriptSaveOutcome.success);
    expect(capturedFileName, 'transcript_2026-08-31_11-45-20.txt');
    expect(utf8.decode(capturedBytes!), 'Xin chào hôm nay.\nCâu đã chốt.');
  });

  test('system saver reports a cancelled system dialog', () async {
    final saver = SystemTranscriptFileSaver(
      writeFile: ({required fileName, required bytes}) async {
        throw FileSaverCancelledException();
      },
    );

    final outcome = await saver.save('Final transcript.');

    expect(outcome, TranscriptSaveOutcome.cancelled);
  });

  test('system saver reports a failed write', () async {
    final saver = SystemTranscriptFileSaver(
      writeFile: ({required fileName, required bytes}) async {
        throw StateError('disk unavailable');
      },
    );

    final outcome = await saver.save('Final transcript.');

    expect(outcome, TranscriptSaveOutcome.failed);
  });
}
