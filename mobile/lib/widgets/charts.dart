import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../theme/app_theme.dart';
import 'kit.dart';

// =================================================================== gauge
/// Semicircular PD gauge on a log scale (0.1% .. 100%) with band segments.
class PdGauge extends StatelessWidget {
  final double pd;
  final String rating;
  final double size;
  const PdGauge({super.key, required this.pd, required this.rating, this.size = 240});

  static double pos(double pd) {
    final v = (math.log(pd.clamp(0.001, 1.0)) - math.log(0.001)) / (math.log(1.0) - math.log(0.001));
    return v.clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.001, end: pd),
      duration: const Duration(milliseconds: 1100),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => SizedBox(
        width: size,
        height: size * 0.66,
        child: CustomPaint(
          painter: _GaugePainter(v, k),
          child: Align(
            alignment: const Alignment(0, 0.72),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(fmtPd(v), style: KType.mono(k.forPd(v), size * 0.15, w: FontWeight.w600)),
              const SizedBox(height: 4),
              RatingBadge(rating, size: size * 0.05),
            ]),
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double pd;
  final KColors k;
  _GaugePainter(this.pd, this.k);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * 0.92);
    final r = size.width * 0.44;
    const start = math.pi * 1.0, sweep = math.pi;
    final rect = Rect.fromCircle(center: c, radius: r);
    final segs = [(0.0, 0.03, k.low), (0.03, 0.10, k.moderate), (0.10, 0.30, k.high), (0.30, 1.0, k.critical)];
    for (final s in segs) {
      final a0 = PdGauge.pos(math.max(s.$1, 0.001)), a1 = PdGauge.pos(s.$2);
      canvas.drawArc(rect, start + sweep * a0, sweep * (a1 - a0) - 0.012, false,
          Paint()..style = PaintingStyle.stroke..strokeWidth = 10..color = s.$3.withValues(alpha: 0.22));
    }
    final p = PdGauge.pos(pd);
    canvas.drawArc(rect, start, sweep * p, false,
        Paint()..style = PaintingStyle.stroke..strokeWidth = 10..strokeCap = StrokeCap.butt..color = k.forPd(pd));
    // ticks
    for (final t in [0.001, 0.01, 0.03, 0.1, 0.3, 1.0]) {
      final a = start + sweep * PdGauge.pos(t);
      final o = c + Offset(math.cos(a), math.sin(a)) * (r + 12);
      final i = c + Offset(math.cos(a), math.sin(a)) * (r + 6);
      canvas.drawLine(i, o, Paint()..color = k.faint..strokeWidth = 1);
      final tp = TextPainter(text: TextSpan(text: t >= 0.01 ? '${(t * 100).round()}%' : '0.1%', style: KType.mono(k.faint, 9)),
          textDirection: TextDirection.ltr)..layout();
      final lp = c + Offset(math.cos(a), math.sin(a)) * (r + 22);
      tp.paint(canvas, lp - Offset(tp.width / 2, tp.height / 2));
    }
    // needle
    final a = start + sweep * p;
    final tip = c + Offset(math.cos(a), math.sin(a)) * (r - 16);
    canvas.drawLine(c + Offset(math.cos(a), math.sin(a)) * (r - 40), tip, Paint()..color = k.text..strokeWidth = 2);
    canvas.drawCircle(tip, 3, Paint()..color = k.text);
  }

  @override
  bool shouldRepaint(_GaugePainter old) => old.pd != pd;
}

// ============================================================ shared axes
FlTitlesData _titles(BuildContext context, {required Widget Function(double, TitleMeta) bottom,
    required Widget Function(double, TitleMeta) left, double leftSize = 44, double? bottomInterval, double? leftInterval}) {
  return FlTitlesData(
    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 26, interval: bottomInterval,
        getTitlesWidget: (v, m) => SideTitleWidget(meta: m, child: bottom(v, m)))),
    leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: leftSize, interval: leftInterval,
        getTitlesWidget: (v, m) {
          // the axis max is rarely a round number and collides with the tick below it
          if (v == m.max && (m.max - m.min) / m.appliedInterval % 1 > 0.01) return const SizedBox();
          return SideTitleWidget(meta: m, child: left(v, m));
        })),
  );
}

