import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../widgets/risk_widgets.dart';
import '../theme/app_theme.dart';
import 'network_graph_screen.dart';
import 'scenario_screen.dart';

class CompanyScreen extends StatefulWidget {
  final String companyId;
  final String name;
  const CompanyScreen({super.key, required this.companyId, required this.name});

  @override
  State<CompanyScreen> createState() => _CompanyScreenState();
}

class _CompanyScreenState extends State<CompanyScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    final api = context.read<ApiClient>();
    _future = Future.wait([
      api.predict(widget.companyId),
      api.explain(widget.companyId),
      api.contagion(widget.companyId),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.name), actions: [
        IconButton(
          icon: const Icon(Icons.hub_outlined),
          tooltip: 'Network graph',
          onPressed: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => NetworkGraphScreen(companyId: widget.companyId))),
        ),
        IconButton(
          icon: const Icon(Icons.science_outlined),
          tooltip: 'Scenario',
          onPressed: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => ScenarioScreen(companyId: widget.companyId))),
        ),
      ]),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          final pred = snap.data![0];
          final explain = snap.data![1];
          final contagion = snap.data![2];
          final drivers = (explain['feature_drivers'] as List).cast<Map<String, dynamic>>();
          final neighbours = (explain['network_drivers'] as List).cast<Map<String, dynamic>>();
          final horizons = Map<String, dynamic>.from(pred['multi_horizon'] ?? {});
          return ListView(padding: const EdgeInsets.all(16), children: [
            _card('Distress risk', [
              RiskBar(
                label: '12-month distress probability',
                value: (pred['distress_probability'] ?? 0).toDouble(),
                band: pred['risk_band'] ?? 'MODERATE',
              ),
              const SizedBox(height: 12),
              RiskBar(
                label: 'Financial health',
                value: (pred['health_score'] ?? 0).toDouble() / 100,
                band: 'LOW',
              ),
              const SizedBox(height: 12),
              Text('Network contagion: ${(pred['network_contagion'] ?? 0)}/100'),
            ]),
            _card('Multi-horizon risk', [
              ...horizons.entries.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: RiskBar(
                        label: e.key, value: (e.value as num).toDouble(), band: pred['risk_band'] ?? 'MODERATE'),
                  )),
            ]),
            _card('Why is risk high?', [
              ...drivers.map((d) => DriverBar(
                    feature: d['feature'],
                    share: (d['share'] ?? 0).toDouble(),
                    raisesRisk: d['direction'] == 'raises_risk',
                  )),
            ]),
            _card('Network drivers (connected companies)', [
              if (neighbours.isEmpty) const Text('No significant connected exposures.'),
              ...neighbours.map((n) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.link),
                    title: Text(n['neighbour_id'] ?? ''),
                    subtitle: Text('neighbour risk ${((n['neighbour_risk'] ?? 0) * 100).toStringAsFixed(0)}%'),
                    trailing: Text('infl ${(n['influence'] ?? 0).toStringAsFixed(2)}'),
                  )),
            ]),
          ]);
        },
      ),
    );
  }

  Widget _card(String title, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            ...children,
          ]),
        ),
      );
}
