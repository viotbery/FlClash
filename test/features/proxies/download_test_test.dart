import 'dart:async';

import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/features/proxies/download_test.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Core extends Mock implements CoreHandlerInterface {}

const _result = DownloadResult(
  name: 'a',
  bytes: 1024,
  duration: 1000,
  bytesPerSecond: 1024,
);

void main() {
  late _Core core;
  late DownloadTestController controller;
  setUp(() {
    core = _Core();
    when(() => core.startDownloadTests()).thenAnswer((_) async => 'session');
    when(() => core.cancelDownloadTests(any())).thenAnswer((_) async {});
    controller = DownloadTestController(core);
  });
  tearDown(() => controller.dispose());

  test(
    'deduplicates targets and tests sequentially, continuing after failure',
    () async {
      final first = Completer<DownloadResult>();
      when(
        () => core.testDownload('session', 'a'),
      ).thenAnswer((_) => first.future);
      when(
        () => core.testDownload('session', 'b'),
      ).thenThrow(StateError('failed'));
      when(
        () => core.testDownload('session', 'c'),
      ).thenAnswer((_) async => _result.copyWith(name: 'c'));
      final run = controller.start(['a', 'a', 'b', 'c']);
      await Future<void>.delayed(Duration.zero);
      expect(controller.entries['a']!.status, DownloadTestStatus.testing);
      expect(controller.entries['b']!.status, DownloadTestStatus.queued);
      verifyNever(() => core.testDownload('session', 'b'));
      first.complete(_result);
      await run;
      expect(controller.entries.keys, ['a', 'b', 'c']);
      expect(controller.entries['a']!.result, _result);
      expect(controller.entries['b']!.status, DownloadTestStatus.failed);
      expect(controller.entries['c']!.status, DownloadTestStatus.complete);
      expect(controller.running, isFalse);
      verify(() => core.cancelDownloadTests('session')).called(1);
    },
  );

  test(
    'cancel discards late completion, skips queued nodes, and permits rerun',
    () async {
      final first = Completer<DownloadResult>();
      when(
        () => core.testDownload('session', 'a'),
      ).thenAnswer((_) => first.future);
      final run = controller.start(['a', 'b']);
      await Future<void>.delayed(Duration.zero);
      controller.cancel();
      await controller.start(['b']);
      expect(controller.stopping, isTrue);
      first.complete(_result);
      await run;
      expect(
        controller.entries.values.every(
          (entry) => entry.status == DownloadTestStatus.cancelled,
        ),
        isTrue,
      );
      verifyNever(() => core.testDownload('session', 'b'));
      when(
        () => core.testDownload('session', 'b'),
      ).thenAnswer((_) async => _result.copyWith(name: 'b'));
      await controller.start(['b']);
      expect(controller.entries.keys, ['b']);
      expect(controller.entries['b']!.status, DownloadTestStatus.complete);
    },
  );

  test(
    'cancel before session acknowledgement closes the session without downloading',
    () async {
      final session = Completer<String>();
      when(() => core.startDownloadTests()).thenAnswer((_) => session.future);
      final run = controller.start(['a']);
      controller.cancel(clear: true);
      session.complete('late');
      await run;
      expect(controller.entries, isEmpty);
      verifyNever(() => core.testDownload(any(), any()));
      verify(() => core.cancelDownloadTests('late')).called(1);
    },
  );

  test('failed session creation and cleanup leave no running state', () async {
    when(() => core.startDownloadTests()).thenThrow(StateError('offline'));
    await controller.start(['a']);
    expect(controller.entries['a']!.status, DownloadTestStatus.failed);
    expect(controller.failure, isA<StateError>());
    expect(controller.running, isFalse);
    when(() => core.startDownloadTests()).thenAnswer((_) async => 'session');
    when(
      () => core.testDownload(any(), any()),
    ).thenAnswer((_) async => _result);
    when(
      () => core.cancelDownloadTests(any()),
    ).thenAnswer((_) async => throw StateError('offline'));
    await controller.start(['a']);
    expect(controller.running, isFalse);
    expect(controller.failure, isA<StateError>());
  });

  test('a superseded core session cancels the remaining queue', () async {
    when(
      () => core.testDownload('session', 'a'),
    ).thenAnswer((_) async => _result.copyWith(error: 'cancelled'));
    await controller.start(['a', 'b']);
    expect(controller.entries['b']!.status, DownloadTestStatus.cancelled);
    verifyNever(() => core.testDownload('session', 'b'));
  });
}