FlGridData _grid(KColors k, {bool vertical = false}) => FlGridData(
      show: true, drawVerticalLine: vertical,
      getDrawingHorizontalLine: (_) => FlLine(color: k.line, strokeWidth: 1, dashArray: [3, 4]),
      getDrawingVerticalLine: (_) => FlLine(color: k.line, strokeWidth: 1, dashArray: [3, 4]),
    );

Text _axis(KColors k, String s) => Text(s == '0.00%' ? '0' : s, style: KType.mono(k.faint, 10));

// ======================================================== term structure
class TermStructureChart extends StatelessWidget {
  final Map<String, dynamic> horizons; // {"3m": .., "6m": .., "12m": .., "24m": ..}
  final Map<String, dynamic>? compare; // optional scenario curve
  const TermStructureChart({super.key, required this.horizons, this.compare});

  List<FlSpot> _spots(Map<String, dynamic> h) => [
        const FlSpot(0, 0),
        for (final e in h.entries) FlSpot(double.parse(e.key.replaceAll('m', '')), (e.value as num).toDouble()),
      ];

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final spots = _spots(horizons);
    final maxY = [...spots, if (compare != null) ..._spots(compare!)].map((s) => s.y).reduce(math.max);
    final col = k.forPd((horizons['12m'] as num).toDouble());
    return SizedBox(
      height: 200,
      child: LineChart(LineChartData(
        minX: 0, maxX: 24, minY: 0, maxY: (maxY * 1.18).clamp(0.01, 1.0),
        gridData: _grid(k),
        borderData: FlBorderData(show: false),
        titlesData: _titles(context,
            bottomInterval: 3,
            bottom: (v, _) => [3, 6, 12, 24].contains(v.round()) ? _axis(k, '${v.round()}m') : const SizedBox(),
            left: (v, _) => _axis(k, fmtPd(v))),
        lineTouchData: LineTouchData(touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => k.raised,
          getTooltipItems: (spots) => [
            for (final s in spots)
              LineTooltipItem('${s.x.round()}m  ${fmtPd(s.y)}', KType.mono(s.bar.color ?? k.text, 12)),
          ],
        )),
        lineBarsData: [
          if (compare != null)
            LineChartBarData(spots: _spots(compare!), isCurved: true, color: k.critical, barWidth: 1.6, dashArray: [5, 4],
                dotData: const FlDotData(show: false)),
          LineChartBarData(
            spots: spots, isCurved: true, curveSmoothness: 0.25, color: col, barWidth: 2.2,
            dotData: FlDotData(show: true, getDotPainter: (s, _, __, ___) =>
                FlDotCirclePainter(radius: s.x == 0 ? 0 : 3.2, color: k.bg, strokeColor: col, strokeWidth: 2)),
            belowBarData: BarAreaData(show: true, gradient: LinearGradient(
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: [col.withValues(alpha: 0.25), col.withValues(alpha: 0.0)])),
          ),
        ],
      )),
    );
  }
}

// ================================================================ radar
class HealthRadar extends StatelessWidget {
  final Map<String, dynamic> components; // liquidity, leverage, profitability, cash_flow, growth -> 0..100
  const HealthRadar({super.key, required this.components});

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final keys = ['liquidity', 'leverage', 'profitability', 'cash_flow', 'growth'];
    final vals = [for (final key in keys) ((components[key] ?? 0) as num).toDouble()];
    return SizedBox(
      height: 230,
      child: RadarChart(RadarChartData(
        radarShape: RadarShape.polygon,
        tickCount: 4,
        ticksTextStyle: const TextStyle(color: Colors.transparent, fontSize: 1),
        radarBorderData: BorderSide(color: k.lineStrong),
        gridBorderData: BorderSide(color: k.line),
        tickBorderData: BorderSide(color: k.line),
        titlePositionPercentageOffset: 0.16,
        titleTextStyle: TextStyle(color: k.muted, fontSize: 11.5),
        getTitle: (i, _) => RadarChartTitle(text: '${context.t(keys[i])}  ${vals[i].round()}'),
        dataSets: [
          RadarDataSet(dataEntries: [for (final _ in keys) const RadarEntry(value: 100)],
              fillColor: Colors.transparent, borderColor: Colors.transparent, entryRadius: 0, borderWidth: 0),
          RadarDataSet(dataEntries: [for (final _ in keys) const RadarEntry(value: 0)],
              fillColor: Colors.transparent, borderColor: Colors.transparent, entryRadius: 0, borderWidth: 0),
          RadarDataSet(dataEntries: [for (final v in vals) RadarEntry(value: v)],
              fillColor: k.accent.withValues(alpha: 0.18), borderColor: k.accent, borderWidth: 2, entryRadius: 3),
        ],
      )),
    );
  }
}

