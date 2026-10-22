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
import androidx.core.app.Person
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat

/**
 * Run notifications:
 *  - while any session is running, a quiet ongoing notification (backed by a foreground
 *    service) keeps the process — and so the WebSocket — alive when the app is in the background;
 *  - when a run finishes while the app isn't visible, a "done" notification that opens that session.
 */
object Notifier {
    const val EXTRA_SESSION = "session"
    const val EXTRA_BUBBLE = "bubble"
    private const val CH_DONE = "done"
    private const val CH_BUBBLE = "chat"
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
            NotificationChannel(CH_BUBBLE, "Chats", NotificationManager.IMPORTANCE_HIGH)
                .apply { description = "Chat notifications that can be shown as bubbles"; setShowBadge(true) }
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


    // --- bubbles -------------------------------------------------------------------

    private fun shortcutId(sid: String) = "chat_$sid"

    private fun bubbleIntent(ctx: Context, sid: String): PendingIntent {
        val i = Intent(ctx, BubbleActivity::class.java)
            .putExtra(EXTRA_SESSION, sid)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            ctx, shortcutId(sid).hashCode(), i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    /**
     * Publishes (or refreshes) the conversation shortcut a bubble needs on Android 11+.
     * Long-lived so it survives reboots, matching the persistent watch notification.
     */
    private fun publishShortcut(ctx: Context, sid: String, title: String) {
        val person = Person.Builder().setName(title.ifBlank { "Pi" }).setImportant(true).build()
        val info = ShortcutInfoCompat.Builder(ctx, shortcutId(sid))
            .setShortLabel(title.ifBlank { "Pi" })
            .setLongLabel(title.ifBlank { "Pi" })
            .setIcon(IconCompat.createWithResource(ctx, android.R.drawable.stat_notify_chat))
            .setPerson(person)
            .setLongLived(true)
            .setIntent(Intent(ctx, BubbleActivity::class.java).putExtra(EXTRA_SESSION, sid).setAction(Intent.ACTION_VIEW))
            .build()
        runCatching { ShortcutManagerCompat.pushDynamicShortcut(ctx, info) }
    }

    /**
     * Posts/updates the chat as a bubble. The notification itself is silent and grouped;
     * tapping the bubble opens [BubbleActivity] in a floating window.
     */
    fun bubble(ctx: Context, sid: String, title: String, detail: String, ping: Boolean) {
        if (!canPost(ctx)) return
        publishShortcut(ctx, sid, title)
        val bubble = NotificationCompat.BubbleMetadata.Builder(bubbleIntent(ctx, sid), IconCompat.createWithResource(ctx, R.mipmap.ic_launcher))
            .setDesiredHeight(600)
            .setAutoExpandBubble(false)
            .setSuppressNotification(false)
            .build()
        val person = Person.Builder().setName(title.ifBlank { "Pi" }).setImportant(true).build()
        val n = NotificationCompat.Builder(ctx, CH_BUBBLE)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title.ifBlank { "Pi" })
            .setContentText(detail.ifBlank { "Pi" })
            .setContentIntent(bubbleIntent(ctx, sid))
            .setBubbleMetadata(bubble)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setShortcutId(shortcutId(sid))
            .addPerson(person)
            .setStyle(NotificationCompat.MessagingStyle(person)
                .setConversationTitle(title.ifBlank { "Pi" })
                .addMessage(detail.ifBlank { "Pi" }, System.currentTimeMillis(), person))
            .setSilent(!ping)
            .setAutoCancel(false)
            .setOngoing(true)
            .build()
        NotificationManagerCompat.from(ctx).notify(bubbleId(sid), n)
    }

    private fun bubbleId(sid: String) = sid.hashCode() xor 0x3C3C3C3C

    fun unbubble(ctx: Context, sid: String) {
        NotificationManagerCompat.from(ctx).cancel(bubbleId(sid))
        runCatching { ShortcutManagerCompat.removeDynamicShortcuts(ctx, listOf(shortcutId(sid))) }
    }

    /** False when the user turned bubbles off for the app in system settings. */
    fun bubblesEnabled(ctx: Context): Boolean =
        ctx.getSystemService(NotificationManager::class.java).areBubblesAllowed()

    fun isBubbled(ctx: Context, sid: String): Boolean =
        NotificationManagerCompat.from(ctx).activeNotifications.any { it.id == bubbleId(sid) }

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
