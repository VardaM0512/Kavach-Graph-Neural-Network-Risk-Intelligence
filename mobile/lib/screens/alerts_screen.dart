import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../widgets/risk_widgets.dart';
import 'company_screen.dart';

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});
  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<ApiClient>().earlyWarnings(threshold: 0.6);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Early-warning alerts')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          final alerts = (snap.data!['alerts'] as List).cast<Map<String, dynamic>>();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('${snap.data!['count']} companies in HIGH/CRITICAL band',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ...alerts.map((a) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.warning_amber_rounded),
                      title: Text(a['company_id']),
                      trailing: RiskBandChip(a['band']),
                      subtitle: Text('risk ${((a['risk'] ?? 0) * 100).toStringAsFixed(0)}%'),
                      onTap: () => Navigator.push(context, MaterialPageRoute(
                          builder: (_) => CompanyScreen(
                              companyId: a['company_id'], name: a['company_id']))),
                    ),
                  )),
            ],
          );
        },
      ),
    );
  }
}