// ========================================================= driver bars
/// Diverging contribution bars: right = raises risk, left = lowers risk.
class DriverBars extends StatefulWidget {
  final List<Map<String, dynamic>> rows; // {label, value (log-odds), detail}
  const DriverBars({super.key, required this.rows});
  @override
  State<DriverBars> createState() => _DriverBarsState();
}

class _DriverBarsState extends State<DriverBars> {
  int? _hover;
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final maxAbs = widget.rows.fold<double>(0.05, (m, r) => math.max(m, (r['value'] as num).abs().toDouble()));
    return Column(children: [
      for (var i = 0; i < widget.rows.length; i++)
        MouseRegion(
          onEnter: (_) => setState(() => _hover = i),
          onExit: (_) => setState(() => _hover = null),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
            color: _hover == i ? k.raised : Colors.transparent,
            child: Row(children: [
              SizedBox(width: 168, child: Text(widget.rows[i]['label'], maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: k.text))),
              Expanded(child: LayoutBuilder(builder: (context, c) {
                final v = (widget.rows[i]['value'] as num).toDouble();
                final half = c.maxWidth / 2;
                final w = half * (v.abs() / maxAbs);
                final col = v > 0 ? k.critical : k.low;
                return SizedBox(height: 16, child: Stack(children: [
                  Positioned(left: half - 0.5, top: 0, bottom: 0, child: Container(width: 1, color: k.lineStrong)),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: w), duration: Duration(milliseconds: 500 + i * 60), curve: Curves.easeOutCubic,
                    builder: (context, ww, _) => Positioned(
                      left: v > 0 ? half : half - ww, top: 3, bottom: 3,
                      child: Container(width: ww, decoration: BoxDecoration(color: col.withValues(alpha: _hover == i ? 1 : 0.8),
                          borderRadius: BorderRadius.circular(1.5))),
                    ),
                  ),
                ]));
              })),
              SizedBox(width: 92, child: Text(widget.rows[i]['detail'] ?? '', textAlign: TextAlign.end,
                  style: KType.mono(k.muted, 11.5))),
            ]),
          ),
        ),
    ]);
  }
}

// ============================================================ histogram
class PdHistogram extends StatelessWidget {
  final List<Map<String, dynamic>> bins; // {lo, hi, count}
  const PdHistogram({super.key, required this.bins});

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final maxC = bins.map((b) => (b['count'] as num).toDouble()).reduce(math.max);
    return SizedBox(
      height: 210,
      child: BarChart(BarChartData(
        maxY: maxC * 1.15,
        alignment: BarChartAlignment.spaceBetween,
        gridData: _grid(k),
        borderData: FlBorderData(show: false),
        titlesData: _titles(context, leftSize: 34,
            bottom: (v, _) {
              final i = v.round();
              if (i % 2 != 0 || i >= bins.length) return const SizedBox();
              return _axis(k, fmtPd(bins[i]['lo']));
            },
            left: (v, _) => _axis(k, v.round().toString())),
        barTouchData: BarTouchData(touchTooltipData: BarTouchTooltipData(
          getTooltipColor: (_) => k.raised,
          getTooltipItem: (g, _, r, __) => BarTooltipItem(
              '${fmtPd(bins[g.x]['lo'])} – ${fmtPd(bins[g.x]['hi'])}\n${bins[g.x]['count']} ${context.tr('companies')}',
              KType.mono(k.text, 11.5)),
        )),
        barGroups: [
          for (var i = 0; i < bins.length; i++)
            BarChartGroupData(x: i, barRods: [
              BarChartRodData(
                toY: (bins[i]['count'] as num).toDouble(),
                width: 14,
                color: k.forPd(((bins[i]['lo'] as num) + (bins[i]['hi'] as num)).toDouble() / 2),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
              ),
            ]),
        ],
      )),
    );
  }
}

