package dev.eissar.piagent

// Port of src/contract/rpc.ts (client half) + src/renderer/lib/ws-transport.ts.
// Five message kinds: request / response / subscribe / unsubscribe / event.

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

val PiJson = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = false; isLenient = true }

/** Mirrors RpcErrorShape / RpcError in contract/types.ts. */
class RpcError(val code: String, message: String, val detail: JsonElement? = null) : Exception(message)

private const val DEFAULT_CALL_TIMEOUT_MS = 120_000L

private val idCounter = AtomicInteger()
private fun makeId(): String = "r${idCounter.incrementAndGet()}_${System.currentTimeMillis().toString(36)}"

/**
 * Resolve the standalone backend RPC endpoint from a user-entered address
 * (ws-transport.ts resolveRpcUrl + createWebSocketPort token handling).
 * Accepts "host[:port]", "ws(s)://host:port[/rpc]", "http(s)://host:port".
 */
fun resolveRpcUrl(address: String, token: String?): String? {
    var a = address.trim()
    if (a.isEmpty()) return null
    var scheme = "ws"
    when {
        a.startsWith("wss://") -> { scheme = "wss"; a = a.removePrefix("wss://") }
        a.startsWith("ws://") -> a = a.removePrefix("ws://")
        a.startsWith("https://") -> { scheme = "wss"; a = a.removePrefix("https://") }
        a.startsWith("http://") -> a = a.removePrefix("http://")
    }
    val slash = a.indexOf('/')
    val hostPort = if (slash >= 0) a.substring(0, slash) else a
    var path = if (slash >= 0) a.substring(slash) else ""
    if (hostPort.isEmpty()) return null
    if (path.isEmpty() || path == "/") path = "/rpc"
    else if (!path.startsWith("/rpc")) path = "/rpc" + (path.indexOf('?').takeIf { it >= 0 }?.let { path.substring(it) } ?: "")
    val withPort = if (hostPort.startsWith("[") || hostPort.contains(':')) hostPort else "$hostPort:7860"
    var url = "$scheme://$withPort$path"
    val t = token?.trim().orEmpty()
    if (t.isNotEmpty()) url += (if (url.contains('?')) "&" else "?") + "token=" + URLEncoder.encode(t, "UTF-8")
    return url
}

/** Typed facade for PiRpc: call / callWithTimeout / subscribe / close. */
class PiRpc private constructor() {
    private lateinit var ws: WebSocket
    private class SubEntry(val topic: String, val key: String, val handler: (JsonElement) -> Unit)

    private val pending = ConcurrentHashMap<String, CompletableDeferred<JsonElement>>()
    private val subs = ConcurrentHashMap<String, SubEntry>()
    @Volatile private var closed = false

    suspend fun call(method: String, params: JsonElement? = null): JsonElement =
        callWithTimeout(method, DEFAULT_CALL_TIMEOUT_MS, params)

    suspend fun callWithTimeout(method: String, timeoutMs: Long, params: JsonElement? = null): JsonElement {
        if (closed) throw RpcError("CLOSED", "RPC port closed")
        val id = makeId()
        val d = CompletableDeferred<JsonElement>()
        pending[id] = d
        val req = buildJsonObject {
            put("kind", "request"); put("id", id); put("method", method)
            if (params != null) put("params", params)
        }
        if (!ws.send(req.toString())) {
            pending.remove(id)
            throw RpcError("CLOSED", "RPC port closed")
        }
        val safe = if (timeoutMs > 0) timeoutMs else DEFAULT_CALL_TIMEOUT_MS
        return try {
            withTimeout(safe) { d.await() }
        } catch (e: TimeoutCancellationException) {
            pending.remove(id)
            throw RpcError("TIMEOUT", "RPC call timed out: $method")
        }
    }

    /** Handler is invoked on OkHttp's reader thread; returns an unsubscribe function. */
    fun subscribe(topic: String, key: String, on: (JsonElement) -> Unit): () -> Unit {
        val id = makeId()
        ws.send(buildJsonObject { put("kind", "subscribe"); put("id", id); put("topic", topic); put("key", key) }.toString())
        subs[id] = SubEntry(topic, key, on)
        return {
            subs.remove(id)
            ws.send(buildJsonObject { put("kind", "unsubscribe"); put("id", id); put("topic", topic); put("key", key) }.toString())
        }
    }

    fun close() {
        markClosed()
        ws.close(1000, null)
    }

    private fun markClosed() {
        if (closed) return
        closed = true
        val err = RpcError("CLOSED", "RPC port closed")
        pending.values.forEach { it.completeExceptionally(err) }
        pending.clear()
        subs.clear()
    }

    private fun onMessage(text: String) {
        val msg = runCatching { PiJson.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
        when (msg.str("kind")) {
            "response" -> {
                val p = pending.remove(msg.str("id")) ?: return
                if (msg.bool("ok")) p.complete(msg["result"] ?: JsonNull)
                else {
                    val e = msg["error"] as? JsonObject
                    p.completeExceptionally(
                        RpcError(e.str("code").ifEmpty { "UNKNOWN" }, e.str("message").ifEmpty { "Unknown RPC error" }, e?.get("detail"))
                    )
                }
            }
            "event" -> {
                val topic = msg.str("topic")
                val key = msg.str("key")
                val data = msg["data"] ?: JsonNull
                for (sub in subs.values) {
                    if (sub.topic == topic && (sub.key == "*" || sub.key == key || key == "*")) {
                        runCatching { sub.handler(data) } // ignore subscriber errors
                    }
                }
            }
        }
    }

    companion object {
        private val http = OkHttpClient.Builder()
            .pingInterval(20, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()

        /**
         * Opens the WebSocket. Resolves once open (createWebSocketPort's `opened` promise);
         * [onClose] fires once when the connection drops after opening.
         */
        suspend fun connect(url: String, onClose: (String?) -> Unit): PiRpc {
            val opened = CompletableDeferred<PiRpc>()
            val rpc = PiRpc()
            val listener = object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    opened.complete(rpc)
                }
                override fun onMessage(webSocket: WebSocket, text: String) { rpc.onMessage(text) }
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(1000, null) }
                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = dropped(reason.ifEmpty { null })
                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) =
                    dropped(t.message ?: t.javaClass.simpleName)

                private fun dropped(reason: String?) {
                    val r = rpc
                    if (!opened.isCompleted) {
                        opened.completeExceptionally(RpcError("CONNECT_FAILED", "WebSocket connection failed: ${reason ?: url}"))
                    } else if (!r.closed) {
                        r.markClosed()
                        onClose(reason)
                    } else r.markClosed()
                }
            }
            val ws = http.newWebSocket(Request.Builder().url(url).build(), listener)
            rpc.ws = ws
            return try {
                opened.await()
            } catch (e: Throwable) {
                ws.cancel()
                throw e
            }
        }
    }
}
