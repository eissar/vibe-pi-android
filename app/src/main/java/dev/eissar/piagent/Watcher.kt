package dev.eissar.piagent

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

/** Coarse state of a watched chat; a change in this (after debounce) pings the user. */
enum class WatchState(val label: String) { Idle("Idle"), Working("Working"), NeedsInput("Waiting for your input"), Error("Error") }

/**
 * Watched chats: each gets a persistent notification showing its live status
 * (updated silently), a bubble (when bubbles are enabled for the app), and an
 * audible ping when its [WatchState] changes and then stays unchanged for
 * [PING_DEBOUNCE_MS].
 */
class Watcher(private val ctx: Context, private val scope: CoroutineScope) {
    private class Entry(val sid: String, var title: String) {
        var state = WatchState.Idle
        var detail = ""
        var pingJob: Job? = null
        var unsubscribe: (() -> Unit)? = null
    }

    private val prefs = ctx.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val entries = LinkedHashMap<String, Entry>()

    init {
        prefs.getStringSet("watched", emptySet())!!.forEach { line ->
            val sid = line.substringBefore('\t')
            entries[sid] = Entry(sid, line.substringAfter('\t', "Session"))
        }
    }

    val ids: Set<String> get() = entries.keys
    fun isWatched(sid: String?) = sid != null && sid in entries

    private fun save() = prefs.edit().putStringSet("watched", entries.values.map { "${it.sid}\t${it.title}" }.toSet()).apply()

    fun add(sid: String, title: String, running: Boolean) {
        val e = entries.getOrPut(sid) { Entry(sid, title) }
        e.title = title
        e.state = if (running) WatchState.Working else WatchState.Idle
        save()
        post(e, ping = false)
    }

    fun remove(sid: String) {
        val e = entries.remove(sid) ?: return
        e.pingJob?.cancel()
        e.unsubscribe?.invoke()
        save()
        Notifier.unwatch(ctx, sid)
        Notifier.unbubble(ctx, sid)
    }

    fun setTitle(sid: String, title: String) {
        val e = entries[sid] ?: return
        if (e.title == title || title.isBlank()) return
        e.title = title; save(); post(e, ping = false)
    }

    /** (Re)subscribe each watched session's events on a fresh connection. */
    fun attach(rpc: PiRpc, onMain: (() -> Unit) -> Unit) {
        for (e in entries.values) {
            e.unsubscribe?.invoke()
            e.unsubscribe = rpc.subscribe("agent.events", e.sid) { ev -> onMain { onEvent(e.sid, ev as? JsonObject ?: return@onMain) } }
        }
    }

    fun subscribe(sid: String, rpc: PiRpc?, onMain: (() -> Unit) -> Unit) {
        val e = entries[sid] ?: return
        e.unsubscribe?.invoke()
        e.unsubscribe = rpc?.subscribe("agent.events", sid) { ev -> onMain { onEvent(sid, ev as? JsonObject ?: return@onMain) } }
    }

    /** Server-wide running set (agent.running). */
    fun onRunning(ids: Set<String>) {
        for (e in entries.values) {
            val running = e.sid in ids
            when {
                running && e.state == WatchState.Idle -> update(e, WatchState.Working, "Working…")
                !running && e.state == WatchState.Working -> update(e, WatchState.Idle, "Finished")
            }
        }
    }

    private fun onEvent(sid: String, ev: JsonObject) {
        val e = entries[sid] ?: return
        when (ev.str("type")) {
            "agent_start" -> update(e, WatchState.Working, "Thinking…")
            "message_update" -> if (e.detail != "Writing…") update(e, WatchState.Working, "Writing…")
            "tool_execution_start" -> update(e, WatchState.Working, "Running ${ev.str("toolName")}…")
            "auto_compaction_start", "compaction_start" -> update(e, WatchState.Working, "Compacting…")
            "auto_retry_start" -> update(e, WatchState.Working, "Retrying…")
            "extension_ui_request" -> when (ev.str("method")) {
                "select", "confirm", "input", "editor" ->
                    update(e, WatchState.NeedsInput, ev.str("title").ifBlank { "Waiting for your input" })
            }
            "message_end" -> ev.obj("message")?.takeIf { it.str("role") == "assistant" }?.let { m ->
                val err = m.str("errorMessage")
                if (err.isNotEmpty()) update(e, WatchState.Error, err)
                else lastText(m)?.let { e.detail = it }
            }
            "prompt_error" -> update(e, WatchState.Error, ev.str("errorMessage").ifBlank { "Failed" })
            "agent_end", "prompt_done" -> if (e.state != WatchState.Error) update(e, WatchState.Idle, e.detail.takeIf {
                it.isNotBlank() && !it.endsWith("…")
            } ?: "Finished")
        }
    }

    private fun lastText(m: JsonObject): String? =
        m.objs("content").filter { it.str("type") == "text" }.joinToString("\n") { it.str("text") }.trim().takeIf { it.isNotEmpty() }?.take(300)

    private fun update(e: Entry, state: WatchState, detail: String) {
        val previous = e.state
        e.state = state
        e.detail = detail
        post(e, ping = false) // live text, always silent
        if (state == previous) return
        // Only a completed agent turn is allowed to make a sound: the transition back to Idle
        // after the chat was actually working. Errors, waiting-for-input and the start of work
        // update the notification silently.
        if (state != WatchState.Idle || previous != WatchState.Working) return
        // Debounce so a turn that immediately queues another one doesn't chirp twice.
        e.pingJob?.cancel()
        e.pingJob = scope.launch {
            delay(PING_DEBOUNCE_MS)
            if (e.state == WatchState.Idle) post(e, ping = true)
        }
    }

    /** Watched chats are also bubbled: one notification + bubble per chat, kept in sync here. */
    private fun post(e: Entry, ping: Boolean) {
        Notifier.watch(ctx, e.sid, e.title, e.state, e.detail, ping)
        if (bubbles) Notifier.bubble(ctx, e.sid, e.title, e.detail.ifBlank { e.state.label }, ping)
    }

    /** User preference (system setting permitting): watched chats show as bubbles. */
    private var bubbles = prefs.getBoolean("bubbleWatched", true)

    fun setBubbles(on: Boolean) {
        bubbles = on
        prefs.edit().putBoolean("bubbleWatched", on).apply()
        entries.values.forEach { e ->
            if (bubbles) post(e, ping = false) else Notifier.unbubble(ctx, e.sid)
        }
    }

    fun bubblesOn(): Boolean = bubbles

    /** Re-post all (e.g. after process restart) without pinging. */
    fun repostAll() = entries.values.forEach { post(it, ping = false) }

    companion object { const val PING_DEBOUNCE_MS = 5_000L }
}
