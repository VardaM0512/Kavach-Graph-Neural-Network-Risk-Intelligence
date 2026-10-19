import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/strings.dart';
import '../services/account.dart';
import '../services/api_client.dart';
import '../services/report_pdf.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/charts.dart';
import '../widgets/kit.dart';
import '../widgets/network_canvas.dart';
import '../widgets/report_sections.dart';
import 'screener_screen.dart' show sectorNames;

const _fields = ['revenue', 'ebitda', 'net_profit', 'interest_expense', 'assets', 'debt', 'equity', 'cash',
  'current_assets', 'current_liabilities', 'inventory', 'ocf', 'capex'];
const _fieldKeys = {'revenue': 'revenue', 'ebitda': 'ebitda', 'net_profit': 'netProfit', 'interest_expense': 'fInterest',
  'assets': 'fAssets', 'debt': 'debt', 'equity': 'fEquity', 'cash': 'cash', 'current_assets': 'fCurAssets',
  'current_liabilities': 'fCurLiab', 'inventory': 'fInventory', 'ocf': 'ocf', 'capex': 'fCapex'};

/// "My companies": the user's real companies, scored together as one network.
class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key});
  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  Json? _res;
  bool _busy = false;
  Object? _err;
  int _sig = 0;
  final _compare = <String>{};
  Json? _retrain;

  Future<void> _score() async {
    final st = context.read<AppState>();
    if (st.workspace.isEmpty) {
      setState(() => _res = null);
      return;
    }
    setState(() { _busy = true; _err = null; });
    try {
      final r = await st.api.scoreWorkspace(st.workspacePayload);
      if (mounted) setState(() => _res = r);
    } catch (e) {
      if (mounted) setState(() => _err = e);
    }
    if (mounted) setState(() => _busy = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  // --------------------------------------------------------------- imports
  Future<void> _uploadSheet() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['csv', 'xlsx', 'xls']);
    if (picked.isEmpty || !mounted) return;
    final f = picked.first;
    final st = context.read<AppState>();
    try {
      final r = await st.api.parseTable(await f.readAsBytes(), f.name);
      if (!mounted) return;
      final comps = (r['companies'] as List).map((e) => Json.from(e)).toList();
      final rels = (r['relationships'] as List).map((e) => Json.from(e)).toList();
      final ok = await showDialog<bool>(context: context, builder: (_) => _PreviewDialog(
        title: context.t('reviewImport'),
        lines: [for (final c in comps) '${c['name']} · ${c['sector'] ?? '—'} · ${(c['years'] as List).length} ${context.t('fiscalYears').toLowerCase()}'],
        footer: '${rels.length} ${context.t('relationships').toLowerCase()}',
        warnings: (r['warnings'] as List).cast<String>(),
      ));
      if (ok != true) return;
      await st.addCompanies([
        for (final c in comps)
          WsCompany(c['name'], c['sector'], (c['years'] as List).map((e) => Json.from(e)).toList(),
              promoterPledge: ((c['promoter_pledge'] as num?) ?? 0).toDouble(), defaulted: (c['defaulted'] as num?)?.toInt(),
              source: 'upload'),
      ], [for (final l in rels) WsLink(l['company'], l['counterparty'], l['relation'], (l['share'] as num).toDouble(), health: l['health'] ?? 'stable')]);
      _score();
    } catch (e) {
      _toast('${context.tr('error')} $e');
    }
  }

  Future<void> _addTicker() async {
    final res = await showDialog<WsCompany>(context: context, builder: (_) => const _TickerDialog());
    if (res == null || !mounted) return;
    await context.read<AppState>().addCompanies([res]);
    _score();
  }

  Future<void> _fromPdf() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (picked.isEmpty || !mounted) return;
    final f = picked.first;
    final st = context.read<AppState>();
    try {
      final r = await st.api.extractPdf(await f.readAsBytes(), f.name);
      if (!mounted) return;
      final c = await showDialog<WsCompany>(context: context, builder: (_) => _StatementsDialog(
          initial: Json.from(r['current']), evidence: Json.from(r['evidence'] ?? {}), source: 'pdf',
          suggestedName: f.name.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '')));
      if (c == null) return;
      await st.addCompanies([c]);
      _score();
    } catch (e) {
      if (mounted) _toast('${context.tr('error')} $e');
    }
  }

  Future<void> _manual() async {
    final c = await showDialog<WsCompany>(context: context, builder: (_) => const _StatementsDialog(initial: {}, source: 'manual'));
    if (c == null || !mounted) return;
    await context.read<AppState>().addCompanies([c]);
    _score();
  }

  Future<void> _sample() async {
    await context.read<AppState>().addCompanies(_sampleCompanies, _sampleLinks);
    _score();
  }

  Future<void> _addLink() async {
    final l = await showDialog<WsLink>(context: context, builder: (_) => const _LinkDialog());
    if (l == null || !mounted) return;
    await context.read<AppState>().addCompanies(const [], [l]);
    _score();
  }

  Future<void> _runRetrain() async {
    final st = context.read<AppState>();
    try {
      final r = await st.api.retrain(st.workspacePayload);
      if (mounted) setState(() => _retrain = r);
    } catch (e) {
      if (mounted) _toast('${context.tr('error')} $e');
    }
  }

  // ------------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final st = context.watch<AppState>();
    final sig = jsonEncode(st.workspacePayload).hashCode;
    if (sig != _sig) {
      _sig = sig;
      WidgetsBinding.instance.addPostFrameCallback((_) => _score());
    }
    final actions = [
      FilledButton.icon(onPressed: _uploadSheet, icon: const Icon(Icons.upload_file, size: 18), label: Text(context.t('uploadSheet'))),
      OutlinedButton.icon(onPressed: _addTicker, icon: const Icon(Icons.travel_explore, size: 18), label: Text(context.t('addTicker'))),
      OutlinedButton.icon(onPressed: _fromPdf, icon: const Icon(Icons.picture_as_pdf_outlined, size: 18), label: Text(context.t('fromPdf'))),
      OutlinedButton.icon(onPressed: _manual, icon: const Icon(Icons.edit_note, size: 18), label: Text(context.t('addManual'))),
      TextButton.icon(onPressed: () => launchUrl(Uri.parse(st.api.templateUrl)), icon: const Icon(Icons.download, size: 16),
          label: Text(context.t('downloadTemplate'))),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 48),
      child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PageHeader(eyebrow: context.t('navCompanies'), title: context.t('companiesTitle'), body: context.t('companiesBody')),
          Wrap(spacing: 10, runSpacing: 10, children: actions),
          const SizedBox(height: 20),
          if (st.workspace.isEmpty)
            Panel(child: Column(children: [
              Icon(Icons.business_center_outlined, size: 32, color: k.muted),
              const SizedBox(height: 10),
              Text(context.t('emptyCompanies'), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _sample, child: Text(context.t('sampleData'))),
            ]))
          else if (_err != null && _res == null)
            ErrorBlock(_err!, _score)
          else if (_res == null)
            const LoadingBlock(height: 360)
          else
            _content(context, st, k),
        ]),
      )),
    );
  }

  Widget _content(BuildContext context, AppState st, KColors k) {
    final res = _res!;
    final reports = (res['companies'] as List).map((e) => Json.from(e)).toList();
    final sum = Json.from(res['summary']);
    final systemic = ((res['systemic'] as List?) ?? []).map((e) => Json.from(e)).toList();
    final net = Json.from(res['network']);
    final labelled = st.workspace.where((c) => c.defaulted != null).toList();
    final canRetrain = labelled.any((c) => c.defaulted == 1) && labelled.any((c) => c.defaulted == 0);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_busy) const LinearProgressIndicator(minHeight: 1),
      KpiStrip([
        Kpi(label: context.t('companies'), value: '${sum['count']}'),
        Kpi(label: context.t('meanPd'), value: fmtPd(sum['mean_pd']), valueColor: k.forPd((sum['mean_pd'] as num).toDouble())),
        Kpi(label: context.t('expectedDefaults'), value: (sum['expected_defaults'] as num).toStringAsFixed(2)),
        Kpi(label: context.t('internalLinks'), value: '${sum['internal_links']}'),
      ]),
      const SizedBox(height: 16),
      Panel(
        title: context.t('companies'),
        trailing: Text(_compare.length >= 2 ? '${context.t('compare')} · ${_compare.length}' : context.t('compareHint'),
            style: context.tt.bodySmall),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
        child: Column(children: [
          for (final r in reports) _row(context, st, k, r),
        ]),
      ),
      if (_compare.length >= 2) ...[
        const SizedBox(height: 16),
        _ComparePanel(reports: reports.where((r) => _compare.contains(r['name'])).toList()),
      ],
      const SizedBox(height: 16),
      Cols([
        Panel(
          title: context.t('relationships'),
          trailing: TextButton.icon(onPressed: _addLink, icon: const Icon(Icons.add, size: 16), label: Text(context.t('addLink'))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if ((net['nodes'] as List).length > 1)
              NetworkCanvas(nodes: (net['nodes'] as List).map((e) => Json.from(e)).toList(),
                  edges: (net['edges'] as List).map((e) => Json.from(e)).toList(), height: 340),
            const SizedBox(height: 8),
            for (final l in st.links)
              Row(children: [
                Expanded(child: Text('${l.company} → ${l.counterparty}', style: const TextStyle(fontSize: 13))),
                Text('${l.relation} · ${(l.share * 100).round()}%', style: context.tt.bodySmall),
                IconButton(visualDensity: VisualDensity.compact, icon: Icon(Icons.close, size: 15, color: k.faint),
                    onPressed: () async {
                      st.links.remove(l);
                      await st.addCompanies(const []);
                      _score();
                    }),
              ]),
          ]),
        ),
        Panel(
          title: context.t('systemicTitle'),
          subtitle: context.t('systemicBody'),
          child: systemic.isEmpty
              ? Text(context.t('addLink'), style: context.tt.bodySmall)
              : Column(children: [
                  for (final s in systemic)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(Icons.bolt, size: 16, color: (s['impact'] as num) > 0.01 ? k.critical : k.faint),
                        const SizedBox(width: 8),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(s['name'], style: const TextStyle(fontWeight: FontWeight.w600)),
                          for (final a in (s['affected'] as List))
                            Text('${a['name']}: ${fmtPd(a['before'])} → ${fmtPd(a['after'])}', style: context.tt.bodySmall),
                        ])),
                        Text('+${((s['impact'] as num) * 100).toStringAsFixed(1)} pp', style: KType.mono(k.muted, 12)),
                      ]),
                    ),
                ]),
        ),
      ]),
      const SizedBox(height: 16),
      Panel(
        title: context.t('retrainTitle'),
        subtitle: context.t('retrainBody'),
        trailing: FilledButton(onPressed: canRetrain ? _runRetrain : null, child: Text(context.t('retrain'))),
        child: _retrain == null
            ? Text('${labelled.length} / ${st.workspace.length}', style: KType.mono(k.muted, 12))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final c in (_retrain!['companies'] as List))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Expanded(child: Text('${c['name']}  ${c['defaulted'] == 1 ? '· ${context.t('markDefaulted').toLowerCase()}' : ''}')),
                      Text('${context.t('before')} ${fmtPd(c['pd_member_before'])}', style: KType.mono(k.muted, 12)),
                      const SizedBox(width: 14),
                      Text('${context.t('after')} ${fmtPd(c['pd_member_after'])}', style: KType.mono(k.text, 12)),
                    ]),
                  ),
                if (_retrain!['leave_one_out'] != null)
                  Text('Leave-one-out ROC-AUC on your companies: ${_retrain!['leave_one_out']['roc_auc_user_loo']} '
                      '(synthetic-only model: ${_retrain!['leave_one_out']['roc_auc_user_synthetic_only']})',
                      style: context.tt.bodySmall),
              ]),
      ),
    ]);
  }

  Widget _row(BuildContext context, AppState st, KColors k, Json r) {
    final pd = (r['distress_probability'] as num).toDouble();
    final name = r['name'] as String;
    final tl = ((r['timeline'] as List?) ?? []).map((e) => ((e as Map)['risk'] as num).toDouble()).toList();
    final ws = st.workspace.firstWhere((w) => w.name == name, orElse: () => WsCompany(name, null, const []));
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => WorkspaceCompanyScreen(report: r))),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Checkbox(
            value: _compare.contains(name),
            onChanged: (v) => setState(() {
              if (v == true && _compare.length < 4) {
                _compare.add(name);
              } else {
                _compare.remove(name);
              }
            }),
          ),
          Container(width: 3, height: 32, color: k.forPd(pd)),
          const SizedBox(width: 10),
          Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
              if (ws.defaulted == 1) ...[const SizedBox(width: 6), Icon(Icons.report, size: 14, color: k.critical)],
            ]),
            Text('${r['industry'] ?? '—'} · FY${r['fiscal_year']} · ${ws.source}', style: context.tt.bodySmall?.copyWith(fontSize: 11.5)),
          ])),
          Sparkline(tl),
          const SizedBox(width: 16),
          RatingBadge(r['implied_rating'], size: 11),
          const SizedBox(width: 12),
          SizedBox(width: 120, child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(fmtPd(pd), style: KType.mono(k.forPd(pd), 14, w: FontWeight.w600)),
            Text('${fmtPd(r['pd_low'])} – ${fmtPd(r['pd_high'])}', style: KType.mono(k.faint, 10.5)),
          ])),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, size: 18, color: k.muted),
            onSelected: (v) async {
              if (v == 'del') {
                await st.removeCompany(name);
              } else {
                await st.setDefaulted(name, v == 'd1' ? 1 : v == 'd0' ? 0 : null);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'd1', child: Text(context.t('markDefaulted'))),
              PopupMenuItem(value: 'd0', child: Text(context.t('markHealthy'))),
              PopupMenuItem(value: 'dn', child: Text(context.t('markUnknown'))),
              PopupMenuItem(value: 'del', child: Text(context.t('remove'))),
            ],
          ),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------ compare
