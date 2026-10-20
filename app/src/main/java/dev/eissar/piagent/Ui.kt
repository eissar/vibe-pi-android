@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)

package dev.eissar.piagent

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

private val Mono = FontFamily.Monospace
private val Ok = Color(0xFF81C995)

@Composable
fun PiTheme(content: @Composable () -> Unit) = MaterialTheme(
    colorScheme = darkColorScheme(
        primary = Color(0xFF8AB4F8), background = Color(0xFF111318), surface = Color(0xFF111318),
        surfaceContainer = Color(0xFF1A1D24), surfaceContainerHigh = Color(0xFF242832),
    ),
    typography = Typography().let { t ->
        t.copy(
            titleLarge = t.titleLarge.copy(fontSize = 18.sp, lineHeight = 24.sp),
            titleMedium = t.titleMedium.copy(fontSize = 15.sp, lineHeight = 20.sp),
            bodyLarge = t.bodyLarge.copy(fontSize = 14.sp, lineHeight = 20.sp),
            bodyMedium = t.bodyMedium.copy(fontSize = 13.sp, lineHeight = 18.sp),
            bodySmall = t.bodySmall.copy(fontSize = 12.sp, lineHeight = 16.sp),
            labelLarge = t.labelLarge.copy(fontSize = 13.sp),
        )
    },
    content = content,
)

@Composable
fun Root(s: AppState) {
    var settings by remember { mutableStateOf(s.address.isBlank()) }
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        val chat = s.chat
        when {
            chat != null -> ChatScreen(s, chat)
            settings || s.address.isBlank() -> ServerScreen(s) { settings = false }
            else -> HomeScreen(s) { settings = true }
        }
        s.ask?.let { AskDialog(s, it) }
        s.notice?.let {
            Surface(
                Modifier.align(Alignment.BottomCenter).navigationBarsPadding().imePadding().padding(bottom = 90.dp, start = 24.dp, end = 24.dp),
                shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh, shadowElevation = 4.dp,
            ) { Text(it, Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) }
        }
    }
}

@Composable
private fun Muted(text: String, modifier: Modifier = Modifier, size: Int = 13, lines: Int = 1) = Text(
    text, modifier, fontSize = size.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
    maxLines = lines, overflow = TextOverflow.Ellipsis,
)

@Composable
private fun OfflineBar(s: AppState) {
    if (s.conn == Conn.Online) return
    Text(
        if (s.conn == Conn.Connecting) "Connecting…" else "Offline: ${s.connError ?: ""} (tap to retry)",
        Modifier.fillMaxWidth().background(Color(0xFF4A3410)).clickable { s.connect() }.padding(horizontal = 16.dp, vertical = 8.dp),
        fontSize = 13.sp, maxLines = 2,
    )
}

// --- server -----------------------------------------------------------------------

@Composable
private fun ServerScreen(s: AppState, done: () -> Unit) {
    LaunchedEffect(s.conn) { if (s.conn == Conn.Online) done() }
    Scaffold(topBar = { TopAppBar(title = { Text("Server") }) }) { pad ->
        Column(Modifier.padding(pad).padding(20.dp).imePadding(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(
                s.address, { s.address = it }, Modifier.fillMaxWidth(), singleLine = true,
                label = { Text("Address") }, placeholder = { Text("192.168.1.10:7860") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            )
            OutlinedTextField(
                s.token, { s.token = it }, Modifier.fillMaxWidth(), singleLine = true,
                label = { Text("Token (optional)") }, visualTransformation = PasswordVisualTransformation(),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(s::connect, enabled = s.conn != Conn.Connecting) {
                    Text(if (s.conn == Conn.Connecting) "Connecting…" else "Connect")
                }
                if (s.conn == Conn.Online) {
                    OutlinedButton(done) { Text("Back") }
                    OutlinedButton(s::disconnect) { Text("Disconnect") }
                }
            }
            s.connError?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 13.sp) }
            Muted("Run the server with PI_WEBUI_HOST=0.0.0.0 npm start", lines = 3)
        }
    }
}

// --- home: sessions ----------------------------------------------------------------

