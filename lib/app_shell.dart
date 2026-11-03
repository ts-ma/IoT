import 'package:flutter/material.dart';

import 'chart_page.dart';
import 'history.dart';
import 'home.dart';
import 'performance.dart';
import 'services/perf_sampler.dart';
import 'services/prediction_history_writer.dart';
import 'services/sensor_controller.dart';
import 'services/social_sample_processor.dart';
import 'services/user_session.dart';
import 'tools_page.dart';

/// Tab order in the bottom bar: Tools · Performance · (Home) · History · Chart.
enum AppTab { tools, performance, home, history, chart }

/// The visible tab. Tabs stay alive in an IndexedStack (a running real-time
/// trial or the live graphs survive switching), so pages that show saved data
/// listen to this and reload when they come into view.
final ValueNotifier<AppTab> shellTab = ValueNotifier(AppTab.home);

/// The app's frame: the five tabs and the bottom bar, with Home as the big
/// round button in the middle. The user avatar and the Settings gear sit at
/// the top left of every tab (see TabLeading). Everything below is rebuilt
/// when another user logs in, so no screen shows the previous user's data.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.sensor,
    this.historyWriter,
    this.socialProcessor,
    this.sampler,
    this.session,
  });

  final SensorController sensor;
  final PerfSampler? sampler;
  final PredictionHistoryWriter? historyWriter;
  final SocialSampleProcessor? socialProcessor;
  final UserSession? session;

  @override
  State<AppShell> createState() => AppShellState();
}

class AppShellState extends State<AppShell> {
  UserSession get _session => widget.session ?? userSession;

  @override
  void initState() {
    super.initState();
    shellTab.value = AppTab.home;
  }

  void select(AppTab tab) => shellTab.value = tab;

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return ValueListenableBuilder<AppTab>(
      valueListenable: shellTab,
      builder: (context, tab, _) => Scaffold(
        body: ListenableBuilder(
          listenable: _session,
          builder: (context, _) => KeyedSubtree(
            key: ValueKey('user-${_session.username}'),
            child: IndexedStack(
              index: tab.index,
              children: [
                ToolsPage(sensor: widget.sensor, session: _session),
                PerformancePage(
                    historyWriter: widget.historyWriter,
                    sensor: widget.sensor,
                    sampler: widget.sampler,
                    session: _session),
                HomePage(
                  sensor: widget.sensor,
                  socialProcessor: widget.socialProcessor,
                  session: _session,
                  onOpenChart: () => select(AppTab.chart),
                ),
                HistoryPage(session: _session),
                ChartPage(session: _session),
              ],
            ),
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
        floatingActionButton: keyboardOpen ? null : _homeButton(context, tab),
        bottomNavigationBar: _bar(context, tab),
      ),
    );
  }

  Widget _homeButton(BuildContext context, AppTab tab) {
    final scheme = Theme.of(context).colorScheme;
    final selected = tab == AppTab.home;
    return SizedBox(
      width: 72,
      height: 72,
      child: FloatingActionButton(
        key: const ValueKey('tab-home'),
        heroTag: null,
        tooltip: 'Home',
        shape: const CircleBorder(),
        elevation: selected ? 4 : 2,
        backgroundColor: selected ? scheme.primary : scheme.primaryContainer,
        foregroundColor:
            selected ? scheme.onPrimary : scheme.onPrimaryContainer,
        onPressed: () => select(AppTab.home),
        child: const Icon(Icons.home_rounded, size: 36),
      ),
    );
  }

  Widget _bar(BuildContext context, AppTab tab) {
    Widget item(AppTab t, IconData icon, IconData selectedIcon, String label) =>
        Expanded(
          child: _BarItem(
            key: ValueKey('tab-${t.name}'),
            icon: tab == t ? selectedIcon : icon,
            label: label,
            selected: tab == t,
            onTap: () => select(t),
          ),
        );
    return BottomAppBar(
      shape: const CircularNotchedRectangle(),
      notchMargin: 6,
      height: 68,
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          item(AppTab.tools, Icons.handyman_outlined, Icons.handyman, 'Tools'),
          item(AppTab.performance, Icons.speed_outlined, Icons.speed,
              'Performance'),
          const SizedBox(width: 84),
          item(
              AppTab.history, Icons.history_outlined, Icons.history, 'History'),
          item(AppTab.chart, Icons.insights_outlined, Icons.insights, 'Chart'),
        ],
      ),
    );
  }
}

class _BarItem extends StatelessWidget {
  const _BarItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
              decoration: BoxDecoration(
                color:
                    selected ? scheme.secondaryContainer : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 3),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: selected ? FontWeight.bold : FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}
