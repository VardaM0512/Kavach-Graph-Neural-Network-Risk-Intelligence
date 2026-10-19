import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../l10n/strings.dart';
import '../screens/company_screen.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'kit.dart';

/// Opens the Ask Kavach command palette.
Future<void> showAskKavach(BuildContext context, {String? initial, bool voice = false}) => showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (_) => AskKavachDialog(initial: initial, startVoice: voice),
    );

class _Turn {
  final String question;
  final bool voice;
  Json? reply;
  Object? error;
  _Turn(this.question, this.voice);
}

class AskKavachDialog extends StatefulWidget {
  final String? initial;
  final bool startVoice;
  const AskKavachDialog({super.key, this.initial, this.startVoice = false});
  @override
  State<AskKavachDialog> createState() => _AskKavachDialogState();
}

class _AskKavachDialogState extends State<AskKavachDialog> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _turns = <_Turn>[];
  final _stt = SpeechToText();
  final _tts = FlutterTts();
  bool _sttReady = false, _listening = false;

  @override
  void initState() {
    super.initState();
    _stt.initialize(onStatus: (s) {
      if (s == 'done' || s == 'notListening') setState(() => _listening = false);
    }, onError: (_) => setState(() => _listening = false)).then((ok) {
      setState(() => _sttReady = ok);
      if (ok && widget.startVoice) _listen();
    }).catchError((_) {});
    if (widget.initial != null) WidgetsBinding.instance.addPostFrameCallback((_) => _ask(widget.initial!));
  }

  @override
  void dispose() {
    _stt.cancel();
    _tts.stop();
    super.dispose();
  }

  Future<void> _ask(String q, {bool voice = false}) async {
    if (q.trim().isEmpty) return;
    final st = context.read<AppState>();
    final turn = _Turn(q.trim(), voice);
    setState(() => _turns.add(turn));
    _input.clear();
    try {
      turn.reply = await st.api.ask(q, st.lang);
      final text = composeAnswer(st.lang, turn.reply!);
      st.account.logQuery(q, turn.reply!['intent'], text, st.lang, voice);
      if (voice) _speak(text);
    } catch (e) {
      turn.error = e;
    }
    if (mounted) setState(() {});
    await Future.delayed(const Duration(milliseconds: 60));
    if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  Future<void> _listen() async {
    if (!_sttReady) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.tr('voiceUnavailable'))));
      return;
    }
    if (_listening) {
      await _stt.stop();
      return;
    }
    final lang = langOf(context.read<AppState>().lang);
    setState(() => _listening = true);
    await _stt.listen(
      localeId: lang.speech,
      listenOptions: SpeechListenOptions(partialResults: true),
      onResult: (r) {
        setState(() => _input.text = r.recognizedWords);
        if (r.finalResult) {
          setState(() => _listening = false);
          _ask(r.recognizedWords, voice: true);
        }
      },
    );
  }

  Future<void> _speak(String text) async {
    final lang = langOf(context.read<AppState>().lang);
    try {
      await _tts.setLanguage(lang.speech);
      await _tts.setSpeechRate(0.5);
      await _tts.speak(text);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final sugg = [
      ('sugMarket', 'market summary'),
      ('sugCement', 'riskiest cement companies'),
      ('sugPower', 'how is the power sector doing'),
      ('sugRealty', 'riskiest real estate companies'),
    ];
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 40),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 10),
            child: Row(children: [
              Icon(Icons.auto_awesome_outlined, size: 18, color: k.accent),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _input,
                  autofocus: true,
                  onSubmitted: (v) => _ask(v),
                  onEditingComplete: () {}, // keep focus for follow-up questions
                  style: const TextStyle(fontSize: 16),
                  decoration: InputDecoration(
                    hintText: _listening ? context.t('listening') : context.t('askHint'),
                    filled: false, border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
                  ),
                ),
              ),
              _MicButton(listening: _listening, onTap: _listen),
              IconButton(onPressed: () => _ask(_input.text), icon: Icon(Icons.arrow_upward_rounded, color: k.text)),
            ]),
          ),
          Divider(color: k.line),
          Flexible(
            child: _turns.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Eyebrow(context.t('askKavach')),
                      const SizedBox(height: 6),
                      Text(context.t('ruleBased'), style: context.tt.bodySmall),
                      const SizedBox(height: 12),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final s in sugg)
                          ActionChip(
                            label: Text(context.t(s.$1)),
                            onPressed: () => _ask(s.$2),
                            backgroundColor: k.raised,
                            side: BorderSide(color: k.line),
                          ),
                      ]),
                    ]),
                  )
                : ListView(controller: _scroll, padding: const EdgeInsets.all(16), shrinkWrap: true, children: [
                    for (final t in _turns) _TurnView(turn: t, onSpeak: _speak),
                  ]),
          ),
        ]),
      ),
    );
  }
}

