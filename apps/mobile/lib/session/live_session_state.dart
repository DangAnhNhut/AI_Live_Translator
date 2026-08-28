enum LiveSessionState {
  ready,
  permission,
  connecting,
  listening,
  paused,
  reconnecting,
  error,
}

enum LiveSessionRetryKind { freshStart, activeSessionReconnect }
