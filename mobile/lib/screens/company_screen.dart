import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/charts.dart';
import '../widgets/kit.dart';
import '../widgets/network_canvas.dart';
import '../widgets/report_sections.dart';
import 'contagion_screen.dart';

void openCompany(BuildContext context, String id, [String? name]) {
  Navigator.of(context).push(PageRouteBuilder(
    pageBuilder: (_, __, ___) => CompanyScreen(companyId: id, name: name),
    transitionsBuilder: (_, a, __, child) => FadeTransition(
      opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
      child: SlideTransition(position: Tween(begin: const Offset(0, 0.015), end: Offset.zero).animate(a), child: child),
    ),
    transitionDuration: const Duration(milliseconds: 260),
  ));
}

class CompanyScreen extends StatefulWidget {
  final String companyId;
  final String? name;
  const CompanyScreen({super.key, required this.companyId, this.name});
  @override
  State<CompanyScreen> createState() => _CompanyScreenState();
}

class _CompanyScreenState extends State<CompanyScreen> with SingleTickerProviderStateMixin {
  late Future<Json> _future;
  late final TabController _tabs = TabController(length: 4, vsync: this);

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => _future = context.read<AppState>().api.company(widget.companyId);

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: k.bg,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 0,
        title: Text(widget.name ?? widget.companyId, style: const TextStyle(fontSize: 15)),
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1), child: Divider(color: k.line)),
      ),
      body: Async<Json>(
        future: _future,
        onRetry: () => setState(_load),
        builder: (context, d) => _Body(d: d, tabs: _tabs),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final Json d;
  final TabController tabs;
  const _Body({required this.d, required this.tabs});

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final st = context.watch<AppState>();
    final r = Report(d);
    final id = d['company_id'] as String;
    final watched = st.isWatched(id);
    return NestedScrollView(
      headerSliverBuilder: (context, _) => [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
            child: Center(child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1280),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Eyebrow(d['industry'], color: k.accent),
                  Text('·', style: TextStyle(color: k.faint)),
                  Eyebrow(d['group'] == 'standalone' ? context.t('standaloneCo') : '${context.t('group')} ${d['group']}'),
                  Text('·', style: TextStyle(color: k.faint)),
                  Eyebrow('${d['hq']} · ${context.t('since')} ${d['incorporated']}'),
                ]),
                const SizedBox(height: 10),
                Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.end, runSpacing: 14, children: [
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(d['name'], style: context.tt.headlineLarge),
                    const SizedBox(height: 8),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(id, style: KType.mono(k.muted, 12)),
                      const SizedBox(width: 10),
                      Text('${context.t('revenue')} ${fmtCr(d['revenue'])}', style: KType.mono(k.muted, 12)),
                      const SizedBox(width: 10),
                      Tooltip(message: context.t('dataNote'), child: Text(context.t('fictional'), style: TextStyle(color: k.faint, fontSize: 12))),
                    ]),
                  ]),
                  Wrap(spacing: 10, runSpacing: 10, children: [
                    OutlinedButton.icon(
                      onPressed: () => st.toggleWatch(id, d['name'], r.pd),
                      icon: Icon(watched ? Icons.visibility : Icons.visibility_outlined, size: 18, color: watched ? k.accent : k.text),
                      label: Text(watched ? context.t('watching') : context.t('watch')),
                    ),
                    FilledButton.icon(
                      onPressed: () => Navigator.push(context, MaterialPageRoute(
                          builder: (_) => Scaffold(appBar: AppBar(backgroundColor: k.bg), body: ContagionScreen(initial: id, initialName: d['name'])))),
                      icon: const Icon(Icons.bolt_rounded, size: 18),
                      label: Text(context.t('simulateDefault')),
                    ),
                  ]),
                ]),
                const SizedBox(height: 22),
                Cols([RiskHeadline(r), Column(children: [TermPanel(r), const SizedBox(height: 16), _Timeline(d)]), HealthPanel(r)],
                    flex: const [4, 5, 4], breakpoint: 1000),
                const SizedBox(height: 18),
              ]),
            )),
          ),
        ),
        SliverPersistentHeader(pinned: true, delegate: _TabsHeader(tabs, k, [
          context.t('summary'), context.t('network'), context.t('stressTest'), context.t('financials'),
        ])),
      ],
      body: TabBarView(controller: tabs, children: [
        _Page(child: _SummaryTab(d: d, r: r)),
        _Page(child: _NetworkTab(id: id)),
        _Page(child: _StressTab(id: id, r: r)),
        _Page(child: _FinancialsTab(d: d)),
      ]),
    );
  }
}

class _Page extends StatelessWidget {
  final Widget child;
  const _Page({required this.child});
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 48),
        child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1280), child: child)),
      );
}

