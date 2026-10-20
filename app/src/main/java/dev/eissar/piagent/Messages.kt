package dev.eissar.piagent

// Conversion of Pi agent messages (pi-ai Message JSON) into the display model.

import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicInteger

// --- org.json helpers (null-safe; JSONObject.optString returns "null" for JSON null) ---

fun JSONObject?.str(key: String): String {
    if (this == null) return ""
    val v = opt(key)
    return if (v is String) v else ""
}
fun JSONObject?.bool(key: String): Boolean = this?.opt(key) == true
fun JSONObject?.num(key: String): Double = (this?.opt(key) as? Number)?.toDouble() ?: 0.0
fun JSONObject?.obj(key: String): JSONObject? = this?.opt(key) as? JSONObject
fun JSONObject?.arr(key: String): List<Any?> = (this?.opt(key) as? JSONArray).toList()
fun JSONArray?.toList(): List<Any?> = if (this == null) emptyList() else List(length()) { opt(it) }
fun List<Any?>.objects(): List<JSONObject> = filterIsInstance<JSONObject>()
fun List<Any?>.strings(): List<String> = filterIsInstance<String>()

enum class Role { User, Assistant, ToolResult, Custom, Other }
enum class BlockKind { Text, Thinking, ToolCall, Image, Error }

data class Block(
    val kind: BlockKind,
    val text: String,          // text / thinking / pretty args
    val name: String = "",     // tool name
    val summary: String = "",  // tool one-line summary
    val callId: String = "",
)

data class Message(
    val uid: Int,
    val role: Role,
    val blocks: List<Block>,
    val toolCallId: String = "",
    val toolName: String = "",
    val isError: Boolean = false,
    val label: String = "",
) {
    fun plainText(): String = blocks
        .filter { it.kind == BlockKind.Text || it.kind == BlockKind.Error || it.kind == BlockKind.ToolCall }
        .joinToString("\n\n") { it.text }
}

private val uidCounter = AtomicInteger()
fun nextUid() = uidCounter.incrementAndGet()

fun userMessage(text: String) = Message(nextUid(), Role.User, listOf(Block(BlockKind.Text, text)))

private val SUMMARY_KEYS = listOf("command", "path", "file_path", "filePath", "pattern", "query", "url", "task", "prompt")

fun toolSummary(args: Any?): String {
    val o = args as? JSONObject ?: return ""
    val s = SUMMARY_KEYS.firstNotNullOfOrNull { k -> o.str(k).takeIf { it.isNotEmpty() } }
        ?: o.keys().asSequence().firstNotNullOfOrNull { k -> o.str(k).takeIf { it.isNotEmpty() } }
        ?: return ""
    return s.substringBefore('\n')
}

/** Pretty-print a JSON value (tool arguments); multi-line strings shown raw. */
fun jsonPretty(v: Any?, indent: Int = 0): String {
    val sb = StringBuilder()
    fun pad(n: Int) = repeat(n) { sb.append("  ") }
    fun go(v: Any?, ind: Int) {
        when (v) {
            null, JSONObject.NULL -> sb.append("null")
            is String -> if (v.contains('\n') && ind > 0) {
                sb.append("|\n")
                v.lines().forEach { pad(ind + 1); sb.append(it).append('\n') }
                pad(ind)
            } else sb.append(JSONObject.quote(v))
            is Number -> {
                val d = v.toDouble()
                if (d == Math.floor(d) && Math.abs(d) < 1e15) sb.append(d.toLong()) else sb.append(v)
            }
            is Boolean -> sb.append(v)
            is JSONArray -> {
                if (v.length() == 0) { sb.append("[]"); return }
                sb.append("[\n")
                for (i in 0 until v.length()) {
                    pad(ind + 1); go(v.opt(i), ind + 1)
                    if (i < v.length() - 1) sb.append(',')
                    sb.append('\n')
                }
                pad(ind); sb.append(']')
            }
            is JSONObject -> {
                if (v.length() == 0) { sb.append("{}"); return }
                sb.append("{\n")
                val keys = v.keys().asSequence().toList()
                keys.forEachIndexed { i, k ->
                    pad(ind + 1); sb.append(k).append(": "); go(v.opt(k), ind + 1)
                    if (i < keys.size - 1) sb.append(',')
                    sb.append('\n')
                }
                pad(ind); sb.append('}')
            }
            else -> sb.append(v.toString())
        }
    }
    go(v, indent)
    return sb.toString()
}

fun messageFromJson(v: JSONObject): Message {
    val role = v.str("role")
    val uid = nextUid()
    if (role == "bashExecution") {
        return Message(uid, Role.Other, listOf(Block(BlockKind.Text, "$ ${v.str("command")}\n${v.str("output")}")), label = "bash")
    }
    val blocks = ArrayList<Block>()
    when (val content = v.opt("content")) {
        is String -> blocks += Block(BlockKind.Text, content)
        is JSONArray -> for (part in content.toList().objects()) {
            when (part.str("type")) {
                "text" -> part.str("text").takeIf { it.isNotBlank() }?.let { blocks += Block(BlockKind.Text, it) }
                "thinking" -> part.str("thinking").takeIf { it.isNotBlank() }?.let { blocks += Block(BlockKind.Thinking, it) }
                "toolCall", "tool_use" -> {
                    val args = part.opt("arguments") ?: part.opt("input")
                    blocks += Block(
                        BlockKind.ToolCall,
                        text = if (args is String) args else jsonPretty(args),
                        name = part.str("name"),
                        summary = toolSummary(args),
                        callId = part.str("id"),
                    )
                }
                "image" -> blocks += Block(BlockKind.Image, "[image]")
            }
        }
    }
    val r = when (role) {
        "user" -> Role.User
        "assistant" -> Role.Assistant
        "toolResult" -> Role.ToolResult
        "custom" -> Role.Custom
        else -> Role.Other
    }
    if (r == Role.Assistant) {
        val em = v.str("errorMessage")
        if (em.isNotEmpty()) blocks += Block(BlockKind.Error, em)
        else if (v.str("stopReason") == "aborted") blocks += Block(BlockKind.Error, "Aborted")
    }
    return Message(
        uid, r, blocks,
        toolCallId = v.str("toolCallId"),
        toolName = v.str("toolName"),
        isError = v.bool("isError"),
        label = when (r) { Role.Custom -> v.str("customType"); Role.Other -> role; else -> "" },
    )
}

/** Text of a user message JSON (for de-duplicating optimistic bubbles). */
fun userTextOfJson(v: JSONObject): String = when (val c = v.opt("content")) {
    is String -> c
    is JSONArray -> c.toList().objects().firstOrNull { it.str("type") == "text" }.str("text")
    else -> ""
}
