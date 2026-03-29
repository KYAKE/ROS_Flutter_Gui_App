import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:ros_flutter_gui_app/app/logging/app_logger.dart';

/// A [LogSink] that writes log entries to rotating files on disk.
///
/// - Creates daily log files named `app_YYYY-MM-DD.log`.
/// - Automatically deletes files older than [retentionDays].
/// - Batches writes using a periodic flush timer to reduce I/O.
class FileLogSink implements LogSink {
  final String logDirectory;
  final int retentionDays;
  final Duration flushInterval;

  IOSink? _currentSink;
  String? _currentFileName;
  Timer? _flushTimer;
  final List<String> _buffer = [];
  bool _disposed = false;

  FileLogSink({
    required this.logDirectory,
    this.retentionDays = 7,
    this.flushInterval = const Duration(seconds: 5),
  }) {
    _startFlushTimer();
    _cleanOldLogs();
  }

  @override
  void write(LogEntry entry) {
    if (_disposed) return;
    _buffer.add(entry.format());
    if (entry.stackTrace != null) {
      _buffer.add(entry.stackTrace.toString());
    }
  }

  @override
  Future<void> flush() async {
    if (_disposed || _buffer.isEmpty) return;

    try {
      final sink = _getSink();
      for (final line in _buffer) {
        sink.writeln(line);
      }
      _buffer.clear();
      await sink.flush();
    } catch (e) {
      debugPrint('FileLogSink flush error: $e');
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _flushTimer?.cancel();
    await flush();
    await _currentSink?.flush();
    await _currentSink?.close();
    _currentSink = null;
  }

  IOSink _getSink() {
    final today = _dateString(DateTime.now());
    if (_currentFileName != today) {
      _currentSink?.close();
      final dir = Directory(logDirectory);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final file = File('$logDirectory/app_$today.log');
      _currentSink = file.openWrite(mode: FileMode.append);
      _currentFileName = today;
    }
    return _currentSink!;
  }

  void _startFlushTimer() {
    _flushTimer = Timer.periodic(flushInterval, (_) => flush());
  }

  Future<void> _cleanOldLogs() async {
    try {
      final dir = Directory(logDirectory);
      if (!dir.existsSync()) return;

      final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.log')) {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            await entity.delete();
          }
        }
      }
    } catch (e) {
      debugPrint('FileLogSink cleanup error: $e');
    }
  }

  String _dateString(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  /// Read all log files and return content as a single string (for export).
  Future<String> exportLogs() async {
    await flush();
    final dir = Directory(logDirectory);
    if (!dir.existsSync()) return '';

    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.log')) {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));

    final buffer = StringBuffer();
    for (final file in files) {
      buffer.writeln('=== ${file.uri.pathSegments.last} ===');
      buffer.writeln(await file.readAsString());
    }
    return buffer.toString();
  }

  /// Get total size of all log files in bytes.
  Future<int> totalSize() async {
    final dir = Directory(logDirectory);
    if (!dir.existsSync()) return 0;
    int total = 0;
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.log')) {
        total += await entity.length();
      }
    }
    return total;
  }
}
