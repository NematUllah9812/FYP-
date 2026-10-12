package com.terrastep.terrastep

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/**
 * Durable local recording — Blueprint Section 13/14.
 * Samples persist here even if the Flutter view or the whole app process is
 * destroyed. Rows are only marked uploaded after the server acknowledges
 * them (Section 16); they are never deleted on failure.
 */
class TrackerDb(context: Context) :
    SQLiteOpenHelper(context.applicationContext, "tracker.db", null, 1) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """CREATE TABLE samples(
                 seq INTEGER PRIMARY KEY AUTOINCREMENT,
                 session_id TEXT NOT NULL,
                 t INTEGER NOT NULL,
                 lat REAL NOT NULL,
                 lng REAL NOT NULL,
                 acc REAL NOT NULL,
                 steps INTEGER,
                 uploaded INTEGER NOT NULL DEFAULT 0)"""
        )
        db.execSQL("CREATE INDEX idx_samples_session ON samples(session_id, seq)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {}

    fun insert(sessionId: String, t: Long, lat: Double, lng: Double, acc: Float, steps: Int?) {
        val v = ContentValues().apply {
            put("session_id", sessionId)
            put("t", t)
            put("lat", lat)
            put("lng", lng)
            put("acc", acc.toDouble())
            if (steps != null) put("steps", steps) else putNull("steps")
        }
        writableDatabase.insert("samples", null, v)
    }

    fun read(sessionId: String, afterSeq: Long): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        readableDatabase.query(
            "samples", arrayOf("seq", "t", "lat", "lng", "acc", "steps"),
            "session_id=? AND seq>? AND uploaded=0", arrayOf(sessionId, afterSeq.toString()),
            null, null, "seq ASC"
        ).use { c ->
            while (c.moveToNext()) {
                out.add(
                    mapOf(
                        "seq" to c.getLong(0),
                        "t" to c.getLong(1),
                        "lat" to c.getDouble(2),
                        "lng" to c.getDouble(3),
                        "acc" to c.getDouble(4),
                        "steps" to if (c.isNull(5)) null else c.getInt(5)
                    )
                )
            }
        }
        return out
    }

    fun markUploaded(sessionId: String, upToSeq: Long) {
        writableDatabase.execSQL(
            "UPDATE samples SET uploaded=1 WHERE session_id=? AND seq<=?",
            arrayOf(sessionId, upToSeq)
        )
    }

    fun discard(sessionId: String) {
        writableDatabase.execSQL("DELETE FROM samples WHERE session_id=?", arrayOf(sessionId))
    }
}