// ============================================================== scatter
/// Debt/equity (x) against interest cover (y, signed-log), coloured by PD.
class LeverageScatter extends StatefulWidget {
  final List<Map<String, dynamic>> points;
  final void Function(String id, String name) onOpen;
  final String? highlightSector;
  const LeverageScatter({super.key, required this.points, required this.onOpen, this.highlightSector});
  @override
  State<LeverageScatter> createState() => _LeverageScatterState();
}

class _LeverageScatterState extends State<LeverageScatter> {
  static double _y(double icr) => icr.sign * math.log(1 + icr.abs());
  static double _x(double de) => math.log(1 + de.clamp(0.0, 15.0));
  static double _xInv(double x) => math.exp(x) - 1;

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final pts = widget.points;
    return SizedBox(
      height: 320,
      child: ScatterChart(ScatterChartData(
        minX: 0, maxX: _x(15), minY: _y(-2), maxY: _y(50),
        gridData: _grid(k, vertical: true),
        borderData: FlBorderData(show: false),
        titlesData: _titles(context, leftSize: 38, bottomInterval: _x(15) / 6,
            bottom: (v, _) {
              final de = _xInv(v);
              return _axis(k, '${de.toStringAsFixed(de < 1 ? 1 : 0)}×');
            },
            left: (v, _) {
              final icr = (math.exp(v.abs()) - 1) * v.sign;
              return _axis(k, '${icr.toStringAsFixed(icr.abs() < 10 ? 1 : 0)}×');
            }),
        scatterSpots: [
          for (final p in pts)
            ScatterSpot(
              _x((p['de'] as num).toDouble()),
              _y(((p['icr'] as num).toDouble()).clamp(-2.0, 50.0)),
              dotPainter: FlDotCirclePainter(
                radius: 1.6 + math.sqrt(((p['revenue'] as num).toDouble()) / 3000).clamp(0.0, 4.0),
                color: k.forPd((p['pd'] as num).toDouble()).withValues(
                    alpha: widget.highlightSector == null || widget.highlightSector == p['industry'] ? 0.85 : 0.08),
              ),
            ),
        ],
        scatterTouchData: ScatterTouchData(
          enabled: true,
          handleBuiltInTouches: true,
          touchTooltipData: ScatterTouchTooltipData(
            getTooltipColor: (_) => k.raised,
            getTooltipItems: (s) {
              final i = pts.indexWhere((p) =>
                  _x((p['de'] as num).toDouble()) == s.x &&
                  _y(((p['icr'] as num).toDouble()).clamp(-2.0, 50.0)) == s.y);
              if (i < 0) return null;
              final p = pts[i];
              return ScatterTooltipItem('${p['name']}\nPD ${fmtPd(p['pd'])} · D/E ${(p['de'] as num).toStringAsFixed(2)}',
                  textStyle: KType.mono(k.text, 11));
            },
          ),
          touchCallback: (e, r) {
            if (e is FlTapUpEvent && r?.touchedSpot != null) {
              final p = pts[r!.touchedSpot!.spotIndex];
              widget.onOpen(p['id'], p['name']);
            }
          },
        ),
      )),
    );
  }
}

// ============================================================ timeline
class RiskTimeline extends StatelessWidget {
  final List<Map<String, dynamic>> points; // {year, risk}
  final double height;
  const RiskTimeline({super.key, required this.points, this.height = 150});

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final spots = [for (final p in points) FlSpot((p['year'] as num).toDouble(), (p['risk'] as num).toDouble())];
    final maxY = spots.map((s) => s.y).reduce(math.max);
    final col = k.forPd(spots.last.y);
    return SizedBox(
      height: height,
      child: LineChart(LineChartData(
        minY: 0, maxY: (maxY * 1.25).clamp(0.01, 1.0),
        gridData: _grid(k),
        borderData: FlBorderData(show: false),
        titlesData: _titles(context, bottomInterval: 1, bottom: (v, _) => _axis(k, 'FY${(v.round() % 100)}'),
            left: (v, _) => _axis(k, fmtPd(v))),
        lineTouchData: LineTouchData(touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => k.raised,
          getTooltipItems: (ss) => [for (final s in ss) LineTooltipItem('FY${s.x.round() % 100}  ${fmtPd(s.y)}', KType.mono(k.text, 12))],
        )),
        lineBarsData: [
          LineChartBarData(spots: spots, color: col, barWidth: 2, isCurved: false,
              dotData: FlDotData(getDotPainter: (s, _, __, ___) =>
                  FlDotCirclePainter(radius: 3, color: k.forPd(s.y), strokeWidth: 0)),
              belowBarData: BarAreaData(show: true, color: col.withValues(alpha: 0.08))),
        ],
      )),
    );
  }
}

