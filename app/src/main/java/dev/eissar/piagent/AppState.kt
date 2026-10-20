package dev.eissar.piagent

import android.app.Application
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
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
data class Model(val provider: String, val id: String, val name: String)
/** An extension_ui_request awaiting the user's answer (select / confirm / input / editor). */
data class Ask(val sessionId: String, val req: JsonObject) {
    val id get() = req.str("id")
    val method get() = req.str("method")
}

enum class Conn { Offline, Connecting, Online }

class AppState(app: Application) : AndroidViewModel(app) {
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
        var streaming = false
        var draft by mutableStateOf("")
    }

    init {
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
        setRunning(r.strs("runningSessionIds"))
    }

    private fun setRunning(ids: List<String>) {
        running.clear()
        ids.forEach { running[it] = true }
        val c = chat ?: return
        val now = c.sessionId?.let { running[it] } == true
        if (c.busy && !now) { c.busy = false; c.status = "" }
        if (!c.busy && now) c.busy = true
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
                c.streaming = false
                ctx.obj("model")?.let { c.model = findModel(it.str("provider"), it.str("modelId")) }
                r.obj("info")?.str("name")?.takeIf { it.isNotBlank() }?.let { c.title = it }
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

    private suspend fun command(sid: String, cmd: JsonObject) =
        call("agent.command", buildJsonObject { put("sessionId", sid); put("command", cmd) })

    fun send() {
        val c = chat ?: return
        val text = c.draft.trim()
        if (text.isEmpty()) return
        c.draft = ""
        val wasBusy = c.busy
        c.busy = true
        if (c.status.isEmpty()) c.status = "Thinking…"
        c.messages += buildJsonObject { put("role", "user"); put("content", text); put("pending", true) }
        launchSafe {
            try {
                val sid = c.sessionId ?: call("agent.new", buildJsonObject {
                    put("cwd", c.cwd)
                    c.model?.let { put("provider", it.provider); put("modelId", it.id) }
                }).str("sessionId").also { c.sessionId = it; watch(it) }
                command(sid, buildJsonObject {
                    put("type", "prompt"); put("message", text)
                    if (wasBusy) put("streamingBehavior", "followUp")
                })
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
                if (c.streaming && c.messages.isNotEmpty()) c.messages[c.messages.lastIndex] = m
                else { c.messages += m; c.streaming = true }
                c.status = ""
            }
            "message_end" -> {
                val m = ev.obj("message") ?: return
                when (m.str("role")) {
                    "assistant" -> {
                        if (c.streaming && c.messages.isNotEmpty()) c.messages[c.messages.lastIndex] = m else c.messages += m
                        c.streaming = false
                    }
                    "user" -> {
                        val i = c.messages.indexOfLast { it.bool("pending") }
                        if (i >= 0) c.messages[i] = m else c.messages += m
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
            "agent_end", "prompt_done" -> { c.busy = false; c.status = "" }
            "prompt_error" -> { c.busy = false; c.status = ""; say(ev.str("errorMessage").ifEmpty { ev.str("error") }) }
        }
    }

    private fun onExtensionUi(ev: JsonObject) {
        when (ev.str("method")) {
            "notify" -> say(ev.str("message"))
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

    override fun onCleared() { rpc?.close() }
}
