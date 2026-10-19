import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/api_client.dart';
import '../theme/app_theme.dart';
import 'charts.dart';
import 'kit.dart';

/// Normalised view over a company-detail or analyze response.
class Report {
  final Json j;
  Report(this.j);
  double get pd => (j['distress_probability'] as num).toDouble();
  double? get prevPd => (j['previous_probability'] as num?)?.toDouble();
  double? get lo => (j['pd_low'] as num?)?.toDouble();
  double? get hi => (j['pd_high'] as num?)?.toDouble();
  String get band => j['risk_band'];
  String get rating => j['implied_rating'];
  Json get horizons => Json.from(j['multi_horizon'] ?? j['prediction']?['multi_horizon'] ?? {});
  Json get health => Json.from(j['health'] ?? {});
  Json get explain => Json.from(j['explain'] ?? {});
  Json get contagion => Json.from(j['contagion'] ?? {});
  Json? get peers => j['peer_comparison'] == null ? null : Json.from(j['peer_comparison']);
  Json get ratios => Json.from(j['ratios'] ?? {});
}

/// Gauge + the four numbers a credit officer reads first.
class RiskHeadline extends StatelessWidget {
  final Report r;
  const RiskHeadline(this.r, {super.key});

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final ct = r.contagion;
    return Panel(
      title: context.t('pd12'),
      child: Column(children: [
        Center(child: PdGauge(pd: r.pd, rating: r.rating, size: 250)),
        if (r.lo != null && r.hi != null)
          Center(child: Tooltip(
            message: context.t('modelRange'),
            child: Text('${context.t('modelRange')} ${fmtPd(r.lo)} – ${fmtPd(r.hi)}',
                textDirection: TextDirection.ltr, style: KType.mono(k.muted, 11.5)),
          )),
        const SizedBox(height: 8),
        Center(child: BandChip(r.band)),
        const SizedBox(height: 18),
        Divider(color: k.line),
        _row(context, context.t('healthScore'), '${(r.health['health_score'] ?? 0)}', suffix: '/100'),
        if (r.prevPd != null) _rowW(context, context.t('vsLastYear'), DeltaText(r.pd - r.prevPd!)),
        _row(context, context.t('contagionIndex'), '${ct['contagion_score'] ?? '—'}', suffix: '/100'),
        if (ct['standalone_probability'] != null) _row(context, context.t('standalone'), fmtPd(ct['standalone_probability'])),
        if (ct['network_uplift'] != null) _rowW(context, context.t('networkUplift'), DeltaText((ct['network_uplift'] as num).toDouble())),
      ]),
    );
  }

  Widget _row(BuildContext context, String label, String value, {String suffix = ''}) =>
      _rowW(context, label, Text.rich(TextSpan(children: [
        TextSpan(text: value, style: KType.mono(context.k.text, 13.5)),
        TextSpan(text: suffix, style: KType.mono(context.k.faint, 11)),
      ])));

  Widget _rowW(BuildContext context, String label, Widget value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(children: [Expanded(child: Text(label, style: context.tt.bodySmall?.copyWith(fontSize: 13))), value]),
      );
}

class TermPanel extends StatelessWidget {
  final Report r;
  final Json? compare;
  const TermPanel(this.r, {super.key, this.compare});
  @override
  Widget build(BuildContext context) => Panel(
        title: context.t('termStructure'),
        child: Column(children: [
          TermStructureChart(horizons: r.horizons, compare: compare),
          const SizedBox(height: 12),
          Row(children: [
            for (final e in r.horizons.entries)
              Expanded(child: Column(children: [
                Text(e.key, style: KType.label(context.k.faint)),
                const SizedBox(height: 4),
                Text(fmtPd(e.value), style: KType.mono(context.k.forPd((e.value as num).toDouble()), 14, w: FontWeight.w600)),
              ])),
          ]),
          const SizedBox(height: 10),
          Text(context.t('derivedNote'), style: context.tt.bodySmall?.copyWith(fontSize: 11.5)),
        ]),
      );
}

class HealthPanel extends StatelessWidget {
  final Report r;
  const HealthPanel(this.r, {super.key});
  @override
  Widget build(BuildContext context) => Panel(
        title: context.t('healthScore'),
        trailing: Text('${r.health['health_score'] ?? '—'}', style: KType.mono(context.k.text, 15, w: FontWeight.w600)),
        child: HealthRadar(components: Json.from(r.health['components'] ?? {})),
      );
}

/// Own-fundamental drivers and counterparty drivers, both in log-odds.
class DriversPanel extends StatelessWidget {
  final Report r;
  final void Function(String id, String name)? onOpen;
  const DriversPanel(this.r, {super.key, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final ex = r.explain;
    final own = ((ex['feature_drivers'] as List?) ?? []).map((e) => Json.from(e)).toList();
    final nbrs = ((ex['network_drivers'] as List?) ?? []).map((e) => Json.from(e)).toList();
    final ratios = r.ratios;
    return Panel(
      title: context.t('drivers'),
      subtitle: '← ${context.t('lowersRisk')}   ·   ${context.t('raisesRisk')} →',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Eyebrow(context.t('ownDrivers'), color: k.faint),
        const SizedBox(height: 6),
        DriverBars(rows: [
          for (final d in own.take(7))
            {'label': context.t(d['feature']), 'value': d['contribution'],
              'detail': ratios[d['feature']] == null ? '' : fmtRatio(d['feature'], ratios[d['feature']])},
        ]),
        if (nbrs.isNotEmpty) ...[
          const SizedBox(height: 18),
          Eyebrow(context.t('networkDrivers'), color: k.faint),
          const SizedBox(height: 6),
          for (final n in nbrs.where((n) => (n['influence'] as num).abs() > 0.004).take(6))
            _NeighbourRow(n: n, onOpen: onOpen),
        ],
      ]),
    );
  }
}