// ========================================================== sweep curve
class SweepChart extends StatelessWidget {
  final List<Map<String, dynamic>> points; // {x, risk}
  final double marker;
  final String Function(double) fmtX;
  const SweepChart({super.key, required this.points, required this.marker, required this.fmtX});

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final spots = [for (final p in points) FlSpot((p['x'] as num).toDouble(), (p['risk'] as num).toDouble())];
    final maxY = spots.map((s) => s.y).reduce(math.max);
    return SizedBox(
      height: 170,
      child: LineChart(LineChartData(
        minY: 0, maxY: (maxY * 1.15).clamp(0.01, 1.0),
        gridData: _grid(k),
        borderData: FlBorderData(show: false),
        extraLinesData: ExtraLinesData(verticalLines: [
          VerticalLine(x: marker, color: k.accent, strokeWidth: 1.4, dashArray: [4, 3]),
        ]),
        titlesData: _titles(context, bottomInterval: (spots.last.x - spots.first.x) / 4,
            bottom: (v, m) => _axis(k, fmtX(v)), left: (v, _) => _axis(k, fmtPd(v))),
        lineTouchData: LineTouchData(touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => k.raised,
          getTooltipItems: (ss) => [for (final s in ss) LineTooltipItem('${fmtX(s.x)} → ${fmtPd(s.y)}', KType.mono(k.text, 12))],
        )),
        lineBarsData: [
          LineChartBarData(spots: spots, isCurved: true, barWidth: 2, dotData: const FlDotData(show: false),
              gradient: LinearGradient(colors: [for (final s in spots) k.forPd(s.y)]),
              belowBarData: BarAreaData(show: true, color: k.accent.withValues(alpha: 0.05))),
        ],
      )),
    );
  }
}

// ========================================================= sector donut
class SectorDonut extends StatelessWidget {
  final List<Map<String, dynamic>> sectors; // {industry, weight}
  const SectorDonut({super.key, required this.sectors});
  static const _palette = [0xFF8C9BFF, 0xFF41D69B, 0xFFE4C452, 0xFFFF8B45, 0xFFB98CFF, 0xFF5CC8E8, 0xFFFF7FAF, 0xFFA3B18A];

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return Row(children: [
      SizedBox(
        width: 150, height: 150,
        child: PieChart(PieChartData(
          centerSpaceRadius: 46, sectionsSpace: 2,
          sections: [
            for (var i = 0; i < sectors.length; i++)
              PieChartSectionData(value: (sectors[i]['weight'] as num).toDouble(), color: Color(_palette[i % _palette.length]),
                  radius: 22, showTitle: false),
          ],
        )),
      ),
      const SizedBox(width: 18),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < sectors.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Container(width: 8, height: 8, color: Color(_palette[i % _palette.length])),
              const SizedBox(width: 8),
              Expanded(child: Text(sectors[i]['industry'], style: const TextStyle(fontSize: 12.5), overflow: TextOverflow.ellipsis)),
              Text('${((sectors[i]['weight'] as num) * 100).toStringAsFixed(0)}%', style: KType.mono(k.muted, 12)),
            ]),
          ),
      ])),
    ]);
  }
}

// ============================================================= treemap
/// Squarified treemap of sectors: area = revenue, colour = average PD.
class SectorTreemap extends StatefulWidget {
  final List<Map<String, dynamic>> sectors;
  final void Function(String sector)? onTap;
  const SectorTreemap({super.key, required this.sectors, this.onTap});
  @override
  State<SectorTreemap> createState() => _SectorTreemapState();
}

class _SectorTreemapState extends State<SectorTreemap> {
  String? _hover;

