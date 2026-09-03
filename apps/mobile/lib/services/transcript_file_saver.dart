import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_file_saver/flutter_file_saver.dart';

enum TranscriptSaveOutcome { success, cancelled, failed }

abstract interface class TranscriptFileSaver {
  Future<TranscriptSaveOutcome> save(String transcript);
}

typedef TranscriptFileWriter =
    Future<String> Function({
      required String fileName,
      required Uint8List bytes,
    });

class SystemTranscriptFileSaver implements TranscriptFileSaver {
  SystemTranscriptFileSaver({
    DateTime Function()? now,
    TranscriptFileWriter? writeFile,
  }) : _now = now ?? DateTime.now,
       _writeFile = writeFile ?? _writeWithSystemDialog;

  final DateTime Function() _now;
  final TranscriptFileWriter _writeFile;

  @override
  Future<TranscriptSaveOutcome> save(String transcript) async {
    try {
      await _writeFile(
        fileName: _suggestedFileName(_now()),
        bytes: Uint8List.fromList(utf8.encode(transcript)),
      );
      return TranscriptSaveOutcome.success;
    } on FileSaverCancelledException {
      return TranscriptSaveOutcome.cancelled;
    } catch (_) {
      return TranscriptSaveOutcome.failed;
    }
  }

  static Future<String> _writeWithSystemDialog({
    required String fileName,
    required Uint8List bytes,
  }) {
    return FlutterFileSaver().writeFileAsBytes(
      fileName: fileName,
      bytes: bytes,
    );
  }

  static String _suggestedFileName(DateTime timestamp) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return 'transcript_${timestamp.year}-${twoDigits(timestamp.month)}-'
        '${twoDigits(timestamp.day)}_${twoDigits(timestamp.hour)}-'
        '${twoDigits(timestamp.minute)}-${twoDigits(timestamp.second)}.txt';
  }
}
