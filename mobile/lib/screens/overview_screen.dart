import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/charts.dart';
import '../widgets/kit.dart';
import 'company_screen.dart';

class OverviewScreen extends StatefulWidget {
  const OverviewScreen({super.key});
  @override
  State<OverviewScreen> createState() => _OverviewScreenState();
}

class _OverviewScreenState extends State<OverviewScreen> {
  late Future<Json> _f = context.read<AppState>().api.overview();
  String? _sector;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 48),
      child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: Async<Json>(
          future: _f,
          onRetry: () => setState(() => _f = context.read<AppState>().api.overview()),
          builder: (context, d) => _content(context, d),
        ),
      )),
    );
  }

  Widget _content(BuildContext context, Json d) {
    final k = context.k;
    final u = Json.from(d['universe']);
    final trend = (d['trend'] as List).map((e) => Json.from(e)).toList();
    final prevMean = trend.length > 1 ? (trend[trend.length - 2]['avg_pd'] as num).toDouble() : null;
    final sectors = (d['sectors'] as List).map((e) => Json.from(e)).toList();
    final scatter = (d['scatter'] as List).map((e) => Json.from(e)).toList();
    final bands = Json.from(d['band_counts']);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(
        eyebrow: 'FY${u['fiscal_year']} · ${u['companies']} ${context.t('companies')} · ${u['sectors']} ${context.t('statSectors')}',
        title: context.t('overviewTitle'),
      ),
      KpiStrip([
        Kpi(label: context.t('expectedDefaults'), value: '${(d['expected_defaults'] as num).round()}',
            hint: '${context.t('companies')}: ${u['companies']}'),
        Kpi(label: context.t('meanPd'), value: fmtPd(d['mean_pd']), valueColor: k.forPd((d['mean_pd'] as num).toDouble()),
            delta: prevMean == null ? null : '${(d['mean_pd'] as num) >= prevMean ? '▲' : '▼'} ${fmtPp((d['mean_pd'] as num) - prevMean)} ${context.t('vsLastYear')}',
            deltaColor: prevMean != null && (d['mean_pd'] as num) > prevMean ? k.critical : k.low),
        Kpi(label: context.t('debtWeightedPd'), value: fmtPd(d['debt_weighted_pd']), valueColor: k.forPd((d['debt_weighted_pd'] as num).toDouble())),
        Kpi(label: context.t('debtCovered'), value: fmtCr(u['debt_cr']), hint: '${u['relationships']} ${context.t('statLinks')}'),
      ]),
      const SizedBox(height: 16),
      Cols([
        Panel(
          title: context.t('sectorMap'),
          trailing: _sector == null ? null : TextButton(onPressed: () => setState(() => _sector = null), child: Text(context.t('all'))),
          child: SectorTreemap(sectors: sectors, onTap: (s) => setState(() => _sector = _sector == s ? null : s)),
        ),
        Panel(
          title: context.t('pdDistribution'),
          child: Column(children: [
            PdHistogram(bins: (d['pd_histogram'] as List).map((e) => Json.from(e)).toList()),
            const SizedBox(height: 14),
            _BandBar(bands),
          ]),
        ),
      ], flex: const [6, 5]),
      const SizedBox(height: 16),
      Panel(
        title: context.t('leverageVsCoverage'),
        subtitle: '${_sector ?? context.t('all')} · ${context.t('tapToOpen')}',
        trailing: Wrap(spacing: 4, children: [
          for (final b in ['LOW', 'MODERATE', 'HIGH', 'CRITICAL'])
            Padding(padding: const EdgeInsets.only(left: 8), child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 7, height: 7, decoration: BoxDecoration(color: k.band(b), shape: BoxShape.circle)),
              const SizedBox(width: 4),
              Text(context.t('band$b'), style: context.tt.bodySmall),
            ])),
        ]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          LeverageScatter(points: scatter, highlightSector: _sector, onOpen: (id, name) => openCompany(context, id, name)),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Text('↑ ${context.t('interest_coverage')}', style: context.tt.bodySmall),
              const Spacer(),
              Text('${context.t('debt_to_equity')} →', style: context.tt.bodySmall),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      Cols([
        _CompanyList(title: context.t('topRisk'), rows: (d['top_risk'] as List).map((e) => Json.from(e)).toList()),
        _CompanyList(title: context.t('movers'), rows: (d['movers'] as List).map((e) => Json.from(e)).toList(), showDelta: true),
        Panel(title: context.t('universeTrend'), child: _TrendBars(trend)),
      ], breakpoint: 1000),
    ]);
  }
}

