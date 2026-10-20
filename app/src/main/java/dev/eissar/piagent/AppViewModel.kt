package dev.eissar.piagent

// Application state, RPC message handling and screen logic.

import android.app.Application
import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import org.json.JSONObject
import java.time.Instant

enum class Screen { Connect, Sessions, NewSession, Chat }

data class SessionItem(
    val id: String, val name: String, val first: String, val cwd: String,
    val count: Int, val modTime: Long, // epoch seconds
) {
    val title get() = name.ifEmpty { first }.trim().substringBefore('\n').ifEmpty { "(empty session)" }
}

data class ModelItem(val id: String, val name: String, val provider: String)

data class Dialog(
    val id: String, val sid: String, val method: String,
    val title: String, val message: String, val options: List<String>, val prefill: String,
)

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val prefs = application.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())
    private val rpc = RpcClient(::onConnState, ::onEvent)

    // --- connection / global ---
    var screen by mutableStateOf(Screen.Connect)
    var host by mutableStateOf(prefs.getString("host", null) ?: "10.0.2.2:7860")
    var token by mutableStateOf(prefs.getString("token", "")!!)
    var cwdField by mutableStateOf(prefs.getString("cwd", "")!!)
    var conn by mutableStateOf(ConnState.Closed); private set
    var connError by mutableStateOf<String?>(null); private set
    private var connectWanted = prefs.getBoolean("auto", false)
    private var everConnected = false
    private var reconnectDelay = 0L

    var toastText by mutableStateOf<String?>(null); private set
    private var toastSeq = 0

    // --- sessions ---
    val sessions = mutableStateListOf<SessionItem>()
    var sessionsLoaded by mutableStateOf(false); private set
    var sessionsLoading by mutableStateOf(false); private set
    val runningIds = mutableStateMapOf<String, Boolean>()
    val recentCwds = mutableStateListOf<String>()
    var defaultCwd by mutableStateOf(""); private set
    private var sessionsRefreshQueued = false

    // --- models ---
    val models = mutableStateListOf<ModelItem>()
    var defaultModel by mutableStateOf(ModelItem("", "", "")); private set
    var modelPicker by mutableStateOf(false)

    // --- chat ---
    var sid by mutableStateOf(""); private set
    var chatCwd by mutableStateOf(""); private set
    var chatTitle by mutableStateOf(""); private set
    private var isNew = false
    var loading by mutableStateOf(false); private set
    var running by mutableStateOf(false); private set
    var phase by mutableStateOf(""); private set
    val messages = mutableStateListOf<Message>()
    private var streaming = -1
    val calls = mutableStateMapOf<String, Int>()      // tool call id -> uid of message containing the call
    val results = mutableStateMapOf<String, Message>() // tool call id -> toolResult message
    val runningTools = mutableStateMapOf<String, Boolean>()
    var composer by mutableStateOf("")
    private var pendingPrompt: String? = null
    var provider by mutableStateOf(""); private set
    var modelId by mutableStateOf(""); private set
    /** Bumped whenever the chat should jump to the bottom. */
    var scrollToBottom by mutableStateOf(0); private set

    var dialog by mutableStateOf<Dialog?>(null); private set

    init {
        if (connectWanted) connect()
    }

    override fun onCleared() {
        main.removeCallbacksAndMessages(null)
        rpc.close()
    }

    fun saveSettings() {
        prefs.edit().putString("host", host).putString("token", token).putString("cwd", cwdField)
            .putBoolean("auto", connectWanted).apply()
    }

    fun toast(msg: String) {
        if (msg.isBlank()) return
        toastText = msg
        val seq = ++toastSeq
        main.postDelayed({ if (toastSeq == seq) toastText = null }, 3200)
    }

    // --- connection ---------------------------------------------------------------

    fun connect() {
        val url = buildRpcUrl(host, token)
        if (url == null) { toast("Invalid server address"); return }
        connectWanted = true
        rpc.connect(url)
    }

    fun disconnect() {
        connectWanted = false
        main.removeCallbacks(reconnectTask)
        rpc.close()
        conn = ConnState.Closed
        screen = Screen.Connect
        saveSettings()
    }

    fun onResume() {
        if (connectWanted && rpc.state == ConnState.Closed) {
            reconnectDelay = 0
            main.removeCallbacks(reconnectTask)
            connect()
        }
    }

    private val reconnectTask = Runnable { if (connectWanted && rpc.state == ConnState.Closed) connect() }

    private fun onConnState(s: ConnState, error: String?) {
        conn = s
        when (s) {
            ConnState.Connecting -> connError = null
            ConnState.Open -> onConnected()
            ConnState.Closed -> {
                connError = error
                loading = false
                sessionsLoading = false
                if (!everConnected && screen == Screen.Connect) {
                    connectWanted = false // first attempt failed: no retry loop
                } else if (connectWanted) {
                    reconnectDelay = (reconnectDelay * 2).coerceIn(1000, 15000)
                    main.postDelayed(reconnectTask, reconnectDelay)
                }
            }
        }
    }

    private fun onConnected() {
        everConnected = true
        reconnectDelay = 0
        saveSettings()
        rpc.subscribe("agent.events")
        rpc.subscribe("agent.running")
        rpc.subscribe("sessions.changed")
        refreshSessions()
        rpc.call("models.list") { r -> r.onSuccess { onModels(it as? JSONObject) }.onFailure(::err) }
        rpc.call("system.defaultCwd") { r ->
            r.onSuccess {
                defaultCwd = (it as? JSONObject).str("cwd")
                if (cwdField.isEmpty()) cwdField = defaultCwd
            }
        }
        if (screen == Screen.Connect) screen = Screen.Sessions
        if (screen == Screen.Chat && sid.isNotEmpty()) reloadChat()
    }

    private fun err(t: Throwable) = toast(t.message ?: "Error")

    // --- sessions -------------------------------------------------------------------

    fun refreshSessions() {
        if (sessionsLoading) return
        sessionsLoading = true
        rpc.call("sessions.list") { r ->
            sessionsLoading = false
            r.onSuccess {
                val o = it as? JSONObject
                sessionsLoaded = true
                setSessions(o.arr("sessions").objects())
                setRunning(o.arr("runningSessionIds").strings())
            }.onFailure(::err)
        }
    }

    private fun queueSessionsRefresh(delayMs: Long) {
        if (sessionsRefreshQueued) return
        sessionsRefreshQueued = true
        main.postDelayed({ sessionsRefreshQueued = false; if (conn == ConnState.Open) refreshSessions() }, delayMs)
    }

    private fun setSessions(arr: List<JSONObject>) {
        val items = arr.map {
            SessionItem(
                id = it.str("id"), name = it.str("name"), first = it.str("firstMessage"), cwd = it.str("cwd"),
                count = it.num("messageCount").toInt(), modTime = parseIso(it.str("modified")),
            )
        }.sortedByDescending { it.modTime }
        sessions.clear(); sessions.addAll(items)
        recentCwds.clear(); recentCwds.addAll(items.map { it.cwd }.filter { it.isNotEmpty() }.distinct())
    }

    private fun setRunning(ids: List<String>) {
        runningIds.clear()
        ids.forEach { runningIds[it] = true }
    }

    fun renameSession(id: String, name: String) =
        rpc.call("sessions.rename", JSONObject().put("id", id).put("name", name)) { r ->
            r.onSuccess { queueSessionsRefresh(0) }.onFailure(::err)
        }

    fun deleteSession(id: String) =
        rpc.call("sessions.delete", JSONObject().put("id", id)) { r ->
            r.onSuccess { queueSessionsRefresh(0) }.onFailure(::err)
        }

    // --- models -----------------------------------------------------------------------

    private fun onModels(r: JSONObject?) {
        models.clear()
        models.addAll(r.arr("models").objects().map { ModelItem(it.str("id"), it.str("name"), it.str("provider")) })
        val dm = r.obj("defaultModel")
        defaultModel = ModelItem(dm.str("modelId"), "", dm.str("provider"))
        if (isNew && modelId.isEmpty()) setModel(defaultModel.provider, defaultModel.id)
    }

    private fun setModel(p: String, id: String) { provider = p; modelId = id }

    val modelLabel: String
        get() = if (modelId.isEmpty()) "default model"
        else models.firstOrNull { it.id == modelId && it.provider == provider && it.name.isNotEmpty() }?.name ?: modelId

    fun chooseModel(m: ModelItem) {
        modelPicker = false
        setModel(m.provider, m.id)
        if (sid.isEmpty()) return
        agentCommand(JSONObject().put("type", "set_model").put("provider", m.provider).put("modelId", m.id)) { r ->
            r.onSuccess { toast("Model updated") }.onFailure(::err)
        }
    }

    // --- events -------------------------------------------------------------------------

    private fun onEvent(topic: String, key: String, data: Any?) {
        when (topic) {
            "agent.events" -> if (screen == Screen.Chat && sid.isNotEmpty() && key == sid) (data as? JSONObject)?.let(::onAgentEvent)
            "agent.running" -> {
                setRunning((data as? JSONObject).arr("sessionIds").strings())
                if (sid.isNotEmpty()) {
                    val now = runningIds[sid] == true
                    if (running && !now) { running = false; phase = ""; runningTools.clear() }
                    else if (!running && now) { running = true; if (phase.isEmpty()) phase = "Working…" }
                }
            }
            "sessions.changed" -> queueSessionsRefresh(600)
        }
    }

    private fun onAgentEvent(ev: JSONObject) {
        when (ev.str("type")) {
            "agent_start" -> {
                running = true
                if (phase.isEmpty() || phase == "Stopping…") phase = "Thinking…"
            }
            "message_start", "message_update" -> {
                val msg = ev.obj("message") ?: return
                if (msg.str("role") != "assistant") return
                val m = messageFromJson(msg)
                if (streaming in messages.indices) replace(streaming, m)
                else { append(m); streaming = messages.size - 1 }
                phase = ""
            }
            "message_end" -> {
                val msg = ev.obj("message") ?: return
                when (msg.str("role")) {
                    "system" -> {}
                    "user" -> {
                        val txt = userTextOfJson(msg).trim()
                        // skip if it is our optimistic bubble
                        val dup = messages.takeLast(3).any {
                            it.role == Role.User && it.blocks.firstOrNull()?.text?.trim() == txt
                        }
                        if (!dup) append(messageFromJson(msg))
                    }
                    "assistant" -> {
                        val m = messageFromJson(msg)
                        if (streaming in messages.indices) replace(streaming, m) else append(m)
                        streaming = -1
                        phase = "Working…"
                    }
                    "custom" -> if (msg.bool("display")) append(messageFromJson(msg))
                    else -> append(messageFromJson(msg))
                }
            }
            "tool_execution_start" -> {
                ev.str("toolCallId").takeIf { it.isNotEmpty() }?.let { runningTools[it] = true }
                phase = "Running ${ev.str("toolName")}…"
            }
            "tool_execution_end" -> {
                runningTools.remove(ev.str("toolCallId"))
                phase = "Working…"
            }
            "prompt_done" -> { running = false; phase = "" }
            "prompt_error" -> { running = false; phase = ""; toast(ev.str("errorMessage")) }
            "auto_retry_start" -> phase = "Retrying…"
            "compaction_start", "auto_compaction_start" -> phase = "Compacting context…"
            "compaction_end", "auto_compaction_end" -> { phase = if (running) "Working…" else ""; reloadChat() }
            "extension_error" -> toast(ev.str("error"))
            "extension_ui_request" -> onExtensionUi(ev)
        }
    }

    // --- chat state -----------------------------------------------------------------

    private fun clearMessages() {
        messages.clear(); calls.clear(); results.clear(); runningTools.clear()
        streaming = -1
    }

    private fun index(m: Message) {
        m.blocks.forEach { if (it.kind == BlockKind.ToolCall && it.callId.isNotEmpty()) calls[it.callId] = m.uid }
        if (m.role == Role.ToolResult && m.toolCallId.isNotEmpty()) results[m.toolCallId] = m
    }

    private fun unindex(m: Message) {
        m.blocks.forEach { if (it.kind == BlockKind.ToolCall && calls[it.callId] == m.uid) calls.remove(it.callId) }
        if (m.role == Role.ToolResult && results[m.toolCallId]?.uid == m.uid) results.remove(m.toolCallId)
    }

    private fun append(m: Message) { messages.add(m); index(m) }

    private fun replace(i: Int, m: Message) { unindex(messages[i]); messages[i] = m; index(m) }

    private fun setMessages(arr: List<JSONObject>) {
        clearMessages()
        for (v in arr) {
            val role = v.str("role")
            if (role == "system") continue
            if (role == "custom" && !v.bool("display")) continue
            append(messageFromJson(v))
        }
    }

    private fun setTitle(t: String) { chatTitle = t.trim().substringBefore('\n') }

    fun openSession(s: SessionItem) {
        clearMessages()
        sid = s.id
        chatCwd = s.cwd
        setTitle(s.title)
        isNew = false
        running = runningIds[s.id] == true
        phase = if (running) "Working…" else ""
        setModel("", "")
        screen = Screen.Chat
        reloadChat()
    }

    fun reloadChat() {
        if (sid.isEmpty()) return
        loading = true
        val forSid = sid
        val params = JSONObject().put("id", sid).put("includeState", true)
            .put("historyWindow", JSONObject().put("maxTurns", 80))
        rpc.call("sessions.get", params) { r ->
            if (forSid != sid) return@call
            loading = false
            r.onSuccess { onSession(it as? JSONObject) }.onFailure(::err)
        }
    }

    private fun onSession(r: JSONObject?) {
        val ctx = r.obj("context")
        setMessages(ctx.arr("messages").objects())
        val model = ctx.obj("model")
        setModel(model.str("provider"), model.str("modelId"))
        val info = r.obj("info")
        info.str("name").ifEmpty { info.str("firstMessage") }.takeIf { it.isNotEmpty() }?.let(::setTitle)
        info.str("cwd").takeIf { it.isNotEmpty() }?.let { chatCwd = it }
        val st = r.obj("agentState")
        val state = st.obj("state")
        running = (st.bool("running") && (state.bool("isStreaming") || state.bool("isPromptRunning"))) || runningIds[sid] == true
        phase = if (running) "Working…" else ""
        scrollToBottom++
    }

    fun startNewSession(cwd: String) {
        clearMessages()
        sid = ""
        chatCwd = cwd.trim()
        setTitle("New session")
        isNew = true
        running = false
        phase = ""
        setModel(defaultModel.provider, defaultModel.id)
        screen = Screen.Chat
    }

    private fun agentCommand(cmd: JSONObject, session: String = sid, cb: (Result<Any?>) -> Unit = {}) =
        rpc.call("agent.command", JSONObject().put("sessionId", session).put("command", cmd), cb)

    private fun sendPrompt(text: String) {
        val cmd = JSONObject().put("type", "prompt").put("message", text)
        if (running) cmd.put("streamingBehavior", "followUp")
        agentCommand(cmd) { r -> r.onFailure { running = false; phase = ""; err(it) } }
    }

    fun send() {
        val text = composer.trim()
        if (text.isEmpty()) return
        if (conn != ConnState.Open) { toast("Not connected"); return }
        append(userMessage(text)) // optimistic bubble
        scrollToBottom++
        if (sid.isEmpty()) {
            pendingPrompt = text
            val p = JSONObject().put("cwd", chatCwd).put("type", "ensure_session")
            if (modelId.isNotEmpty()) p.put("provider", provider).put("modelId", modelId)
            rpc.call("agent.new", p) { r ->
                r.onSuccess {
                    val newSid = (it as? JSONObject).str("sessionId")
                    if (newSid.isEmpty()) return@onSuccess
                    sid = newSid
                    isNew = false
                    pendingPrompt?.let(::sendPrompt)
                    pendingPrompt = null
                }.onFailure { running = false; phase = ""; err(it) }
            }
            cwdField = chatCwd
        } else {
            sendPrompt(text)
        }
        if (!running) { running = true; phase = "Thinking…" }
        composer = ""
    }

    fun abort() {
        if (sid.isEmpty()) return
        agentCommand(JSONObject().put("type", "abort"))
        phase = "Stopping…"
    }

    // --- extension UI dialogs ---------------------------------------------------------

    private fun onExtensionUi(ev: JSONObject) {
        when (val method = ev.str("method")) {
            "notify" -> toast(ev.str("message"))
            "select", "confirm", "input", "editor" -> dialog = Dialog(
                id = ev.str("id"), sid = sid, method = method, title = ev.str("title"),
                message = ev.str("message"), options = ev.arr("options").strings(), prefill = ev.str("prefill"),
            )
        }
    }

    /** Exactly one of value / confirmed / cancelled is meaningful, by dialog method. */
    fun respondDialog(value: String = "", confirmed: Boolean = false, cancelled: Boolean = false) {
        val d = dialog ?: return
        val cmd = JSONObject().put("type", "extension_ui_response").put("id", d.id)
        when {
            cancelled -> cmd.put("cancelled", true)
            d.method == "confirm" -> cmd.put("confirmed", confirmed)
            else -> cmd.put("value", value)
        }
        agentCommand(cmd, d.sid)
        dialog = null
    }

    // --- navigation -------------------------------------------------------------------

    /** Returns true if handled. */
    fun back(): Boolean {
        when {
            dialog != null -> respondDialog(cancelled = true)
            modelPicker -> modelPicker = false
            screen == Screen.Connect && conn == ConnState.Open -> screen = Screen.Sessions
            screen == Screen.Chat -> { screen = Screen.Sessions; queueSessionsRefresh(0) }
            screen == Screen.NewSession -> screen = Screen.Sessions
            else -> return false
        }
        return true
    }
}

fun parseIso(s: String): Long = runCatching { Instant.parse(s).epochSecond }.getOrDefault(0)

fun relativeTime(t: Long): String {
    if (t <= 0) return ""
    val d = System.currentTimeMillis() / 1000 - t
    return when {
        d < 60 -> "just now"
        d < 3600 -> "${d / 60}m ago"
        d < 86400 -> "${d / 3600}h ago"
        d < 86400 * 30 -> "${d / 86400}d ago"
        else -> "${d / (86400 * 30)}mo ago"
    }
}

fun pathBase(p: String): String = p.trimEnd('/').substringAfterLast('/')
