package com.terrastep.terrastep

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority

/** Event sink wired by MainActivity to the Flutter EventChannel. */
object TrackerEvents {
    @Volatile var listener: ((Map<String, Any?>) -> Unit)? = null
    fun emit(event: Map<String, Any?>) {
        listener?.invoke(event)
    }
}

/**
 * Foreground tracking service — Blueprint Section 13.
 * Explicitly user-started, with a visible ongoing notification and a Stop
 * action. Sampling adapts: ~5 s while moving, relaxed when stationary.
 * On service stop (including OEM kills we cannot prevent), already-recorded
 * samples remain durable in TrackerDb and the session can be recovered —
 * the app surfaces an interruption honestly instead of fabricating data.
 */
class TrackerService : Service(), SensorEventListener {

    companion object {
        const val ACTION_START = "terrastep.START"
        const val ACTION_PAUSE = "terrastep.PAUSE"
        const val ACTION_RESUME = "terrastep.RESUME"
        const val ACTION_STOP = "terrastep.STOP"
        const val EXTRA_SESSION = "session_id"
        private const val CHANNEL_ID = "terrastep_tracking"
        private const val NOTIF_ID = 41

        @Volatile var runningSessionId: String? = null
            private set
        @Volatile var isPaused: Boolean = false
            private set
    }

    private lateinit var fused: FusedLocationProviderClient
    private lateinit var db: TrackerDb
    private var sensorManager: SensorManager? = null
    private var stepBaseline: Float? = null
    private var stepsNow: Int? = null
    private var slowFixes = 0
    private var currentIntervalMs = 5_000L

    private val locationCallback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            val session = runningSessionId ?: return
            if (isPaused) return
            for (loc in result.locations) {
                db.insert(
                    session, loc.time, loc.latitude, loc.longitude,
                    if (loc.hasAccuracy()) loc.accuracy else 999f, stepsNow
                )
                TrackerEvents.emit(
                    mapOf(
                        "type" to "fix",
                        "t" to loc.time,
                        "lat" to loc.latitude,
                        "lng" to loc.longitude,
                        "acc" to (if (loc.hasAccuracy()) loc.accuracy.toDouble() else 999.0),
                        "steps" to stepsNow
                    )
                )
                // Stationary relaxation (Section 13): sustained near-zero
                // speed relaxes sampling to 30 s; movement restores 5 s.
                val speed = if (loc.hasSpeed()) loc.speed else -1f
                if (speed in 0f..0.3f) {
                    slowFixes++
                    if (slowFixes >= 3 && currentIntervalMs != 30_000L) requestUpdates(30_000L)
                } else if (speed > 0.3f) {
                    slowFixes = 0
                    if (currentIntervalMs != 5_000L) requestUpdates(5_000L)
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        fused = LocationServices.getFusedLocationProviderClient(this)
        db = TrackerDb(this)
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                runningSessionId = intent.getStringExtra(EXTRA_SESSION)
                isPaused = false
                stepBaseline = null
                startForeground(NOTIF_ID, buildNotification("Recording your walk"))
                registerSteps()
                requestUpdates(5_000L)
            }
            ACTION_PAUSE -> {
                isPaused = true
                updateNotification("Walk paused")
            }
            ACTION_RESUME -> {
                isPaused = false
                updateNotification("Recording your walk")
            }
            ACTION_STOP -> stopTracking()
        }
        // START_NOT_STICKY: after a force-stop we do not silently restart
        // GPS; the app offers session recovery instead (Section 13).
        return START_NOT_STICKY
    }

    private fun requestUpdates(intervalMs: Long) {
        currentIntervalMs = intervalMs
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) return
        val req = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, intervalMs)
            .setMinUpdateIntervalMillis(intervalMs / 2)
            .setWaitForAccurateLocation(false)
            .build()
        fused.removeLocationUpdates(locationCallback)
        fused.requestLocationUpdates(req, locationCallback, Looper.getMainLooper())
    }

    private fun registerSteps() {
        val sensor = sensorManager?.getDefaultSensor(Sensor.TYPE_STEP_COUNTER) ?: return
        sensorManager?.registerListener(this, sensor, SensorManager.SENSOR_DELAY_NORMAL)
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_STEP_COUNTER) return
        val total = event.values[0]
        val baseline = stepBaseline
        if (baseline == null || total < baseline) {
            // First reading, or the cumulative counter reset after reboot
            // (Section 12): re-baseline instead of inventing a huge delta.
            stepBaseline = total
            stepsNow = 0
        } else {
            stepsNow = (total - baseline).toInt()
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    private fun stopTracking() {
        fused.removeLocationUpdates(locationCallback)
        sensorManager?.unregisterListener(this)
        runningSessionId = null
        isPaused = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Walk tracking", NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    private fun buildNotification(text: String): Notification {
        val openApp = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = PendingIntent.getService(
            this, 1,
            Intent(this, TrackerService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("Terrastep")
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(openApp)
            .addAction(android.R.drawable.ic_media_pause, "Stop", stopIntent)
            .build()
    }

    private fun updateNotification(text: String) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIF_ID, buildNotification(text))
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        try {
            fused.removeLocationUpdates(locationCallback)
        } catch (_: Exception) {
        }
        super.onDestroy()
    }
}