  List<(Rect, Map<String, dynamic>)> _layout(Size size) {
    final items = [...widget.sectors]..sort((a, b) => (b['revenue_cr'] as num).compareTo(a['revenue_cr'] as num));
    final total = items.fold<double>(0, (s, e) => s + (e['revenue_cr'] as num).toDouble());
    final out = <(Rect, Map<String, dynamic>)>[];
    var rect = Offset.zero & size;
    var rest = List.of(items);
    var restTotal = total;
    while (rest.isNotEmpty) {
      final horizontal = rect.width >= rect.height;
      final side = horizontal ? rect.height : rect.width;
      var row = <Map<String, dynamic>>[];
      double worst(List<Map<String, dynamic>> r) {
        final s = r.fold<double>(0, (a, e) => a + (e['revenue_cr'] as num).toDouble()) / restTotal * rect.width * rect.height;
        final mx = r.map((e) => (e['revenue_cr'] as num).toDouble() / restTotal * rect.width * rect.height).reduce(math.max);
        final mn = r.map((e) => (e['revenue_cr'] as num).toDouble() / restTotal * rect.width * rect.height).reduce(math.min);
        return math.max(side * side * mx / (s * s), (s * s) / (side * side * mn));
      }
      for (final e in rest) {
        final cand = [...row, e];
        if (row.isEmpty || worst(cand) <= worst(row)) {
          row = cand;
        } else {
          break;
        }
      }
      final rowSum = row.fold<double>(0, (a, e) => a + (e['revenue_cr'] as num).toDouble());
      final frac = rowSum / restTotal;
      final thick = (horizontal ? rect.width : rect.height) * frac;
      var off = 0.0;
      for (final e in row) {
        final len = side * (e['revenue_cr'] as num).toDouble() / rowSum;
        out.add((horizontal
            ? Rect.fromLTWH(rect.left, rect.top + off, thick, len)
            : Rect.fromLTWH(rect.left + off, rect.top, len, thick), e));
        off += len;
      }
      rect = horizontal
          ? Rect.fromLTWH(rect.left + thick, rect.top, rect.width - thick, rect.height)
          : Rect.fromLTWH(rect.left, rect.top + thick, rect.width, rect.height - thick);
      rest = rest.sublist(row.length);
      restTotal -= rowSum;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return SizedBox(
      height: 300,
      child: LayoutBuilder(builder: (context, c) {
        final tiles = _layout(Size(c.maxWidth, 300));
        return Stack(children: [
          for (final (r, s) in tiles)
            Positioned.fromRect(
              rect: r.deflate(1.5),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _hover = s['industry']),
                onExit: (_) => setState(() => _hover = null),
                child: GestureDetector(
                  onTap: () => widget.onTap?.call(s['industry']),
                  child: Tooltip(
                    message: '${s['industry']}\nPD ${fmtPd(s['avg_pd'])} · ${s['count']} ${context.t('companies')}\n'
                        'D/E ${s['median_de']}× · ICR ${s['median_icr']}×',
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Color.alphaBlend(
                            k.forPd((s['avg_pd'] as num).toDouble()).withValues(alpha: _hover == s['industry'] ? 0.22 : 0.12), k.raised),
                        border: Border(top: BorderSide(color: k.forPd((s['avg_pd'] as num).toDouble()), width: 2)),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: r.width > 70 && r.height > 44
                          ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(s['industry'], maxLines: 2, overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: k.text)),
                              const Spacer(),
                              if (r.height > 64) Text(fmtPd(s['avg_pd']),
                                  style: KType.mono(k.forPd((s['avg_pd'] as num).toDouble()), 16, w: FontWeight.w600)),
                              if (r.height > 84) DeltaText((s['pd_change'] as num).toDouble(), size: 10.5),
                            ])
                          : const SizedBox(),
                    ),
                  ),
                ),
              ),
            ),
        ]);
      }),
    );
  }
}

// ============================================================ peer bars
class PeerBars extends StatelessWidget {
  final Map<String, dynamic> company, median;
  const PeerBars({super.key, required this.company, required this.median});

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final keys = company.keys.where((x) => x != 'risk').toList();
    return Column(children: [
      for (final key in keys)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(children: [
            SizedBox(width: 150, child: Text(context.t(key), style: const TextStyle(fontSize: 13))),
            Expanded(child: LayoutBuilder(builder: (context, c) {
              final a = (company[key] as num).toDouble(), b = (median[key] as num).toDouble();
              final m = math.max(a.abs(), b.abs()) * 1.1 + 1e-9;
              return Column(children: [
                _bar(c.maxWidth * a.abs() / m, k.accent, 6),
                const SizedBox(height: 3),
                _bar(c.maxWidth * b.abs() / m, k.faint, 4),
              ]);
            })),
            SizedBox(width: 132, child: Text('${fmtRatio(key, company[key])}  ·  ${fmtRatio(key, median[key])}',
                textAlign: TextAlign.end, style: KType.mono(k.muted, 11))),
          ]),
        ),
    ]);
  }

  Widget _bar(double w, Color c, double h) => Align(
        alignment: AlignmentDirectional.centerStart,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: w), duration: const Duration(milliseconds: 600), curve: Curves.easeOutCubic,
          builder: (_, v, __) => Container(width: v, height: h, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(1))),
        ),
      );
}

