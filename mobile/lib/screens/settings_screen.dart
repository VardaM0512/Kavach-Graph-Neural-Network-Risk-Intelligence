import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/kit.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final st = context.watch<AppState>();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 48),
      child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PageHeader(eyebrow: context.t('navSettings'), title: context.t('navSettings')),
          Panel(
            title: '${context.t('language')} · ${languages.length}',
            child: const LanguageGrid(),
          ),
          const SizedBox(height: 16),
          Cols([
            Panel(
              title: context.t('theme'),
              child: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: ThemeMode.dark, icon: const Icon(Icons.dark_mode_outlined, size: 16), label: Text(context.t('themeDark'))),
                  ButtonSegment(value: ThemeMode.light, icon: const Icon(Icons.light_mode_outlined, size: 16), label: Text(context.t('themeLight'))),
                ],
                selected: {st.themeMode},
                onSelectionChanged: (s) => st.setTheme(s.first),
              ),
            ),
            Panel(
              title: context.t('account'),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(st.user?.name ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(st.user?.email ?? '', style: context.tt.bodySmall),
                const SizedBox(height: 8),
                Text('${context.t('authMode')}: ${st.account.isSupabase ? context.t('authSupabase') : context.t('authDemo')}',
                    style: context.tt.bodySmall),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: st.signOut,
                  icon: Icon(Icons.logout, size: 16, color: k.critical),
                  label: Text(context.t('signOut'), style: TextStyle(color: k.critical)),
                ),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          const _ModelCard(),
        ]),
      )),
    );
  }
}

/// All 23 languages, each shown in its own script.
class LanguageGrid extends StatelessWidget {
  final bool compact;
  const LanguageGrid({super.key, this.compact = false});
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final st = context.watch<AppState>();
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final l in languages)
        InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => st.setLang(l.code),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: compact ? 132 : 150,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: st.lang == l.code ? k.accentSoft : k.raised,
              border: Border.all(color: st.lang == l.code ? k.accent : k.line),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.native, style: TextStyle(fontSize: 15, color: k.text, fontWeight: FontWeight.w500), maxLines: 1),
              const SizedBox(height: 2),
              Text(l.english, style: TextStyle(fontSize: 11, color: k.muted)),
            ]),
          ),
        ),
    ]);
  }
}

class _ModelCard extends StatefulWidget {
  const _ModelCard();
  @override
  State<_ModelCard> createState() => _ModelCardState();
}

class _ModelCardState extends State<_ModelCard> {
  late Future<Json> _f = context.read<AppState>().api.modelCard();
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return Async<Json>(
      future: _f,
      onRetry: () => setState(() => _f = context.read<AppState>().api.modelCard()),
      loadingHeight: 200,
      builder: (context, m) {
        final g = Json.from(m['graph_model']), t = Json.from(m['tabular_model']);
        Widget metric(String name, String key) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Eyebrow(name),
              const SizedBox(height: 6),
              Text((g[key] as num).toStringAsFixed(3), style: KType.mono(k.text, 20, w: FontWeight.w600)),
              Text('${context.t('tabularModel')} ${(t[key] as num).toStringAsFixed(3)}', style: KType.mono(k.faint, 11)),
            ]));
        return Panel(
          title: context.t('modelTitle'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(context.t('modelBody'), style: context.tt.bodyMedium?.copyWith(color: k.muted)),
            const SizedBox(height: 14),
            Text(m['name'], style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(m['trained_on'], style: context.tt.bodySmall),
            const SizedBox(height: 16),
            Eyebrow(m['benchmark'] != null ? context.t('benchmarkTitle') : '${context.t('heldOut')} · n=${m['test_size']}',
                color: k.accent),
            const SizedBox(height: 10),
            Row(children: [metric('ROC-AUC', 'roc_auc'), metric('PR-AUC', 'pr_auc'), metric('Brier', 'brier')]),
            if (m['benchmark'] != null) ...[
              const SizedBox(height: 16),
              for (final e in (Json.from(m['benchmark']).entries.toList()
                ..sort((a, b) => ((b.value as Map)['roc_auc'] as num).compareTo((a.value as Map)['roc_auc'] as num))))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Expanded(child: Text((e.value as Map)['label'], style: TextStyle(fontSize: 13,
                        fontWeight: e.key == 'blend' ? FontWeight.w700 : FontWeight.w400))),
                    SizedBox(width: 120, child: Text(
                        '${((e.value as Map)['roc_auc'] as num).toStringAsFixed(3)} ± ${((e.value as Map)['roc_auc_std'] as num).toStringAsFixed(3)}',
                        textAlign: TextAlign.end, style: KType.mono(k.text, 12))),
                    SizedBox(width: 70, child: Text(((e.value as Map)['pr_auc'] as num).toStringAsFixed(3),
                        textAlign: TextAlign.end, style: KType.mono(k.muted, 12))),
                  ]),
                ),
              Text('ROC-AUC ± std over folds · PR-AUC', style: context.tt.bodySmall),
            ],
            const SizedBox(height: 10),
            Text(m['multi_horizon'] ?? '', style: context.tt.bodySmall),
            const SizedBox(height: 16),
            Eyebrow(context.t('features')),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final f in (m['features'] as List))
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(border: Border.all(color: k.line), borderRadius: BorderRadius.circular(3)),
                  child: Text(context.t(f), style: const TextStyle(fontSize: 12)),
                ),
            ]),
            const SizedBox(height: 14),
            Text(context.t('dataNote'), style: context.tt.bodySmall),
          ]),
        );
      },
    );
  }
}
