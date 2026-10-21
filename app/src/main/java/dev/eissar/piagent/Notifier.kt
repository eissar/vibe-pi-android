package dev.eissar.piagent

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Run notifications:
 *  - while any session is running, a quiet ongoing notification (backed by a foreground
 *    service) keeps the process — and so the WebSocket — alive when the app is in the background;
 *  - when a run finishes while the app isn't visible, a "done" notification that opens that session.
 */
object Notifier {
    const val EXTRA_SESSION = "session"
    private const val CH_DONE = "done"
    private const val CH_WORKING = "working"
    private const val CH_WATCH = "watch"
    const val WORKING_ID = 1

    fun init(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CH_DONE, "Run finished", NotificationManager.IMPORTANCE_DEFAULT)
                .apply { description = "When the agent finishes while Pi is in the background" }
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_WATCH, "Watched chats", NotificationManager.IMPORTANCE_DEFAULT)
                .apply { description = "Live status of chats you watch; pings when their state changes" }
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_WORKING, "Agent working", NotificationManager.IMPORTANCE_MIN)
                .apply { description = "Keeps the connection alive while a run is in progress"; setShowBadge(false) }
        )
    }

    private fun openIntent(ctx: Context, sessionId: String?): PendingIntent {
        val i = Intent(ctx, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        if (sessionId != null) i.putExtra(EXTRA_SESSION, sessionId)
        return PendingIntent.getActivity(
            ctx, sessionId?.hashCode() ?: 0, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun canPost(ctx: Context) = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun finished(ctx: Context, sessionId: String, title: String, detail: String?) {
        if (!canPost(ctx)) return
        val n = NotificationCompat.Builder(ctx, CH_DONE)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title.ifBlank { "Pi" })
            .setContentText(detail?.takeIf { it.isNotBlank() } ?: "Finished")
            .setStyle(detail?.let { NotificationCompat.BigTextStyle().bigText(it) })
            .setContentIntent(openIntent(ctx, sessionId))
            .setAutoCancel(true)
            .build()
        NotificationManagerCompat.from(ctx).notify(sessionId.hashCode(), n)
    }

    private fun watchId(sid: String) = sid.hashCode() xor 0x5A5A5A5A

    /** Persistent per-chat status notification; [ping] = audible, otherwise a silent update. */
    fun watch(ctx: Context, sid: String, title: String, state: WatchState, detail: String, ping: Boolean) {
        if (!canPost(ctx)) return
        val icon = when (state) {
            WatchState.Working -> android.R.drawable.stat_notify_sync
            WatchState.NeedsInput -> android.R.drawable.stat_notify_more
            WatchState.Error -> android.R.drawable.stat_notify_error
            WatchState.Idle -> android.R.drawable.stat_notify_chat
        }
        val n = NotificationCompat.Builder(ctx, CH_WATCH)
            .setSmallIcon(icon)
            .setContentTitle(title.ifBlank { "Pi" })
            .setSubText(state.label)
            .setContentText(detail.ifBlank { state.label })
            .setStyle(NotificationCompat.BigTextStyle().bigText(detail.ifBlank { state.label }))
            .setContentIntent(openIntent(ctx, sid))
            .setOngoing(true)
            .setSilent(!ping)
            .setOnlyAlertOnce(false)
            .setGroup("watch")
            .build()
        NotificationManagerCompat.from(ctx).notify(watchId(sid), n)
    }

    fun unwatch(ctx: Context, sid: String) = NotificationManagerCompat.from(ctx).cancel(watchId(sid))

    fun clear(ctx: Context, sessionId: String) = NotificationManagerCompat.from(ctx).cancel(sessionId.hashCode())

    fun workingNotification(ctx: Context, count: Int) = NotificationCompat.Builder(ctx, CH_WORKING)
        .setSmallIcon(android.R.drawable.stat_notify_sync)
        .setContentTitle("Pi is connected")
        .setContentText(if (count == 1) "1 active or watched chat" else "$count active or watched chats")
        .setContentIntent(openIntent(ctx, null))
        .setOngoing(true)
        .setSilent(true)
        .build()

    /** Start/update/stop the keep-alive service for [count] running sessions. */
    fun working(ctx: Context, count: Int) {
        val i = Intent(ctx, RunService::class.java).putExtra("count", count)
        if (count > 0) {
            // Starting a foreground service is refused while the app is fully in the background;
            // in that case we simply rely on the process staying alive on its own.
            runCatching { ContextCompat.startForegroundService(ctx, i) }
        } else ctx.stopService(i)
    }
}

class RunService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val count = intent?.getIntExtra("count", 1) ?: 1
        ServiceCompat.startForeground(
            this, Notifier.WORKING_ID, Notifier.workingNotification(this, count),
            if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0,
        )
        return START_NOT_STICKY
    }
}
