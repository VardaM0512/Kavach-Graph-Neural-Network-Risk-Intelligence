import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Kavach mark: a shield cut into a K whose arms are network links, joined at
/// the red "default node". Rendered from the same SVG as the app icon.
class KavachMark extends StatelessWidget {
  final double size;
  const KavachMark({super.key, this.size = 22});
  @override
  Widget build(BuildContext context) =>
      SvgPicture.asset('assets/brand/kavach_mark.svg', width: size, height: size);
}

class Wordmark extends StatelessWidget {
  final double size;
  const Wordmark({super.key, this.size = 15});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        KavachMark(size: size + 7),
        const SizedBox(width: 10),
        Text('KAVACH', style: KType.mono(context.k.text, size, w: FontWeight.w700).copyWith(letterSpacing: 3)),
      ]);
}

/// Compact language switcher showing every language in its own script.
class LanguageMenu extends StatelessWidget {
  const LanguageMenu({super.key});
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final st = context.watch<AppState>();
    final cur = langOf(st.lang);
    return PopupMenuButton<String>(
      tooltip: context.t('language'),
      onSelected: st.setLang,
      constraints: const BoxConstraints(maxHeight: 480, minWidth: 220),
      itemBuilder: (_) => [
        for (final l in languages)
          PopupMenuItem(
            value: l.code,
            height: 38,
            child: Row(children: [
              SizedBox(width: 18, child: l.code == st.lang ? Icon(Icons.check, size: 14, color: k.accent) : null),
              Expanded(child: Text(l.native, style: TextStyle(color: k.text))),
              Text(l.english, style: TextStyle(color: k.faint, fontSize: 11.5)),
            ]),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(border: Border.all(color: k.line), borderRadius: BorderRadius.circular(4)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.translate_rounded, size: 15, color: k.muted),
          const SizedBox(width: 8),
          Text(cur.native, style: TextStyle(fontSize: 13, color: k.text)),
          Icon(Icons.expand_more, size: 16, color: k.muted),
        ]),
      ),
    );
  }
}
