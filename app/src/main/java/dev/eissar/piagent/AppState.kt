package dev.eissar.piagent

import android.app.Application
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant

data class Session(val id: String, val title: String, val cwd: String, val modified: Long, val count: Int)
/** Token counts; cost in USD. */
data class Usage(val input: Double = 0.0, val output: Double = 0.0, val cacheRead: Double = 0.0, val cacheWrite: Double = 0.0, val cost: Double = 0.0) {
    operator fun plus(o: Usage) = Usage(input + o.input, output + o.output, cacheRead + o.cacheRead, cacheWrite + o.cacheWrite, cost + o.cost)
    companion object {
        /** From an assistant message's `usage` object. */
        fun of(u: JsonObject?): Usage? = u?.let {
            Usage(it.num("input"), it.num("output"), it.num("cacheRead"), it.num("cacheWrite"), it.obj("cost").num("total"))
        }
    }
}
data class ContextUsage(val tokens: Double?, val window: Double, val percent: Double?)
data class Model(val provider: String, val id: String, val name: String)
/** An extension_ui_request awaiting the user's answer (select / confirm / input / editor). */
data class Ask(val sessionId: String, val req: JsonObject) {
    val id get() = req.str("id")
    val method get() = req.str("method")
}

enum class Conn { Offline, Connecting, Online }

class AppState(val app: Application) {
    /** Process-wide scope: the state can outlive (and be shared by) activities, e.g. bubbled chats. */
    val viewModelScope = kotlinx.coroutines.CoroutineScope(
        kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Main.immediate
    )
    private val prefs = app.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private var rpc: PiRpc? = null
    private var wantOnline = false
    private var retryJob: Job? = null

    // connection
    var address by mutableStateOf(prefs.getString("address", "") ?: "")
    var token by mutableStateOf(prefs.getString("token", "") ?: "")
    var conn by mutableStateOf(Conn.Offline); private set
    var connError by mutableStateOf<String?>(null); private set

    // sessions
    val sessions = mutableStateListOf<Session>()
    val running = mutableStateMapOf<String, Boolean>()
    var defaultCwd by mutableStateOf(""); private set
    val models = mutableStateListOf<Model>()
    private var defaultModel: Model? = null
    /** Supported thinking levels per "provider:modelId". */
    private val thinkingLevels = mutableStateMapOf<String, List<String>>()
    fun levelsFor(m: Model?): List<String> = m?.let { thinkingLevels["${it.provider}:${it.id}"] }.orEmpty()

    // open chat (null = session list)
    var chat by mutableStateOf<Chat?>(null); private set
    var ask by mutableStateOf<Ask?>(null); private set
    var notice by mutableStateOf<String?>(null); private set

    inner class Chat(var sessionId: String?, val cwd: String, title: String) {
        var title by mutableStateOf(title)
        var model by mutableStateOf<Model?>(null)
        var loading by mutableStateOf(sessionId != null)
        var busy by mutableStateOf(sessionId != null && running[sessionId] == true)
        var status by mutableStateOf("")
        /** Raw Pi agent messages, in order. The last one may be a streaming assistant message. */
        val messages = mutableStateListOf<JsonObject>()
        /** Index in [messages] of the assistant message currently streaming, or -1. */
        var streaming = -1
        var draft by mutableStateOf("")
        /** Current thinking level ("" = unknown / server default). */
        var thinking by mutableStateOf("")

        // --- metrics bar ---
        var context by mutableStateOf<ContextUsage?>(null)
        var total by mutableStateOf(Usage())
        var lastReply by mutableStateOf<Usage?>(null)
        var replies by mutableStateOf(0)
        var userMessages by mutableStateOf(0)
        var toolCalls by mutableStateOf(0)
        var queuedSteer by mutableStateOf(emptyList<String>())
        var queuedFollowUp by mutableStateOf(emptyList<String>())
        /** Extension status lines (setStatus), by key. */
        val statuses = mutableStateMapOf<String, String>()
        var compacting by mutableStateOf(false)
    }

    val watcher = Watcher(app, viewModelScope)
    /** Bumped when the watch set changes, so Compose re-reads [isWatched]. */
    var watchVersion by mutableStateOf(0); private set

