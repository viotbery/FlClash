import 'dart:async';

import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';

enum DownloadTestStatus { queued, testing, complete, failed, cancelled }

typedef DownloadTestEntry = ({
  DownloadTestStatus status,
  DownloadResult? result,
});

class DownloadTestController extends ChangeNotifier {
  DownloadTestController(this._core);

  final CoreHandlerInterface _core;
  final Map<String, DownloadTestEntry> _entries = {};
  Map<String, DownloadTestEntry> get entries => Map.unmodifiable(_entries);
  bool get running => _running;
  bool get stopping => _stopping;
  Object? get failure => _failure;

  bool _running = false;
  bool _stopping = false;
  bool _disposed = false;
  int _generation = 0;
  String? _session;
  Future<void>? _cancelling;
  Object? _failure;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start(Iterable<String> names) async {
    final targets = names.toSet();
    if (_running || _disposed || targets.isEmpty) return;
    final generation = ++_generation;
    _running = true;
    _stopping = false;
    _failure = null;
    _entries
      ..clear()
      ..addEntries(
        targets.map(
          (name) =>
              MapEntry(name, (status: DownloadTestStatus.queued, result: null)),
        ),
      );
    _notify();
    try {
      _session = await _core.startDownloadTests();
      for (final name in targets) {
        if (generation != _generation) break;
        _entries[name] = (status: DownloadTestStatus.testing, result: null);
        _notify();
        try {
          final result = await _core.testDownload(_session!, name);
          if (generation != _generation) break;
          _entries[name] = (
            status: result.error.isEmpty
                ? DownloadTestStatus.complete
                : result.error == 'cancelled'
                ? DownloadTestStatus.cancelled
                : DownloadTestStatus.failed,
            result: result,
          );
          if (result.error == 'cancelled') {
            _finishPending(DownloadTestStatus.cancelled);
            break;
          }
        } catch (error) {
          if (generation != _generation) break;
          _entries[name] = (status: DownloadTestStatus.failed, result: null);
        }
        _notify();
      }
    } catch (error) {
      if (generation == _generation) {
        _failure = error;
        _finishPending(DownloadTestStatus.failed);
      }
    } finally {
      await _cancelSession();
      _session = null;
      _cancelling = null;
      _running = false;
      _stopping = false;
      _notify();
    }
  }

  void cancel({bool clear = false}) {
    ++_generation;
    _stopping = _running;
    _finishPending(DownloadTestStatus.cancelled);
    if (clear) {
      _entries.clear();
      _failure = null;
    }
    unawaited(_cancelSession());
    _notify();
  }

  void _finishPending(DownloadTestStatus status) {
    for (final name in _entries.keys.toList()) {
      if (_entries[name]!.status
          case DownloadTestStatus.queued || DownloadTestStatus.testing) {
        _entries[name] = (status: status, result: null);
      }
    }
  }

  Future<void> _cancelSession() async {
    final session = _session;
    if (session == null) return;
    await (_cancelling ??=
        Future<void>.sync(() => _core.cancelDownloadTests(session)).catchError((
          Object error,
        ) {
          if (!_disposed) _failure = error;
        }));
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}
