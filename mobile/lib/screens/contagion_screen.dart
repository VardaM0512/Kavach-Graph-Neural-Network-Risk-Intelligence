import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/company_picker.dart';
import '../widgets/kit.dart';
import '../widgets/network_canvas.dart';
import 'company_screen.dart';

class ContagionScreen extends StatefulWidget {
  final String? initial;
  final String? initialName;
  const ContagionScreen({super.key, this.initial, this.initialName});
  @override
  State<ContagionScreen> createState() => _ContagionScreenState();
}

class _ContagionScreenState extends State<ContagionScreen> {
  String? _id, _name;
  Json? _res;
  bool _busy = false;
  int _round = 0;
  Timer? _player;

  @override
  void initState() {
    super.initState();
    if (widget.initial != null) {
      _id = widget.initial;
      _name = widget.initialName;
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    } else {
      context.read<AppState>().api.companies(limit: 1, sort: 'size').then((r) {
        final c = (r['companies'] as List).first;
        setState(() {
          _id = c['company_id'];
          _name = c['name'];
        });
        _run();
      }).catchError((_) {});
    }
  }

  @override
  void dispose() {
    _player?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    if (_id == null) return;
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.simulateFailure(_id!);
      setState(() {
        _res = r;
        _busy = false;
      });
      _play();
    } catch (_) {
      setState(() => _busy = false);
    }
  }

  void _play() {
    _player?.cancel();
    setState(() => _round = 0);
    final rounds = (_res!['rounds'] as List).length;
    _player = Timer.periodic(const Duration(milliseconds: 1500), (t) {
      if (_round >= rounds) {
        t.cancel();
      } else {
        setState(() => _round++);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 48),
      child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PageHeader(eyebrow: context.t('navContagion'), title: context.t('contagionTitle'), body: context.t('contagionBody')),
          Row(children: [
            Expanded(child: CompanyPicker(
              hint: _name ?? context.t('pickCompany'),
              onPicked: (c) {
                setState(() {
                  _id = c['company_id'];
                  _name = c['name'];
                });
                _run();
              },
            )),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _run,
              icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.bolt_rounded, size: 18),
              label: Text(context.t('runCascade')),
            ),
          ]),
          const SizedBox(height: 20),
          if (_res == null)
            const LoadingBlock(height: 480)
          else
            _result(context, k),
        ]),
      )),
    );
  }

  Widget _result(BuildContext context, KColors k) {
    final r = _res!;
    final rounds = (r['rounds'] as List).map((e) => Json.from(e)).toList();
    final affected = (r['affected'] as List).map((e) => Json.from(e)).toList();
    final start = r['failing_company'] as String;

    // state at the current replay round
    final failed = <String>{start};
    final risk = <String, double>{for (final a in affected) a['company_id']: (a['before'] as num).toDouble()};
    for (var i = 0; i < _round && i < rounds.length; i++) {
      for (final s in (rounds[i]['stressed'] as List)) {
        risk[s['company_id']] = (s['after'] as num).toDouble();
      }
      failed.addAll((rounds[i]['defaults'] as List).cast<String>());
    }
    for (final f in failed) {
      risk[f] = 1.0;
    }
    final nodes = [
      {'id': start, 'name': r['failing_name'], 'risk': 1.0, 'band': 'CRITICAL', 'depth': 0, 'revenue': 3000},
      for (final a in affected)
        {'id': a['company_id'], 'name': a['name'], 'industry': a['industry'], 'risk': a['before'],
          'band': null, 'depth': 1, 'revenue': 600},
    ];
    final edges = (r['edges'] as List).map((e) => Json.from(e)).toList();
    final level = r['estimated_network_impact'] as String;
    final levelColor = {'SYSTEMIC': k.critical, 'HIGH': k.high, 'MODERATE': k.moderate}[level] ?? k.low;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      KpiStrip([
        Kpi(label: context.t('impact'), value: level, valueColor: levelColor),
        Kpi(label: context.t('affected'), value: '${r['affected_count']}'),
        Kpi(label: context.t('secondaryDefaults'), value: '${r['secondary_defaults']}', valueColor: (r['secondary_defaults'] as int) > 0 ? k.critical : null),
        Kpi(label: context.t('debtAtRisk'), value: fmtCr(r['debt_at_risk_cr'])),
      ]),
      const SizedBox(height: 16),
      Cols([
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            for (var i = 0; i <= rounds.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  onTap: () {
                    _player?.cancel();
                    setState(() => _round = i);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: i == _round ? k.accentSoft : Colors.transparent,
                      border: Border.all(color: i <= _round ? k.accent : k.line),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(i == 0 ? 'T0' : '${context.t('round')} $i', style: KType.mono(i <= _round ? k.text : k.faint, 11.5)),
                  ),
                ),
              ),
            const Spacer(),
            TextButton.icon(onPressed: _play, icon: const Icon(Icons.replay, size: 16), label: Text(context.t('replay'))),
          ]),
          const SizedBox(height: 10),
          NetworkCanvas(nodes: nodes, edges: edges, center: start, riskOverride: risk, failed: failed, height: 540,
              onOpen: (id, name) => openCompany(context, id, name)),
        ]),
        Panel(
          title: context.t('mostHit'),
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
          child: Column(children: [
            for (final a in affected.take(14))
              InkWell(
                onTap: () => openCompany(context, a['company_id'], a['name']),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(children: [
                    if (failed.contains(a['company_id']))
                      Padding(padding: const EdgeInsets.only(right: 6), child: Icon(Icons.close_rounded, size: 14, color: k.critical)),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text((a['name'] as String).replaceAll(' Ltd', ''), maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13)),
                      Text(a['industry'], style: context.tt.bodySmall?.copyWith(fontSize: 11.5)),
                    ])),
                    Text(fmtPd(a['before']), style: KType.mono(k.muted, 11.5)),
                    Icon(Icons.arrow_right_alt, size: 14, color: k.faint),
                    SizedBox(width: 52, child: Text(fmtPd(a['after']), textAlign: TextAlign.end,
                        style: KType.mono(k.forPd((a['after'] as num).toDouble()), 12))),
                  ]),
                ),
              ),
          ]),
        ),
      ], flex: const [7, 3], breakpoint: 1000),
    ]);
  }
}
