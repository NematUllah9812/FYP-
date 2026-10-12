import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// League screen — Blueprint Section 6/10.
/// Local board only; delayed snapshots with a cutoff time; no live opponent
/// positions, routes, or exact activity times are ever shown.
class LeagueScreen extends StatefulWidget {
  const LeagueScreen({super.key, required this.state});
  final AppState state;

  @override
  State<LeagueScreen> createState() => _LeagueScreenState();
}

class _LeagueScreenState extends State<LeagueScreen> {
  late Future<Map<String, dynamic>> _board;

  @override
  void initState() {
    super.initState();
    _board = widget.state.api.leagueBoard();
  }

  Future<void> _refresh() async {
    setState(() => _board = widget.state.api.leagueBoard());
    await _board;
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: FutureBuilder<Map<String, dynamic>>(
        future: _board,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return ListView(children: const [
              Padding(
                padding: EdgeInsets.all(TS.s3),
                child: Text('Could not load the league board. '
                    'Pull down to retry — your walks are safe on this phone.'),
              ),
            ]);
          }
          final data = snap.data!;
          final rows = (data['board'] as List).cast<Map<String, dynamic>>();
          final cutoff =
              DateTime.fromMillisecondsSinceEpoch(data['cutoff_ms'] as int);
          return ListView(
            padding: const EdgeInsets.all(TS.s2),
            children: [
              Text('Abbottabad pilot — Season 01',
                  style: Theme.of(context).textTheme.titleMedium),
              Text('Ranked by territory area. Board as of '
                  '${cutoff.hour.toString().padLeft(2, '0')}:${cutoff.minute.toString().padLeft(2, '0')} '
                  '— updates arrive in scheduled batches.'),
              const SizedBox(height: TS.s2),
              if (rows.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(TS.s2),
                    child: Text('No territory claimed yet this season. '
                        'A short walk in an empty cell can be the first claim — '
                        'or just enjoy a solo exploration walk.'),
                  ),
                ),
              for (final r in rows)
                Card(
                  child: ListTile(
                    leading: CircleAvatar(child: Text('${r['rank']}')),
                    title: Text(
                      r['nickname'] as String,
                      style: TextStyle(
                          fontWeight: (r['is_you'] as bool)
                              ? FontWeight.w700
                              : FontWeight.normal),
                    ),
                    subtitle:
                        Text('${r['cells']} cells · ${r['area_km2']} km²'),
                    trailing: (r['is_you'] as bool)
                        ? const Chip(label: Text('You'))
                        : null,
                  ),
                ),
              const SizedBox(height: TS.s2),
              const Text(
                'How ranking works: territory counts current verified cells. '
                'Points come from verified moving minutes (max 45/day), decay '
                'over 7 days, and speed never multiplies score.',
              ),
            ],
          );
        },
      ),
    );
  }
}
