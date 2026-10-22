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
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.MoreVert
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
import kotlinx.coroutines.launch
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

/** True while rendering inside a bubble window, where window insets are already partly
 *  consumed by the floating window and combining system-bar + IME padding over-pads. */
val LocalInBubble = androidx.compose.runtime.staticCompositionLocalOf { false }

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

/**
 * Content of a bubbled chat window: the chat itself, or a short prompt when no
 * session is open (e.g. the bubble outlived its session).
 */
@Composable
fun BubbleRoot(s: AppState) {
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        val chat = s.chat
        if (chat != null) ChatScreen(s, chat) else Surface(Modifier.fillMaxSize()) {
            Column(
                Modifier.fillMaxSize().padding(20.dp).imePadding(),
                verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Muted("No chat open", size = 14)
                Spacer(Modifier.height(12.dp))
                Muted("Open a chat in Pi, then ⋮ → Show as bubble", size = 12, lines = 2)
            }
        }
        s.notice?.let {
            Surface(
                Modifier.align(Alignment.BottomCenter).imePadding().padding(12.dp),
                shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh, shadowElevation = 4.dp,
            ) { Text(it, Modifier.padding(horizontal = 14.dp, vertical = 8.dp)) }
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
    // Close only when a connection attempt *succeeds* while this screen is open; opening the
    // screen while already online must stay put (otherwise it flashes and disappears).
    var wasOnline by remember { mutableStateOf(s.conn == Conn.Online) }
    LaunchedEffect(s.conn) {
        val online = s.conn == Conn.Online
        if (online && !wasOnline) done()
        wasOnline = online
    }
    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Server") },
            navigationIcon = { IconButton(done) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
        )
    }) { pad ->
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
            HorizontalDivider()
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Bubbles for watched chats")
                    Muted("Watched chats also appear as floating bubbles", size = 11, lines = 2)
                }
                Switch(checked = s.bubblesForWatched(), onCheckedChange = s::setBubblesForWatched)
            }
            OutlinedButton({ s.openBubbleSettings() }, contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)) {
                Text("Allow bubbles in system settings", fontSize = 13.sp)
            }
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
    val inBubble = LocalInBubble.current
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
    val scope = rememberCoroutineScope()
    val nearBottom by remember { derivedStateOf { !list.canScrollForward || list.layoutInfo.totalItemsCount == 0 } }
    LaunchedEffect(shown.size, shown.lastOrNull(), c.status) { if (nearBottom || c.loading) list.scrollToItem(shown.size) }

    Scaffold(
        contentWindowInsets = if (inBubble) WindowInsets(0) else ScaffoldDefaults.contentWindowInsets,
        topBar = {
            TopAppBar(
                navigationIcon = { IconButton(s::closeChat) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
                title = {
                    Column {
                        Text(c.title, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Muted(folder(c.cwd), size = 12)
                    }
                },
                actions = {
                    var menu by remember { mutableStateOf(false) }
                    IconButton({ menu = true }) { Icon(Icons.Filled.MoreVert, "More") }
                    DropdownMenu(menu, { menu = false }) {
                        val watched = s.isWatched(c.sessionId)
                        DropdownMenuItem(
                            text = {
                                Column {
                                    Text("Watch")
                                    Muted("Persistent notification + bubble; ping on status change", size = 11, lines = 2)
                                }
                            },
                            leadingIcon = { Checkbox(watched, null) },
                            enabled = c.sessionId != null,
                            onClick = { s.toggleWatch(); menu = false },
                        )
                        val bubbled = c.sessionId?.let { s.isBubbled(it) } == true
                        val autoBubble = s.isWatched(c.sessionId) && s.bubblesForWatched()
                        DropdownMenuItem(
                            text = {
                                Column {
                                    Text(if (bubbled && !autoBubble) "Remove bubble" else "Show as bubble")
                                    Muted(
                                        if (autoBubble) "Automatic for watched chats"
                                        else "Keep this chat in a floating window",
                                        size = 11, lines = 2,
                                    )
                                }
                            },
                            leadingIcon = { Checkbox(bubbled || autoBubble, null) },
                            enabled = c.sessionId != null && !autoBubble,
                            onClick = { s.toggleBubble(); menu = false },
                        )
                        DropdownMenuItem({ Text("Reload") }, { s.reload(); menu = false },
                            leadingIcon = { Icon(Icons.Filled.Refresh, null) })
                    }
                },
            )
        },
        bottomBar = { Composer(s, c) { picking = true } },
    ) { pad ->
        Column(Modifier.padding(pad)) {
            OfflineBar(s)
            if (c.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
            Box(Modifier.weight(1f)) {
                LazyColumn(Modifier.fillMaxSize(), list, contentPadding = PaddingValues(12.dp)) {
                    items(shown) { m -> MessageItem(s, m, results, c) }
                    item {
                        if (c.busy) Row(Modifier.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                            Spacer(Modifier.width(8.dp))
                            Muted(c.status.ifEmpty { "Working…" })
                        }
                    }
                }
                androidx.compose.animation.AnimatedVisibility(
                    !nearBottom, Modifier.align(Alignment.BottomEnd).padding(12.dp),
                    enter = androidx.compose.animation.fadeIn(), exit = androidx.compose.animation.fadeOut(),
                ) {
                    SmallFloatingActionButton({ scope.launch { list.animateScrollToItem(shown.size) } }) {
                        Icon(Icons.Filled.KeyboardArrowDown, "Scroll to bottom")
                    }
                }
            }
        }
    }
    if (picking) ModelSheet(s, c) { picking = false }
}

@Composable
private fun Composer(s: AppState, c: AppState.Chat, pickModel: () -> Unit) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainer) {
        val inBubble = LocalInBubble.current
        Column(
            (if (inBubble) Modifier.imePadding() else Modifier.navigationBarsPadding().imePadding())
                .padding(horizontal = 8.dp, vertical = 6.dp)
        ) {
            MetricsBar(s, c, pickModel)
            Row(verticalAlignment = Alignment.Bottom) {
                OutlinedTextField(
                    c.draft, { c.draft = it }, Modifier.weight(1f), maxLines = 8,
                    placeholder = { Text(if (c.busy) "Steer now / queue follow-up…" else "Message Pi…") },
                )
                Spacer(Modifier.width(6.dp))
                when {
                    c.busy && c.draft.isBlank() ->
                        FilledIconButton(s::stop, colors = IconButtonDefaults.filledIconButtonColors(MaterialTheme.colorScheme.error)) {
                            Icon(Icons.Filled.Close, "Stop")
                        }
                    c.busy -> Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        // Steer interrupts the current run; follow-up waits until it finishes.
                        FilledTonalButton({ s.send(steer = true) }, contentPadding = PaddingValues(horizontal = 12.dp)) { Text("Steer") }
                        OutlinedButton({ s.send(steer = false) }, contentPadding = PaddingValues(horizontal = 12.dp)) { Text("Follow-up") }
                    }
                    else -> FilledIconButton({ s.send() }, enabled = c.draft.isNotBlank() && s.conn == Conn.Online) {
                        Icon(Icons.AutoMirrored.Filled.Send, "Send")
                    }
                }
            }
        }
    }
}

