import 'package:flutter/material.dart';

enum AppMessageLevel {
  info,
  success,
  warning,
  error,
}

class AppFeedbackService {
  AppFeedbackService._();

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  static final Map<String, DateTime> _dedupeTracker = {};

  static void showMessage(
    String message, {
    String? title,
    AppMessageLevel level = AppMessageLevel.info,
    Duration duration = const Duration(seconds: 4),
    String? dedupeKey,
    Duration dedupeWindow = const Duration(seconds: 3),
  }) {
    if (message.trim().isEmpty) {
      return;
    }

    if (dedupeKey != null) {
      final now = DateTime.now();
      final lastShownAt = _dedupeTracker[dedupeKey];
      if (lastShownAt != null && now.difference(lastShownAt) < dedupeWindow) {
        return;
      }
      _dedupeTracker[dedupeKey] = now;
    }

    final messenger = scaffoldMessengerKey.currentState;
    if (messenger == null) {
      return;
    }

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: duration,
          behavior: SnackBarBehavior.floating,
          backgroundColor: _backgroundColor(level),
          content: Text(
            title == null ? message : '$title\n$message',
          ),
        ),
      );
  }

  static Color _backgroundColor(AppMessageLevel level) {
    switch (level) {
      case AppMessageLevel.info:
        return const Color(0xFF1E88E5);
      case AppMessageLevel.success:
        return const Color(0xFF2E7D32);
      case AppMessageLevel.warning:
        return const Color(0xFFF57C00);
      case AppMessageLevel.error:
        return const Color(0xFFC62828);
    }
  }
}
