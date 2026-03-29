import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ros_flutter_gui_app/app/logging/app_logger.dart';
import 'package:ros_flutter_gui_app/app/services/performance_monitor.dart';
import 'package:ros_flutter_gui_app/provider/ros_bridge_player.dart';
import 'package:roslibdart/roslibdart.dart';

/// Manages the ROS bridge connection lifecycle with exponential backoff
/// for automatic reconnection.
class ConnectionService {
  static const String _tag = 'Connection';

  late RosBridgePlayer rosBridgePlayer;

  String _rosUrl = '';
  bool _shouldReconnect = false;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _isConnected = false;

  // Exponential backoff configuration
  static const int _baseDelayMs = 1000;
  static const int _maxDelayMs = 60000;
  static const double _backoffMultiplier = 1.5;

  /// Current connection status exposed as a ValueNotifier for UI binding.
  final ValueNotifier<Status> connectionState = ValueNotifier(Status.none);

  /// Callback invoked when connection is established (to trigger initChannel).
  VoidCallback? onConnected;

  /// Callback invoked when connection is lost.
  VoidCallback? onDisconnected;

  Status get status => connectionState.value;
  bool get isConnected => _isConnected;
  String get currentUrl => _rosUrl;

  // Delegate accessors to rosBridgePlayer
  List<TopicWithSchemaName> get topics => rosBridgePlayer.topics;
  Map<String, dynamic> get datatypes => rosBridgePlayer.datatypes;
  int get currentRosVersion => rosBridgePlayer.currentRosVersion;

  void refreshTopics() => rosBridgePlayer.refreshTopics();

  /// Connect to a ROS bridge at the given WebSocket URL.
  Future<String> connect(String url) async {
    _rosUrl = url;
    connectionState.value = Status.none;
    _reconnectAttempt = 0;

    final perfMon = PerformanceMonitor();
    perfMon.startLatencyMeasure();

    rosBridgePlayer = RosBridgePlayer(
      url: url,
      id: DateTime.now().millisecondsSinceEpoch.toString(),
    );

    rosBridgePlayer.setListener((presence, topics, datatypes) {
      switch (presence) {
        case PlayerPresence.notPresent:
          _updateState(Status.none);
          break;
        case PlayerPresence.initializing:
          _updateState(Status.connecting);
          break;
        case PlayerPresence.present:
          perfMon.endLatencyMeasure();
          _updateState(Status.connected);
          _reconnectAttempt = 0;
          _isConnected = true;
          AppLogger.i('Connected to $url', tag: _tag);
          onConnected?.call();
          break;
        case PlayerPresence.reconnecting:
          _updateState(Status.errored);
          _isConnected = false;
          AppLogger.w('Connection lost to $url', tag: _tag);
          onDisconnected?.call();
          break;
      }
    });

    if (!_shouldReconnect) {
      _shouldReconnect = true;
      _startReconnectWatcher();
    }

    return '';
  }

  /// Close the current connection and stop reconnection.
  void close() {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _isConnected = false;
    rosBridgePlayer.close();
    _updateState(Status.none);
    AppLogger.i('Connection closed', tag: _tag);
  }

  /// Destroy the connection (alias for close).
  void destroy() => close();

  /// Subscribe to a ROS topic.
  void subscribe(String topic, String type,
      Function(Map<String, dynamic>)? callback) {
    rosBridgePlayer.subscribe(topic, type, callback);
  }

  /// Advertise a ROS topic for publishing.
  void advertise(String topic, String type) {
    rosBridgePlayer.advertise(topic, type);
  }

  /// Publish a message to a ROS topic.
  void publish(String topic, Map<String, dynamic> message) {
    rosBridgePlayer.publish(topic, message);
  }

  /// Call a ROS service.
  Future<dynamic> callService(
      String service, Map<String, dynamic> request) async {
    return rosBridgePlayer.callService(service, request);
  }

  void _updateState(Status newState) {
    connectionState.value = newState;
  }

  void _startReconnectWatcher() {
    _reconnectTimer?.cancel();
    _reconnectTimer =
        Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!_shouldReconnect) {
        timer.cancel();
        return;
      }
      if (connectionState.value == Status.connected) return;
      if (connectionState.value == Status.connecting) return;

      _reconnectAttempt++;
      final delay = _calculateBackoffDelay();

      AppLogger.w(
        'Reconnecting to $_rosUrl (attempt $_reconnectAttempt, '
        'next retry in ${delay.inSeconds}s)',
        tag: _tag,
      );

      await _attemptReconnect();

      // Wait for the backoff delay before next attempt
      timer.cancel();
      _reconnectTimer = Timer(delay, () {
        if (_shouldReconnect &&
            connectionState.value != Status.connected) {
          _startReconnectWatcher();
        }
      });
    });
  }

  Duration _calculateBackoffDelay() {
    final delayMs = (_baseDelayMs *
            _pow(_backoffMultiplier, (_reconnectAttempt - 1).clamp(0, 20)))
        .round()
        .clamp(0, _maxDelayMs);
    return Duration(milliseconds: delayMs);
  }

  static double _pow(double base, int exponent) {
    double result = 1;
    for (int i = 0; i < exponent; i++) {
      result *= base;
    }
    return result;
  }

  Future<void> _attemptReconnect() async {
    try {
      final perfMon = PerformanceMonitor();
      perfMon.startLatencyMeasure();

      rosBridgePlayer = RosBridgePlayer(
        url: _rosUrl,
        id: DateTime.now().millisecondsSinceEpoch.toString(),
      );

      rosBridgePlayer.setListener((presence, topics, datatypes) {
        switch (presence) {
          case PlayerPresence.notPresent:
            _updateState(Status.none);
            break;
          case PlayerPresence.initializing:
            _updateState(Status.connecting);
            break;
          case PlayerPresence.present:
            perfMon.endLatencyMeasure();
            _updateState(Status.connected);
            _reconnectAttempt = 0;
            _isConnected = true;
            AppLogger.i('Reconnected to $_rosUrl', tag: _tag);
            onConnected?.call();
            break;
          case PlayerPresence.reconnecting:
            _updateState(Status.errored);
            _isConnected = false;
            break;
        }
      });
    } catch (e) {
      AppLogger.e('Reconnect attempt failed', tag: _tag, error: e);
    }
  }
}