private val LevelHints = mapOf(
    "off" to "No reasoning", "minimal" to "Very brief reasoning", "low" to "Light reasoning",
    "medium" to "Balanced", "high" to "Deep reasoning", "xhigh" to "Maximum reasoning",
)

private val Warn = Color(0xFFFDD663)

/**
 * One fixed-height, horizontally scrolling row above the composer:
 * model · [thinking] · context · session cost · last reply · queued · extension statuses.
 * Items with no data are omitted; the row keeps its height either way.
 */
@Composable
private fun MetricsBar(s: AppState, c: AppState.Chat, pickModel: () -> Unit) {
    var sheet by remember { mutableStateOf<String?>(null) } // "cost" | "queued"
    Row(
        Modifier.fillMaxWidth().height(36.dp).horizontalScroll(rememberScrollState()),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        BarChip(c.model?.name ?: "default model", bold = true, onClick = pickModel)
        ThinkingChip(s, c)
        ContextChip(s, c)
        if (c.total.cost > 0) BarChip(money(c.total.cost), onClick = { sheet = "cost" })
        else if (c.total.input + c.total.output > 0) BarChip("${tokens(c.total.input + c.total.output)} tok", onClick = { sheet = "cost" })
        c.lastReply?.let { u ->
            val cost = if (u.cost > 0) " · ${money(u.cost)}" else ""
            BarChip("last ↑${tokens(u.input + u.cacheRead + u.cacheWrite)} ↓${tokens(u.output)}$cost", onClick = { sheet = "cost" })
        }
        val q = c.queuedSteer.size + c.queuedFollowUp.size
        if (q > 0) BarChip("$q queued", color = MaterialTheme.colorScheme.primary, onClick = { sheet = "queued" })
        c.statuses.values.filter { it.isNotBlank() }.forEach { BarChip(it.lineSequence().first()) }
    }
    when (sheet) {
        "cost" -> CostSheet(c) { sheet = null }
        "queued" -> QueuedSheet(c) { sheet = null }
    }
}

