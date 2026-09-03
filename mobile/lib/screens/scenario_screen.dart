import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../widgets/risk_widgets.dart';

class ScenarioScreen extends StatefulWidget {
  final String companyId;
  const ScenarioScreen({super.key, required this.companyId});
  @override
  State<ScenarioScreen> createState() => _ScenarioScreenState();
}

class _ScenarioScreenState extends State<ScenarioScreen> {
  double _revenue = 0;
  double _rate = 0;
  bool _supplierFailure = false;
  Map<String, dynamic>? _result;
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    final r = await context.read<ApiClient>().scenario(
          widget.companyId,
          revenueChange: _revenue,
          rateChange: _rate,
          supplierFailure: _supplierFailure,
        );
    setState(() { _result = r; _busy = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scenario / Stress test')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _slider('Revenue change', _revenue, -0.5, 0.2, (v) => setState(() => _revenue = v),
            '${(_revenue * 100).toStringAsFixed(0)}%'),
        _slider('Interest rate change', _rate, -0.05, 0.05, (v) => setState(() => _rate = v),
            '${(_rate * 100).toStringAsFixed(0)} bps ×100'),
        SwitchListTile(
          title: const Text('Largest supplier fails'),
          value: _supplierFailure,
          onChanged: (v) => setState(() => _supplierFailure = v),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy ? null : _run,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Run scenario'),
        ),
        const SizedBox(height: 24),
        if (_result != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                RiskBar(label: 'Current risk', value: (_result!['current_risk'] ?? 0).toDouble()),
                const SizedBox(height: 12),
                RiskBar(
                    label: 'Scenario risk',
                    value: (_result!['scenario_risk'] ?? 0).toDouble(),
                    band: 'HIGH'),
                const SizedBox(height: 12),
                Text('Δ ${((_result!['delta'] ?? 0) * 100).toStringAsFixed(1)} pp',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _slider(String label, double v, double min, double max,
          ValueChanged<double> onChanged, String display) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label), Text(display, style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
        Slider(value: v, min: min, max: max, onChanged: onChanged),
      ]);
}