    fun isWatched(sid: String?): Boolean { watchVersion; return watcher.isWatched(sid) }

    fun toggleWatch() {
        val c = chat ?: return
        val sid = c.sessionId ?: return say("Send a message first")
        if (watcher.isWatched(sid)) watcher.remove(sid)
        else {
            watcher.add(sid, c.title, running[sid] == true)
            watcher.subscribe(sid, rpc, ::onMain)
        }
        watchVersion++
        Notifier.working(app, keepAliveCount())
    }

    /** Bumped when the bubble preference changes, so Compose re-reads it. */
    var bubbleVersion by mutableStateOf(0); private set

    /** Whether watched chats are shown as bubbles (user preference). */
    fun bubblesForWatched(): Boolean { bubbleVersion; return watcher.bubblesOn() }

    /** Toggle bubbles for watched chats (all currently watched chats update immediately). */
    fun setBubblesForWatched(on: Boolean) {
        watcher.setBubbles(on)
        bubbleVersion++
        if (on && !Notifier.bubblesEnabled(app))
            say("Enable bubbles for Pi in system settings to see them")
    }

    /** True when this session has a live bubble notification. */
    fun isBubbled(sid: String): Boolean = Notifier.isBubbled(app, sid)

    /** Show/hide the open chat as a floating bubble. */
    fun toggleBubble() {
        val c = chat ?: return
        val sid = c.sessionId ?: return say("Send a message first")
        if (Notifier.isBubbled(app, sid)) Notifier.unbubble(app, sid)
        else {
            Notifier.bubble(app, sid, c.title, lastAssistantText(c).ifBlank { c.status }, ping = false)
            if (!Notifier.bubblesEnabled(app))
                say("Bubble posted — enable bubbles for Pi in system settings if it doesn't appear")
        }
    }

    /** Keep an existing bubble's text in sync as messages stream in. */
    private fun refreshBubble(c: Chat) {
        val sid = c.sessionId ?: return
        if (!Notifier.isBubbled(app, sid)) return
        Notifier.bubble(app, sid, c.title, lastAssistantText(c).ifBlank { c.status }, ping = false)
    }

    private fun lastAssistantText(c: Chat): String =
        c.messages.lastOrNull { it.str("role") == "assistant" }?.let { m ->
            m.objs("content").filter { it.str("type") == "text" }.joinToString("\n") { it.str("text") }
        }?.take(400).orEmpty()

    private fun keepAliveCount() = (running.keys + watcher.ids).size

    init {
        watcher.repostAll()
        if (prefs.getBoolean("online", false) && address.isNotBlank()) connect()
    }

    fun say(msg: String) {
        if (msg.isBlank()) return
        notice = msg
        viewModelScope.launch { delay(3500); if (notice == msg) notice = null }
    }

    private fun launchSafe(block: suspend () -> Unit) = viewModelScope.launch {
        try { block() } catch (e: Exception) { say(e.message ?: e.toString()) }
    }

    private suspend fun call(method: String, params: JsonElement? = null): JsonObject? {
        val r = rpc ?: throw RpcError("OFFLINE", "Not connected")
        return r.call(method, params) as? JsonObject
    }

    // --- connection --------------------------------------------------------------------

    fun connect() {
        val url = resolveRpcUrl(address, token) ?: return say("Enter a server address")
        wantOnline = true
        prefs.edit().putString("address", address).putString("token", token).putBoolean("online", true).apply()
        retryJob?.cancel()
        rpc?.close(); rpc = null
        conn = Conn.Connecting
        connError = null
        viewModelScope.launch {
            val client = try {
                PiRpc.connect(url) { reason -> viewModelScope.launch(Dispatchers.Main) { dropped(reason) } }
            } catch (e: Exception) {
                conn = Conn.Offline; connError = e.message; scheduleRetry(); return@launch
            }
            rpc = client
            conn = Conn.Online
            retryDelay = 1000
            client.subscribe("agent.running", "*") { ev -> onMain { setRunning((ev as? JsonObject).strs("sessionIds")) } }
            client.subscribe("sessions.changed", "*") { onMain { refreshSoon() } }
            watcher.attach(client, ::onMain)
            refreshSessions()
            launchSafe { defaultCwd = call("system.defaultCwd").str("cwd") }
            launchSafe { loadModels() }
            chat?.sessionId?.let { watch(it); reload() }
        }
    }

