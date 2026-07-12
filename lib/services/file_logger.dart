import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class FileLogger {
  static final FileLogger _instance = FileLogger._();
  factory FileLogger() => _instance;
  FileLogger._();

  static const _channel = MethodChannel('com.stivaros.app/logs');
  File? _file;
  String _buffer = '';
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/mtn.txt');
      if (await _file!.exists()) {
        await _file!.delete();
      }
      await _file!.create();
      _initialized = true;
      await copyToDownloads();
      i('FileLogger', 'Log file created at ${_file!.path}');
    } catch (e) {
      print('FileLogger init error: $e');
    }
  }

  Future<void> copyToDownloads() async {
    try {
      await _channel.invokeMethod('saveToDownloads', {'source': _file?.path ?? ''});
    } catch (_) {}
  }

  void i(String tag, String message) => _log('INFO', tag, message);
  void w(String tag, String message) => _log('WARN', tag, message);
  void e(String tag, String message) => _log('ERROR', tag, message);

  void _log(String level, String tag, String message) {
    final line = '[${DateTime.now().toIso8601String()}] [$level] [$tag] $message';
    _buffer += '$line\n';

    if (_initialized && _file != null) {
      try {
        _file!.writeAsStringSync(_buffer, mode: FileMode.append);
        _buffer = '';
      } catch (_) {
        _buffer += line;
      }
    }
  }

  Future<void> flush() async {
    if (_buffer.isNotEmpty && _file != null) {
      try {
        await _file!.writeAsString(_buffer, mode: FileMode.append);
        _buffer = '';
      } catch (_) {}
    }
  }
}
