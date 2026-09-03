import 'package:flutter/material.dart';
import 'package:graphview/GraphView.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../theme/app_theme.dart';

/// Interactive supplier/customer network around a company.
class NetworkGraphScreen extends StatefulWidget {
  final String companyId;
  const NetworkGraphScreen({super.key, required this.companyId});
  @override
  State<NetworkGraphScreen> createState() => _NetworkGraphScreenState();
}

class _NetworkGraphScreenState extends State<NetworkGraphScreen> {
  final Graph _graph = Graph();
  final _builder = FruchtermanReingoldAlgorithm();
  Map<String, dynamic>? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await context.read<ApiClient>().egoGraph(widget.companyId, hops: 1);
    final nodesById = <String, Node>{};
    for (final n in (d['nodes'] as List)) {
      nodesById[n['id']] = Node.Id(n['id']);
    }
    for (final e in (d['edges'] as List)) {
      final s = nodesById[e['source']];
      final t = nodesById[e['target']];
      if (s != null && t != null) _graph.addEdge(s, t);
    }
    setState(() => _data = d);
  }

  Color _bandOf(String id) {
    final n = (_data!['nodes'] as List).firstWhere((x) => x['id'] == id, orElse: () => null);
    return n == null ? Colors.grey : AppTheme.bandColor(n['band'] ?? 'MODERATE');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Network · ${widget.companyId}')),
      body: _data == null
          ? const Center(child: CircularProgressIndicator())
          : InteractiveViewer(
              constrained: false,
              boundaryMargin: const EdgeInsets.all(200),
              minScale: 0.2,
              maxScale: 4,
              child: GraphView(
                graph: _graph,
                algorithm: _builder,
                builder: (Node node) {
                  final id = node.key!.value as String;
                  final c = _bandOf(id);
                  return Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: c.withOpacity(0.2),
                      border: Border.all(color: c, width: 2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(id, style: const TextStyle(fontWeight: FontWeight.bold)),
                  );
                },
              ),
            ),
    );
  }
}