class _NeighbourRow extends StatelessWidget {
  final Json n;
  final void Function(String id, String name)? onOpen;
  const _NeighbourRow({required this.n, this.onOpen});
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final infl = (n['influence'] as num).toDouble();
    final rel = {'suppliers': 'relationSuppliers', 'customers': 'relationCustomers', 'group': 'relationGroup',
      'peers': 'relationPeers'}[n['relation']] ?? 'relationPeers';
    final risk = (n['neighbour_risk'] as num?)?.toDouble();
    final canOpen = onOpen != null && n['neighbour_id'] != null && RegExp(r'^C\d{4}$').hasMatch(n['neighbour_id']);
    return InkWell(
      onTap: canOpen ? () => onOpen!(n['neighbour_id'], n['name'] ?? n['neighbour_id']) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        child: Row(children: [
          Container(width: 3, height: 30, color: infl > 0 ? k.critical : k.low),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(n['name'] ?? n['neighbour_id'], maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5))),
              if (n['defaulted'] == true) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(border: Border.all(color: k.critical), borderRadius: BorderRadius.circular(3)),
                  child: Text(context.t('counterpartyDefaulted'), style: TextStyle(color: k.critical, fontSize: 10)),
                ),
              ],
            ]),
            Text('${context.t(rel)} · ${context.t('dependency')} ${((n['relationship_weight'] as num) * 100).round()}%'
                '${n['health'] != null ? ' · ${context.t('health${(n['health'] as String)[0].toUpperCase()}${(n['health'] as String).substring(1)}')}' : ''}',
                style: context.tt.bodySmall),
          ])),
          if (risk != null) Text(fmtPd(risk), style: KType.mono(k.forPd(risk), 12.5)),
          const SizedBox(width: 14),
          SizedBox(width: 64, child: Text('${infl > 0 ? '+' : '−'}${infl.abs().toStringAsFixed(2)}', textAlign: TextAlign.end,
              style: KType.mono(infl > 0 ? k.critical : k.low, 12.5))),
          if (canOpen) Icon(Icons.chevron_right, size: 16, color: k.faint),
        ]),
      ),
    );
  }
}

class PeersPanel extends StatelessWidget {
  final Report r;
  const PeersPanel(this.r, {super.key});
  @override
  Widget build(BuildContext context) {
    final p = r.peers;
    if (p == null) return const SizedBox();
    final k = context.k;
    return Panel(
      title: context.t('peers'),
      subtitle: '${p['industry']} · ${p['peer_count']} ${context.t('companies')}',
      trailing: Text('#${p['risk_rank']} / ${p['peer_count']}', style: KType.mono(k.muted, 12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(width: 10, height: 4, color: k.accent), const SizedBox(width: 6),
          Text(context.t('company'), style: context.tt.bodySmall), const SizedBox(width: 14),
          Container(width: 10, height: 4, color: k.faint), const SizedBox(width: 6),
          Text(context.t('median'), style: context.tt.bodySmall),
        ]),
        const SizedBox(height: 8),
        PeerBars(company: Json.from(p['company']), median: Json.from(p['industry_median'])),
      ]),
    );
  }
}

class RatioGrid extends StatelessWidget {
  final Json ratios;
  const RatioGrid(this.ratios, {super.key});
  static const groups = {
    'liquidity': ['current_ratio', 'quick_ratio', 'cash_ratio', 'working_capital_to_assets'],
    'leverage': ['debt_to_equity', 'debt_to_assets', 'interest_coverage', 'net_debt_to_ebitda'],
    'profitability': ['ebitda_margin', 'net_margin', 'return_on_assets', 'return_on_equity'],
    'cash_flow': ['ocf_to_debt', 'fcf_margin', 'cash_burn_months'],
    'growth': ['revenue_growth_yoy', 'revenue_cagr_3y', 'margin_trend', 'promoter_pledge'],
  };

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth > 1000 ? 5 : c.maxWidth > 640 ? 3 : 2;
      final w = (c.maxWidth - (cols - 1) * 12) / cols;
      return Wrap(spacing: 12, runSpacing: 12, children: [
        for (final g in groups.entries)
          SizedBox(
            width: w,
            child: Panel(
              title: context.t(g.key),
              padding: const EdgeInsets.all(14),
              child: Column(children: [
                for (final f in g.value)
                  if (ratios[f] != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(children: [
                        Expanded(child: Text(context.t(f), style: TextStyle(fontSize: 12.5, color: k.muted))),
                        Text(fmtRatio(f, ratios[f]), style: KType.mono(k.text, 12.5)),
                      ]),
                    ),
              ]),
            ),
          ),
      ]);
    });
  }
}
