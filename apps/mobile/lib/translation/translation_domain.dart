enum TranslationTargetLanguage {
  english('en', 'English'),
  japanese('ja', 'Japanese'),
  korean('ko', 'Korean'),
  chineseSimplified('zh-CN', 'Chinese (Simplified)'),
  thai('th', 'Thai'),
  french('fr', 'French'),
  german('de', 'German'),
  spanish('es', 'Spanish');

  const TranslationTargetLanguage(this.code, this.label);

  final String code;
  final String label;

  static TranslationTargetLanguage? fromCode(String code) {
    for (final language in values) {
      if (language.code == code) {
        return language;
      }
    }
    return null;
  }
}

const defaultTranslationTarget = TranslationTargetLanguage.english;
const translationSourceLanguage = 'vi';
const translationSourceLanguageLabel = 'Vietnamese';

const _translationErrorCodes = {
  'provider_unavailable',
  'provider_error',
  'queue_overflow',
  'request_timeout',
  'internal_error',
};

sealed class TranslationEvent {
  const TranslationEvent();
}

class TranslationConfiguredEvent extends TranslationEvent {
  const TranslationConfiguredEvent({
    required this.streamId,
    required this.sourceLanguage,
    required this.targetLanguage,
  });

  final String streamId;
  final String sourceLanguage;
  final TranslationTargetLanguage targetLanguage;
}

sealed class TranslationUtteranceEvent extends TranslationEvent {
  const TranslationUtteranceEvent({
    required this.streamId,
    required this.utteranceId,
    required this.sourceSegmentIds,
    required this.sourceText,
    required this.sourceLanguage,
    required this.targetLanguage,
  });

  final String streamId;
  final String utteranceId;
  final List<String> sourceSegmentIds;
  final String sourceText;
  final String sourceLanguage;
  final TranslationTargetLanguage targetLanguage;
}

class TranslationPendingEvent extends TranslationUtteranceEvent {
  const TranslationPendingEvent({
    required super.streamId,
    required super.utteranceId,
    required super.sourceSegmentIds,
    required super.sourceText,
    required super.sourceLanguage,
    required super.targetLanguage,
  });
}

class TranslationFinalEvent extends TranslationUtteranceEvent {
  const TranslationFinalEvent({
    required super.streamId,
    required super.utteranceId,
    required super.sourceSegmentIds,
    required super.sourceText,
    required super.sourceLanguage,
    required super.targetLanguage,
    required this.translatedText,
  });

  final String translatedText;
}

class TranslationUtteranceErrorEvent extends TranslationUtteranceEvent {
  const TranslationUtteranceErrorEvent({
    required super.streamId,
    required super.utteranceId,
    required super.sourceSegmentIds,
    required super.sourceText,
    required super.sourceLanguage,
    required super.targetLanguage,
    required this.code,
    required this.message,
  });

  final String code;
  final String message;
}

class TranslationSessionErrorEvent extends TranslationEvent {
  const TranslationSessionErrorEvent({
    required this.streamId,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.code,
    required this.message,
  });

  final String streamId;
  final String sourceLanguage;
  final TranslationTargetLanguage targetLanguage;
  final String code;
  final String message;
}

TranslationEvent? parseTranslationEvent(Object? value) {
  if (value is! Map<String, dynamic>) {
    return null;
  }
  switch (value['type']) {
    case 'translation.configured':
      final fields = _parseConfiguration(value);
      return fields == null
          ? null
          : TranslationConfiguredEvent(
              streamId: fields.streamId,
              sourceLanguage: fields.sourceLanguage,
              targetLanguage: fields.targetLanguage,
            );
    case 'translation.pending':
      final fields = _parseUtterance(value);
      return fields == null
          ? null
          : TranslationPendingEvent(
              streamId: fields.streamId,
              utteranceId: fields.utteranceId,
              sourceSegmentIds: fields.sourceSegmentIds,
              sourceText: fields.sourceText,
              sourceLanguage: fields.sourceLanguage,
              targetLanguage: fields.targetLanguage,
            );
    case 'translation.final':
      final fields = _parseUtterance(value);
      final translatedText = _nonEmptyString(value['translated_text']);
      return fields == null || translatedText == null
          ? null
          : TranslationFinalEvent(
              streamId: fields.streamId,
              utteranceId: fields.utteranceId,
              sourceSegmentIds: fields.sourceSegmentIds,
              sourceText: fields.sourceText,
              sourceLanguage: fields.sourceLanguage,
              targetLanguage: fields.targetLanguage,
              translatedText: translatedText,
            );
    case 'translation.error':
      return _parseTranslationError(value);
    default:
      return null;
  }
}

