import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const _languages = {
    'en': 'English', 'hi': 'हिन्दी', 'ta': 'தமிழ்',
  };

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        ListTile(
          leading: const Icon(Icons.person_outline),
          title: Text(state.user?['name'] ?? 'Analyst'),
          subtitle: Text(state.user?['email'] ?? ''),
        ),
        const Divider(),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Language', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        ..._languages.entries.map((e) => RadioListTile<String>(
              title: Text(e.value),
              value: e.key,
              groupValue: state.locale.languageCode,
              onChanged: (v) => state.setLocale(v!),
            )),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.logout, color: Colors.red),
          title: const Text('Sign out', style: TextStyle(color: Colors.red)),
          onTap: () => state.logout(),
        ),
      ]),
    );
  }
}
