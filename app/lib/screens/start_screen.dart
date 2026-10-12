import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Start screen — Blueprint Section 6.
/// Readable map, own location, GPS quality, prominent Start. During a
/// session: elapsed moving time, distance, Pause and Finish come first.
/// Territory shown during a walk is PROVISIONAL until the server verifies.
///
/// Map tiles: development uses the OSM standard tiles for local testing
/// only. Production must use a licensed provider (Blueprint Section 11) —
/// swap [TileLayer.urlTemplate] for the contracted provider.
class StartScreen extends StatefulWidget {
  const StartScreen({super.key, required this.state});
  final AppState state;

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  static const _pilotCenter = LatLng(34.1688, 73.2215); // Abbottabad pilot
  String _gps = 'searching';

  @override
  void initState() {
    super.initState();
    _refreshGps();
  }

  Future<void> _refreshGps() async {
    final s = await widget.state.tracker.gpsStatus();
    if (mounted) setState(() => _gps = s);
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final st = widget.state;
        final live = st.live;
        final pos = live.lastFix != null
            ? LatLng(live.lastFix!.lat, live.lastFix!.lng)
            : _pilotCenter;
        final recording = st.phase == SessionPhase.recording ||
            st.phase == SessionPhase.paused;
        return Column(
          children: [
            Expanded(
              child: FlutterMap(
                options: MapOptions(initialCenter: pos, initialZoom: 15),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.terrastep.terrastep',
                  ),
                  const RichAttributionWidget(
                    attributions: [
                      TextSourceAttribution('© OpenStreetMap contributors'),
                    ],
                  ),
                  MarkerLayer(markers: [
                    Marker(
                      point: pos,
                      width: 36,
                      height: 36,
                      child: const Icon(Icons.my_location,
                          color: TSColors.action, size: 30),
                    ),
                  ]),
                ],
              ),
            ),
            Card(
              margin: const EdgeInsets.all(TS.s2),
              child: Padding(
                padding: const EdgeInsets.all(TS.s2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _gps == 'ready'
                              ? Icons.gps_fixed
                              : Icons.gps_not_fixed,
                          size: 18,
                          color: _gps == 'ready'
                              ? TSColors.action
                              : Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: TS.s1),
                        Text(switch (_gps) {
                          'ready' => 'GPS ready',
                          'denied' =>
                            'Location denied — ranked walks need precise location',
                          'precise_off' =>
                            'Precise location is off — ranked walks need it',
                          'off' => 'Location is off',
                          _ => 'Finding GPS…',
                        }),
                        const Spacer(),
                        if (live.lastFix != null)
                          Text(
                              '±${live.lastFix!.accuracyM.toStringAsFixed(0)} m'),
                      ],
                    ),
                    if (recording) ...[
                      const SizedBox(height: TS.s2),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _stat('Moving',
                              _fmt(Duration(milliseconds: live.movingMs))),
                          _stat('Distance',
                              '${(live.distanceM / 1000).toStringAsFixed(2)} km'),
                          _stat('Steps', live.steps?.toString() ?? '—'),
                        ],
                      ),
                      const SizedBox(height: TS.s1),
                      const Text(
                        'Progress is provisional until the server verifies your walk.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                    if (st.lastError != null) ...[
                      const SizedBox(height: TS.s1),
                      Text(st.lastError!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ],
                    const SizedBox(height: TS.s2),
                    if (!recording)
                      FilledButton.icon(
                        onPressed: st.phase == SessionPhase.starting
                            ? null
                            : () async {
                                await st.startWalk();
                                _refreshGps();
                              },
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Start walk'),
                      )
                    else
                      Row(
                        children: [
                          Expanded(
                            child: st.phase == SessionPhase.recording
                                ? OutlinedButton.icon(
                                    onPressed: st.pauseWalk,
                                    icon: const Icon(Icons.pause),
                                    label: const Text('Pause'),
                                  )
                                : OutlinedButton.icon(
                                    onPressed: st.resumeWalk,
                                    icon: const Icon(Icons.play_arrow),
                                    label: const Text('Resume'),
                                  ),
                          ),
                          const SizedBox(width: TS.s1),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () async {
                                final summary = await st.finishWalk();
                                if (summary != null && context.mounted) {
                                  _showSummary(context, summary);
                                }
                              },
                              icon: const Icon(Icons.flag),
                              label: const Text('Finish'),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _stat(String label, String value) => Column(
        children: [
          Text(value,
              style:
                  const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          Text(label),
        ],
      );

  void _showSummary(BuildContext context, Map<String, dynamic> s) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Walk complete'),
        content: Text(
          'Status: ${s['status']}\n'
          'Distance: ${s['recorded_distance_m']} m\n'
          'Verified minutes: ${s['verified_minutes']}\n'
          'Cells you hold now: ${(s['owned_cells_now'] as List).length}\n\n'
          '${s['explanation']}',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Great')),
        ],
      ),
    );
  }
}
