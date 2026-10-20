package dev.eissar.piagent

// Pi WebUI RPC wire protocol over a WebSocket (mirrors pi-agent-webui's
// src/contract/rpc.ts + renderer/lib/ws-transport.ts).
//
//   -> {"kind":"request","id","method","params"}      <- {"kind":"response","id","ok","result"|"error"}
//   -> {"kind":"subscribe","id","topic","key"}         <- {"kind":"event","topic","key","data"}

import android.os.Handler
import android.os.Looper
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

enum class ConnState { Closed, Connecting, Open }

class RpcError(val code: String, message: String) : Exception(message)

/** Parses "host[:port][/rpc?query]" (optionally with ws:// / http:// prefix) into a ws:// URL. */
fun buildRpcUrl(address: String, token: String): String? {
    var a = address.trim()
    var scheme = "ws"
    for ((p, s) in listOf("ws://" to "ws", "http://" to "ws", "wss://" to "wss", "https://" to "wss")) {
        if (a.startsWith(p)) { a = a.removePrefix(p); scheme = s; break }
    }
    var path = "/rpc"
    val slash = a.indexOf('/')
    if (slash >= 0) {
        val rest = a.substring(slash)
        a = a.substring(0, slash)
        if (rest.startsWith("/rpc")) path = rest
        else rest.indexOf('?').takeIf { it >= 0 }?.let { path = "/rpc" + rest.substring(it) }
    }
    val hostPort = when {
        a.startsWith("[") -> if (a.contains("]:")) a else "$a:7860"
        a.contains(':') -> a
        else -> "$a:7860"
    }
    if (hostPort.startsWith(":") || hostPort.isBlank()) return null
    val t = token.trim()
    if (t.isNotEmpty() && !path.contains("token=")) {
        path += (if (path.contains('?')) "&" else "?") + "token=" + URLEncoder.encode(t, "UTF-8")
    }
    return "$scheme://$hostPort$path"
}

/** All callbacks are delivered on the main thread. */
class RpcClient(
    private val onState: (ConnState, String?) -> Unit,
    private val onEvent: (topic: String, key: String, data: Any?) -> Unit,
) {
    private val http = OkHttpClient.Builder()
        .pingInterval(20, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()
    private val main = Handler(Looper.getMainLooper())
    private var ws: WebSocket? = null
    private var nextId = 0
    private val pending = HashMap<String, (Result<Any?>) -> Unit>()

    var state = ConnState.Closed
        private set

    fun connect(url: String) {
        close()
        state = ConnState.Connecting
        onState(state, null)
        val socket = http.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = main.post {
                if (ws !== webSocket) return@post
                state = ConnState.Open
                onState(state, null)
            }.let { }

            override fun onMessage(webSocket: WebSocket, text: String) = main.post {
                if (ws === webSocket) handle(text)
            }.let { }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) =
                main.post { dropped(webSocket, reason.ifEmpty { null }) }.let { }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) =
                main.post { dropped(webSocket, t.message ?: t.javaClass.simpleName) }.let { }
        })
        ws = socket
    }

    private fun dropped(socket: WebSocket, error: String?) {
        if (ws !== socket) return
        ws = null
        state = ConnState.Closed
        failPending("Disconnected")
        onState(state, error)
    }

    fun close() {
        val s = ws ?: return
        ws = null
        s.close(1000, null)
        state = ConnState.Closed
        failPending("Disconnected")
    }

    private fun failPending(msg: String) {
        val cbs = pending.values.toList()
        pending.clear()
        cbs.forEach { it(Result.failure(RpcError("DISCONNECTED", msg))) }
    }

    fun call(method: String, params: JSONObject? = null, cb: (Result<Any?>) -> Unit = {}) {
        val s = ws
        if (s == null || state != ConnState.Open) {
            cb(Result.failure(RpcError("NOT_CONNECTED", "Not connected")))
            return
        }
        val id = "a${++nextId}"
        val msg = JSONObject().put("kind", "request").put("id", id).put("method", method)
        if (params != null) msg.put("params", params)
        pending[id] = cb
        if (!s.send(msg.toString())) {
            pending.remove(id)
            cb(Result.failure(RpcError("SEND_FAILED", "Send failed")))
        }
    }

    fun subscribe(topic: String, key: String = "*") {
        ws?.send(
            JSONObject().put("kind", "subscribe").put("id", "s${++nextId}")
                .put("topic", topic).put("key", key).toString()
        )
    }

    private fun handle(text: String) {
        val v = runCatching { JSONObject(text) }.getOrNull() ?: return
        when (v.optString("kind")) {
            "response" -> {
                val cb = pending.remove(v.optString("id")) ?: return
                if (v.optBoolean("ok")) {
                    cb(Result.success(v.opt("result")))
                } else {
                    val e = v.optJSONObject("error")
                    val code = e?.optString("code").orEmpty()
                    cb(Result.failure(RpcError(code, e?.optString("message").orEmpty().ifEmpty { code })))
                }
            }
            "event" -> onEvent(v.optString("topic"), v.optString("key"), v.opt("data"))
        }
    }
}