    fun disconnect() {
        wantOnline = false
        retryJob?.cancel()
        prefs.edit().putBoolean("online", false).apply()
        rpc?.close(); rpc = null
        conn = Conn.Offline
    }

    /** Called when the app returns to the foreground. */
    fun resume() { if (wantOnline && conn == Conn.Offline) connect() }

    private fun onMain(f: () -> Unit) { viewModelScope.launch(Dispatchers.Main) { f() } }

    private var retryDelay = 1000L
    private fun dropped(reason: String?) {
        rpc = null
        conn = Conn.Offline
        connError = reason
        scheduleRetry()
    }

    private fun scheduleRetry() {
        if (!wantOnline) return
        retryJob?.cancel()
        retryJob = viewModelScope.launch {
            delay(retryDelay)
            retryDelay = (retryDelay * 2).coerceAtMost(15_000)
            if (wantOnline && conn == Conn.Offline) connect()
        }
    }

    // --- sessions -----------------------------------------------------------------------

    private var refreshJob: Job? = null
    private fun refreshSoon() {
        if (refreshJob?.isActive == true) return
        refreshJob = viewModelScope.launch { delay(500); refreshSessions() }
    }

    fun refreshSessions() = launchSafe {
        val r = call("sessions.list")
        sessions.clear()
        sessions += r.objs("sessions").map {
            Session(
                id = it.str("id"),
                title = it.str("name").ifBlank { it.str("firstMessage") }.trim().lineSequence().firstOrNull().orEmpty()
                    .ifEmpty { "(untitled)" },
                cwd = it.str("cwd"),
                modified = runCatching { Instant.parse(it.str("modified")).epochSecond }.getOrDefault(0),
                count = it.num("messageCount").toInt(),
            )
        }.sortedByDescending { it.modified }
        sessions.forEach { if (watcher.isWatched(it.id)) watcher.setTitle(it.id, it.title) }
        setRunning(r.strs("runningSessionIds"))
    }

    /** True while an activity is visible; run-finished notifications only fire when false. */
    var foreground = true
        set(v) { field = v; if (v) chat?.sessionId?.let { Notifier.clear(app, it) } }

    private fun setRunning(ids: List<String>) {
        val finished = running.keys - ids.toSet()
        running.clear()
        ids.forEach { running[it] = true }
        watcher.onRunning(ids.toSet())
        Notifier.working(app, keepAliveCount())
        // Watched chats have their own notification; don't double up.
        if (!foreground) finished.filterNot(watcher::isWatched).forEach(::notifyFinished)
        val c = chat ?: return
        val now = c.sessionId?.let { running[it] } == true
        if (c.busy && !now) { c.busy = false; c.status = "" }
        if (!c.busy && now) c.busy = true
    }

    /** Post "done" for a session: its title plus the start of the agent's final reply. */
    private fun notifyFinished(sid: String) = viewModelScope.launch {
        val title = sessions.firstOrNull { it.id == sid }?.title ?: chat?.takeIf { it.sessionId == sid }?.title ?: "Pi"
        val last = runCatching {
            val msgs = chat?.takeIf { it.sessionId == sid }?.messages?.toList()
                ?: call("sessions.get", buildJsonObject {
                    put("id", sid); put("historyWindow", buildJsonObject { put("maxTurns", 1) })
                }).obj("context").objs("messages")
            val a = msgs.lastOrNull { it.str("role") == "assistant" }
            a?.str("errorMessage")?.takeIf { it.isNotEmpty() }?.let { "Error: $it" }
                ?: a?.objs("content")?.filter { it.str("type") == "text" }?.joinToString("\n") { it.str("text") }?.trim()
        }.getOrNull()
        Notifier.finished(app, sid, title, last?.take(400))
    }