class _TabsHeader extends SliverPersistentHeaderDelegate {
  final TabController c;
  final KColors k;
  final List<String> labels;
  _TabsHeader(this.c, this.k, this.labels);
  @override
  double get minExtent => 48;
  @override
  double get maxExtent => 48;
  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => Container(
        color: k.bg,
        child: Column(children: [
          Expanded(child: Center(child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1280),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TabBar(
                controller: c, isScrollable: true, tabAlignment: TabAlignment.start,
                labelColor: k.text, unselectedLabelColor: k.muted, indicatorColor: k.accent,
                indicatorSize: TabBarIndicatorSize.label, dividerColor: Colors.transparent,
                labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                tabs: [for (final l in labels) Tab(text: l)],
              ),
            ),
          ))),
          Divider(color: k.line),
        ]),
      );
  @override
  bool shouldRebuild(covariant _TabsHeader old) => old.labels != labels;
}

class _Timeline extends StatelessWidget {
  final Json d;
  const _Timeline(this.d);
  @override
  Widget build(BuildContext context) {
    final tl = ((d['risk_timeline']?['timeline'] as List?) ?? []).map((e) => Json.from(e)).toList();
    if (tl.length < 2) return const SizedBox();
    return Panel(title: context.t('timeline'), child: RiskTimeline(points: tl, height: 130));
  }
}

// ------------------------------------------------------------ summary tab
class _SummaryTab extends StatelessWidget {
  final Json d;
  final Report r;
  const _SummaryTab({required this.d, required this.r});
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final flags = ((d['anomalies']?['anomalies'] as List?) ?? []).map((e) => Json.from(e)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Cols([
        DriversPanel(r, onOpen: (id, name) => openCompany(context, id, name)),
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Panel(
            title: context.t('redFlags'),
            child: flags.isEmpty
                ? Row(children: [Icon(Icons.check_circle_outline, color: k.low, size: 18), const SizedBox(width: 8),
                    Expanded(child: Text(context.t('noFlags'), style: context.tt.bodySmall))])
                : Column(children: [
                    for (final f in flags)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(children: [
                          Icon(Icons.flag_outlined, size: 16, color: k.high),
                          const SizedBox(width: 10),
                          Expanded(child: Text(context.t('flag_${f['type']}'))),
                          Text(f['type'] == 'earnings_quality'
                              ? '${(f['magnitude'] as num).toStringAsFixed(2)}×'
                              : '${((f['magnitude'] as num) * 100).toStringAsFixed(0)}%', style: KType.mono(k.muted, 12)),
                        ]),
                      ),
                  ]),
          ),
          const SizedBox(height: 16),
          PeersPanel(r),
        ]),
      ], flex: const [6, 5]),
    ]);
  }
}

// ------------------------------------------------------------ network tab
class _NetworkTab extends StatefulWidget {
  final String id;
  const _NetworkTab({required this.id});
  @override
  State<_NetworkTab> createState() => _NetworkTabState();
}

class _NetworkTabState extends State<_NetworkTab> {
  int _hops = 1;
  late Future<Json> _f = _load();
  Future<Json> _load() => context.read<AppState>().api.egoGraph(widget.id, hops: _hops);

  @override
  Widget build(BuildContext context) {
    return Async<Json>(
      future: _f,
      onRetry: () => setState(() => _f = _load()),
      builder: (context, g) {
        final nodes = (g['nodes'] as List).map((e) => Json.from(e)).toList();
        final edges = (g['edges'] as List).map((e) => Json.from(e)).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Eyebrow('${nodes.length - 1} ${context.t('counterparties').toLowerCase()}'),
            const Spacer(),
            SegmentedButton<int>(
              segments: const [ButtonSegment(value: 1, label: Text('1 hop')), ButtonSegment(value: 2, label: Text('2 hops'))],
              selected: {_hops},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() {
                _hops = s.first;
                _f = _load();
              }),
            ),
          ]),
          const SizedBox(height: 12),
          NetworkCanvas(nodes: nodes, edges: edges, center: widget.id, height: 560,
              onOpen: (id, name) => id == widget.id ? null : openCompany(context, id, name)),
        ]);
      },
    );
  }
}

// ------------------------------------------------------------- stress tab
class _StressTab extends StatefulWidget {
  final String id;
  final Report r;
  const _StressTab({required this.id, required this.r});
  @override
  State<_StressTab> createState() => _StressTabState();
}