class _ComparePanel extends StatelessWidget {
  final List<Json> reports;
  const _ComparePanel({required this.reports});
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    const keys = ['ebitda_margin', 'debt_to_equity', 'interest_coverage', 'current_ratio', 'ocf_to_debt', 'revenue_growth_yoy'];
    return Panel(
      title: context.t('compare'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CompareTimeline(series: {
          for (final r in reports) r['name'] as String: ((r['timeline'] as List?) ?? []).map((e) => Json.from(e)).toList(),
        }),
        const SizedBox(height: 16),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 34, dataRowMinHeight: 32, dataRowMaxHeight: 36,
            headingTextStyle: KType.label(k.muted),
            columns: [const DataColumn(label: Text('')), for (final r in reports) DataColumn(label: Text(r['name']))],
            rows: [
              DataRow(cells: [DataCell(Text(context.t('pd12'))),
                for (final r in reports) DataCell(Text('${fmtPd(r['distress_probability'])}  (${fmtPd(r['pd_low'])}–${fmtPd(r['pd_high'])})',
                    style: KType.mono(k.forPd((r['distress_probability'] as num).toDouble()), 12)))]),
              DataRow(cells: [DataCell(Text(context.t('impliedRating'))),
                for (final r in reports) DataCell(Text('${r['implied_rating']}', style: KType.mono(k.text, 12)))]),
              DataRow(cells: [DataCell(Text(context.t('healthScore'))),
                for (final r in reports) DataCell(Text('${r['health_score']}', style: KType.mono(k.text, 12)))]),
              for (final key in keys)
                DataRow(cells: [DataCell(Text(context.t(key))),
                  for (final r in reports) DataCell(Text(fmtRatio(key, (r['ratios'] as Map)[key]), style: KType.mono(k.text, 12)))]),
            ],
          ),
        ),
      ]),
    );
  }
}