class _MicButton extends StatefulWidget {
  final bool listening;
  final VoidCallback onTap;
  const _MicButton({required this.listening, required this.onTap});
  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: widget.listening
              ? [BoxShadow(color: k.critical.withValues(alpha: 0.25 + 0.3 * _c.value), blurRadius: 6 + 10 * _c.value, spreadRadius: 1)]
              : null,
        ),
        child: IconButton(
          onPressed: widget.onTap,
          icon: Icon(widget.listening ? Icons.graphic_eq_rounded : Icons.mic_none_rounded,
              color: widget.listening ? k.critical : k.muted),
        ),
      ),
    );
  }
}

class _TurnView extends StatelessWidget {
  final _Turn turn;
  final void Function(String) onSpeak;
  const _TurnView({required this.turn, required this.onSpeak});

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final st = context.watch<AppState>();
    final r = turn.reply;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (turn.voice) Padding(padding: const EdgeInsets.only(right: 6), child: Icon(Icons.mic, size: 14, color: k.faint)),
          Expanded(child: Text(turn.question, style: TextStyle(color: k.muted, fontSize: 13))),
        ]),
        const SizedBox(height: 8),
        if (turn.error != null)
          Text(context.t('apiDown'), style: TextStyle(color: k.critical))
        else if (r == null)
          const LinearProgressIndicator(minHeight: 1)
        else ...[
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(composeAnswer(st.lang, r), style: const TextStyle(fontSize: 15.5, height: 1.45))),
            IconButton(
              tooltip: context.t('speak'),
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.volume_up_outlined, size: 18, color: k.muted),
              onPressed: () => onSpeak(composeAnswer(st.lang, r)),
            ),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in _cards(r)) _CompanyPill(c),
          ]),
        ],
      ]),
    );
  }

  List<Json> _cards(Json r) => [
        if (r['company'] != null) Json.from(r['company']),
        ...((r['companies'] as List?) ?? []).map((e) => Json.from(e)),
        ...(((r['data'] as Map?)?['top'] as List?) ?? []).take(3).map((e) => {
              'company_id': e['company_id'], 'name': e['name'], 'distress_probability': e['after'],
              'risk_band': null,
            }),
      ];
}

class _CompanyPill extends StatelessWidget {
  final Json c;
  const _CompanyPill(this.c);
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final pd = (c['distress_probability'] as num?)?.toDouble() ?? 0;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () {
        Navigator.of(context).pop();
        openCompany(context, c['company_id'], c['name']);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: k.raised, border: Border.all(color: k.line), borderRadius: BorderRadius.circular(4)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: k.forPd(pd), shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text((c['name'] ?? c['company_id']).toString().replaceAll(' Ltd', ''), style: const TextStyle(fontSize: 13)),
          const SizedBox(width: 10),
          Text(fmtPd(pd), style: KType.mono(k.forPd(pd), 12)),
          const SizedBox(width: 6),
          Icon(Icons.north_east_rounded, size: 13, color: k.muted),
        ]),
      ),
    );
  }
}

/// Render the structured reply in the user's language.
String composeAnswer(String lang, Json r) {
  String t(String key, [Map<String, Object?> a = const {}]) => translate(lang, key, a);
  final d = Json.from((r['data'] as Map?) ?? {});
  final c = r['company'] != null ? Json.from(r['company']) : null;
  switch (r['intent']) {
    case 'company_risk':
      return t('ansCompany', {'name': c!['name'], 'pd': fmtPd(c['distress_probability']), 'rating': c['implied_rating']});
    case 'compare':
      final cs = (r['companies'] as List).map((e) => Json.from(e)).toList()
        ..sort((a, b) => (b['distress_probability'] as num).compareTo(a['distress_probability'] as num));
      return t('ansCompare', {'name': cs.first['name'], 'pd': fmtPd(cs.first['distress_probability'])});
    case 'scenario':
      return t('ansScenario', {'name': c!['name'], 'from': fmtPd(d['current_risk']), 'to': fmtPd(d['scenario_risk'])});
    case 'contagion':
      return t('ansContagion', {'name': c!['name'], 'n': d['affected_count'], 'k': d['secondary_defaults']});
    case 'top_risk':
      final cs = (r['companies'] as List?) ?? [];
      if (cs.isEmpty) return t('ansHelp');
      return t('ansTopRisk', {'name': cs.first['name'], 'pd': fmtPd(cs.first['distress_probability'])});
    case 'sector':
      return t('ansSector', {'sector': r['sector'], 'pd': fmtPd(d['avg_pd']),
        'share': '${(((d['high_share'] as num?) ?? 0) * 100).round()}%'});
    case 'overview':
      return t('ansOverview', {'pd': fmtPd(d['mean_pd']), 'n': ((d['expected_defaults'] as num?) ?? 0).round()});
    case 'exposure':
      final top = ((d['top_exposures'] as List?) ?? []).take(3).map((e) => e['name'] ?? e['neighbour_id']).join(', ');
      final pp = ((d['network_uplift'] as num?) ?? 0) * 100;
      return t('ansExposure', {'pp': '${pp >= 0 ? '+' : ''}${pp.toStringAsFixed(1)}', 'names': top});
  }
  return t('ansHelp');
}