@Composable
private fun BarChip(text: String, bold: Boolean = false, color: Color? = null, onClick: (() -> Unit)? = null) {
    Surface(
        shape = RoundedCornerShape(8.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = Modifier.height(30.dp).let { if (onClick != null) it.clip(RoundedCornerShape(8.dp)).clickable(onClick = onClick) else it },
    ) {
        Box(Modifier.padding(horizontal = 10.dp), contentAlignment = Alignment.Center) {
            Text(
                text, fontSize = 12.sp, maxLines = 1, softWrap = false,
                fontWeight = if (bold) FontWeight.SemiBold else FontWeight.Normal,
                color = color ?: MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** Shows the level as [low]; the picker only opens on tap. */
@Composable
private fun ThinkingChip(s: AppState, c: AppState.Chat) {
    val levels = s.levelsFor(c.model)
    if (levels.size <= 1) return
    var open by remember { mutableStateOf(false) }
    Box {
        BarChip("[${c.thinking.ifEmpty { "default" }}]", onClick = { open = true })
        DropdownMenu(open, { open = false }) {
            levels.forEach { l ->
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(l, fontWeight = if (l == c.thinking) FontWeight.Bold else FontWeight.Normal)
                            LevelHints[l]?.let { Muted(it, size = 11) }
                        }
                    },
                    onClick = { s.setThinking(l); open = false },
                )
            }
        }
    }
}

/** ctx 42% · 84k/200k, amber above 70%, red above 90%; tap for "Compact now". */
@Composable
private fun ContextChip(s: AppState, c: AppState.Chat) {
    val u = c.context ?: return
    if (u.window <= 0) return
    var open by remember { mutableStateOf(false) }
    val pct = u.percent ?: u.tokens?.let { it / u.window * 100 }
    val color = when {
        pct == null -> null
        pct >= 90 -> MaterialTheme.colorScheme.error
        pct >= 70 -> Warn
        else -> null
    }
    val label = if (pct == null) "ctx ? / ${tokens(u.window)}"
    else "ctx ${pct.toInt()}% · ${tokens(u.tokens ?: (pct / 100 * u.window))}/${tokens(u.window)}"
    Box {
        BarChip(if (c.compacting) "compacting…" else label, color = color, onClick = { open = true })
        DropdownMenu(open, { open = false }) {
            DropdownMenuItem(
                text = { Text("Compact now") },
                enabled = c.sessionId != null && !c.compacting && s.conn == Conn.Online,
                onClick = { open = false; s.compact() },
            )
        }
    }
}

@Composable
private fun CostSheet(c: AppState.Chat, close: () -> Unit) {
    ModalBottomSheet(close) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Session usage", fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
            val t = c.total
            StatRow("Cost", if (t.cost > 0) money(t.cost) else "—")
            StatRow("Input", tokens(t.input))
            StatRow("Output", tokens(t.output))
            StatRow("Cache read", tokens(t.cacheRead))
            StatRow("Cache write", tokens(t.cacheWrite))
            val inAll = t.input + t.cacheRead
            if (inAll > 0) StatRow("Cache hit", "${(t.cacheRead / inAll * 100).toInt()}%")
            StatRow("Messages", "${c.userMessages} user · ${c.replies} assistant")
            StatRow("Tool calls", "${c.toolCalls}")
            c.context?.let { StatRow("Context window", tokens(it.window)) }
            c.lastReply?.let { u ->
                Spacer(Modifier.height(8.dp))
                Text("Last reply", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                StatRow("Input", "${tokens(u.input)} (+${tokens(u.cacheRead)} cached)")
                StatRow("Output", tokens(u.output))
                if (u.cost > 0) StatRow("Cost", money(u.cost))
            }
        }
    }
}

@Composable
private fun StatRow(label: String, value: String) = Row(Modifier.fillMaxWidth()) {
    Muted(label, Modifier.weight(1f), size = 13)
    Text(value, fontSize = 13.sp, fontFamily = Mono)
}

@Composable
private fun QueuedSheet(c: AppState.Chat, close: () -> Unit) {
    ModalBottomSheet(close) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Queued", fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
            c.queuedSteer.forEach { QueuedRow("Steer", it) }
            c.queuedFollowUp.forEach { QueuedRow("Follow-up", it) }
        }
    }
}

