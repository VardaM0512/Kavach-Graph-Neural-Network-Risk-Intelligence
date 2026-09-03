import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../services/api_client.dart';
import '../state/app_state.dart';

/// Voice assistant: speak a query, get a spoken multilingual risk answer.
///
/// On-device STT/TTS via speech_to_text + flutter_tts for the interactive path;
/// the backend /api/voice/* endpoints provide the server-side pipeline and the
/// multilingual answer generation.
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key});
  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _available = false;
  bool _listening = false;
  String _transcript = '';
  String _answer = '';

  @override
  void initState() {
    super.initState();
    _stt.initialize().then((v) => setState(() => _available = v));
  }

  Future<void> _toggle() async {
    final lang = context.read<AppState>().locale.languageCode;
    if (_listening) {
      await _stt.stop();
      setState(() => _listening = false);
      await _answerQuery(_transcript, lang);
    } else {
      setState(() { _listening = true; _answer = ''; });
      await _stt.listen(
        localeId: lang,
        onResult: (r) => setState(() => _transcript = r.recognizedWords),
      );
    }
  }

  Future<void> _answerQuery(String text, String lang) async {
    // Extract a company id and ask the backend for a spoken-ready summary.
    final match = RegExp(r'[Cc]\d{3,4}').firstMatch(text);
    final api = context.read<ApiClient>();
    String answer;
    if (match != null) {
      final id = match.group(0)!.toUpperCase().padLeft(5, '0');
      try {
        final p = await api.predict(id);
        answer = '$id distress risk is ${((p['distress_probability'] ?? 0) * 100).toStringAsFixed(0)} '
            'percent, rated ${p['risk_band']}.';
      } catch (_) {
        answer = 'Company not found.';
      }
    } else {
      final w = await api.earlyWarnings();
      answer = 'There are ${w['count']} high-risk companies right now.';
    }
    setState(() => _answer = answer);
    await _tts.setLanguage(lang);
    await _tts.speak(answer);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Voice assistant')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_available ? 'Ask about a company, e.g. "risk on C0007"'
                : 'Speech recognition unavailable on this device'),
            const SizedBox(height: 24),
            GestureDetector(
              onTap: _available ? _toggle : null,
              child: CircleAvatar(
                radius: 56,
                backgroundColor: _listening ? Colors.red : Theme.of(context).colorScheme.primary,
                child: Icon(_listening ? Icons.stop : Icons.mic, size: 48, color: Colors.white),
              ),
            ),
            const SizedBox(height: 24),
            if (_transcript.isNotEmpty) Text('“$_transcript”',
                style: const TextStyle(fontStyle: FontStyle.italic)),
            const SizedBox(height: 12),
            if (_answer.isNotEmpty)
              Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(_answer))),
          ]),
        ),
      ),
    );
  }
}
