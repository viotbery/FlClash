import 'dart:async';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/proxies/download_test.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/test_app.dart';

class _Core extends Mock implements CoreHandlerInterface {}

void main() {
  late _Core core;
  late ProviderContainer container;

  Future<void> mount(
    WidgetTester tester, {
    bool connected = true,
    int count = 2,
  }) async {
    core = _Core();
    when(() => core.startDownloadTests()).thenAnswer((_) async => 'session');
    when(() => core.cancelDownloadTests(any())).thenAnswer((_) async {});
    container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        coreStatusProvider.overrideWithBuild(
          (_, _) => connected ? CoreStatus.connected : CoreStatus.disconnected,
        ),
        currentProfileProvider.overrideWithValue(null),
        routeTrackerProvider.overrideWithBuild((_, _) => const RouteState()),
        groupsProvider.overrideWithValue([
          Group(
            name: 'Group',
            type: GroupType.Selector,
            now: 'Node 0',
            all: [
              const Proxy(name: 'DIRECT', type: 'Direct'),
              const Proxy(name: 'Group', type: 'Selector'),
              const Proxy(name: 'DNS handler', type: 'Dns'),
              const Proxy(name: 'Pass handler', type: 'PassRule'),
              for (var i = 0; i < count; i++)
                Proxy(name: 'Node $i', type: 'Shadowsocks'),
              if (count > 0) const Proxy(name: 'Node 0', type: 'Shadowsocks'),
            ],
          ),
        ]),
      ],
    );
    addTearDown(container.dispose);
    globalState.container = container;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(locale: Locale('en'), child: DownloadTestView()),
      ),
    );
    await tester.pump();
  }

  testWidgets('selects nodes without routing changes and displays speeds', (
    tester,
  ) async {
    await mount(tester);
    final pending = Completer<DownloadResult>();
    when(
      () => core.testDownload('session', 'Node 0'),
    ).thenAnswer((_) => pending.future);
    when(() => core.testDownload('session', 'Node 1')).thenAnswer(
      (_) async => const DownloadResult(
        name: 'Node 1',
        bytes: 0,
        duration: 0,
        bytesPerSecond: 0,
        error: 'failed',
      ),
    );
    expect(find.byType(Checkbox), findsNWidgets(2));
    expect(find.text('DIRECT'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.tap(find.text('Select all'));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(find.text('Testing…'), findsOneWidget);
    expect(find.text('Queued'), findsOneWidget);
    pending.complete(
      const DownloadResult(
        name: 'Node 0',
        bytes: 1048576,
        duration: 1000,
        bytesPerSecond: 1048576,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('/s'), findsOneWidget);
    expect(find.text('Test failed'), findsOneWidget);
    expect(find.text('2/2 finished'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancels on stop and on closing the page', (tester) async {
    await mount(tester);
    final pending = Completer<DownloadResult>();
    when(
      () => core.testDownload(any(), any()),
    ).thenAnswer((_) => pending.future);
    await tester.tap(find.text('Node 0'));
    await tester.pump();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(find.text('Cancelled'), findsOneWidget);
    verify(() => core.cancelDownloadTests('session')).called(1);
    await tester.pumpWidget(const SizedBox());
    pending.complete(
      const DownloadResult(
        name: 'Node 0',
        bytes: 1,
        duration: 1,
        bytesPerSecond: 1000,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows disconnected and empty states', (tester) async {
    await mount(tester, connected: false, count: 0);
    expect(
      find.text('Groups show up here once the core starts'),
      findsOneWidget,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('closing an active page cancels its download', (tester) async {
    await mount(tester);
    final pending = Completer<DownloadResult>();
    when(
      () => core.testDownload(any(), any()),
    ).thenAnswer((_) => pending.future);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    verify(() => core.cancelDownloadTests('session')).called(1);
    pending.complete(
      const DownloadResult(
        name: 'Node 0',
        bytes: 0,
        duration: 0,
        bytesPerSecond: 0,
        error: 'cancelled',
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'configuration changes clear selection and ignore pending results',
    (tester) async {
      await mount(tester);
      final pending = Completer<DownloadResult>();
      when(
        () => core.testDownload(any(), any()),
      ).thenAnswer((_) => pending.future);
      await tester.tap(find.text('Select all'));
      await tester.pump();
      await tester.tap(find.text('Start'));
      await tester.pump();
      container.read(routeTrackerProvider.notifier).bumpHostEpoch();
      await tester.pump();
      expect(find.text('0 selected'), findsOneWidget);
      pending.complete(
        const DownloadResult(
          name: 'Node 0',
          bytes: 1024,
          duration: 1000,
          bytesPerSecond: 1024,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('/s'), findsNothing);
      verify(() => core.cancelDownloadTests('session')).called(1);
      verifyNever(() => core.testDownload('session', 'Node 1'));
    },
  );

  testWidgets('empty list fits a small window', (tester) async {
    tester.view.physicalSize = const Size(400, 280);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, count: 0);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pump();
    expect(find.text('Proxy group is empty'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolls a long node list and handles a session failure', (
    tester,
  ) async {
    await mount(tester, count: 80);
    when(() => core.startDownloadTests()).thenThrow(StateError('offline'));
    await tester.tap(find.text('Select all'));
    await tester.pump();
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(find.text('Test failed'), findsWidgets);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
    await tester.pump();
    expect(find.text('Node 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
