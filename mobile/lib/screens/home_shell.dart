import 'package:flutter/material.dart';

import 'dashboard_screen.dart';
import 'alerts_screen.dart';
import 'portfolio_screen.dart';
import 'voice_screen.dart';
import 'settings_screen.dart';

/// Bottom-nav shell that hosts the main workflow modes.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  final _screens = const [
    DashboardScreen(),
    AlertsScreen(),
    PortfolioScreen(),
    VoiceScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.notifications_outlined), label: 'Alerts'),
          NavigationDestination(icon: Icon(Icons.pie_chart_outline), label: 'Portfolio'),
          NavigationDestination(icon: Icon(Icons.mic_none), label: 'Voice'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
        ],
      ),
    );
  }
}
