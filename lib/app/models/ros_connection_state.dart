enum RosConnectionStatus {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed,
}

class RosConnectionState {
  const RosConnectionState({
    required this.status,
    this.url = '',
    this.errorMessage,
    this.retryAttempt = 0,
  });

  final RosConnectionStatus status;
  final String url;
  final String? errorMessage;
  final int retryAttempt;

  bool get isBusy =>
      status == RosConnectionStatus.connecting ||
      status == RosConnectionStatus.reconnecting;

  RosConnectionState copyWith({
    RosConnectionStatus? status,
    String? url,
    String? errorMessage,
    int? retryAttempt,
    bool clearError = false,
  }) {
    return RosConnectionState(
      status: status ?? this.status,
      url: url ?? this.url,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      retryAttempt: retryAttempt ?? this.retryAttempt,
    );
  }

  static const disconnected =
      RosConnectionState(status: RosConnectionStatus.disconnected);
}
