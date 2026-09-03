final RegExp _sttSessionIdPattern = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$',
);

String? normalizeSttSessionId(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  if (!_sttSessionIdPattern.hasMatch(normalized)) {
    throw FormatException(
      'STT_SESSION_ID must be 1-64 characters and contain only letters, '
      'numbers, dots, underscores, or hyphens; it must start with a letter '
      'or number.',
    );
  }
  return normalized;
}