class _BandBar extends StatelessWidget {
  final Json bands;
  const _BandBar(this.bands);
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final total = bands.values.fold<num>(0, (a, b) => a + (b as num));
    return Column(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: Row(children: [
          for (final b in ['LOW', 'MODERATE', 'HIGH', 'CRITICAL'])
            Expanded(flex: ((bands[b] as num) * 1000 / total).round().clamp(1, 1000),
                child: Container(height: 8, color: k.band(b))),
        ]),
      ),
      const SizedBox(height: 10),
      Row(children: [
        for (final b in ['LOW', 'MODERATE', 'HIGH', 'CRITICAL'])
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(context.t('band$b'), style: context.tt.bodySmall),
            Text('${bands[b]}', style: KType.mono(k.band(b), 15, w: FontWeight.w600)),
          ])),
      ]),
    ]);
  }
}

class _CompanyList extends StatelessWidget {
  final String title;
  final List<Json> rows;
  final bool showDelta;
  const _CompanyList({required this.title, required this.rows, this.showDelta = false});
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return Panel(
      title: title,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
      child: Column(children: [
        for (final c in rows)
          InkWell(
            onTap: () => openCompany(context, c['company_id'], c['name']),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text((c['name'] as String).replaceAll(' Ltd', ''), maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5)),
                  Text(c['industry'], style: context.tt.bodySmall?.copyWith(fontSize: 11.5)),
                ])),
                if (showDelta)
                  DeltaText((c['distress_probability'] as num).toDouble() - (c['previous_probability'] as num).toDouble(), size: 11.5)
                else
                  RatingBadge(c['implied_rating'], size: 11),
                const SizedBox(width: 12),
                SizedBox(width: 50, child: Text(fmtPd(c['distress_probability']), textAlign: TextAlign.end,
                    style: KType.mono(k.forPd((c['distress_probability'] as num).toDouble()), 12.5))),
              ]),
            ),
          ),
      ]),
    );
  }
}

class _TrendBars extends StatelessWidget {
  final List<Json> trend;
  const _TrendBars(this.trend);
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return SizedBox(
      height: 260,
      child: BarChart(BarChartData(
        maxY: trend.map((t) => (t['high_share'] as num).toDouble()).reduce((a, b) => a > b ? a : b) * 1.3,
        gridData: FlGridData(drawVerticalLine: false, getDrawingHorizontalLine: (_) => FlLine(color: k.line, dashArray: [3, 4])),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(), rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 36,
              getTitlesWidget: (v, m) => SideTitleWidget(meta: m, child: Text('${(v * 100).round()}%', style: KType.mono(k.faint, 10))))),
          bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true,
              getTitlesWidget: (v, m) => SideTitleWidget(meta: m, child: Text('FY${v.round() % 100}', style: KType.mono(k.faint, 10))))),
        ),
        barTouchData: BarTouchData(touchTooltipData: BarTouchTooltipData(
          getTooltipColor: (_) => k.raised,
          getTooltipItem: (g, _, r, __) => BarTooltipItem('${(r.toY * 100).toStringAsFixed(1)}%', KType.mono(k.text, 12)),
        )),
        barGroups: [
          for (final t in trend)
            BarChartGroupData(x: t['year'] as int, barRods: [
              BarChartRodData(toY: (t['high_share'] as num).toDouble(), width: 22, color: k.high.withValues(alpha: 0.85),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(2))),
            ]),
        ],
      )),
    );
  }
}