    /** Opens a session by id (from a notification tap). */
    fun openById(sid: String) {
        Notifier.clear(app, sid)
        if (chat?.sessionId == sid) return
        val s = sessions.firstOrNull { it.id == sid } ?: Session(sid, "Session", "", 0, 0)
        open(s)
    }

    fun rename(id: String, name: String) = launchSafe {
        call("sessions.rename", buildJsonObject { put("id", id); put("name", name) })
        refreshSessions()
    }

    fun delete(id: String) = launchSafe {
        call("sessions.delete", buildJsonObject { put("id", id) })
        refreshSessions()
    }

    val recentCwds get() = sessions.map { it.cwd }.filter { it.isNotBlank() }.distinct()

    // --- models -------------------------------------------------------------------------

    private suspend fun loadModels() {
        val r = call("models.list")
        models.clear()
        models += r.objs("models").map { Model(it.str("provider"), it.str("id"), it.str("name").ifEmpty { it.str("id") }) }
        thinkingLevels.clear()
        r.obj("thinkingLevels")?.forEach { (k, v) ->
            thinkingLevels[k] = (v as? kotlinx.serialization.json.JsonArray)?.mapNotNull { it.string() }.orEmpty()
        }
        defaultModel = r.obj("defaultModel")?.let { d -> findModel(d.str("provider"), d.str("modelId")) }
        chat?.let { if (it.model == null && it.sessionId == null) it.model = defaultModel }
    }

    private fun findModel(provider: String, id: String) =
        models.firstOrNull { it.provider == provider && it.id == id } ?: Model(provider, id, id).takeIf { id.isNotEmpty() }

    fun pickModel(m: Model) {
        val c = chat ?: return
        c.model = m
        val sid = c.sessionId ?: return
        launchSafe { command(sid, buildJsonObject { put("type", "set_model"); put("provider", m.provider); put("modelId", m.id) }) }
    }

    // --- chat ---------------------------------------------------------------------------

    fun open(s: Session) {
        chat = Chat(s.id, s.cwd, s.title)
        watch(s.id)
        reload()
        refreshState()
    }

    fun newChat(cwd: String) {
        chat = Chat(null, cwd.trim().ifEmpty { defaultCwd }, "New session").also { it.model = defaultModel }
    }

    fun closeChat() { chat = null; watch(null); refreshSessions() }

    fun reload() {
        val c = chat ?: return
        val sid = c.sessionId ?: return
        c.loading = true
        launchSafe {
            try {
                val r = call("sessions.get", buildJsonObject {
                    put("id", sid); put("includeState", true)
                    put("historyWindow", buildJsonObject { put("maxTurns", 80) })
                })
                if (chat !== c) return@launchSafe
                val ctx = r.obj("context")
                c.messages.clear()
                c.messages += ctx.objs("messages")
                c.streaming = -1
                ctx.str("thinkingLevel").takeIf { it.isNotEmpty() }?.let { c.thinking = it }
                r.obj("agentState").obj("state").str("thinkingLevel").takeIf { it.isNotEmpty() }?.let { c.thinking = it }
                ctx.obj("model")?.let { c.model = findModel(it.str("provider"), it.str("modelId")) }
                r.obj("info")?.str("name")?.takeIf { it.isNotBlank() }?.let { c.title = it }
                r.obj("stats")?.let { st ->
                    val t = st.obj("tokens")
                    c.total = Usage(t.num("input"), t.num("output"), t.num("cacheRead"), t.num("cacheWrite"), st.num("cost"))
                    c.replies = st.num("assistantMessages").toInt()
                    c.userMessages = st.num("userMessages").toInt()
                    c.toolCalls = st.num("toolCalls").toInt()
                    st.obj("contextUsage")?.let { c.context = contextOf(it) }
                }
                c.lastReply = c.messages.lastOrNull { it.str("role") == "assistant" && it.obj("usage") != null }?.let { Usage.of(it.obj("usage")) }
                applyState(c, r.obj("agentState").obj("state"))
                val st = r.obj("agentState")
                c.busy = running[sid] == true ||
                    (st.bool("running") && (st.obj("state").bool("isStreaming") || st.obj("state").bool("isPromptRunning")))
            } finally { c.loading = false }
        }
    }

