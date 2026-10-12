package com.terrastep.terrastep

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter <-> native bridge (channels defined in tracker_bridge.dart).
 * Flutter owns orchestration; this activity only forwards commands to the
 * tracker service / durable store and reports GPS readiness.
 */
class MainActivity : FlutterActivity() {

    private val methodsChannel = "terrastep/tracker"
    private val eventsChannel = "terrastep/tracker_events"
    private lateinit var db: TrackerDb

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        db = TrackerDb(this)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventsChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    TrackerEvents.listener = { event ->
                        runOnUiThread { sink?.success(event) }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    TrackerEvents.listener = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val sessionId = call.argument<String>("sessionId")
                        if (sessionId == null) {
                            result.error("bad_args", "sessionId required", null)
                        } else {
                            getSharedPreferences("terrastep", Context.MODE_PRIVATE)
                                .edit().putString("last_session", sessionId).apply()
                            val intent = Intent(this, TrackerService::class.java)
                                .setAction(TrackerService.ACTION_START)
                                .putExtra(TrackerService.EXTRA_SESSION, sessionId)
                            ContextCompat.startForegroundService(this, intent)
                            result.success(null)
                        }
                    }
                    "pause" -> {
                        startService(Intent(this, TrackerService::class.java).setAction(TrackerService.ACTION_PAUSE))
                        result.success(null)
                    }
                    "resume" -> {
                        startService(Intent(this, TrackerService::class.java).setAction(TrackerService.ACTION_RESUME))
                        result.success(null)
                    }
                    "stop" -> {
                        startService(Intent(this, TrackerService::class.java).setAction(TrackerService.ACTION_STOP))
                        result.success(null)
                    }
                    "gpsStatus" -> result.success(gpsStatus())
                    "readSamples" -> {
                        val session = TrackerService.runningSessionId ?: lastSessionHint()
                        val after = (call.argument<Number>("afterSeq")?.toLong()) ?: 0L
                        if (session == null) result.success(emptyList<Any>())
                        else result.success(db.read(session, after))
                    }
                    "markUploaded" -> {
                        val session = TrackerService.runningSessionId ?: lastSessionHint()
                        val upTo = (call.argument<Number>("upToSeq")?.toLong()) ?: 0L
                        if (session != null) db.markUploaded(session, upTo)
                        result.success(null)
                    }
                    "discardSession" -> {
                        val session = TrackerService.runningSessionId ?: lastSessionHint()
                        if (session != null) db.discard(session)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // The sync engine may run after the service stopped (e.g. Finish flow
    // reads remaining samples): the last session id is kept in prefs.
    private fun lastSessionHint(): String? =
        getSharedPreferences("terrastep", Context.MODE_PRIVATE).getString("last_session", null)

    private fun gpsStatus(): String {
        val fine = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
        val coarse = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION)
        if (fine != PackageManager.PERMISSION_GRANTED && coarse != PackageManager.PERMISSION_GRANTED) {
            return "denied"
        }
        val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val gpsOn = try {
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER)
        } catch (_: Exception) {
            false
        }
        if (!gpsOn) return "off"
        if (fine != PackageManager.PERMISSION_GRANTED) return "precise_off"
        // High-accuracy mode check (best effort across API levels).
        val mode = try {
            @Suppress("DEPRECATION")
            Settings.Secure.getInt(contentResolver, Settings.Secure.LOCATION_MODE)
        } catch (_: Exception) {
            Settings.Secure.LOCATION_MODE_HIGH_ACCURACY
        }
        return if (mode == Settings.Secure.LOCATION_MODE_HIGH_ACCURACY ||
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
        ) "ready" else "searching"
    }
}
