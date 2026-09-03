import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/api_client.dart';
import '../widgets/risk_widgets.dart';
import 'company_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<List<CompanyCard>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<CompanyCard>> _load() async {
    final raw = await context.read<ApiClient>().companies(limit: 60);
    return raw.map((e) => CompanyCard.fromJson(Map<String, dynamic>.from(e))).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Corporate Risk Intelligence')),
      body: FutureBuilder<List<CompanyCard>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Could not reach API:\n${snap.error}',
                textAlign: TextAlign.center));
          }
          final items = snap.data!;
          final high = items.where((c) => c.riskBand == 'HIGH' || c.riskBand == 'CRITICAL').length;
          final mod = items.where((c) => c.riskBand == 'MODERATE').length;
          final low = items.where((c) => c.riskBand == 'LOW').length;
          return RefreshIndicator(
            onRefresh: () async => setState(() => _future = _load()),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _summaryRow(items.length, high, mod, low),
                const SizedBox(height: 16),
                Text('Companies', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                ...items.map((c) => _companyTile(c)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _summaryRow(int total, int high, int mod, int low) => Row(
        children: [
          _stat('Tracked', '$total', Colors.indigo),
          _stat('High', '$high', const Color(0xFFDC2626)),
          _stat('Moderate', '$mod', const Color(0xFFF59E0B)),
          _stat('Low', '$low', const Color(0xFF16A34A)),
        ],
      );

  Widget _stat(String label, String value, Color c) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(children: [
              Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: c)),
              Text(label, style: const TextStyle(fontSize: 12)),
            ]),
          ),
        ),
      );

  Widget _companyTile(CompanyCard c) => Card(
        child: ListTile(
          title: Text(c.name),
          subtitle: Text('${c.industry} · Health ${c.healthScore.toStringAsFixed(0)}/100'),
          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            RiskBandChip(c.riskBand),
            const SizedBox(height: 4),
            Text('${(c.distressProbability * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ]),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => CompanyScreen(companyId: c.companyId, name: c.name))),
        ),
      );
}
