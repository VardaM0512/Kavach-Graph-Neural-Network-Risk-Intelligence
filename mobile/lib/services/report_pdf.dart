import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'api_client.dart';

/// One-company credit report as a PDF (downloaded on web, shared on mobile).
///
/// Text is English and amounts use "INR" because the built-in PDF fonts carry
/// neither the rupee sign nor Indic scripts.
Future<void> exportCompanyPdf(Json r) async {
  final bytes = await buildCompanyPdf(r);
  final name = (r['name'] as String? ?? 'company').replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
  await Printing.sharePdf(bytes: bytes, filename: 'Kavach_$name.pdf');
}

String _pd(num? p) {
  final v = (p ?? 0).toDouble() * 100;
  return v < 1 ? '${v.toStringAsFixed(2)}%' : v < 10 ? '${v.toStringAsFixed(1)}%' : '${v.toStringAsFixed(0)}%';
}

const _labels = {
  'current_ratio': 'Current ratio', 'quick_ratio': 'Quick ratio', 'cash_ratio': 'Cash ratio',
  'working_capital_to_assets': 'Working capital / assets', 'debt_to_equity': 'Debt / equity',
  'debt_to_assets': 'Debt / assets', 'interest_coverage': 'Interest cover', 'net_debt_to_ebitda': 'Net debt / EBITDA',
  'ebitda_margin': 'EBITDA margin', 'net_margin': 'Net margin', 'return_on_assets': 'Return on assets',
  'return_on_equity': 'Return on equity', 'ocf_to_debt': 'Cash flow / debt', 'fcf_margin': 'FCF margin',
  'cash_burn_months': 'Cash runway (months)', 'revenue_growth_yoy': 'Revenue growth', 'revenue_cagr_3y': '3y revenue CAGR',
  'margin_trend': 'Margin trend', 'promoter_pledge': 'Promoter pledge',
};

Future<Uint8List> buildCompanyPdf(Json r) async {
  final doc = pw.Document(title: 'Kavach credit report: ${r['name']}', author: 'Kavach');
  final ink = PdfColor.fromHex('#15171B');
  final muted = PdfColor.fromHex('#5C616B');
  final accent = PdfColor.fromHex('#3B4BD8');
  final line = PdfColor.fromHex('#E2DDD2');
  final ex = Json.from(r['explain'] ?? {});
  final drivers = ((ex['feature_drivers'] as List?) ?? []).map((e) => Json.from(e)).take(6).toList();
  final nbrs = ((ex['network_drivers'] as List?) ?? []).map((e) => Json.from(e)).take(6).toList();
  final ratios = Json.from(r['ratios'] ?? {});
  final hz = Json.from(r['multi_horizon'] ?? {});
  final timeline = ((r['timeline'] as List?) ?? []).map((e) => Json.from(e)).toList();
  final health = Json.from((r['health'] as Map?)?['components'] ?? {});

  pw.Widget h(String t) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
        child: pw.Text(t.toUpperCase(), style: pw.TextStyle(fontSize: 8.5, color: accent, fontWeight: pw.FontWeight.bold, letterSpacing: 1)),
      );
  pw.Widget kv(String k, String v) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(children: [pw.Expanded(child: pw.Text(k, style: pw.TextStyle(fontSize: 9.5, color: muted))),
          pw.Text(v, style: pw.TextStyle(fontSize: 9.5, color: ink))]),
      );

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(36),
    footer: (c) => pw.Text('Kavach credit risk report  |  model estimate, not a credit rating  |  page ${c.pageNumber}/${c.pagesCount}',
        style: pw.TextStyle(fontSize: 7.5, color: muted)),
    build: (c) => [
      pw.Text('KAVACH', style: pw.TextStyle(fontSize: 9, letterSpacing: 3, color: muted, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 6),
      pw.Text('${r['name']}', style: pw.TextStyle(fontSize: 22, color: ink, fontWeight: pw.FontWeight.bold)),
      pw.Text('${r['industry'] ?? 'Sector not set'}  |  FY${r['fiscal_year'] ?? ''}', style: pw.TextStyle(fontSize: 10, color: muted)),
      pw.SizedBox(height: 14),
      pw.Container(
        padding: const pw.EdgeInsets.all(12),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: line), borderRadius: pw.BorderRadius.circular(4)),
        child: pw.Row(children: [
          pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('12-month probability of default', style: pw.TextStyle(fontSize: 8.5, color: muted)),
            pw.Text(_pd(r['distress_probability']), style: pw.TextStyle(fontSize: 26, color: ink, fontWeight: pw.FontWeight.bold)),
            if (r['pd_low'] != null)
              pw.Text('Model range ${_pd(r['pd_low'])} - ${_pd(r['pd_high'])}', style: pw.TextStyle(fontSize: 9, color: muted)),
          ])),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text('Implied rating ${r['implied_rating']}', style: pw.TextStyle(fontSize: 11, color: ink, fontWeight: pw.FontWeight.bold)),
            pw.Text('${r['risk_band']} risk', style: pw.TextStyle(fontSize: 10, color: muted)),
            pw.Text('Health score ${r['health_score']}/100', style: pw.TextStyle(fontSize: 10, color: muted)),
          ]),
        ]),
      ),
      h('Term structure'),
      pw.Row(children: [for (final e in hz.entries) pw.Expanded(child: kv(e.key, _pd(e.value)))]),
      pw.Text('3, 6 and 24-month values are derived from the 12-month PD with a hazard curve, not predicted separately.',
          style: pw.TextStyle(fontSize: 8, color: muted)),
      if (timeline.length > 1) ...[
        h('Risk by fiscal year'),
        pw.Row(children: [for (final t in timeline) pw.Expanded(child: kv('FY${t['year']}', _pd(t['risk'])))]),
      ],
      h('Financial health (percentile vs. universe)'),
      pw.Row(children: [for (final e in health.entries) pw.Expanded(child: kv(e.key.replaceAll('_', ' '), '${e.value}'))]),
      h('What drives the risk (own fundamentals, log-odds)'),
      for (final d in drivers)
        kv('${_labels[d['feature']] ?? d['feature']}  (${ratios[d['feature']] ?? ''})',
            '${(d['contribution'] as num) > 0 ? '+' : ''}${(d['contribution'] as num).toStringAsFixed(2)}'),
      if (nbrs.isNotEmpty) ...[
        h('Counterparties'),
        for (final n in nbrs)
          kv('${n['name'] ?? n['neighbour_id']}  |  ${n['relation']}  |  ${((n['relationship_weight'] as num) * 100).round()}%'
              '${n['defaulted'] == true ? '  |  in default' : ''}',
              '${(n['influence'] as num) > 0 ? '+' : ''}${(n['influence'] as num).toStringAsFixed(2)}'),
      ],
      h('Ratios'),
      pw.Wrap(spacing: 18, children: [
        for (final e in ratios.entries)
          pw.SizedBox(width: 160, child: kv(_labels[e.key] ?? e.key, (e.value as num).toStringAsFixed(3))),
      ]),
      pw.SizedBox(height: 12),
      pw.Text('Scored by a blend of graph neural networks trained on a simulated Indian corporate universe; '
          'explanations are exact attributions from the linear relational member. Amounts in INR crore.',
          style: pw.TextStyle(fontSize: 8, color: muted)),
    ],
  ));
  return doc.save();
}