class _StressTabState extends State<_StressTab> {
  double _rev = 0, _rate = 0, _margin = 0, _debt = 0;
  bool _sup = false, _cust = false;
  Json? _res;
  Timer? _debounce;
  late final Future<Json> _sweep = context.read<AppState>().api.sweep(widget.id);

  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () async {
      final r = await context.read<AppState>().api.scenario(widget.id, revenueChange: _rev, rateChange: _rate,
          marginChange: _margin, debtChange: _debt, supplierFailure: _sup, customerLoss: _cust);
      if (mounted) setState(() => _res = r);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Widget _slider(String label, double v, double min, double max, String Function(double) f, ValueChanged<double> on) {
    final k = context.k;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13.5))),
          Text(f(v), style: KType.mono(v == 0 ? k.muted : k.text, 13)),
        ]),
        Slider(value: v, min: min, max: max, onChanged: (x) {
          setState(() => on(x));
          _changed();
        }),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final base = widget.r.pd;
    final sp = (_res?['scenario_risk'] as num?)?.toDouble() ?? base;
    final changed = ((_res?['changed_ratios'] as List?) ?? []).map((e) => Json.from(e)).toList();
    final pctF = (double v) => '${v >= 0 ? '+' : ''}${(v * 100).round()}%';
    final bpsF = (double v) => '${v >= 0 ? '+' : ''}${(v * 10000).round()} bps';
    final ppF = (double v) => '${v >= 0 ? '+' : ''}${(v * 100).toStringAsFixed(1)} pp';
    return Cols([
      Panel(
        title: context.t('stressTest'),
        trailing: TextButton(onPressed: () {
          setState(() { _rev = 0; _rate = 0; _margin = 0; _debt = 0; _sup = false; _cust = false; _res = null; });
        }, child: Text(context.t('reset'))),
        child: Column(children: [
          _slider(context.t('revenueShock'), _rev, -0.5, 0.3, pctF, (x) => _rev = x),
          _slider(context.t('rateShock'), _rate, -0.02, 0.05, bpsF, (x) => _rate = x),
          _slider(context.t('marginShock'), _margin, -0.10, 0.05, ppF, (x) => _margin = x),
          _slider(context.t('debtShock'), _debt, 0, 1.0, pctF, (x) => _debt = x),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(context.t('supplierFails'), style: const TextStyle(fontSize: 13.5)),
              value: _sup, onChanged: (v) { setState(() => _sup = v); _changed(); }),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(context.t('customerLeaves'), style: const TextStyle(fontSize: 13.5)),
              value: _cust, onChanged: (v) { setState(() => _cust = v); _changed(); }),
        ]),
      ),
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Panel(
          child: Row(children: [
            Expanded(child: Kpi(label: context.t('currentPd'), value: fmtPd(base), valueColor: k.forPd(base),
                hint: widget.r.rating)),
            Icon(Icons.arrow_forward_rounded, color: k.faint),
            const SizedBox(width: 18),
            Expanded(child: Kpi(label: context.t('scenarioPd'), value: fmtPd(sp), valueColor: k.forPd(sp),
                hint: (_res?['scenario_rating'] as String?) ?? widget.r.rating)),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              DeltaText(sp - base, size: 16),
              const SizedBox(height: 8),
              BandChip((_res?['scenario_band'] as String?) ?? widget.r.band),
            ])),
          ]),
        ),
        const SizedBox(height: 16),
        if (changed.isNotEmpty) ...[
          Panel(
            title: context.t('ratiosMoved'),
            child: Column(children: [
              for (final c in changed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    Expanded(child: Text(context.t(c['feature']), style: const TextStyle(fontSize: 13))),
                    Text(fmtRatio(c['feature'], c['before']), style: KType.mono(k.muted, 12.5)),
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_right_alt, size: 16, color: k.faint)),
                    SizedBox(width: 80, child: Text(fmtRatio(c['feature'], c['after']), textAlign: TextAlign.end, style: KType.mono(k.text, 12.5))),
                  ]),
                ),
            ]),
          ),
          const SizedBox(height: 16),
        ],
        Async<Json>(
          future: _sweep,
          onRetry: () {},
          loadingHeight: 200,
          builder: (context, s) => Column(children: [
            Panel(title: context.t('sensRevenue'), child: SweepChart(
                points: (s['revenue'] as List).map((e) => Json.from(e)).toList(), marker: _rev, fmtX: pctF)),
            const SizedBox(height: 16),
            Panel(title: context.t('sensRate'), child: SweepChart(
                points: (s['rate'] as List).map((e) => Json.from(e)).toList(), marker: _rate, fmtX: bpsF)),
          ]),
        ),
      ]),
    ], flex: const [4, 6]);
  }
}

// --------------------------------------------------------- financials tab
class _FinancialsTab extends StatelessWidget {
  final Json d;
  const _FinancialsTab({required this.d});
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final years = ((d['statements']?['years'] as List?) ?? []).map((e) => Json.from(e)).toList();
    const rows = [('revenue', 'revenue'), ('ebitda', 'ebitda'), ('net_profit', 'netProfit'), ('interest_expense', 'fInterest'),
      ('ocf', 'ocf'), ('capex', 'fCapex'), ('debt', 'debt'), ('equity', 'fEquity'), ('cash', 'cash')];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        title: '${context.t('financials')} · ${context.t('inCrore')}',
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 36, dataRowMinHeight: 34, dataRowMaxHeight: 38, columnSpacing: 36,
            dividerThickness: 0.6,
            headingTextStyle: KType.label(k.muted),
            columns: [
              const DataColumn(label: Text('')),
              for (final y in years) DataColumn(numeric: true, label: Text('FY${(y['year'] as int) % 100}')),
            ],
            rows: [
              for (final (key, label) in rows)
                DataRow(cells: [
                  DataCell(Text(context.t(label), style: const TextStyle(fontSize: 13))),
                  for (final y in years)
                    DataCell(Text((y[key] as num).toStringAsFixed(0),
                        style: KType.mono((y[key] as num) < 0 ? k.critical : k.text, 12.5))),
                ]),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      RatioGrid(Json.from(d['ratios'] ?? {})),
    ]);
  }
}