    private var unwatch: (() -> Unit)? = null

    /** Follow live agent events for one session (the open chat). */
    private fun watch(sid: String?) {
        unwatch?.invoke(); unwatch = null
        val r = rpc ?: return
        if (sid == null) return
        unwatch = r.subscribe("agent.events", sid) { ev ->
            onMain { if (chat?.sessionId == sid) onAgentEvent(ev as? JsonObject ?: return@onMain) }
        }
    }

    /** tokens / percent are null right after compaction, until the next reply. */
    private fun contextOf(o: JsonObject) = ContextUsage(
        tokens = o.numOrNull("tokens"), window = o.num("contextWindow"), percent = o.numOrNull("percent"),
    )

    /** Apply a get_state snapshot (context usage, queue, statuses, thinking level). */
    private fun applyState(c: Chat, st: JsonObject?) {
        st ?: return
        st.obj("contextUsage")?.let { c.context = contextOf(it) }
        st.obj("queuedMessages").let { q ->
            c.queuedSteer = q.strs("steering"); c.queuedFollowUp = q.strs("followUp")
        }
        st.str("thinkingLevel").takeIf { it.isNotEmpty() }?.let { c.thinking = it }
        c.compacting = st.bool("isCompacting")
        if (st.containsKey("extensionStatuses")) {
            c.statuses.clear()
            st.objs("extensionStatuses").forEach { c.statuses[it.str("key")] = it.str("text") }
        }
    }

    /** Re-read live agent state (context usage, queue). Cheap; called after turns and queue changes. */
    private fun refreshState() {
        val c = chat ?: return
        val sid = c.sessionId ?: return
        viewModelScope.launch {
            runCatching {
                val r = call("agent.state", buildJsonObject { put("sessionId", sid) })
                if (chat === c) applyState(c, r.obj("state"))
            }
        }
    }

    fun compact() {
        val c = chat ?: return
        val sid = c.sessionId ?: return
        c.compacting = true
        c.status = "Compacting…"
        launchSafe {
            try { command(sid, buildJsonObject { put("type", "compact") }) } finally {
                c.compacting = false
                if (!c.busy) c.status = ""
                reload()
            }
        }
    }

    private suspend fun command(sid: String, cmd: JsonObject) =
        call("agent.command", buildJsonObject { put("sessionId", sid); put("command", cmd) })

    fun setThinking(level: String) {
        val c = chat ?: return
        c.thinking = level
        val sid = c.sessionId ?: return // new session: sent with agent.new
        launchSafe { command(sid, buildJsonObject { put("type", "set_thinking_level"); put("level", level) }) }
    }

    /**
     * Send the draft. While the agent is running, [steer] = true interrupts the current
     * run with the message; false queues it as a follow-up for after the run.
     */
    fun send(steer: Boolean = true) {
        val c = chat ?: return
        val text = c.draft.trim()
        if (text.isEmpty()) return
        c.draft = ""
        val wasBusy = c.busy
        c.busy = true
        if (c.status.isEmpty()) c.status = "Thinking…"
        c.messages += buildJsonObject {
            put("role", "user"); put("content", text); put("pending", true)
            if (wasBusy) put("queued", if (steer) "steer" else "follow-up")
        }
        launchSafe {
            try {
                val sid = c.sessionId ?: call("agent.new", buildJsonObject {
                    put("cwd", c.cwd)
                    c.model?.let { put("provider", it.provider); put("modelId", it.id) }
                    if (c.thinking.isNotEmpty()) put("thinkingLevel", c.thinking)
                }).str("sessionId").also { c.sessionId = it; watch(it) }
                command(sid, buildJsonObject {
                    when {
                        !wasBusy -> { put("type", "prompt"); put("message", text) }
                        steer -> { put("type", "steer"); put("message", text) }
                        else -> { put("type", "prompt"); put("message", text); put("streamingBehavior", "followUp") }
                    }
                })
                if (wasBusy) refreshState()
            } catch (e: Exception) {
                c.busy = false; c.status = ""; throw e
            }
        }
    }