TranslationEvent? _parseTranslationError(Map<String, dynamic> value) {
  final code = _nonEmptyString(value['code']);
  final message = _nonEmptyString(value['message']);
  if (code == null ||
      !_translationErrorCodes.contains(code) ||
      message == null) {
    return null;
  }
  if (value['scope'] == 'session') {
    final fields = _parseConfiguration(value);
    return fields == null
        ? null
        : TranslationSessionErrorEvent(
            streamId: fields.streamId,
            sourceLanguage: fields.sourceLanguage,
            targetLanguage: fields.targetLanguage,
            code: code,
            message: message,
          );
  }
  if (value['scope'] == 'utterance') {
    final fields = _parseUtterance(value);
    return fields == null
        ? null
        : TranslationUtteranceErrorEvent(
            streamId: fields.streamId,
            utteranceId: fields.utteranceId,
            sourceSegmentIds: fields.sourceSegmentIds,
            sourceText: fields.sourceText,
            sourceLanguage: fields.sourceLanguage,
            targetLanguage: fields.targetLanguage,
            code: code,
            message: message,
          );
  }
  return null;
}

_ConfigurationFields? _parseConfiguration(Map<String, dynamic> value) {
  final streamId = _nonEmptyString(value['stream_id']);
  final sourceLanguage = value['source_language'];
  final targetCode = value['target_language'];
  if (streamId == null ||
      sourceLanguage != translationSourceLanguage ||
      targetCode is! String) {
    return null;
  }
  final targetLanguage = TranslationTargetLanguage.fromCode(targetCode);
  return targetLanguage == null
      ? null
      : _ConfigurationFields(streamId, sourceLanguage, targetLanguage);
}

_UtteranceFields? _parseUtterance(Map<String, dynamic> value) {
  final configuration = _parseConfiguration(value);
  final utteranceId = _nonEmptyString(value['utterance_id']);
  final sourceText = _nonEmptyString(value['source_text']);
  final rawIds = value['source_segment_ids'];
  if (configuration == null ||
      utteranceId == null ||
      sourceText == null ||
      rawIds is! List ||
      rawIds.isEmpty) {
    return null;
  }
  final ids = <String>[];
  for (final value in rawIds) {
    final id = _nonEmptyString(value);
    if (id == null) {
      return null;
    }
    ids.add(id);
  }
  return _UtteranceFields(
    configuration.streamId,
    utteranceId,
    List.unmodifiable(ids),
    sourceText,
    configuration.sourceLanguage,
    configuration.targetLanguage,
  );
}

String? _nonEmptyString(Object? value) {
  return value is String && value.trim().isNotEmpty ? value : null;
}

class _ConfigurationFields {
  const _ConfigurationFields(
    this.streamId,
    this.sourceLanguage,
    this.targetLanguage,
  );

  final String streamId;
  final String sourceLanguage;
  final TranslationTargetLanguage targetLanguage;
}

class _UtteranceFields extends _ConfigurationFields {
  const _UtteranceFields(
    super.streamId,
    this.utteranceId,
    this.sourceSegmentIds,
    this.sourceText,
    super.sourceLanguage,
    super.targetLanguage,
  );

  final String utteranceId;
  final List<String> sourceSegmentIds;
  final String sourceText;
}

class TranslationUtteranceIdentity {
  const TranslationUtteranceIdentity(this.streamId, this.utteranceId);

  final String streamId;
  final String utteranceId;

  @override
  bool operator ==(Object other) =>
      other is TranslationUtteranceIdentity &&
      other.streamId == streamId &&
      other.utteranceId == utteranceId;

  @override
  int get hashCode => Object.hash(streamId, utteranceId);
}

enum TranslationStatus { pending, finalResult, failed }

class TranslationUtterance {
  const TranslationUtterance({
    required this.identity,
    required this.sourceSegmentIds,
    required this.sourceText,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.status,
    this.translatedText,
    this.errorCode,
    this.errorMessage,
  });

  final TranslationUtteranceIdentity identity;
  final List<String> sourceSegmentIds;
  final String sourceText;
  final String sourceLanguage;
  final TranslationTargetLanguage targetLanguage;
  final TranslationStatus status;
  final String? translatedText;
  final String? errorCode;
  final String? errorMessage;

