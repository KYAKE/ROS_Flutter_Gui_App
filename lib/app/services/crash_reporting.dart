import 'package:ros_flutter_gui_app/app/logging/app_logger.dart';

abstract class CrashReporter {
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    String reason = '',
    Map<String, Object?> context = const {},
  });
}

class NoopCrashReporter implements CrashReporter {
  @override
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    String reason = '',
    Map<String, Object?> context = const {},
  }) async {
    AppLogger.e(
      'Crash reporter captured error${reason.isEmpty ? '' : ' ($reason)'} '
      'context=$context',
      tag: 'CrashReporter',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

final CrashReporter crashReporter = NoopCrashReporter();
