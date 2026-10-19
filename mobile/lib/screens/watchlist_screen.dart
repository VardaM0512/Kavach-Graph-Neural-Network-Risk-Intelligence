import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/kit.dart';
import 'company_screen.dart';

/// Followed companies with live PD vs. PD when added, plus band-downgrade alerts.
class WatchlistScreen extends StatefulWidget {
  const WatchlistScreen({super.key});
  @override
  State<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends State<WatchlistScreen> {
  late Future<Json> _alerts = context.read<AppState>().api.earlyWarnings();
  final _cards = <String, Json>{};
  final _inflight = <String>{};

  Future<void> _refreshCards(List<String> ids) async {
    final api = context.read<AppState>().api;
    for (final id in ids.where((i) => !_cards.containsKey(i) && !_inflight.contains(i)).toList()) {
      _inflight.add(id);
      try {
        final d = await api.company(id);
        if (mounted) setState(() => _cards[id] = d);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final st = context.watch<AppState>();
    _refreshCards(st.watchlist.map((w) => w.companyId).toList());
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 48),
      child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PageHeader(eyebrow: context.t('navWatchlist'), title: '${st.watchlist.length} ${context.t('companies')}'),
          Cols([
            Panel(
              title: context.t('navWatchlist'),
              child: st.watchlist.isEmpty
                  ? Text(context.t('emptyWatchlist'), style: context.tt.bodySmall)
                  : Column(children: [
                      for (final w in st.watchlist)
                        Builder(builder: (context) {
                          final d = _cards[w.companyId];
                          final pd = (d?['distress_probability'] as num?)?.toDouble();
                          return InkWell(
                            onTap: () => openCompany(context, w.companyId, w.name),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              child: Row(children: [
                                Container(width: 3, height: 32, color: pd == null ? k.line : k.forPd(pd)),
                                const SizedBox(width: 12),
                                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(w.name),
                                  Text(d?['industry'] ?? w.companyId, style: context.tt.bodySmall),
                                ])),
                                if (pd != null && w.pdAtAdd != null) DeltaText(pd - w.pdAtAdd!, size: 11.5),
                                const SizedBox(width: 14),
                                if (pd != null && pd >= w.threshold)
                                  Tooltip(message: '${context.t('alertAbove')} ${fmtPd(w.threshold)}',
                                      child: Icon(Icons.notifications_active_outlined, size: 16, color: k.high)),
                                SizedBox(width: 64, child: Text(pd == null ? '…' : fmtPd(pd), textAlign: TextAlign.end,
                                    style: KType.mono(pd == null ? k.faint : k.forPd(pd), 13))),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(Icons.close, size: 16, color: k.faint),
                                  onPressed: () => st.toggleWatch(w.companyId, w.name, pd ?? 0),
                                ),
                              ]),
                            ),
                          );
                        }),
                    ]),
            ),
            Async<Json>(
              future: _alerts,
              onRetry: () => setState(() => _alerts = context.read<AppState>().api.earlyWarnings()),
              builder: (context, a) {
                final rows = (a['alerts'] as List).map((e) => Json.from(e)).where((e) => e['reason'] == 'band_downgrade').take(12).toList();
                return Panel(
                  title: '${context.t('movers')} · ${rows.length}',
                  child: Column(children: [
                    for (final r in rows)
                      InkWell(
                        onTap: () => openCompany(context, r['company_id'], r['name']),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Row(children: [
                            Expanded(child: Text((r['name'] as String).replaceAll(' Ltd', ''), maxLines: 1, overflow: TextOverflow.ellipsis)),
                            BandChip(r['previous_band'], dense: true),
                            Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.arrow_right_alt, size: 14, color: k.faint)),
                            BandChip(r['band'], dense: true),
                          ]),
                        ),
                      ),
                  ]),
                );
              },
            ),
          ], flex: const [6, 5]),
        ]),
      )),
    );
  }
}
