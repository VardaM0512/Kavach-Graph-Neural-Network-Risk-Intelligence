import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/kit.dart';
import 'company_screen.dart';

const sectorNames = [
  'IT Services', 'Pharmaceuticals', 'FMCG', 'Auto & Components', 'Capital Goods', 'Steel & Metals', 'Cement',
  'Chemicals', 'Textiles & Apparel', 'Power & Utilities', 'Infrastructure & EPC', 'Real Estate', 'Telecom & Media',
  'Logistics', 'Retail', 'Hospitality',
];

class ScreenerScreen extends StatefulWidget {
  const ScreenerScreen({super.key});
  @override
  State<ScreenerScreen> createState() => _ScreenerScreenState();
}

class _ScreenerScreenState extends State<ScreenerScreen> {
  String? _sector, _band;
  String _sort = 'risk', _q = '';
  final _rows = <Json>[];
  int _total = 0;
  bool _loading = false;
  Object? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _fetch(reset: true);
  }

  Future<void> _fetch({bool reset = false}) async {
    if (reset) _rows.clear();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await context.read<AppState>().api.companies(
          limit: 40, offset: _rows.length, sector: _sector, band: _band, q: _q, sort: _sort);
      _rows.addAll((r['companies'] as List).map((e) => Json.from(e)));
      _total = r['total'];
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 48),
      child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PageHeader(eyebrow: context.t('navScreener'), title: '$_total ${context.t('companies')}'),
          Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(width: 280, child: TextField(
              decoration: InputDecoration(hintText: context.t('search'), prefixIcon: Icon(Icons.search, size: 18, color: k.muted)),
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 250), () {
                  _q = v;
                  _fetch(reset: true);
                });
              },
            )),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(color: k.raised, border: Border.all(color: k.line), borderRadius: BorderRadius.circular(4)),
              child: DropdownButtonHideUnderline(child: DropdownButton<String?>(
                value: _sector,
                hint: Text('${context.t('sector')}: ${context.t('all')}'),
                dropdownColor: k.raised,
                items: [
                  DropdownMenuItem(value: null, child: Text('${context.t('sector')}: ${context.t('all')}')),
                  for (final s in sectorNames) DropdownMenuItem(value: s, child: Text(s)),
                ],
                onChanged: (v) {
                  _sector = v;
                  _fetch(reset: true);
                },
              )),
            ),
            for (final b in ['LOW', 'MODERATE', 'HIGH', 'CRITICAL'])
              FilterChip(
                label: Text(context.t('band$b')),
                selected: _band == b,
                showCheckmark: false,
                selectedColor: k.band(b).withValues(alpha: 0.2),
                side: BorderSide(color: _band == b ? k.band(b) : k.line),
                onSelected: (s) {
                  _band = s ? b : null;
                  _fetch(reset: true);
                },
              ),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: 'risk', label: Text(context.t('sortRisk'))),
                ButtonSegment(value: 'movers', label: Text(context.t('sortMovers'))),
                ButtonSegment(value: 'safe', label: Text(context.t('sortSafe'))),
                ButtonSegment(value: 'size', label: Text(context.t('sortSize'))),
              ],
              selected: {_sort},
              onSelectionChanged: (s) {
                _sort = s.first;
                _fetch(reset: true);
              },
            ),
          ]),
          const SizedBox(height: 16),
          if (_error != null && _rows.isEmpty)
            ErrorBlock(_error!, () => _fetch(reset: true))
          else
            Container(
              decoration: BoxDecoration(color: k.surface, border: Border.all(color: k.line), borderRadius: BorderRadius.circular(6)),
              child: Column(children: [
                const _HeaderRow(),
                for (final r in _rows) _Row(r),
                if (_loading) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator(minHeight: 1)),
                if (!_loading && _rows.length < _total)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: OutlinedButton(onPressed: _fetch, child: Text('${_rows.length} / $_total  ·  +40')),
                  ),
              ]),
            ),
        ]),
      )),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final wide = MediaQuery.sizeOf(context).width > 900;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k.line))),
      child: Row(children: [
        Expanded(flex: 5, child: Eyebrow(context.t('company'))),
        if (wide) Expanded(flex: 2, child: Eyebrow(context.t('revenue'))),
        if (wide) Expanded(flex: 2, child: Eyebrow(context.t('healthScore'))),
        Expanded(flex: 2, child: Eyebrow(context.t('impliedRating'))),
        Expanded(flex: 2, child: Align(alignment: AlignmentDirectional.centerEnd, child: Eyebrow(context.t('vsLastYear')))),
        Expanded(flex: 2, child: Align(alignment: AlignmentDirectional.centerEnd, child: Eyebrow('PD 12M'))),
      ]),
    );
  }
}

class _Row extends StatefulWidget {
  final Json c;
  const _Row(this.c);
  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final c = widget.c;
    final pd = (c['distress_probability'] as num).toDouble();
    final wide = MediaQuery.sizeOf(context).width > 900;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: () => openCompany(context, c['company_id'], c['name']),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(color: _hover ? k.raised : null, border: Border(bottom: BorderSide(color: k.line))),
          child: Row(children: [
            Expanded(flex: 5, child: Row(children: [
              Container(width: 3, height: 30, color: k.forPd(pd)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c['name'], maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                Text('${c['industry']} · ${c['company_id']}', style: context.tt.bodySmall?.copyWith(fontSize: 11.5)),
              ])),
            ])),
            if (wide) Expanded(flex: 2, child: Text(fmtCr(c['revenue']), style: KType.mono(k.muted, 12.5))),
            if (wide) Expanded(flex: 2, child: Row(children: [
              SizedBox(width: 60, child: ClipRRect(borderRadius: BorderRadius.circular(1), child: LinearProgressIndicator(
                  value: ((c['health_score'] as num) / 100).toDouble(), minHeight: 3, backgroundColor: k.line, color: k.accent))),
              const SizedBox(width: 8),
              Text('${(c['health_score'] as num).round()}', style: KType.mono(k.muted, 12)),
            ])),
            Expanded(flex: 2, child: Align(alignment: AlignmentDirectional.centerStart, child: RatingBadge(c['implied_rating'], size: 11.5))),
            Expanded(flex: 2, child: Align(alignment: AlignmentDirectional.centerEnd,
                child: DeltaText(pd - (c['previous_probability'] as num).toDouble(), size: 11.5))),
            Expanded(flex: 2, child: Text(fmtPd(pd), textAlign: TextAlign.end, style: KType.mono(k.forPd(pd), 14, w: FontWeight.w600))),
          ]),
        ),
      ),
    );
  }
}