// ----------------------------------------------------- company detail
class WorkspaceCompanyScreen extends StatelessWidget {
  final Json report;
  const WorkspaceCompanyScreen({super.key, required this.report});
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final r = Report(report);
    final years = ((report['years'] as List?) ?? []).map((e) => Json.from(e)).toList();
    final tl = ((report['timeline'] as List?) ?? []).map((e) => Json.from(e)).toList();
    return Scaffold(
      appBar: AppBar(backgroundColor: k.bg, title: Text(report['name'], style: const TextStyle(fontSize: 15)), actions: [
        TextButton.icon(onPressed: () => exportCompanyPdf(report), icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
            label: Text(context.t('exportPdf'))),
        const SizedBox(width: 12),
      ]),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 48),
        child: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1280),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Eyebrow('${report['industry'] ?? '—'} · FY${report['fiscal_year']}', color: k.accent),
            const SizedBox(height: 8),
            Text(report['name'], style: context.tt.headlineLarge),
            const SizedBox(height: 18),
            Cols([RiskHeadline(r), Column(children: [
              TermPanel(r),
              if (tl.length > 1) ...[const SizedBox(height: 16), Panel(title: context.t('timeline'), child: RiskTimeline(points: tl, height: 140))],
            ]), HealthPanel(r)], flex: const [4, 5, 4], breakpoint: 1000),
            const SizedBox(height: 16),
            Cols([DriversPanel(r), PeersPanel(r)], flex: const [6, 5]),
            const SizedBox(height: 16),
            if (years.isNotEmpty)
              Panel(
                title: '${context.t('financials')} · ${context.t('inCrore')}',
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingRowHeight: 34, dataRowMinHeight: 32, dataRowMaxHeight: 36, headingTextStyle: KType.label(k.muted),
                    columns: [const DataColumn(label: Text('')), for (final y in years) DataColumn(numeric: true, label: Text('FY${(y['year'] as num).toInt() % 100}'))],
                    rows: [
                      for (final f in _fields)
                        DataRow(cells: [DataCell(Text(context.t(_fieldKeys[f]!), style: const TextStyle(fontSize: 13))),
                          for (final y in years) DataCell(Text(((y[f] as num?) ?? 0).toStringAsFixed(0), style: KType.mono(k.text, 12)))]),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 16),
            RatioGrid(r.ratios),
          ]),
        )),
      ),
    );
  }
}