// ============================================================ sparkline
class Sparkline extends StatelessWidget {
  final List<double> values;
  final double width, height;
  const Sparkline(this.values, {super.key, this.width = 72, this.height = 22});
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    if (values.length < 2) return SizedBox(width: width, height: height);
    return SizedBox(width: width, height: height, child: CustomPaint(painter: _SparkPainter(values, k)));
  }
}

class _SparkPainter extends CustomPainter {
  final List<double> v;
  final KColors k;
  _SparkPainter(this.v, this.k);
  @override
  void paint(Canvas canvas, Size s) {
    final mx = v.reduce(math.max), mn = v.reduce(math.min);
    final span = (mx - mn).abs() < 1e-9 ? 1.0 : mx - mn;
    final path = Path();
    for (var i = 0; i < v.length; i++) {
      final p = Offset(s.width * i / (v.length - 1), s.height - 2 - (s.height - 4) * (v[i] - mn) / span);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    final up = v.last > v.first;
    canvas.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.6..color = up ? k.critical : k.low);
    canvas.drawCircle(Offset(s.width, s.height - 2 - (s.height - 4) * (v.last - mn) / span), 2.2,
        Paint()..color = up ? k.critical : k.low);
  }

  @override
  bool shouldRepaint(_SparkPainter o) => o.v != v;
}

// ======================================================= compare chart
/// PD by fiscal year for several companies, with each company's model range shaded.
class CompareTimeline extends StatelessWidget {
  final Map<String, List<Map<String, dynamic>>> series; // name -> [{year, risk, low, high}]
  const CompareTimeline({super.key, required this.series});
  static const palette = [0xFF8C9BFF, 0xFF41D69B, 0xFFE4C452, 0xFFFF8B45];

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final names = series.keys.toList();
    final all = series.values.expand((s) => s).toList();
    if (all.isEmpty) return const SizedBox();
    final maxY = all.map((p) => ((p['high'] ?? p['risk']) as num).toDouble()).reduce(math.max);
    final years = all.map((p) => (p['year'] as num).toDouble());
    final bars = <LineChartBarData>[];
    for (var i = 0; i < names.length; i++) {
      final c = Color(palette[i % palette.length]);
      final pts = series[names[i]]!;
      bars.add(LineChartBarData(
        spots: [for (final p in pts) FlSpot((p['year'] as num).toDouble(), (p['risk'] as num).toDouble())],
        color: c, barWidth: 2.2, isCurved: false,
        dotData: FlDotData(getDotPainter: (s, _, __, ___) => FlDotCirclePainter(radius: 3, color: c, strokeWidth: 0)),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        height: 220,
        child: LineChart(LineChartData(
          minX: years.reduce(math.min) - 0.2, maxX: years.reduce(math.max) + 0.2,
          minY: 0, maxY: (maxY * 1.2).clamp(0.01, 1.0),
          gridData: _grid(k),
          borderData: FlBorderData(show: false),
          titlesData: _titles(context, bottomInterval: 1, bottom: (v, _) => v == v.roundToDouble() ? _axis(k, 'FY${v.round() % 100}') : const SizedBox(),
              left: (v, _) => _axis(k, fmtPd(v))),
          lineTouchData: LineTouchData(touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => k.raised,
            getTooltipItems: (ss) => [for (final s in ss) LineTooltipItem('${names[s.barIndex]}  ${fmtPd(s.y)}', KType.mono(s.bar.color ?? k.text, 11.5))],
          )),
          lineBarsData: bars,
        )),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 14, children: [
        for (var i = 0; i < names.length; i++)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 10, height: 3, color: Color(palette[i % palette.length])),
            const SizedBox(width: 6),
            Text(names[i], style: TextStyle(fontSize: 12, color: k.muted)),
          ]),
      ]),
    ]);
  }
}
