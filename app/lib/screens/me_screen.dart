import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Me screen — Blueprint Section 6.
/// Private dashboard (Today / Week / Month / All time), activity history and
/// personal bests. Recorded walks are distinguished from verified minutes;
/// missing data is never shown as a measured zero.
class MeScreen extends StatefulWidget {
  const MeScreen({super.key, required this.state});
  final AppState state;

  @override
  State<MeScreen> createState() => _MeScreenState();
}

class _MeScreenState extends State<MeScreen> {
  late Future<Map<String, dynamic>> _activities;
  String _range = 'Week';

  @override
  void initState() {
    super.initState();
    _activities = widget.state.api.myActivities();
  }

  bool _inRange(int startedMs) {
    final now = DateTime.now();
    final start = DateTime.fromMillisecondsSinceEpoch(startedMs);
    return switch (_range) {
      'Today' => start.year == now.year &&
          start.month == now.month &&
          start.day == now.day,
      'Week' => now.difference(start).inDays < 7,
      'Month' => now.difference(start).inDays < 30,
      _ => true,
    };
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _activities,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return const Center(
              child: Text('Could not load your history. Pull to retry.'));
        }
        final all =
            (snap.data!['activities'] as List).cast<Map<String, dynamic>>();
        final inRange = all
            .where(
                (a) => a['summary'] != null && _inRange(a['started_ms'] as int))
            .toList();
        var distance = 0.0;
        var verified = 0.0;
        var best = 0.0;
        for (final a in inRange) {
          final s = a['summary'] as Map<String, dynamic>;
          final d = (s['recorded_distance_m'] as num).toDouble();
          distance += d;
          verified += (s['verified_minutes'] as num).toDouble();
          if (d > best) best = d;
        }
        return RefreshIndicator(
          onRefresh: () async {
            setState(() => _activities = widget.state.api.myActivities());
            await _activities;
          },
          child: ListView(
            padding: const EdgeInsets.all(TS.s2),
            children: [
              Text('Your private dashboard',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: TS.s1),
              Wrap(
                spacing: TS.s1,
                children: [
                  for (final r in ['Today', 'Week', 'Month', 'All time'])
                    ChoiceChip(
                      label: Text(r),
                      selected: _range == r,
                      onSelected: (_) => setState(() => _range = r),
                    ),
                ],
              ),
              const SizedBox(height: TS.s2),
              Row(
                children: [
                  _tile(
                      'Distance', '${(distance / 1000).toStringAsFixed(2)} km'),
                  _tile('Verified minutes', verified.toStringAsFixed(0)),
                  _tile(
                      'Longest walk', '${(best / 1000).toStringAsFixed(2)} km'),
                ],
              ),
              const SizedBox(height: TS.s2),
              Text('Activity history',
                  style: Theme.of(context).textTheme.titleMedium),
              if (all.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: TS.s2),
                  child: Text('No walks recorded yet. Your first walk starts '
                      'whenever you do — head to the Start tab.'),
                ),
              for (final a in all)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.directions_walk),
                    title: Text(DateFormat('EEE, d MMM, HH:mm').format(
                        DateTime.fromMillisecondsSinceEpoch(
                            a['started_ms'] as int))),
                    subtitle: Text(a['summary'] == null
                        ? 'Saved on this phone, waiting to sync'
                        : '${(a['summary']['recorded_distance_m'])} m · '
                            '${a['summary']['verified_minutes']} verified min · '
                            '${a['summary']['status']}'),
                    trailing: Icon(
                      a['summary'] == null
                          ? Icons.cloud_upload
                          : Icons.verified,
                      color: a['summary'] == null ? null : TSColors.action,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _tile(String label, String value) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(TS.s1),
            child: Column(
              children: [
                Text(value,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                Text(label, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      );
}