// ------------------------------------------------------------ dialogs
class _PreviewDialog extends StatelessWidget {
  final String title, footer;
  final List<String> lines, warnings;
  const _PreviewDialog({required this.title, required this.lines, required this.footer, required this.warnings});
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return AlertDialog(
      title: Text(title),
      content: SizedBox(width: 460, child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        for (final l in lines) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text(l)),
        const SizedBox(height: 8),
        Text(footer, style: context.tt.bodySmall),
        for (final w in warnings) Text('⚠ $w', style: TextStyle(color: k.moderate, fontSize: 12)),
      ]))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.t('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.t('add'))),
      ],
    );
  }
}

class _TickerDialog extends StatefulWidget {
  const _TickerDialog();
  @override
  State<_TickerDialog> createState() => _TickerDialogState();
}

class _TickerDialogState extends State<_TickerDialog> {
  final _ctl = TextEditingController();
  Json? _r;
  String? _err, _sector;
  bool _busy = false;

  Future<void> _fetch() async {
    setState(() { _busy = true; _err = null; });
    try {
      final r = await context.read<AppState>().api.ticker(_ctl.text.trim());
      setState(() { _r = r; _sector = r['sector']; });
    } catch (e) {
      setState(() => _err = '$e'.contains('404') ? context.tr('error') : '$e');
    }
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final years = ((_r?['years'] as List?) ?? []).map((e) => Json.from(e)).toList();
    return AlertDialog(
      title: Text(context.t('addTicker')),
      content: SizedBox(width: 520, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: TextField(controller: _ctl, autofocus: true, onSubmitted: (_) => _fetch(),
              textCapitalization: TextCapitalization.characters, decoration: InputDecoration(hintText: context.t('tickerHint')))),
          const SizedBox(width: 10),
          FilledButton(onPressed: _busy ? null : _fetch, child: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('fetch'))),
        ]),
        if (_err != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_err!, style: TextStyle(color: k.critical))),
        if (_r != null) ...[
          const SizedBox(height: 14),
          Text(_r!['name'], style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
          Text('${_r!['symbol']} · ${_r!['source_sector'] ?? ''}${_r!['converted_to_inr'] == true ? ' · ${_r!['currency']} → INR' : ''}',
              style: context.tt.bodySmall),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _sector, dropdownColor: k.raised,
            decoration: InputDecoration(labelText: context.t('sector')),
            items: [for (final s in sectorNames) DropdownMenuItem(value: s, child: Text(s))],
            onChanged: (v) => setState(() => _sector = v),
          ),
          const SizedBox(height: 10),
          for (final y in years)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text('FY${y['year']}: ${context.t('revenue')} ${fmtCr(y['revenue'])} · EBITDA ${fmtCr(y['ebitda'])} · ${context.t('debt')} ${fmtCr(y['debt'])}',
                  style: KType.mono(k.muted, 11.5)),
            ),
        ],
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _r == null ? null : () => Navigator.pop(context, WsCompany(_r!['name'], _sector, years, source: 'ticker')),
          child: Text(context.t('add')),
        ),
      ],
    );
  }
}

