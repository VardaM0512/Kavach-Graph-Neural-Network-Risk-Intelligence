import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'kit.dart';

/// Typo-tolerant company search with a live suggestion list.
class CompanyPicker extends StatefulWidget {
  final String? hint;
  final void Function(Json company) onPicked;
  final bool clearOnPick;
  const CompanyPicker({super.key, this.hint, required this.onPicked, this.clearOnPick = false});
  @override
  State<CompanyPicker> createState() => _CompanyPickerState();
}

class _CompanyPickerState extends State<CompanyPicker> {
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  final _link = LayerLink();
  OverlayEntry? _overlay;
  List<Json> _hits = [];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) Future.delayed(const Duration(milliseconds: 180), _hide);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _hide();
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _search(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      _hits = [];
      _hide();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 160), () async {
      try {
        _hits = await context.read<AppState>().api.search(q, limit: 8);
        if (mounted) _show();
      } catch (_) {}
    });
  }

  void _hide() {
    _overlay?.remove();
    _overlay = null;
  }

  void _show() {
    _hide();
    if (_hits.isEmpty) return;
    final box = context.findRenderObject() as RenderBox;
    final k = context.k;
    _overlay = OverlayEntry(builder: (_) => Positioned(
      width: box.size.width,
      child: CompositedTransformFollower(
        link: _link, offset: Offset(0, box.size.height + 4), showWhenUnlinked: false,
        child: Material(
          color: k.raised,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6), side: BorderSide(color: k.lineStrong)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 340),
            child: ListView(padding: const EdgeInsets.symmetric(vertical: 6), shrinkWrap: true, children: [
              for (final h in _hits)
                InkWell(
                  onTap: () {
                    widget.onPicked(h);
                    _ctl.text = widget.clearOnPick ? '' : h['name'];
                    _hide();
                    _focus.unfocus();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    child: Row(children: [
                      Container(width: 7, height: 7, decoration: BoxDecoration(
                          color: k.forPd((h['distress_probability'] as num).toDouble()), shape: BoxShape.circle)),
                      const SizedBox(width: 10),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(h['name'], style: TextStyle(color: k.text, fontSize: 13.5)),
                        Text('${h['industry']} · ${h['company_id']}', style: TextStyle(color: k.muted, fontSize: 11.5)),
                      ])),
                      Text(fmtPd(h['distress_probability']), style: KType.mono(k.forPd((h['distress_probability'] as num).toDouble()), 12)),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
      ),
    ));
    Overlay.of(context).insert(_overlay!);
  }

  @override
  Widget build(BuildContext context) => CompositedTransformTarget(
        link: _link,
        child: TextField(
          controller: _ctl,
          focusNode: _focus,
          onChanged: _search,
          decoration: InputDecoration(
            hintText: widget.hint ?? context.t('search'),
            prefixIcon: Icon(Icons.search, size: 18, color: context.k.muted),
          ),
        ),
      );
}
