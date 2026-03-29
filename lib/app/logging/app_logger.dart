import 'dart:collection';
import 'package:flutter/foundation.dart';

enum AppLogLevel {
  debug,
  info,
  warning,
  error,
}

/// A single structured log entry.
class LogEntry {
  final DateTime timestamp;
  final AppLogLevel level;
  final String tag;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
    this.error,
    this.stackTrace,
  });

  String format() {
    final ts = timestamp.toIso8601String();
    final buf = StringBuffer('$ts [${_levelLabel(level)}][$tag] $message');
    if (error != null) {
      buf.write(' | error=$error');
    }
    return buf.toString();
  }

  static String _levelLabel(AppLogLevel level) {
    switch (level) {
      case AppLogLevel.debug:
        return 'DEBUG';
      case AppLogLevel.info:
        return 'INFO';
      case AppLogLevel.warning:
        return 'WARN';
      case AppLogLevel.error:
        return 'ERROR';
    }
  }
}

/// Abstract interface for log output destinations.
abstract class LogSink {
  void write(LogEntry entry);
  Future<void> flush() async {}
  Future<void> dispose() async {}
}

/// Default console sink using debugPrint.
class ConsoleLogSink implements LogSink {
  @override
  void write(LogEntry entry) {
    debugPrint(entry.format());
    if (entry.stackTrace != null) {
      debugPrintStack(stackTrace: entry.stackTrace!);
    }
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> dispose() async {}
}

/// In-memory ring buffer sink for recent log access.
class MemoryLogSink implements LogSink {
  final int maxEntries;
  final Queue<LogEntry> _entries = Queue();

  MemoryLogSink({this.maxEntries = 500});

  @override
  void write(LogEntry entry) {
    _entries.addLast(entry);
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
  }

  List<LogEntry> get entries => _entries.toList();

  List<LogEntry> query({AppLogLevel? minLevel, String? tag, int? limit}) {
    Iterable<LogEntry> result = _entries;
    if (minLevel != null) {
      result = result.where((e) => e.level.index >= minLevel.index);
    }
    if (tag != null) {
      result = result.where((e) => e.tag == tag);
    }
    final list = result.toList();
    if (limit != null && list.length > limit) {
      return list.sublist(list.length - limit);
    }
    return list;
  }

  void clear() => _entries.clear();

  @override
  Future<void> flush() async {}

  @override
  Future<void> dispose() async {}
}

class AppLogger {
  AppLogger._();

  static AppLogLevel minimumLevel =
      kReleaseMode ? AppLogLevel.info : AppLogLevel.debug;

  static final List<LogSink> _sinks = [ConsoleLogSink()];
  static final MemoryLogSink _memorySink = MemoryLogSink();

  static bool _initialized = false;

  /// Initialize logger with optional additional sinks.
  static void init({List<LogSink>? additionalSinks}) {
    if (_initialized) return;
    _sinks.add(_memorySink);
    if (additionalSinks != null) {
      _sinks.addAll(additionalSinks);
    }
    _initialized = true;
  }

  /// Add a sink at runtime (e.g., after obtaining storage path).
  static void addSink(LogSink sink) {
    _sinks.add(sink);
  }

  /// Access the in-memory log buffer.
  static MemoryLogSink get memory => _memorySink;

  static void d(String message, {String tag = 'App'}) {
    _log(AppLogLevel.debug, message, tag: tag);
  }

  static void i(String message, {String tag = 'App'}) {
    _log(AppLogLevel.info, message, tag: tag);
  }

  static void w(
    String message, {
    String tag = 'App',
    Object? error,
    StackTrace? stackTrace,
  }) {
    _log(AppLogLevel.warning, message, tag: tag, error: error, stackTrace: stackTrace);
  }

  static void e(
    String message, {
    String tag = 'App',
    Object? error,
    StackTrace? stackTrace,
  }) {
    _log(AppLogLevel.error, message, tag: tag, error: error, stackTrace: stackTrace);
  }

  static void _log(
    AppLogLevel level,
    String message, {
    required String tag,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (level.index < minimumLevel.index) return;

    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
      error: error,
      stackTrace: stackTrace,
    );

    for (final sink in _sinks) {
      try {
        sink.write(entry);
      } catch (_) {
        // Prevent sink errors from crashing the app.
      }
    }
  }

  static Future<void> flush() async {
    for (final sink in _sinks) {
      await sink.flush();
    }
  }

  static Future<void> dispose() async {
    for (final sink in _sinks) {
      await sink.dispose();
    }
  }
}