/// Enter or confirm one fiscal year of statements (used for PDF extraction and manual entry).
class _StatementsDialog extends StatefulWidget {
  final Json initial;
  final Json evidence;
  final String source;
  final String? suggestedName;
  const _StatementsDialog({required this.initial, this.evidence = const {}, required this.source, this.suggestedName});
  @override
  State<_StatementsDialog> createState() => _StatementsDialogState();
}

class _StatementsDialogState extends State<_StatementsDialog> {
  late final _name = TextEditingController(text: widget.suggestedName ?? '');
  final _year = TextEditingController(text: '2025');
  String? _sector;
  late final _ctl = {for (final f in _fields) f: TextEditingController(text: widget.initial[f] == null ? '' : '${widget.initial[f]}')};

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return AlertDialog(
      title: Text(widget.source == 'pdf' ? context.t('extracted') : context.t('addManual')),
      content: SizedBox(width: 640, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(flex: 3, child: TextField(controller: _name, decoration: InputDecoration(labelText: context.t('companyName')))),
          const SizedBox(width: 10),
          Expanded(child: TextField(controller: _year, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('latestYear')))),
        ]),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          initialValue: _sector, dropdownColor: k.raised, decoration: InputDecoration(labelText: context.t('sector')),
          items: [for (final s in sectorNames) DropdownMenuItem(value: s, child: Text(s))],
          onChanged: (v) => setState(() => _sector = v),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 10, children: [
          for (final f in _fields)
            SizedBox(width: 190, child: Tooltip(
              message: widget.evidence[f] ?? '',
              child: TextField(
                controller: _ctl[f],
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                style: KType.mono(k.text, 13),
                decoration: InputDecoration(
                  labelText: context.t(_fieldKeys[f]!), suffixText: '₹ cr',
                  helperText: widget.source == 'pdf' && widget.initial[f] == null ? context.t('noFound') : null,
                  helperStyle: TextStyle(color: k.moderate),
                ),
              ),
            )),
        ]),
      ]))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            final rev = double.tryParse(_ctl['revenue']!.text.replaceAll(',', ''));
            if (name.isEmpty || rev == null || rev <= 0) return;
            final year = {'year': int.tryParse(_year.text) ?? 2025,
              for (final f in _fields) f: double.tryParse(_ctl[f]!.text.replaceAll(',', '')) ?? 0.0};
            Navigator.pop(context, WsCompany(name, _sector, [year], source: widget.source));
          },
          child: Text(context.t('add')),
        ),
      ],
    );
  }
}

