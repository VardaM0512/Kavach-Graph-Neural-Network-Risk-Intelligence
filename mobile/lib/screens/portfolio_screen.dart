import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/account.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/charts.dart';
import '../widgets/company_picker.dart';
import '../widgets/kit.dart';
import 'company_screen.dart';

class PortfolioScreen extends StatefulWidget {
  const PortfolioScreen({super.key});
  @override
  State<PortfolioScreen> createState() => _PortfolioScreenState();
}

class _PortfolioScreenState extends State<PortfolioScreen> {
  Json? _res;
  Timer? _debounce;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _compute());
  }

  void _compute() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      final h = context.read<AppState>().holdings;
      if (h.isEmpty) {
        setState(() => _res = null);
        return;
      }
      setState(() => _busy = true);
      try {
        final r = await context.read<AppState>().api.portfolioRisk([for (final x in h) {'company_id': x.companyId, 'weight': x.weight}]);
        if (mounted) setState(() => _res = r);
      } catch (_) {}
      if (mounted) setState(() => _busy = false);
    });
  }

  Future<void> _sample() async {
    final st = context.read<AppState>();
    final r = await st.api.companies(limit: 8, sort: 'size');
    await st.setHoldings([for (final c in (r['companies'] as List)) Holding(c['company_id'], c['name'], 1.0)]);
    _compute();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final st = context.watch<AppState>();
    final h = st.holdings;
    final total = h.fold<double>(0, (a, b) => a + b.weight);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 48),
      child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PageHeader(eyebrow: context.t('navPortfolio'), title: context.t('portfolioTitle')),
          Row(children: [
            Expanded(child: CompanyPicker(hint: context.t('addHolding'), clearOnPick: true, onPicked: (c) async {
              if (h.any((x) => x.companyId == c['company_id'])) return;
              await st.setHoldings([...h, Holding(c['company_id'], c['name'], 1.0)]);
              _compute();
            })),
            if (_busy) const Padding(padding: EdgeInsets.only(left: 12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
          ]),
          const SizedBox(height: 16),
          if (h.isEmpty)
            Panel(child: Column(children: [
              Text(context.t('emptyPortfolio')),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _sample, child: Text(context.t('loadExample'))),
            ]))
          else ...[
            if (_res != null) ...[
              KpiStrip([
                Kpi(label: context.t('exposure'), value: fmtPd(_res!['portfolio_distress_exposure']),
                    valueColor: k.forPd((_res!['portfolio_distress_exposure'] as num).toDouble()), hint: _res!['implied_rating']),
                Kpi(label: context.t('expectedLoss'), value: fmtPd(_res!['expected_loss']), hint: 'LGD 45%'),
                Kpi(label: context.t('concentration'), value: (_res!['concentration_hhi'] as num).toStringAsFixed(3)),
                Kpi(label: context.t('interlinked'), value: '${_res!['interlinked_pairs']}',
                    valueColor: (_res!['interlinked_pairs'] as int) > 0 ? k.high : null),
              ]),
              const SizedBox(height: 16),
            ],
            Cols([
              Panel(
                title: context.t('holdings'),
                child: Column(children: [
                  for (final x in h) _holdingRow(context, x, total),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (_res != null) ...[
                  Panel(title: context.t('sectorMix'), child: SectorDonut(sectors: (_res!['sectors'] as List).map((e) => Json.from(e)).toList())),
                  const SizedBox(height: 16),
                  Panel(title: context.t('underStress'), child: Column(children: [
                    _stressRow(context, context.t('currentPd'), (_res!['portfolio_distress_exposure'] as num).toDouble(), _res!),
                    for (final s in (_res!['stress'] as List))
                      _stressRow(context, {
                        'Revenue -20%': '${context.t('revenueShock')} −20%',
                        'Rates +200 bps': '${context.t('rateShock')} +200 bps',
                        'Top supplier fails': context.t('supplierFails'),
                      }[s['scenario']] ?? s['scenario'], (s['exposure'] as num).toDouble(), _res!),
                  ])),
                ],
              ]),
            ], flex: const [6, 5]),
            if (_res != null && (_res!['shared_network_exposure'] as List).isNotEmpty) ...[
              const SizedBox(height: 16),
              Panel(
                title: context.t('sharedExposure'),
                subtitle: context.t('sharedExposureBody'),
                child: Column(children: [
                  for (final s in (_res!['shared_network_exposure'] as List))
                    InkWell(
                      onTap: () => openCompany(context, s['company_id'], s['name']),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(children: [
                          Icon(Icons.hub_outlined, size: 16, color: k.accent),
                          const SizedBox(width: 10),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(s['name']),
                            Text('↔ ${(s['linked_holdings'] as List).join(', ')}', style: context.tt.bodySmall),
                          ])),
                          Text(fmtPd(s['risk']), style: KType.mono(k.forPd((s['risk'] as num).toDouble()), 12.5)),
                        ]),
                      ),
                    ),
                ]),
              ),
            ],
          ],
        ]),
      )),
    );
  }

  Widget _holdingRow(BuildContext context, Holding x, double total) {
    final k = context.k;
    final st = context.read<AppState>();
    final row = (_res?['holdings'] as List?)?.cast<Map>().firstWhere((r) => r['company_id'] == x.companyId, orElse: () => {});
    final pd = (row?['risk'] as num?)?.toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(flex: 4, child: InkWell(
          onTap: () => openCompany(context, x.companyId, x.name),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(x.name.replaceAll(' Ltd', ''), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
            Text(row?['industry'] ?? x.companyId, style: context.tt.bodySmall?.copyWith(fontSize: 11.5)),
          ]),
        )),
        Expanded(flex: 4, child: Slider(
          value: x.weight.clamp(0.1, 5.0), min: 0.1, max: 5.0,
          onChanged: (v) => st.setHoldings([for (final y in st.holdings) y.companyId == x.companyId ? y.withWeight(v) : y]),
          onChangeEnd: (_) => _compute(),
        )),
        SizedBox(width: 44, child: Text('${(x.weight / total * 100).round()}%', textAlign: TextAlign.end, style: KType.mono(k.muted, 12))),
        SizedBox(width: 60, child: Text(pd == null ? '—' : fmtPd(pd), textAlign: TextAlign.end,
            style: KType.mono(pd == null ? k.faint : k.forPd(pd), 12.5))),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.close, size: 16, color: k.faint),
          onPressed: () async {
            await st.setHoldings(st.holdings.where((y) => y.companyId != x.companyId).toList());
            _compute();
          },
        ),
      ]),
    );
  }

  Widget _stressRow(BuildContext context, String label, double v, Json res) {
    final k = context.k;
    final maxV = [(res['portfolio_distress_exposure'] as num).toDouble(),
      ...(res['stress'] as List).map((s) => (s['exposure'] as num).toDouble())].reduce((a, b) => a > b ? a : b);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        SizedBox(width: 150, child: Text(label, style: const TextStyle(fontSize: 13))),
        Expanded(child: LayoutBuilder(builder: (context, c) => Align(
          alignment: AlignmentDirectional.centerStart,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: c.maxWidth * v / (maxV * 1.05)), duration: const Duration(milliseconds: 500),
            builder: (_, w, __) => Container(width: w, height: 8, decoration: BoxDecoration(color: k.forPd(v), borderRadius: BorderRadius.circular(1))),
          ),
        ))),
        SizedBox(width: 60, child: Text(fmtPd(v), textAlign: TextAlign.end, style: KType.mono(k.text, 12.5))),
      ]),
    );
  }
}
