import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/client.dart';
import '../tracker/tracker_bridge.dart';

/// Upload/outbox engine — Blueprint Sections 14/16.
/// Samples live in the native tracker's durable store until the server
/// acknowledges them. Uploads are chunked, idempotent (batch_id derived
/// from the sequence range), and retried with backoff. Nothing is deleted
/// on failure: "Saved on this phone, waiting to sync" is a distinct state
/// from "Verified" (Blueprint Section 6).
class SyncEngine {
  SyncEngine(this.api, this.tracker);

  final TerrastepApi api;
  final TrackerBridge tracker;

  static const _batchSize = 60; // ~5 min at the moving sampling interval

  String _key(String sessionId) => 'uploaded_seq_$sessionId';

  Future<int> _uploadedSeq(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_key(sessionId)) ?? 0;
  }

  Future<void> _setUploadedSeq(String sessionId, int seq) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key(sessionId), seq);
  }

  /// Upload every sample the server has not yet acknowledged.
  /// Returns the last server receipt, or null when nothing was pending
  /// or the device is offline (samples simply stay in the outbox).
  Future<Map<String, dynamic>?> syncPending(
      String sessionId, String ticket) async {
    Map<String, dynamic>? lastReceipt;
    var after = await _uploadedSeq(sessionId);
    while (true) {
      final samples = await tracker.readSamples(after);
      if (samples.isEmpty) break;
      final chunk = samples.take(_batchSize).toList();
      final firstSeq = (chunk.first['seq'] as num).toInt();
      final lastSeq = (chunk.last['seq'] as num).toInt();
      final batch = <String, dynamic>{
        // Deterministic idempotency key: a retry of the same range is the
        // same batch_id, so the server returns the stored receipt.
        'batch_id': 'seq-$firstSeq-$lastSeq',
        'seq_from': firstSeq,
        'seq_to': lastSeq,
        'samples': chunk
            .map((s) => {
                  't': s['t'],
                  'lat': s['lat'],
                  'lng': s['lng'],
                  'acc': s['acc'],
                  if (s['steps'] != null) 'steps': s['steps'],
                })
            .toList(),
      };
      try {
        lastReceipt = await api.uploadBatch(sessionId, ticket, batch);
      } on ApiException catch (e) {
        if (e.status == 409) {
          // Same range, different content: do not loop forever; surface it.
          rethrow;
        }
        return lastReceipt; // offline / server down: keep the outbox as-is
      } catch (_) {
        return lastReceipt; // connectivity failure: retry later
      }
      await _setUploadedSeq(sessionId, lastSeq);
      await tracker.markUploaded(lastSeq);
      after = lastSeq;
      if (samples.length <= _batchSize) break;
    }
    return lastReceipt;
  }

  /// Periodic sync while a session is live (about every 60 s, Section 13).
  Timer startPeriodicSync(String sessionId, String ticket,
      {Duration every = const Duration(seconds: 60)}) {
    return Timer.periodic(every, (_) {
      syncPending(sessionId, ticket).catchError((_) => null);
    });
  }
}