class _LinkDialog extends StatefulWidget {
  const _LinkDialog();
  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  String? _company, _cp;
  String _rel = 'customer', _health = 'stable';
  final _ext = TextEditingController();
  final _share = TextEditingController(text: '25');

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final names = context.watch<AppState>().workspace.map((c) => c.name).toList();
    const rels = {'supplier': 'relSupplier', 'customer': 'relCustomer', 'parent': 'relParent',
      'subsidiary': 'relSubsidiary', 'guarantor': 'relGuarantor'};
    const healths = ['strong', 'stable', 'weak', 'distressed'];
    return AlertDialog(
      title: Text(context.t('addLink')),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<String>(initialValue: _company, dropdownColor: k.raised, decoration: InputDecoration(labelText: context.t('company')),
            items: [for (final n in names) DropdownMenuItem(value: n, child: Text(n))], onChanged: (v) => setState(() => _company = v)),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(initialValue: _cp, dropdownColor: k.raised, decoration: InputDecoration(labelText: context.t('counterparty')),
            items: [
              for (final n in names.where((n) => n != _company)) DropdownMenuItem(value: n, child: Text(n)),
              DropdownMenuItem(value: '__ext', child: Text('${context.t('counterparty')} (external)')),
            ], onChanged: (v) => setState(() => _cp = v)),
        if (_cp == '__ext') ...[
          const SizedBox(height: 10),
          TextField(controller: _ext, decoration: InputDecoration(labelText: context.t('companyName'))),
        ],
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: DropdownButtonFormField<String>(initialValue: _rel, dropdownColor: k.raised, decoration: InputDecoration(labelText: context.t('relation')),
              items: [for (final e in rels.entries) DropdownMenuItem(value: e.key, child: Text(context.t(e.value)))],
              onChanged: (v) => setState(() => _rel = v!))),
          const SizedBox(width: 10),
          SizedBox(width: 90, child: TextField(controller: _share, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('share')))),
        ]),
        if (_cp == '__ext') ...[
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(initialValue: _health, dropdownColor: k.raised, decoration: InputDecoration(labelText: context.t('health')),
              items: [for (final h in healths) DropdownMenuItem(value: h, child: Text(context.t('health${h[0].toUpperCase()}${h.substring(1)}')))],
              onChanged: (v) => setState(() => _health = v!)),
        ],
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(onPressed: () {
          final cp = _cp == '__ext' ? _ext.text.trim() : _cp;
          final share = (double.tryParse(_share.text) ?? 0) / 100;
          if (_company == null || cp == null || cp.isEmpty || share <= 0) return;
          Navigator.pop(context, WsLink(_company!, cp, _rel, share.clamp(0.01, 1.0), health: _health));
        }, child: Text(context.t('add'))),
      ],
    );
  }
}

