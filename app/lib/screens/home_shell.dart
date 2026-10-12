import 'package:flutter/material.dart';
import '../state/app_state.dart';
import 'league_screen.dart';
import 'me_screen.dart';
import 'settings_screen.dart';
import 'start_screen.dart';

/// App shell — Blueprint Sections 1/6: first navigation is Start, League, Me.
/// (No Market tab; the academic demo stays out of consumer navigation.)
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.state});
  final AppState state;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final screens = [
      StartScreen(state: widget.state),
      LeagueScreen(state: widget.state),
      MeScreen(state: widget.state),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terrastep'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => SettingsScreen(state: widget.state)),
            ),
          ),
        ],
      ),
      body: IndexedStack(index: _tab, children: screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.directions_walk), label: 'Start'),
          NavigationDestination(
              icon: Icon(Icons.emoji_events), label: 'League'),
          NavigationDestination(icon: Icon(Icons.person), label: 'Me'),
        ],
      ),
    );
  }
}