@Composable
private fun QueuedRow(kind: String, text: String) = Column {
    Text(kind, fontSize = 11.sp, color = MaterialTheme.colorScheme.primary)
    Text(text, fontSize = 14.sp, maxLines = 4, overflow = TextOverflow.Ellipsis)
}

/** 950 · 12.3k · 1.2M */
private fun tokens(n: Double): String = when {
    n >= 1_000_000 -> "%.1fM".format(n / 1_000_000)
    n >= 10_000 -> "%.0fk".format(n / 1000)
    n >= 1000 -> "%.1fk".format(n / 1000)
    else -> n.toInt().toString()
}

/** $1.24, or $0.042 below ten cents. */
private fun money(usd: Double): String = if (usd < 0.10) "$%.3f".format(usd) else "$%.2f".format(usd)

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
    if (m.str("role") == "custom" && m.str("customType") == "compaction") return CompactionCard(m)
    when (m.str("role")) {
        "user" -> parseSkill(textOf(m))?.let { SkillCard(it) } ?: Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), horizontalArrangement = Arrangement.End) {
            Surface(
                Modifier.widthIn(max = 320.dp).combinedClickable(onClick = {}, onLongClick = copy),
                shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh,
            ) {
                Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
                    m.str("queued").takeIf { it.isNotEmpty() }?.let {
                        Text(if (it == "steer") "Steer" else "Follow-up · queued", fontSize = 11.sp, color = MaterialTheme.colorScheme.primary)
                    }
                    Text(linkify(textOf(m)))
                }
            }
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
            Text(linkify(textOf(m)), fontSize = 14.sp)
        }
    }
}

// --- special message cards -----------------------------------------------------------