    fun stop() {
        val c = chat ?: return
        val sid = c.sessionId ?: return
        c.status = "Stopping…"
        launchSafe { command(sid, buildJsonObject { put("type", "abort") }) }
    }

    private fun onAgentEvent(ev: JsonObject) {
        val c = chat ?: return
        when (ev.str("type")) {
            "extension_ui_request" -> onExtensionUi(ev)
            "extension_error" -> say(ev.str("error"))
            "agent_start" -> { c.busy = true; c.status = "Thinking…" }
            "message_start", "message_update" -> {
                val m = ev.obj("message") ?: return
                if (m.str("role") != "assistant") return
                if (c.streaming in c.messages.indices) c.messages[c.streaming] = m
                else { c.messages += m; c.streaming = c.messages.lastIndex }
                c.status = ""
                refreshBubble(c)
            }
            "message_end" -> {
                val m = ev.obj("message") ?: return
                when (m.str("role")) {
                    "assistant" -> {
                        if (c.streaming in c.messages.indices) c.messages[c.streaming] = m else c.messages += m
                        c.streaming = -1
                        Usage.of(m.obj("usage"))?.let { u -> c.lastReply = u; c.total += u }
                        c.replies++
                        c.toolCalls += m.objs("content").count { it.str("type") == "toolCall" || it.str("type") == "tool_use" }
                        refreshBubble(c)
                    }
                    "user" -> {
                        // Replace our optimistic bubble (matched by text, so queued ones resolve in order).
                        val text = (m["content"].string() ?: m.objs("content").firstOrNull { it.str("type") == "text" }.str("text")).trim()
                        c.userMessages++
                        if (c.queuedSteer.isNotEmpty() || c.queuedFollowUp.isNotEmpty()) refreshState()
                        val i = c.messages.indexOfFirst { it.bool("pending") && it.str("content").trim() == text }
                        when {
                            i < 0 -> c.messages += m
                            // Delivered steer/follow-up: move it to where the agent actually received it.
                            c.messages[i].str("queued").isNotEmpty() -> {
                                c.messages.removeAt(i)
                                if (c.streaming > i) c.streaming--
                                c.messages += m
                            }
                            else -> c.messages[i] = m
                        }
                    }
                    "system" -> {}
                    else -> c.messages += m
                }
            }
            "tool_execution_start" -> c.status = "Running ${ev.str("toolName")}…"
            "tool_execution_end" -> c.status = "Working…"
            "auto_compaction_start", "compaction_start" -> c.status = "Compacting…"
            "auto_compaction_end", "compaction_end" -> reload()
            "auto_retry_start" -> c.status = "Retrying…"
            "agent_end", "prompt_done" -> { c.busy = false; c.status = ""; refreshState() }
            "turn_end" -> refreshState()
            "prompt_error" -> { c.busy = false; c.status = ""; say(ev.str("errorMessage").ifEmpty { ev.str("error") }) }
        }
    }

    private fun onExtensionUi(ev: JsonObject) {
        when (ev.str("method")) {
            "notify" -> say(ev.str("message"))
            "setStatus" -> chat?.let { c ->
                val text = ev.str("statusText")
                if (text.isBlank()) c.statuses.remove(ev.str("statusKey")) else c.statuses[ev.str("statusKey")] = text
            }
            "select", "confirm", "input", "editor" -> ask = Ask(chat?.sessionId ?: return, ev)
        }
    }

    /** Answer the open dialog. value == null means cancelled. For confirm, pass "true"/"false". */
    fun answer(value: String?) {
        val a = ask ?: return
        ask = null
        launchSafe {
            command(a.sessionId, buildJsonObject {
                put("type", "extension_ui_response"); put("id", a.id)
                when {
                    value == null -> put("cancelled", true)
                    a.method == "confirm" -> put("confirmed", value == "true")
                    else -> put("value", value)
                }
            })
        }
    }

    fun back(): Boolean {
        when {
            ask != null -> answer(null)
            chat != null -> closeChat()
            else -> return false
        }
        return true
    }

    fun dispose() { rpc?.close(); Notifier.working(app, 0) }
}