@Composable
private fun HomeScreen(s: AppState, openSettings: () -> Unit) {
    var newDialog by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf<Session?>(null) }
    var renaming by remember { mutableStateOf<Session?>(null) }
    val clip = LocalClipboardManager.current
    Scaffold(
        topBar = {
            TopAppBar(title = { Text("Pi") }, actions = {
                IconButton({ s.refreshSessions() }) { Icon(Icons.Filled.Refresh, "Refresh") }
                IconButton(openSettings) { Icon(Icons.Filled.Settings, "Server") }
            })
        },
        floatingActionButton = { FloatingActionButton({ newDialog = true }) { Icon(Icons.Filled.Add, "New session") } },
    ) { pad ->
        Column(Modifier.padding(pad)) {
            OfflineBar(s)
            if (s.conn == Conn.Online && s.sessions.isEmpty()) Muted("No sessions yet.", Modifier.padding(20.dp))
            LazyColumn(contentPadding = PaddingValues(bottom = 96.dp)) {
                items(s.sessions, key = { it.id }) { it ->
                    Box {
                        Row(
                            Modifier.fillMaxWidth().combinedClickable(onClick = { s.open(it) }, onLongClick = { menu = it })
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(it.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Muted("${folder(it.cwd)} · ${ago(it.modified)} · ${it.count} msgs", size = 12)
                            }
                            if (s.running[it.id] == true) Dot(MaterialTheme.colorScheme.primary)
                        }
                        DropdownMenu(menu == it, { menu = null }) {
                            DropdownMenuItem({ Text("Rename") }, { renaming = it; menu = null })
                            DropdownMenuItem({ Text("Copy folder path") }, { clip.setText(AnnotatedString(it.cwd)); menu = null })
                            DropdownMenuItem({ Text("Delete") }, { s.delete(it.id); menu = null })
                        }
                    }
                }
            }
        }
    }
    if (newDialog) NewSessionDialog(s) { newDialog = false }
    renaming?.let { r ->
        var name by remember { mutableStateOf(r.title) }
        AlertDialog(
            { renaming = null }, title = { Text("Rename") },
            text = { OutlinedTextField(name, { name = it }, singleLine = true) },
            confirmButton = { TextButton({ s.rename(r.id, name.trim()); renaming = null }) { Text("Save") } },
            dismissButton = { TextButton({ renaming = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun NewSessionDialog(s: AppState, close: () -> Unit) {
    var cwd by remember { mutableStateOf(s.recentCwds.firstOrNull() ?: s.defaultCwd) }
    AlertDialog(
        close, title = { Text("New session") },
        text = {
            Column {
                OutlinedTextField(
                    cwd, { cwd = it }, Modifier.fillMaxWidth(), singleLine = true, label = { Text("Folder on server") },
                    textStyle = LocalTextStyle.current.copy(fontFamily = Mono, fontSize = 13.sp),
                )
                LazyColumn(Modifier.heightIn(max = 260.dp).padding(top = 8.dp)) {
                    items(s.recentCwds) { d ->
                        Column(Modifier.fillMaxWidth().clickable { cwd = d }.padding(vertical = 8.dp)) {
                            Text(folder(d)); Muted(d, size = 11)
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton({ s.newChat(cwd); close() }) { Text("Start") } },
        dismissButton = { TextButton(close) { Text("Cancel") } },
    )
}

// --- chat -------------------------------------------------------------------------

@Composable
private fun ChatScreen(s: AppState, c: AppState.Chat) {
    var picking by remember { mutableStateOf(false) }
    val list = rememberLazyListState()
    // Results are shown inside their tool call card.
    val results = remember(c.messages.toList()) {
        c.messages.filter { it.str("role") == "toolResult" }.associateBy { it.str("toolCallId") }
    }
    val callIds = remember(c.messages.toList()) {
        c.messages.flatMap { m -> m.list("content").mapNotNull { (it as? JsonObject)?.takeIf(::isToolCall)?.str("id") } }.toSet()
    }
    val shown = c.messages.filter { m ->
        when (m.str("role")) {
            "system" -> false
            "custom" -> m.bool("display")
            "toolResult" -> m.str("toolCallId") !in callIds
            else -> true
        }
    }
    // Follow the bottom while near it.
    val nearBottom by remember { derivedStateOf { !list.canScrollForward || list.layoutInfo.totalItemsCount == 0 } }
    LaunchedEffect(shown.size, shown.lastOrNull(), c.status) { if (nearBottom || c.loading) list.scrollToItem(shown.size) }

    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = { IconButton(s::closeChat) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
                title = {
                    Column(Modifier.clickable { picking = true }) {
                        Text(c.title, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Muted("${c.model?.name ?: "default model"} ▾  ${folder(c.cwd)}", size = 12)
                    }
                },
                actions = { IconButton(s::reload) { Icon(Icons.Filled.Refresh, "Reload") } },
            )
        },
        bottomBar = { Composer(s, c) },
    ) { pad ->
        Column(Modifier.padding(pad)) {
            OfflineBar(s)
            if (c.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
            LazyColumn(Modifier.weight(1f), list, contentPadding = PaddingValues(12.dp)) {
                items(shown) { m -> MessageItem(s, m, results, c) }
                item {
                    if (c.busy) Row(Modifier.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(8.dp))
                        Muted(c.status.ifEmpty { "Working…" })
                    }
                }
            }
        }
    }
    if (picking) ModelSheet(s, c) { picking = false }
}

@Composable
private fun Composer(s: AppState, c: AppState.Chat) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainer) {
        Row(Modifier.navigationBarsPadding().imePadding().padding(8.dp), verticalAlignment = Alignment.Bottom) {
            OutlinedTextField(
                c.draft, { c.draft = it }, Modifier.weight(1f), maxLines = 8,
                placeholder = { Text(if (c.busy) "Queue a follow-up…" else "Message Pi…") },
            )
            Spacer(Modifier.width(6.dp))
            if (c.busy && c.draft.isBlank()) {
                FilledIconButton(s::stop, colors = IconButtonDefaults.filledIconButtonColors(MaterialTheme.colorScheme.error)) {
                    Icon(Icons.Filled.Close, "Stop")
                }
            } else {
                FilledIconButton(s::send, enabled = c.draft.isNotBlank() && s.conn == Conn.Online) {
                    Icon(Icons.AutoMirrored.Filled.Send, "Send")
                }
            }
        }
    }
}

private fun isToolCall(b: JsonObject) = b.str("type") == "toolCall" || b.str("type") == "tool_use"

/** Text content of a message (content may be a string or block array). */
private fun textOf(m: JsonObject): String = when (val c = m["content"]) {
    is JsonPrimitive -> c.content
    is JsonArray -> c.filterIsInstance<JsonObject>().filter { it.str("type") == "text" }.joinToString("\n\n") { it.str("text") }
    else -> ""
}

@Composable
private fun MessageItem(s: AppState, m: JsonObject, results: Map<String, JsonObject>, c: AppState.Chat) {
    val clip = LocalClipboardManager.current
    val copy = { clip.setText(AnnotatedString(textOf(m))); s.say("Copied") }
    when (m.str("role")) {
        "user" -> Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), horizontalArrangement = Arrangement.End) {
            Surface(
                Modifier.widthIn(max = 320.dp).combinedClickable(onClick = {}, onLongClick = copy),
                shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh,
            ) { Text(textOf(m), Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) }
        }
        "assistant" -> Column(Modifier.fillMaxWidth().padding(vertical = 4.dp).combinedClickable(onClick = {}, onLongClick = copy)) {
            for (b in m.list("content").filterIsInstance<JsonObject>()) {
                when {
                    b.str("type") == "text" && b.str("text").isNotBlank() ->
                        SelectionContainer { ChatMarkdown(b.str("text")) }
                    b.str("type") == "thinking" && b.str("thinking").isNotBlank() -> Thinking(b.str("thinking"))
                    isToolCall(b) -> ToolCard(b.str("name"), b["arguments"] ?: b["input"], results[b.str("id")], c.busy)
                }
            }
            val err = m.str("errorMessage").ifEmpty { if (m.str("stopReason") == "aborted") "Aborted" else "" }
            if (err.isNotEmpty()) Text(err, color = MaterialTheme.colorScheme.error, fontSize = 14.sp)
        }
        "toolResult" -> ToolCard(m.str("toolName").ifEmpty { "tool" }, null, m, false)
        "bashExecution" -> CodeBlock("$ ${m.str("command")}\n${m.str("output")}")
        else -> Column(Modifier.padding(vertical = 4.dp)) {
            Muted(m.str("customType").ifEmpty { m.str("role") }.uppercase(), size = 11)
            Text(textOf(m), fontSize = 14.sp)
        }
    }
}

@Composable
private fun Thinking(text: String) {
    var open by remember { mutableStateOf(false) }
    Column(Modifier.padding(vertical = 4.dp).clickable { open = !open }) {
        Muted(if (open) "▾ Thinking" else "▸ Thinking")
        if (open) Muted(text, Modifier.padding(start = 12.dp, top = 4.dp), lines = Int.MAX_VALUE)
    }
}

/** Shows a tool call with its arguments and (once available) its result. */
@Composable
private fun ToolCard(name: String, args: JsonElement?, result: JsonObject?, busy: Boolean) {
    var open by remember { mutableStateOf(false) }
    val error = result.bool("isError")
    Surface(Modifier.fillMaxWidth().padding(vertical = 3.dp), RoundedCornerShape(10.dp), MaterialTheme.colorScheme.surfaceContainer) {
        Column {
            Row(Modifier.fillMaxWidth().clickable { open = !open }.padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
                when {
                    result == null && busy -> CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp)
                    else -> Dot(if (error) MaterialTheme.colorScheme.error else if (result != null) Ok else Color.Gray)
                }
                Spacer(Modifier.width(8.dp))
                Text(name, fontFamily = Mono, fontSize = 13.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.width(8.dp))
                Muted(summary(args), Modifier.weight(1f), size = 12)
            }
            if (open) {
                if (args != null) CodeBlock(argsText(args), "Input")
                if (result != null) CodeBlock(textOf(result).ifEmpty { "(no output)" }, if (error) "Error" else "Output")
            }
        }
    }
}

@Composable
private fun CodeBlock(text: String, label: String? = null) {
    Column(Modifier.padding(start = 10.dp, end = 10.dp, bottom = 8.dp)) {
        label?.let { Muted(it, size = 11) }
        val t = if (text.length > 20_000) text.take(20_000) + "\n… (truncated)" else text
        SelectionContainer {
            Text(t, Modifier.horizontalScroll(rememberScrollState()), fontFamily = Mono, fontSize = 12.sp, softWrap = false)
        }
    }
}

/** One-line description of a tool call: its most telling string argument. */
private fun summary(args: JsonElement?): String {
    val o = args as? JsonObject ?: return ""
    val key = listOf("command", "path", "file_path", "pattern", "query", "url").firstOrNull { o.str(it).isNotEmpty() }
    return (key?.let { o.str(it) } ?: o.values.firstNotNullOfOrNull { it.string() } ?: "").lineSequence().first()
}

private fun argsText(args: JsonElement): String = when (args) {
    is JsonObject -> args.entries.joinToString("\n") { (k, v) -> "$k: ${v.string() ?: v.toString()}" }
    else -> args.string() ?: args.toString()
}

@Composable
private fun Dot(color: Color) = Box(Modifier.size(8.dp).clip(CircleShape).background(color))

// --- model sheet & extension dialogs -----------------------------------------------------

@Composable
private fun ModelSheet(s: AppState, c: AppState.Chat, close: () -> Unit) {
    var q by remember { mutableStateOf("") }
    ModalBottomSheet(close) {
        Column(Modifier.padding(horizontal = 16.dp)) {
            OutlinedTextField(q, { q = it }, Modifier.fillMaxWidth(), singleLine = true, placeholder = { Text("Search models") })
            val ql = q.lowercase()
            LazyColumn(Modifier.heightIn(max = 500.dp).padding(top = 8.dp)) {
                items(s.models.filter { ql in it.name.lowercase() || ql in it.id.lowercase() || ql in it.provider.lowercase() }) { m ->
                    val sel = c.model?.id == m.id && c.model?.provider == m.provider
                    Column(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp))
                            .background(if (sel) MaterialTheme.colorScheme.surfaceContainerHigh else Color.Transparent)
                            .clickable { s.pickModel(m); close() }.padding(10.dp),
                    ) { Text(m.name); Muted("${m.provider} · ${m.id}", size = 12) }
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun AskDialog(s: AppState, a: Ask) {
    val r = a.req
    var text by remember(a.id) { mutableStateOf(r.str("prefill")) }
    AlertDialog(
        { s.answer(null) },
        title = { Text(r.str("title")) },
        text = {
            Column {
                if (r.str("message").isNotEmpty()) Text(r.str("message"))
                when (a.method) {
                    "select" -> LazyColumn(Modifier.heightIn(max = 360.dp)) {
                        items(r.strs("options")) { o ->
                            Text(o, Modifier.fillMaxWidth().clickable { s.answer(o) }.padding(vertical = 12.dp))
                        }
                    }
                    "input" -> OutlinedTextField(text, { text = it }, Modifier.fillMaxWidth(), singleLine = true,
                        placeholder = { Text(r.str("placeholder")) })
                    "editor" -> OutlinedTextField(text, { text = it }, Modifier.fillMaxWidth().heightIn(min = 160.dp),
                        textStyle = LocalTextStyle.current.copy(fontFamily = Mono, fontSize = 13.sp))
                }
            }
        },
        confirmButton = {
            when (a.method) {
                "confirm" -> TextButton({ s.answer("true") }) { Text("Yes") }
                "input", "editor" -> TextButton({ s.answer(text) }) { Text("OK") }
            }
        },
        dismissButton = {
            if (a.method == "confirm") TextButton({ s.answer("false") }) { Text("No") }
            else TextButton({ s.answer(null) }) { Text("Cancel") }
        },
    )
}

// --- formatting ---------------------------------------------------------------------------

private fun folder(path: String) = path.trimEnd('/').substringAfterLast('/').ifEmpty { path }

private fun ago(epochSec: Long): String {
    if (epochSec <= 0) return ""
    val d = System.currentTimeMillis() / 1000 - epochSec
    return when {
        d < 60 -> "now"
        d < 3600 -> "${d / 60}m"
        d < 86400 -> "${d / 3600}h"
        else -> "${d / 86400}d"
    }
}