/** A collapsible bordered card with a mono tag, a title and expandable content. */
@Composable
private fun FoldCard(tag: String, title: String, content: @Composable () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Surface(
        Modifier.fillMaxWidth().padding(vertical = 6.dp), RoundedCornerShape(10.dp),
        MaterialTheme.colorScheme.surfaceContainer,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Column {
            Row(Modifier.fillMaxWidth().clickable { open = !open }.padding(horizontal = 10.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Muted(if (open) "▾" else "▸", size = 12)
                Spacer(Modifier.width(6.dp))
                Text(tag, fontFamily = Mono, fontSize = 11.sp, fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.width(8.dp))
                Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (open) Column(Modifier.padding(start = 12.dp, end = 12.dp, bottom = 10.dp)) { content() }
        }
    }
}

/** Compaction entries: summary body plus the <read-files>/<modified-files> lists Pi appends. */
@Composable
private fun CompactionCard(m: JsonObject) {
    val (body, read, modified) = remember(m) { parseCompaction(textOf(m)) }
    val before = m.obj("details").num("tokensBefore")
    FoldCard("compaction", "Conversation compacted" + if (before > 0) " · ${tokens(before)} tokens before" else "") {
        Muted("The history before this point was compacted into this summary:", size = 12, lines = 3)
        Spacer(Modifier.height(6.dp))
        if (body.isNotBlank()) SelectionContainer { ChatMarkdown(body) } else Muted("(no summary)")
        FileList("Read", read)
        FileList("Modified", modified)
    }
}

@Composable
private fun FileList(label: String, files: List<String>) {
    if (files.isEmpty()) return
    Spacer(Modifier.height(8.dp))
    Muted("$label (${files.size})", size = 11)
    files.forEach { Text(it, fontFamily = Mono, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) }
}

private val FileSection = Regex("""<(read-files|modified-files)>\s*([\s\S]*?)\s*</\1>""")

private fun parseCompaction(summary: String): Triple<String, List<String>, List<String>> {
    val read = ArrayList<String>(); val modified = ArrayList<String>()
    FileSection.findAll(summary).forEach { mr ->
        val files = mr.groupValues[2].lines().map { it.trim() }.filter { it.isNotEmpty() }
        if (mr.groupValues[1] == "read-files") read += files else modified += files
    }
    val body = FileSection.find(summary)?.let { summary.substring(0, it.range.first) } ?: summary
    return Triple(body.trim(), read, modified)
}

/** Pi persists `/skill:name msg` as <skill name=".." location="..">content</skill>\n\nmsg. */
private data class Skill(val name: String, val location: String, val content: String, val message: String?)

private val SkillBlock = Regex("""^<skill name="([^"]+)" location="([^"]+)">\n([\s\S]*?)\n</skill>(?:\n\n([\s\S]+))?$""")

private fun parseSkill(text: String): Skill? = SkillBlock.find(text)?.let {
    Skill(it.groupValues[1], it.groupValues[2], it.groupValues[3], it.groupValues[4].trim().ifEmpty { null })
}

@Composable
private fun SkillCard(k: Skill) {
    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp), horizontalAlignment = Alignment.End) {
        // What the user actually typed, as a normal bubble…
        Surface(Modifier.widthIn(max = 320.dp), RoundedCornerShape(16.dp), MaterialTheme.colorScheme.surfaceContainerHigh) {
            Text(linkify("/skill:${k.name}" + (k.message?.let { " $it" } ?: "")), Modifier.padding(horizontal = 14.dp, vertical = 10.dp))
        }
        // …and the injected skill text folded away.
        FoldCard("skill", k.name) {
            Muted(k.location, size = 11, lines = 2)
            Spacer(Modifier.height(6.dp))
            SelectionContainer { ChatMarkdown(k.content) }
        }
    }
}

// --- links ---------------------------------------------------------------------------

private val UrlRe = Regex("""https?://[^\s<>()\[\]"']+[^\s<>()\[\]"'.,;:!?]""")

/** Plain text with tappable http(s) links (opened in the browser). */
@Composable
fun linkify(text: String): AnnotatedString {
    val color = MaterialTheme.colorScheme.primary
    return remember(text, color) {
        androidx.compose.ui.text.buildAnnotatedString {
            append(text)
            UrlRe.findAll(text).forEach { mr ->
                addLink(
                    androidx.compose.ui.text.LinkAnnotation.Url(
                        mr.value,
                        androidx.compose.ui.text.TextLinkStyles(androidx.compose.ui.text.SpanStyle(
                            color = color, textDecoration = androidx.compose.ui.text.style.TextDecoration.Underline)),
                    ),
                    mr.range.first, mr.range.last + 1,
                )
            }
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
