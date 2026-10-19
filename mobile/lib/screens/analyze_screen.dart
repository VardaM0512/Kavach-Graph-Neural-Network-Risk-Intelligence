import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/account.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/company_picker.dart';
import '../widgets/kit.dart';
import '../widgets/report_sections.dart';
import 'company_screen.dart';
import 'screener_screen.dart';

const _fields = [
  ('revenue', 'revenue'), ('ebitda', 'ebitda'), ('net_profit', 'netProfit'), ('interest_expense', 'fInterest'),
  ('assets', 'fAssets'), ('debt', 'debt'), ('equity', 'fEquity'), ('cash', 'cash'),
  ('current_assets', 'fCurAssets'), ('current_liabilities', 'fCurLiab'), ('inventory', 'fInventory'),
  ('ocf', 'ocf'), ('capex', 'fCapex'),
];

class _Cp {
  final name = TextEditingController();
  final share = TextEditingController();
  String relation = 'customer', health = 'stable';
  String? companyId;
  Json? statements;          // a company from "My companies": its real statements are used
}

class AnalyzeScreen extends StatefulWidget {
  const AnalyzeScreen({super.key});
  @override
  State<AnalyzeScreen> createState() => _AnalyzeScreenState();
}

class _AnalyzeScreenState extends State<AnalyzeScreen> {
  int _step = 0;
  final _name = TextEditingController();
  final _pledge = TextEditingController(text: '0');
  final _fy = TextEditingController(text: '2025');
  String? _sector;
  final _cur = {for (final f in _fields) f.$1: TextEditingController()};
  final _prevRev = TextEditingController(), _prevEbitda = TextEditingController(), _earlyRev = TextEditingController();
  final _cps = <_Cp>[];
  Json? _template, _result, _lastPayload;
  bool _busy = false, _saved = false;
  double _revShock = 0, _rateShock = 0;
  Timer? _debounce;
  List<SavedAnalysis> _history = [];

