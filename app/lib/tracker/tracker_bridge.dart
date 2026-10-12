import 'dart:async';
import 'package:flutter/services.dart';

/// Bridge to the native Kotlin tracker — Blueprint Section 13.
/// The Kotlin module owns the Fused Location Provider, motion sensors,
/// foreground-service lifecycle and durable local recording. Flutter owns
/// presentation and orchestration; samples persist natively even if this
/// Dart side is destroyed.
class GpsFix {
  GpsFix(
      {required this.tMs,
      required this.lat,
      required this.lng,
      required this.accuracyM,
      this.stepsTotal});
  final int tMs;
  final double lat;
  final double lng;
  final double accuracyM;
  final int? stepsTotal;

  Map<String, dynamic> toJson() => {
        't': tMs,
        'lat': lat,
        'lng': lng,
        'acc': accuracyM,
        if (stepsTotal != null) 'steps': stepsTotal,
      };

  factory GpsFix.fromMap(Map<dynamic, dynamic> m) => GpsFix(
        tMs: (m['t'] as num).toInt(),
        lat: (m['lat'] as num).toDouble(),
        lng: (m['lng'] as num).toDouble(),
        accuracyM: (m['acc'] as num?)?.toDouble() ?? 999,
        stepsTotal: (m['steps'] as num?)?.toInt(),
      );
}

class TrackerBridge {
  static const _methods = MethodChannel('terrastep/tracker');
  static const _events = EventChannel('terrastep/tracker_events');

  Stream<GpsFix>? _fixStream;

  /// Live fix stream while the app is in the foreground. When the app is
  /// backgrounded/destroyed the service keeps recording natively; unsent
  /// samples are pulled later with [readSamples].
  Stream<GpsFix> fixes() {
    _fixStream ??= _events
        .receiveBroadcastStream()
        .where((e) => e is Map && e['type'] == 'fix')
        .map((e) => GpsFix.fromMap(e as Map));
    return _fixStream!;
  }

  Future<void> start({required String sessionId}) =>
      _methods.invokeMethod('start', {'sessionId': sessionId});

  Future<void> pause() => _methods.invokeMethod('pause');
  Future<void> resume() => _methods.invokeMethod('resume');
  Future<void> stop() => _methods.invokeMethod('stop');

  /// GPS quality for the Start screen indicator (Blueprint Section 6):
  /// 'ready' | 'searching' | 'denied' | 'precise_off' | 'off'
  Future<String> gpsStatus() async =>
      await _methods.invokeMethod<String>('gpsStatus') ?? 'off';

  /// Samples recorded natively since [afterSeq] (durable local store).
  /// Each sample: {seq, t, lat, lng, acc, steps}
  Future<List<Map<String, dynamic>>> readSamples(int afterSeq) async {
    final raw = await _methods
        .invokeMethod<List<dynamic>>('readSamples', {'afterSeq': afterSeq});
    return (raw ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> markUploaded(int upToSeq) =>
      _methods.invokeMethod('markUploaded', {'upToSeq': upToSeq});

  Future<void> discardSession() => _methods.invokeMethod('discardSession');
}