  TranslationUtterance copyWith({
    TranslationStatus? status,
    String? translatedText,
    String? errorCode,
    String? errorMessage,
  }) {
    return TranslationUtterance(
      identity: identity,
      sourceSegmentIds: sourceSegmentIds,
      sourceText: sourceText,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
      status: status ?? this.status,
      translatedText: translatedText ?? this.translatedText,
      errorCode: errorCode ?? this.errorCode,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

class TranslationConfiguration {
  const TranslationConfiguration({
    required this.streamId,
    required this.sourceLanguage,
    required this.targetLanguage,
  });

  final String streamId;
  final String sourceLanguage;
  final TranslationTargetLanguage targetLanguage;
}

class TranslationSessionError {
  const TranslationSessionError({
    required this.streamId,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.code,
    required this.message,
  });

  final String streamId;
  final String sourceLanguage;
  final TranslationTargetLanguage targetLanguage;
  final String code;
  final String message;
}

class TranslationState {
  const TranslationState({
    this.configurations = const [],
    this.utterances = const [],
    this.sessionErrors = const [],
  });

  final List<TranslationConfiguration> configurations;
  final List<TranslationUtterance> utterances;
  final List<TranslationSessionError> sessionErrors;

  TranslationConfiguration? get activeConfiguration =>
      configurations.isEmpty ? null : configurations.last;

  TranslationState apply(TranslationEvent event) {
    if (event is TranslationConfiguredEvent) {
      return _applyConfiguration(event);
    }
    if (event is TranslationSessionErrorEvent) {
      return _applySessionError(event);
    }
    return _applyUtterance(event as TranslationUtteranceEvent);
  }

  TranslationState _applyConfiguration(TranslationConfiguredEvent event) {
    final index = configurations.indexWhere(
      (item) => item.streamId == event.streamId,
    );
    if (index >= 0) {
      final existing = configurations[index];
      if (existing.sourceLanguage == event.sourceLanguage &&
          existing.targetLanguage == event.targetLanguage) {
        return this;
      }
    }
    final value = TranslationConfiguration(
      streamId: event.streamId,
      sourceLanguage: event.sourceLanguage,
      targetLanguage: event.targetLanguage,
    );
    final next = [...configurations];
    index < 0 ? next.add(value) : next[index] = value;
    return TranslationState(
      configurations: List.unmodifiable(next),
      utterances: utterances,
      sessionErrors: sessionErrors,
    );
  }

  TranslationState _applySessionError(TranslationSessionErrorEvent event) {
    final index = sessionErrors.indexWhere(
      (item) => item.streamId == event.streamId && item.code == event.code,
    );
    if (index >= 0) {
      final existing = sessionErrors[index];
      if (existing.sourceLanguage == event.sourceLanguage &&
          existing.targetLanguage == event.targetLanguage &&
          existing.message == event.message) {
        return this;
      }
    }
    final value = TranslationSessionError(
      streamId: event.streamId,
      sourceLanguage: event.sourceLanguage,
      targetLanguage: event.targetLanguage,
      code: event.code,
      message: event.message,
    );
    final next = [...sessionErrors];
    index < 0 ? next.add(value) : next[index] = value;
    return TranslationState(
      configurations: configurations,
      utterances: utterances,
      sessionErrors: List.unmodifiable(next),
    );
  }

  TranslationState _applyUtterance(TranslationUtteranceEvent event) {
    final identity = TranslationUtteranceIdentity(
      event.streamId,
      event.utteranceId,
    );
    final index = utterances.indexWhere((item) => item.identity == identity);
    final existing = index < 0 ? null : utterances[index];
    if (existing?.status == TranslationStatus.finalResult) {
      return this;
    }
    if (event is TranslationPendingEvent && existing != null) {
      return this;
    }

    late final TranslationUtterance nextUtterance;
    if (event is TranslationFinalEvent) {
      nextUtterance = _utteranceFrom(
        event,
        status: TranslationStatus.finalResult,
        translatedText: event.translatedText,
      );
    } else if (event is TranslationUtteranceErrorEvent) {
      if (existing?.status == TranslationStatus.failed &&
          existing!.errorCode == event.code &&
          existing.errorMessage == event.message) {
        return this;
      }
      nextUtterance = _utteranceFrom(
        event,
        status: TranslationStatus.failed,
        errorCode: event.code,
        errorMessage: event.message,
      );
    } else {
      nextUtterance = _utteranceFrom(event, status: TranslationStatus.pending);
    }
    final next = [...utterances];
    index < 0 ? next.add(nextUtterance) : next[index] = nextUtterance;
    return TranslationState(
      configurations: configurations,
      utterances: List.unmodifiable(next),
      sessionErrors: sessionErrors,
    );
  }
}

TranslationUtterance _utteranceFrom(
  TranslationUtteranceEvent event, {
  required TranslationStatus status,
  String? translatedText,
  String? errorCode,
  String? errorMessage,
}) {
  return TranslationUtterance(
    identity: TranslationUtteranceIdentity(event.streamId, event.utteranceId),
    sourceSegmentIds: List.unmodifiable(event.sourceSegmentIds),
    sourceText: event.sourceText,
    sourceLanguage: event.sourceLanguage,
    targetLanguage: event.targetLanguage,
    status: status,
    translatedText: translatedText,
    errorCode: errorCode,
    errorMessage: errorMessage,
  );
}