  @override
  void initState() {
    super.initState();
    final st = context.read<AppState>();
    st.api.analyzeTemplate().then((t) => setState(() => _template = t)).catchError((_) {});
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final h = await context.read<AppState>().account.analyses();
      if (mounted) setState(() => _history = h);
    } catch (_) {}
  }

  double? _num(TextEditingController c) => double.tryParse(c.text.replaceAll(',', '').trim());

  void _loadExample(Json ex) {
    setState(() {
      _name.text = ex['name'];
      _sector = ex['sector'];
      _pledge.text = '${((ex['promoter_pledge'] as num) * 100).round()}';
      final cur = Json.from(ex['current']);
      for (final f in _fields) {
        _cur[f.$1]!.text = '${cur[f.$1] ?? ''}';
      }
      _prevRev.text = '${ex['previous']?['revenue'] ?? ''}';
      _prevEbitda.text = '${ex['previous']?['ebitda'] ?? ''}';
      _cps.clear();
      for (final c in (ex['counterparties'] as List? ?? [])) {
        final cp = _Cp()
          ..relation = c['relation']
          ..health = c['health'];
        cp.name.text = c['name'];
        cp.share.text = '${((c['share'] as num) * 100).round()}';
        _cps.add(cp);
      }
      _result = null;
    });
  }

  Json _payload() => {
        'name': _name.text.trim().isEmpty ? 'Unnamed company' : _name.text.trim(),
        'sector': _sector,
        'fiscal_year': int.tryParse(_fy.text) ?? 2025,
        'promoter_pledge': ((_num(_pledge) ?? 0) / 100).clamp(0, 1),
        'current': {for (final f in _fields) f.$1: _num(_cur[f.$1]!) ?? 0},
        if (_num(_prevRev) != null) 'previous': {'revenue': _num(_prevRev), 'ebitda': _num(_prevEbitda)},
        if (_num(_earlyRev) != null) 'earlier': [{'year': (int.tryParse(_fy.text) ?? 2025) - 3, 'revenue': _num(_earlyRev)}],
        'counterparties': [
          for (final c in _cps)
            if ((_num(c.share) ?? 0) > 0)
              {'name': c.name.text, 'relation': c.relation, 'share': ((_num(c.share) ?? 0) / 100).clamp(0, 1),
                'health': c.health, if (c.companyId != null) 'company_id': c.companyId,
                if (c.statements != null) 'statements': c.statements},
        ],
      };

  Future<void> _score({bool withShocks = false}) async {
    setState(() => _busy = true);
    try {
      final p = _payload();
      if (withShocks && (_revShock != 0 || _rateShock != 0)) {
        p['shocks'] = {'revenue_change': _revShock, 'interest_rate_change': _rateShock};
      } else {
        _lastPayload = p;
        _saved = false;
      }
      final r = await context.read<AppState>().api.analyze(p);
      setState(() {
        _result = r;
        _step = 3;
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${context.tr('error')} $e')));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save() async {
    if (_lastPayload == null || _result == null) return;
    final st = context.read<AppState>();
    await st.account.saveAnalysis(_lastPayload!, _result!);
    // keep the company in "My companies" so it can be tracked across years and linked to others
    final p = _lastPayload!;
    await st.addCompanies([
      WsCompany(p['name'], p['sector'], [{'year': p['fiscal_year'], ...Json.from(p['current'])}],
          promoterPledge: ((p['promoter_pledge'] as num?) ?? 0).toDouble(), source: 'manual'),
    ]);
    setState(() => _saved = true);
    _loadHistory();
  }

  // ---------------------------------------------------------- auto-fill
  final _ticker = TextEditingController();
  bool _filling = false;

  void _fillYears(List<Json> years) {
    years.sort((a, b) => (b['year'] as num).compareTo(a['year'] as num));
    final cur = years.first;
    for (final f in _fields) {
      if (cur[f.$1] != null) _cur[f.$1]!.text = '${cur[f.$1]}';
    }
    _fy.text = '${cur['year']}';
    if (years.length > 1) {
      _prevRev.text = '${years[1]['revenue']}';
      _prevEbitda.text = '${years[1]['ebitda']}';
    }
    if (years.length > 3) _earlyRev.text = '${years[3]['revenue']}';
  }

  Future<void> _fillTicker() async {
    if (_ticker.text.trim().isEmpty) return;
    setState(() => _filling = true);
    try {
      final r = await context.read<AppState>().api.ticker(_ticker.text.trim());
      setState(() {
        _name.text = r['name'];
        if (r['sector'] != null) _sector = r['sector'];
        _fillYears((r['years'] as List).map((e) => Json.from(e)).toList());
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${context.tr('error')} $e')));
    }
    if (mounted) setState(() => _filling = false);
  }

  Future<void> _fillPdf() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (picked.isEmpty || !mounted) return;
    setState(() => _filling = true);
    try {
      final r = await context.read<AppState>().api.extractPdf(await picked.first.readAsBytes(), picked.first.name);
      final cur = Json.from(r['current']);
      setState(() {
        for (final f in _fields) {
          if (cur[f.$1] != null) _cur[f.$1]!.text = '${cur[f.$1]}';
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.tr('extracted'))));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${context.tr('error')} $e')));
    }
    if (mounted) setState(() => _filling = false);
  }

  bool get _statementsOk => (_num(_cur['revenue']!) ?? 0) > 0 && _num(_cur['ebitda']!) != null;

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final steps = [context.t('stepCompany'), context.t('stepStatements'), context.t('stepNetwork'), context.t('stepResult')];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 48),
      child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PageHeader(eyebrow: context.t('navAnalyze'), title: context.t('analyzeTitle'), body: context.t('analyzeBody'), actions: [
            if (_template != null)
              MenuAnchor(
                builder: (context, menu, _) => OutlinedButton.icon(
                  onPressed: () => menu.isOpen ? menu.close() : menu.open(),
                  icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
                  label: Text(context.t('loadExample')),
                ),
                menuChildren: [
                  for (final e in (_template!['examples'] as List))
                    MenuItemButton(onPressed: () => _loadExample(Json.from(e)), child: Text(e['name'])),
                ],
              ),
          ]),
          // stepper
          Row(children: [
            for (var i = 0; i < steps.length; i++) ...[
              InkWell(
                onTap: (i < 3 || _result != null) ? () => setState(() => _step = i) : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(children: [
                    Container(
                      width: 24, height: 24, alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: i == _step ? k.accent : Colors.transparent,
                        border: Border.all(color: i <= _step ? k.accent : k.lineStrong), shape: BoxShape.circle),
                      child: Text('${i + 1}', style: KType.mono(i == _step ? k.bg : k.muted, 11, w: FontWeight.w700)),
                    ),
                    const SizedBox(width: 8),
                    Text(steps[i], style: TextStyle(color: i == _step ? k.text : k.muted, fontWeight: FontWeight.w600, fontSize: 13)),
                  ]),
                ),
              ),
              if (i < steps.length - 1) Expanded(child: Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 12), color: k.line)),
            ],
          ]),
          const SizedBox(height: 18),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: KeyedSubtree(key: ValueKey(_step), child: [_stepCompany, _stepStatements, _stepNetwork, _stepResult][_step](context)),
          ),
          if (_history.isNotEmpty && _step < 3) ...[
            const SizedBox(height: 28),
            Panel(
              title: context.t('myAnalyses'),
              child: Column(children: [
                for (final h in _history.take(8))
                  InkWell(
                    onTap: () => setState(() {
                      _result = h.result;
                      _lastPayload = h.input;
                      _saved = true;
                      _step = 3;
                    }),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(children: [
                        Expanded(child: Text(h.name)),
                        Text(h.sector ?? '', style: context.tt.bodySmall),
                        const SizedBox(width: 16),
                        RatingBadge(h.rating, size: 11),
                        const SizedBox(width: 12),
                        SizedBox(width: 60, child: Text(fmtPd(h.pd), textAlign: TextAlign.end, style: KType.mono(k.forPd(h.pd), 12.5))),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(Icons.delete_outline, size: 16, color: k.faint),
                          onPressed: () async {
                            await context.read<AppState>().account.deleteAnalysis(h.id);
                            _loadHistory();
                          },
                        ),
                      ]),
                    ),
                  ),
              ]),
            ),
          ],
        ]),
      )),
    );
  }

  // --------------------------------------------------------------- steps
  Widget _nav({bool canNext = true, VoidCallback? next, String? nextLabel}) => Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Row(children: [
          if (_step > 0) OutlinedButton(onPressed: () => setState(() => _step--), child: Text(context.t('back'))),
          const Spacer(),
          FilledButton(
            onPressed: canNext && !_busy ? (next ?? () => setState(() => _step++)) : null,
            child: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(nextLabel ?? context.t('next')),
          ),
        ]),
      );

  Widget _stepCompany(BuildContext context) {
    final k = context.k;
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: TextField(controller: _ticker, textCapitalization: TextCapitalization.characters,
              onSubmitted: (_) => _fillTicker(),
              decoration: InputDecoration(labelText: context.t('autofill'), hintText: context.t('tickerHint'),
                  prefixIcon: Icon(Icons.travel_explore, size: 18, color: k.muted)))),
          const SizedBox(width: 10),
          OutlinedButton(onPressed: _filling ? null : _fillTicker, child: Text(context.t('fetch'))),
          const SizedBox(width: 10),
          OutlinedButton.icon(onPressed: _filling ? null : _fillPdf, icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
              label: Text(context.t('fromPdf'))),
          if (_filling) const Padding(padding: EdgeInsets.only(left: 10), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
        ]),
        const SizedBox(height: 14),
        TextField(controller: _name, decoration: InputDecoration(labelText: context.t('companyName'))),
        const SizedBox(height: 14),
        Wrap(spacing: 14, runSpacing: 14, children: [
          SizedBox(width: 320, child: DropdownButtonFormField<String>(
            initialValue: _sector,
            decoration: InputDecoration(labelText: context.t('sector')),
            dropdownColor: k.raised,
            items: [for (final s in sectorNames) DropdownMenuItem(value: s, child: Text(s))],
            onChanged: (v) => setState(() => _sector = v),
          )),
          SizedBox(width: 160, child: TextField(controller: _fy, keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(labelText: context.t('latestYear')))),
          SizedBox(width: 220, child: TextField(controller: _pledge, keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: context.t('promoterPledge')))),
        ]),
        _nav(),
      ]),
    );
  }

  Widget _numField(TextEditingController c, String label, {bool required = false}) => SizedBox(
        width: 210,
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-]'))],
          style: KType.mono(context.k.text, 14),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: label, suffixText: '₹ cr', helperText: required ? context.t('required') : null),
        ),
      );

  Widget _stepStatements(BuildContext context) => Panel(
        title: '${context.t('latestYear')} · ${context.t('inCrore')}',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 14, runSpacing: 14, children: [
            for (final f in _fields) _numField(_cur[f.$1]!, context.t(f.$2), required: f.$1 == 'revenue' || f.$1 == 'ebitda'),
          ]),
          const SizedBox(height: 22),
          Eyebrow(context.t('previousYear')),
          const SizedBox(height: 10),
          Wrap(spacing: 14, runSpacing: 14, children: [
            _numField(_prevRev, context.t('revenue')),
            _numField(_prevEbitda, context.t('ebitda')),
            _numField(_earlyRev, '${context.t('revenue')} (−3y)'),
          ]),
          _nav(canNext: _statementsOk),
        ]),
      );

  Widget _stepNetwork(BuildContext context) {
    final k = context.k;
    const rels = ['supplier', 'customer', 'parent', 'subsidiary', 'guarantor'];
    const relKeys = {'supplier': 'relSupplier', 'customer': 'relCustomer', 'parent': 'relParent',
      'subsidiary': 'relSubsidiary', 'guarantor': 'relGuarantor'};
    const healths = ['strong', 'stable', 'weak', 'distressed'];
    return Panel(
      title: context.t('counterparties'),
      subtitle: context.t('counterpartyHint'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final c in _cps)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(width: 260, child: c.companyId != null
                  ? InputDecorator(decoration: InputDecoration(labelText: context.t('company')),
                      child: Row(children: [
                        Expanded(child: Text(c.name.text, overflow: TextOverflow.ellipsis)),
                        InkWell(onTap: () => setState(() => c.companyId = null), child: Icon(Icons.link_off, size: 16, color: k.muted)),
                      ]))
                  : TextField(controller: c.name, decoration: InputDecoration(labelText: context.t('company')))),
              SizedBox(width: 160, child: DropdownButtonFormField<String>(
                initialValue: c.relation, dropdownColor: k.raised,
                decoration: InputDecoration(labelText: context.t('relation')),
                items: [for (final r in rels) DropdownMenuItem(value: r, child: Text(context.t(relKeys[r]!)))],
                onChanged: (v) => setState(() => c.relation = v!),
              )),
              SizedBox(width: 110, child: TextField(controller: c.share, keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: context.t('share')))),
              SizedBox(width: 150, child: DropdownButtonFormField<String>(
                initialValue: c.health, dropdownColor: k.raised,
                decoration: InputDecoration(labelText: context.t('health')),
                items: [for (final h in healths) DropdownMenuItem(value: h,
                    child: Text(context.t('health${h[0].toUpperCase()}${h.substring(1)}')))],
                onChanged: c.companyId != null ? null : (v) => setState(() => c.health = v!),
              )),
              SizedBox(width: 220, child: CompanyPicker(hint: '↔ ${context.t('search')}', clearOnPick: true, onPicked: (co) {
                setState(() {
                  c.companyId = co['company_id'];
                  c.statements = null;
                  c.name.text = co['name'];
                });
              })),
              if (context.watch<AppState>().workspace.isNotEmpty)
                PopupMenuButton<WsCompany>(
                  tooltip: context.t('navCompanies'),
                  icon: Icon(Icons.business_center_outlined, size: 18, color: c.statements != null ? k.accent : k.muted),
                  onSelected: (w) => setState(() {
                    c.statements = Json.from(w.latest)..remove('year');
                    c.companyId = null;
                    c.name.text = w.name;
                    c.health = w.defaulted == 1 ? 'distressed' : 'stable';
                  }),
                  itemBuilder: (_) => [
                    for (final w in context.read<AppState>().workspace) PopupMenuItem(value: w, child: Text(w.name)),
                  ],
                ),
              IconButton(icon: Icon(Icons.close, size: 18, color: k.muted), onPressed: () => setState(() => _cps.remove(c))),
            ]),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(onPressed: () => setState(() => _cps.add(_Cp())), icon: const Icon(Icons.add, size: 18),
              label: Text(context.t('addCounterparty'))),
        ),
        _nav(next: () => _score(), nextLabel: context.t('scoreCompany')),
      ]),
    );
  }

  Widget _stepResult(BuildContext context) {
    final k = context.k;
    final res = _result;
    if (res == null) return const SizedBox();
    final r = Report(res);
    final ood = ((res['out_of_distribution'] as List?) ?? []).map((e) => Json.from(e)).toList();
    final assumptions = ((res['assumptions'] as List?) ?? []).cast<String>();
    final checks = ((res['data_checks'] as List?) ?? []).map((e) => Json.from(e)).toList();
    final pctF = (double v) => '${v >= 0 ? '+' : ''}${(v * 100).round()}%';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Eyebrow(res['industry'] ?? '—', color: k.accent),
          const SizedBox(height: 6),
          Text(res['name'], style: context.tt.headlineMedium),
        ])),
        OutlinedButton.icon(
          onPressed: _saved || _revShock != 0 || _rateShock != 0 ? null : _save,
          icon: Icon(_saved ? Icons.check : Icons.bookmark_add_outlined, size: 18),
          label: Text(_saved ? context.t('saved') : context.t('save')),
        ),
      ]),
      const SizedBox(height: 16),
      if (ood.isNotEmpty || assumptions.isNotEmpty || checks.isNotEmpty) ...[
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: k.moderate.withValues(alpha: 0.08), border: Border.all(color: k.moderate.withValues(alpha: 0.4)),
              borderRadius: BorderRadius.circular(6)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final a in assumptions) _note(context, Icons.info_outline, context.t('assumption_$a')),
            for (final c in checks) _note(context, Icons.rule, '${context.t('dataChecks')}: ${c['field']} (${c['issue']})'),
            if (ood.isNotEmpty)
              _note(context, Icons.warning_amber_rounded,
                  '${context.t('outOfRange')}: ${ood.map((o) => '${context.t(o['feature'])} ${fmtRatio(o['feature'], o['value'])}').join(' · ')}'),
          ]),
        ),
        const SizedBox(height: 16),
      ],
      Cols([RiskHeadline(r), TermPanel(r), HealthPanel(r)], flex: const [4, 5, 4], breakpoint: 1000),
      const SizedBox(height: 16),
      Cols([
        DriversPanel(r, onOpen: (id, name) => openCompany(context, id, name)),
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Panel(
            title: context.t('stressTest'),
            child: Column(children: [
              _shockSlider(context.t('revenueShock'), _revShock, -0.5, 0.3, pctF, (v) => _revShock = v),
              _shockSlider(context.t('rateShock'), _rateShock, -0.02, 0.05, (v) => '${v >= 0 ? '+' : ''}${(v * 10000).round()} bps',
                  (v) => _rateShock = v),
            ]),
          ),
          const SizedBox(height: 16),
          PeersPanel(r),
        ]),
      ], flex: const [6, 5]),
      const SizedBox(height: 16),
      RatioGrid(r.ratios),
    ]);
  }

  Widget _shockSlider(String label, double v, double min, double max, String Function(double) f, void Function(double) set) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Text(label, style: const TextStyle(fontSize: 13.5))), Text(f(v), style: KType.mono(context.k.text, 13))]),
        Slider(value: v, min: min, max: max, onChanged: (x) {
          setState(() => set(x));
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 260), () => _score(withShocks: true));
        }),
      ]);

  Widget _note(BuildContext context, IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: context.k.moderate),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ]),
      );
}
