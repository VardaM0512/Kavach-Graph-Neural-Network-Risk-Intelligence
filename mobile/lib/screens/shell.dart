import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/assistant.dart';
import '../widgets/brand.dart';
import '../widgets/kit.dart';
import 'analyze_screen.dart';
import 'contagion_screen.dart';
import 'overview_screen.dart';
import 'portfolio_screen.dart';
import 'screener_screen.dart';
import 'settings_screen.dart';
import 'watchlist_screen.dart';
import 'workspace_screen.dart';

class _Dest {
  final String key;
  final IconData icon;
  final Widget Function() page;
  const _Dest(this.key, this.icon, this.page);
}

final _dests = <_Dest>[
  _Dest('navCompanies', Icons.business_center_outlined, () => const WorkspaceScreen()),
  _Dest('navAnalyze', Icons.add_chart_outlined, () => const AnalyzeScreen()),
  _Dest('navOverview', Icons.space_dashboard_outlined, () => const OverviewScreen()),
  _Dest('navScreener', Icons.view_list_outlined, () => const ScreenerScreen()),
  _Dest('navContagion', Icons.bolt_outlined, () => const ContagionScreen()),
  _Dest('navPortfolio', Icons.donut_large_outlined, () => const PortfolioScreen()),
  _Dest('navWatchlist', Icons.visibility_outlined, () => const WatchlistScreen()),
  _Dest('navSettings', Icons.tune_outlined, () => const SettingsScreen()),
];

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _i = 0;
  final _pages = <int, Widget>{};

  Widget _page(int i) => _pages.putIfAbsent(i, () => _dests[i].page());

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final wide = MediaQuery.sizeOf(context).width >= 1100;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => showAskKavach(context),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () => showAskKavach(context),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Row(children: [
            if (wide) _Sidebar(index: _i, onSelect: (i) => setState(() => _i = i)),
            Expanded(child: Column(children: [
              _TopBar(wide: wide),
              Expanded(child: IndexedStack(index: _i, children: [
                for (var i = 0; i < _dests.length; i++) i == _i || _pages.containsKey(i) ? _page(i) : const SizedBox(),
              ])),
            ])),
          ]),
          bottomNavigationBar: wide ? null : NavigationBar(
            backgroundColor: k.surface,
            indicatorColor: k.accentSoft,
            height: 64,
            selectedIndex: _i < 3 ? _i : (_i == 5 ? 3 : 4),
            onDestinationSelected: (j) {
              if (j == 4) {
                _more(context);
              } else {
                setState(() => _i = [0, 1, 2, 5][j]);
              }
            },
            destinations: [
              for (final j in [0, 1, 2, 5])
                NavigationDestination(icon: Icon(_dests[j].icon), label: context.t(_dests[j].key)),
              NavigationDestination(icon: const Icon(Icons.more_horiz), label: context.t('navMore')),
            ],
          ),
          floatingActionButton: wide ? null : FloatingActionButton(
            backgroundColor: k.text, foregroundColor: k.bg,
            onPressed: () => showAskKavach(context),
            child: const Icon(Icons.auto_awesome_outlined),
          ),
        ),
      ),
    );
  }

  void _more(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.k.surface,
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final j in [3, 4, 6, 7])
          ListTile(
            leading: Icon(_dests[j].icon),
            title: Text(context.t(_dests[j].key)),
            onTap: () {
              Navigator.pop(context);
              setState(() => _i = j);
            },
          ),
      ])),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;
  const _Sidebar({required this.index, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final st = context.watch<AppState>();
    return Container(
      width: 236,
      decoration: BoxDecoration(color: k.surface, border: Border(right: BorderSide(color: k.line))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Padding(padding: EdgeInsets.fromLTRB(20, 22, 20, 26), child: Wordmark(size: 14)),
        for (var i = 0; i < _dests.length; i++) ...[
          if (i == 2) Padding(padding: const EdgeInsets.fromLTRB(22, 18, 20, 6), child: Eyebrow(context.t('simMarket'), color: k.faint)),
          if (i == 6) Padding(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10), child: Divider(color: k.line)),
          _NavItem(icon: _dests[i].icon, label: context.t(_dests[i].key), selected: index == i, onTap: () => onSelect(i)),
        ],
        const Spacer(),
        Container(
          margin: const EdgeInsets.all(14),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(border: Border.all(color: k.line), borderRadius: BorderRadius.circular(6)),
          child: Row(children: [
            CircleAvatar(radius: 15, backgroundColor: k.accentSoft,
                child: Text((st.user?.name ?? '?').characters.first.toUpperCase(), style: TextStyle(color: k.accent, fontSize: 13))),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(st.user?.name ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              Text(st.user?.email ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: k.muted)),
            ])),
          ]),
        ),
      ]),
    );
  }
}

class _NavItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _NavItem({required this.icon, required this.label, required this.selected, required this.onTap});
  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.selected ? k.raised : (_hover ? k.raised.withValues(alpha: 0.5) : Colors.transparent),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(children: [
            Container(width: 2, height: 16, color: widget.selected ? k.accent : Colors.transparent),
            const SizedBox(width: 10),
            Icon(widget.icon, size: 18, color: widget.selected ? k.text : k.muted),
            const SizedBox(width: 12),
            Expanded(child: Text(widget.label, style: TextStyle(fontSize: 13.5,
                color: widget.selected ? k.text : k.muted, fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500))),
          ]),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final bool wide;
  const _TopBar({required this.wide});
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(color: k.bg, border: Border(bottom: BorderSide(color: k.line))),
      child: Row(children: [
        if (!wide) ...[const Wordmark(size: 13), const SizedBox(width: 16)],
        if (MediaQuery.sizeOf(context).width < 520) const Spacer() else Expanded(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () => showAskKavach(context),
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(color: k.raised, border: Border.all(color: k.line), borderRadius: BorderRadius.circular(4)),
                  child: Row(children: [
                    Icon(Icons.auto_awesome_outlined, size: 16, color: k.accent),
                    const SizedBox(width: 10),
                    Expanded(child: Text(wide ? context.t('askHint') : context.t('askKavach'),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: k.faint, fontSize: 13.5))),
                    if (wide)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(border: Border.all(color: k.line), borderRadius: BorderRadius.circular(3)),
                        child: Text('Ctrl K', style: KType.mono(k.faint, 10.5)),
                      ),
                  ]),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: context.t('askKavach'),
          icon: Icon(Icons.mic_none_rounded, color: k.muted),
          onPressed: () => showAskKavach(context, voice: true),
        ),
        const SizedBox(width: 4),
        const LanguageMenu(),
      ]),
    );
  }
}
