import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../widgets/risk_widgets.dart';

class PortfolioScreen extends StatefulWidget {
  const PortfolioScreen({super.key});
  @override
  State<PortfolioScreen> createState() => _PortfolioScreenState();
}

class _PortfolioScreenState extends State<PortfolioScreen> {
  final List<Map<String, dynamic>> _holdings = [
    {'company_id': 'C0001', 'weight': 0.25},
    {'company_id': 'C0002', 'weight': 0.25},
    {'company_id': 'C0003', 'weight': 0.25},
    {'company_id': 'C0004', 'weight': 0.25},
  ];
  Map<String, dynamic>? _result;
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    _result = await context.read<ApiClient>().portfolioRisk(_holdings);
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Portfolio risk')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Holdings', style: Theme.of(context).textTheme.titleMedium),
        ..._holdings.map((h) => ListTile(
              dense: true,
              title: Text(h['company_id']),
              trailing: Text('${(h['weight'] * 100).toStringAsFixed(0)}%'),
            )),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy ? null : _run,
          icon: const Icon(Icons.calculate_outlined),
          label: const Text('Compute exposure'),
        ),
        const SizedBox(height: 24),
        if (_result != null) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                RiskBar(
                    label: 'Portfolio distress exposure',
                    value: (_result!['portfolio_distress_exposure'] ?? 0).toDouble(),
                    band: _result!['band'] ?? 'MODERATE'),
                const SizedBox(height: 16),
                const Text('Shared network exposure',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                ...(_result!['shared_network_exposure'] as List).map((s) => Text(
                    '• ${s['company_id']} — ${((s['portfolio_weight'] ?? 0) * 100).toStringAsFixed(0)}% of portfolio linked')),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}
