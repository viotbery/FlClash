import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/proxies/download_test.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DownloadTestView extends ConsumerStatefulWidget {
  const DownloadTestView({super.key});

  @override
  ConsumerState<DownloadTestView> createState() => _DownloadTestViewState();
}

class _DownloadTestViewState extends ConsumerState<DownloadTestView> {
  late final DownloadTestController _controller;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _controller = DownloadTestController(ref.read(coreHandlerProvider));
    ref.listenManual(coreStatusProvider, (_, status) {
      if (status != CoreStatus.connected) _controller.cancel(clear: true);
    });
    ref.listenManual(
      currentProfileProvider.select(
        (profile) => (profile?.id, profile?.lastUpdateDate),
      ),
      (_, _) => _reset(),
    );
    ref.listenManual(
      routeTrackerProvider.select(
        (state) => (state.coreEpoch, state.hostEpoch),
      ),
      (_, _) => _reset(),
    );
  }

  void _reset() {
    _selected.clear();
    _controller.cancel(clear: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = ref.watch(coreStatusProvider) == CoreStatus.connected;
    final groups = ref.watch(groupsProvider);
    final nodes = <String, Proxy>{
      for (final group in groups)
        for (final proxy in group.all)
          if (!reservedCustomProxyNames.contains(proxy.name) &&
              GroupTypeExtension.getGroupType(proxy.type) == null &&
              !const {
                'Direct',
                'Reject',
                'RejectDrop',
                'Pass',
                'PassRule',
                'Rematch',
                'Compatible',
                'Dns',
              }.contains(proxy.type))
            proxy.name: proxy,
    }.values.toList();
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final l10n = context.appLocalizations;
        final entries = _controller.entries;
        final selected = nodes
            .where((node) => _selected.contains(node.name))
            .toList();
        final allSelected = nodes.isNotEmpty && selected.length == nodes.length;
        final completed = entries.values
            .where(
              (entry) =>
                  entry.status != DownloadTestStatus.queued &&
                  entry.status != DownloadTestStatus.testing,
            )
            .length;
        return Scaffold(
          title: l10n.downloadSpeedTest,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(
                              16,
                            ).copyWith(top: context.contentTopPadding + 16),
                            child: Text(l10n.downloadSpeedTestDescription),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Wrap(
                              spacing: 12,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                TextButton(
                                  onPressed:
                                      _controller.running || nodes.isEmpty
                                      ? null
                                      : () {
                                          setState(() {
                                            _selected.clear();
                                            if (!allSelected) {
                                              _selected.addAll(
                                                nodes.map((node) => node.name),
                                              );
                                            }
                                          });
                                        },
                                  child: Text(
                                    allSelected
                                        ? l10n.cancelSelectAll
                                        : l10n.selectAll,
                                  ),
                                ),
                                Text(
                                  l10n.downloadTestSelected(selected.length),
                                ),
                                if (entries.isNotEmpty)
                                  Text(
                                    l10n.downloadTestProgress(
                                      completed,
                                      entries.length,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (_controller.failure != null)
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(l10n.downloadTestFailed),
                            ),
                        ],
                      ),
                    ),
                    if (!connected || nodes.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: Text(
                            !connected
                                ? l10n.proxyGroupsAfterStart
                                : l10n.proxyGroupEmpty,
                          ),
                        ),
                      )
                    else
                      SliverPrismList(
                        itemCount: nodes.length,
                        itemBuilder: (context, index) {
                          final node = nodes[index];
                          final entry = entries[node.name];
                          final checked = _selected.contains(node.name);
                          void toggle() => setState(() {
                            if (!_selected.remove(node.name)) {
                              _selected.add(node.name);
                            }
                          });
                          final status = switch (entry?.status) {
                            null => node.type,
                            DownloadTestStatus.queued =>
                              l10n.downloadTestQueued,
                            DownloadTestStatus.testing =>
                              l10n.downloadTestRunning,
                            DownloadTestStatus.complete =>
                              '${entry!.result!.bytesPerSecond.round().traffic.show}/s',
                            DownloadTestStatus.failed =>
                              l10n.downloadTestFailed,
                            DownloadTestStatus.cancelled =>
                              l10n.downloadTestCancelled,
                          };
                          return DecorationListItem(
                            key: ValueKey(node.name),
                            isSelected: checked,
                            onPressed: _controller.running ? null : toggle,
                            title: Text(
                              node.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(status),
                            trailing: Checkbox(
                              value: checked,
                              isCircle: true,
                              onChanged: _controller.running
                                  ? null
                                  : (_) => toggle(),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton(
                    key: ValueKey((_controller.running, _controller.stopping)),
                    onPressed: _controller.stopping
                        ? null
                        : _controller.running
                        ? () => _controller.cancel()
                        : !connected || selected.isEmpty
                        ? null
                        : () => _controller.start(
                            selected.map((node) => node.name),
                          ),
                    child: Text(
                      _controller.stopping
                          ? l10n.downloadTestStopping
                          : _controller.running
                          ? l10n.stop
                          : l10n.start,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
