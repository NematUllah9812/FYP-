import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../api/client.dart';
import '../data/sync_engine.dart';
import '../tracker/tracker_bridge.dart';

enum SessionPhase { idle, starting, recording, paused, finishing }

/// Live display stats. These are PROVISIONAL (Blueprint Section 6): only the
/// server can verify minutes and award territory.
class LiveStats {
  int elapsedMs = 0;
  int movingMs = 0;
  double distanceM = 0;
  GpsFix? lastFix;
  int? steps;

  void reset() {
    elapsedMs = 0;
    movingMs = 0;
    distanceM = 0;
    lastFix = null;
    steps = null;
  }
}

double _haversineM(GpsFix a, GpsFix b) {
  const r = 6371000.0;
  final p1 = a.lat * math.pi / 180, p2 = b.lat * math.pi / 180;
  final dp = (b.lat - a.lat) * math.pi / 180;
  final dl = (b.lng - a.lng) * math.pi / 180;
  final h = math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.asin(math.sqrt(h));
}

class AppState extends ChangeNotifier {
  AppState(this.api, this.tracker) : sync = SyncEngine(api, tracker);

  final TerrastepApi api;
  final TrackerBridge tracker;
  final SyncEngine sync;

  bool ready = false;
  bool get signedIn => api.userId != null;

  SessionPhase phase = SessionPhase.idle;
  String? sessionId;
  String? ticket;
  final live = LiveStats();
  String? lastError;
  Map<String, dynamic>? lastSummary;
  Timer? _syncTimer;
  StreamSubscription<GpsFix>? _fixSub;

  Future<void> bootstrap() async {
    await api.restoreToken();
    ready = true;
    notifyListeners();
  }

  Future<void> signUp(String email, String password, String nickname) async {
    await api.signUp(email, password, nickname);
    await api.logIn(email, password);
    notifyListeners();
  }

  Future<void> logIn(String email, String password) async {
    await api.logIn(email, password);
    notifyListeners();
  }

  Future<void> signOut() async {
    await api.signOut();
    notifyListeners();
  }

  // ------------------------------------------------------------ session flow
  Future<void> startWalk() async {
    if (phase != SessionPhase.idle) return;
    phase = SessionPhase.starting;
    lastError = null;
    notifyListeners();
    try {
      final out = await api.startSession(null);
      sessionId = out['session_id'] as String;
      ticket = out['ticket'] as String;
      live.reset();
      await tracker.start(sessionId: sessionId!);
      phase = SessionPhase.recording;
      _fixSub = tracker.fixes().listen(_onFix);
      _syncTimer = sync.startPeriodicSync(sessionId!, ticket!);
    } catch (e) {
      phase = SessionPhase.idle;
      lastError = 'Could not start a ranked session. Check your connection — '
          'you can still record a personal walk once tracking starts.';
      // If the server could not issue a ticket, do not start GPS recording
      // pretending it is ranked (Blueprint Section 16 connectivity rules).
    }
    notifyListeners();
  }

  void _onFix(GpsFix fix) {
    final prev = live.lastFix;
    if (prev != null) {
      final dt = fix.tMs - prev.tMs;
      if (dt > 0 && dt <= 60000) {
        final d = _haversineM(prev, fix);
        final speed = d / (dt / 1000);
        if (speed <= 3.5 && d >= 3) {
          live.distanceM += d;
          if (speed >= 0.3) live.movingMs += dt;
        }
        live.elapsedMs += dt;
      }
    }
    live.lastFix = fix;
    if (fix.stepsTotal != null) live.steps = fix.stepsTotal;
    notifyListeners();
  }

  Future<void> pauseWalk() async {
    if (phase != SessionPhase.recording) return;
    await tracker.pause();
    phase = SessionPhase.paused;
    notifyListeners();
  }

  Future<void> resumeWalk() async {
    if (phase != SessionPhase.paused) return;
    await tracker.resume();
    phase = SessionPhase.recording;
    notifyListeners();
  }

  /// Finish: stop tracking, flush the outbox, then ask the server to close
  /// the session. If the flush fails (offline), the local record is kept
  /// and the session stays "waiting to sync" — never lost (Section 6).
  Future<Map<String, dynamic>?> finishWalk() async {
    if (sessionId == null) return null;
    phase = SessionPhase.finishing;
    notifyListeners();
    _syncTimer?.cancel();
    await _fixSub?.cancel();
    await tracker.stop();
    try {
      await sync.syncPending(sessionId!, ticket!);
      lastSummary = await api.finishSession(sessionId!);
    } catch (e) {
      lastError =
          'Saved on this phone, waiting to sync. Your walk is not lost.';
      phase = SessionPhase.idle;
      notifyListeners();
      return null;
    }
    final summary = lastSummary;
    sessionId = null;
    ticket = null;
    phase = SessionPhase.idle;
    notifyListeners();
    return summary;
  }
}