// ------------------------------------------------------------ sample
final _sampleCompanies = [
  WsCompany('Alpha Steel', 'Steel & Metals', const [
    {'year': 2024, 'revenue': 5600, 'ebitda': 910, 'net_profit': 320, 'interest_expense': 190, 'assets': 7900, 'debt': 2800, 'equity': 2750, 'cash': 300, 'current_assets': 2700, 'current_liabilities': 2100, 'inventory': 950, 'ocf': 720, 'capex': 510},
    {'year': 2025, 'revenue': 5200, 'ebitda': 760, 'net_profit': 180, 'interest_expense': 210, 'assets': 8100, 'debt': 3100, 'equity': 2900, 'cash': 240, 'current_assets': 2600, 'current_liabilities': 2200, 'inventory': 900, 'ocf': 610, 'capex': 420},
  ], promoterPledge: 0.12, source: 'upload'),
  WsCompany('Beta Motors', 'Auto & Components', const [
    {'year': 2024, 'revenue': 8700, 'ebitda': 1010, 'net_profit': 380, 'interest_expense': 110, 'assets': 7000, 'debt': 1400, 'equity': 3500, 'cash': 600, 'current_assets': 3600, 'current_liabilities': 2900, 'inventory': 1150, 'ocf': 900, 'capex': 580},
    {'year': 2025, 'revenue': 9100, 'ebitda': 1050, 'net_profit': 410, 'interest_expense': 120, 'assets': 7400, 'debt': 1500, 'equity': 3800, 'cash': 650, 'current_assets': 3900, 'current_liabilities': 3100, 'inventory': 1200, 'ocf': 980, 'capex': 600},
  ], source: 'upload'),
  WsCompany('Gamma Infra', 'Infrastructure & EPC', const [
    {'year': 2024, 'revenue': 3500, 'ebitda': 400, 'net_profit': 20, 'interest_expense': 260, 'assets': 6600, 'debt': 3200, 'equity': 1300, 'cash': 110, 'current_assets': 3300, 'current_liabilities': 3100, 'inventory': 650, 'ocf': 210, 'capex': 180},
    {'year': 2025, 'revenue': 3100, 'ebitda': 280, 'net_profit': -90, 'interest_expense': 300, 'assets': 6900, 'debt': 3600, 'equity': 1200, 'cash': 60, 'current_assets': 3400, 'current_liabilities': 3500, 'inventory': 700, 'ocf': 90, 'capex': 150},
  ], promoterPledge: 0.45, source: 'upload'),
];
const _sampleLinks = [
  WsLink('Alpha Steel', 'Beta Motors', 'customer', 0.35),
  WsLink('Alpha Steel', 'Gamma Infra', 'customer', 0.25),
  WsLink('Beta Motors', 'Alpha Steel', 'supplier', 0.30),
  WsLink('Gamma Infra', 'National Highways Authority', 'customer', 0.60),
];
