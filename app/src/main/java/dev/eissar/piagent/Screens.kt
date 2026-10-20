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
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mikepenz.markdown.m3.Markdown

private const val MAX_TOOL_CHARS = 12000

private val Dark = darkColorScheme(
    primary = Color(0xFF8AB4F8),
    onPrimary = Color(0xFF0B1A33),
    background = Color(0xFF111318),
    surface = Color(0xFF111318),
    surfaceContainer = Color(0xFF1A1D24),
    surfaceContainerHigh = Color(0xFF22262E),
    surfaceVariant = Color(0xFF22262E),
    error = Color(0xFFF28B82),
)

@Composable
fun PiTheme(content: @Composable () -> Unit) = MaterialTheme(colorScheme = Dark, content = content)

private val Mono = FontFamily.Monospace

@Composable
fun App(vm: AppViewModel) {
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Box(Modifier.fillMaxSize()) {
            when (vm.screen) {
                Screen.Connect -> ConnectScreen(vm)
                Screen.Sessions -> SessionsScreen(vm)
                Screen.NewSession -> NewSessionScreen(vm)
                Screen.Chat -> ChatScreen(vm)
            }
            if (vm.modelPicker) ModelPicker(vm)
            vm.dialog?.let { ExtensionDialog(vm, it) }
            vm.toastText?.let { Toast(it, Modifier.align(Alignment.BottomCenter)) }
        }
    }
}

@Composable
private fun Toast(text: String, modifier: Modifier) {
    Surface(
        modifier.navigationBarsPadding().imePadding().padding(bottom = 96.dp, start = 24.dp, end = 24.dp),
        shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh, shadowElevation = 6.dp,
    ) { Text(text, Modifier.padding(horizontal = 16.dp, vertical = 10.dp), fontSize = 14.sp) }
}

@Composable
private fun Dim(text: String, modifier: Modifier = Modifier, size: Int = 13, maxLines: Int = 1) =
    Text(
        text, modifier, fontSize = size.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = maxLines, overflow = TextOverflow.Ellipsis,
    )

@Composable
private fun SectionLabel(text: String) =
    Text(text, fontSize = 12.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(top = 16.dp, bottom = 6.dp))

// --- Connect ------------------------------------------------------------------------

@Composable
private fun ConnectScreen(vm: AppViewModel) {
    val open = vm.conn == ConnState.Open
    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Pi Agent") },
            navigationIcon = {
                if (open) IconButton({ vm.screen = Screen.Sessions }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            },
        )
    }) { pad ->
        Column(Modifier.padding(pad).imePadding().padding(horizontal = 20.dp).fillMaxWidth()) {
            SectionLabel("SERVER ADDRESS")
            OutlinedTextField(
                vm.host, { vm.host = it }, Modifier.fillMaxWidth(), singleLine = true,
                placeholder = { Text("192.168.1.10:7860") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next),
            )
            SectionLabel("TOKEN (OPTIONAL)")
            OutlinedTextField(
                vm.token, { vm.token = it }, Modifier.fillMaxWidth(), singleLine = true,
                placeholder = { Text("PI_WEBUI_TOKEN") }, visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Go),
            )
            Spacer(Modifier.height(20.dp))
            when (vm.conn) {
                ConnState.Open -> {
                    Button({ vm.screen = Screen.Sessions }, Modifier.fillMaxWidth()) { Text("Open sessions") }
                    OutlinedButton(vm::disconnect, Modifier.fillMaxWidth()) { Text("Disconnect") }
                }
                ConnState.Connecting -> Button({}, Modifier.fillMaxWidth(), enabled = false) { Text("Connecting…") }
                ConnState.Closed -> Button(vm::connect, Modifier.fillMaxWidth()) { Text("Connect") }
            }
            vm.connError?.let {
                Text(it, color = MaterialTheme.colorScheme.error, fontSize = 13.sp, modifier = Modifier.padding(top = 12.dp))
            }
            Spacer(Modifier.height(24.dp))
            Dim("Start the server with PI_WEBUI_HOST=0.0.0.0 npm start. ws:// only.", maxLines = 3)
        }
    }
}

// --- Sessions -----------------------------------------------------------------------

@Composable
private fun ConnBanner(vm: AppViewModel) {
    if (vm.conn == ConnState.Open) return
    Text(
        if (vm.conn == ConnState.Connecting) "Connecting…" else "Disconnected (tap to reconnect)",
        Modifier.fillMaxWidth().background(Color(0xFF5C3B00)).clickable { vm.connect() }.padding(8.dp),
        fontSize = 13.sp,
    )
}

@Composable
private fun SessionsScreen(vm: AppViewModel) {
    var menuFor by remember { mutableStateOf<SessionItem?>(null) }
    var renaming by remember { mutableStateOf<SessionItem?>(null) }
    var deleting by remember { mutableStateOf<SessionItem?>(null) }
    val clip = LocalClipboardManager.current
    Scaffold(
        topBar = {
            TopAppBar(title = { Text("Sessions") }, actions = {
                IconButton(vm::refreshSessions) { Icon(Icons.Filled.Refresh, "Refresh") }
                IconButton({ vm.screen = Screen.Connect }) { Icon(Icons.Filled.Settings, "Server") }
            })
        },
        floatingActionButton = {
            FloatingActionButton({ vm.screen = Screen.NewSession }) { Icon(Icons.Filled.Add, "New session") }
        },
    ) { pad ->
        Column(Modifier.padding(pad)) {
            ConnBanner(vm)
            if (vm.sessionsLoading && vm.sessions.isEmpty()) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (vm.sessionsLoaded && vm.sessions.isEmpty()) {
                Dim("No sessions yet. Tap + to start one.", Modifier.padding(24.dp))
            }
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 88.dp)) {
                items(vm.sessions, key = { it.id }) { s ->
                    Box {
                        SessionRow(s, vm.runningIds[s.id] == true, { vm.openSession(s) }, { menuFor = s })
                        DropdownMenu(menuFor == s, { menuFor = null }) {
                            DropdownMenuItem({ Text("Rename") }, { menuFor = null; renaming = s })
                            DropdownMenuItem({ Text("Copy path") }, {
                                menuFor = null; clip.setText(AnnotatedString(s.cwd)); vm.toast("Copied path: ${s.cwd}")
                            })
                            DropdownMenuItem({ Text("Delete") }, { menuFor = null; deleting = s })
                        }
                    }
                }
            }
        }
    }
    renaming?.let { s ->
        var name by remember(s.id) { mutableStateOf(s.title) }
        AlertDialog(
            onDismissRequest = { renaming = null },
            title = { Text("Rename session") },
            text = { OutlinedTextField(name, { name = it }, singleLine = true) },
            confirmButton = { TextButton({ vm.renameSession(s.id, name.trim()); renaming = null }) { Text("Rename") } },
            dismissButton = { TextButton({ renaming = null }) { Text("Cancel") } },
        )
    }
    deleting?.let { s ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Delete session?") },
            text = { Text(s.title) },
            confirmButton = { TextButton({ vm.deleteSession(s.id); deleting = null }) { Text("Delete") } },
            dismissButton = { TextButton({ deleting = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun SessionRow(s: SessionItem, running: Boolean, onClick: () -> Unit, onLong: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().combinedClickable(onClick = onClick, onLongClick = onLong)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(s.title, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Dim(listOf(pathBase(s.cwd), relativeTime(s.modTime), "${s.count} msgs").filter { it.isNotEmpty() }.joinToString(" · "))
        }
        if (running) Box(Modifier.padding(start = 8.dp).size(8.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primary))
    }
}

// --- New session --------------------------------------------------------------------

@Composable
private fun NewSessionScreen(vm: AppViewModel) {
    Scaffold(topBar = {
        TopAppBar(
            title = { Text("New session") },
            navigationIcon = { IconButton({ vm.back() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
        )
    }) { pad ->
        Column(Modifier.padding(pad).imePadding().padding(horizontal = 20.dp)) {
            SectionLabel("WORKING DIRECTORY (ON THE SERVER)")
            OutlinedTextField(
                vm.cwdField, { vm.cwdField = it }, Modifier.fillMaxWidth(), singleLine = true,
                placeholder = { Text(vm.defaultCwd.ifEmpty { "/home/me/project" }) },
                textStyle = LocalTextStyle.current.copy(fontFamily = Mono),
            )
            Spacer(Modifier.height(12.dp))
            Button(
                { vm.startNewSession(vm.cwdField.ifBlank { vm.defaultCwd }) }, Modifier.fillMaxWidth(),
            ) { Text("Start session") }
            if (vm.recentCwds.isNotEmpty()) SectionLabel("RECENT DIRECTORIES")
            LazyColumn {
                items(vm.recentCwds) { cwd ->
                    Column(Modifier.fillMaxWidth().clickable { vm.cwdField = cwd }.padding(vertical = 10.dp)) {
                        Text(pathBase(cwd), fontSize = 15.sp)
                        Dim(cwd, size = 12)
                    }
                }
            }
        }
    }
}

// --- Chat ---------------------------------------------------------------------------

@Composable
private fun ChatScreen(vm: AppViewModel) {
    val list = rememberLazyListState()
    val atBottom by remember { derivedStateOf { !list.canScrollForward } }
    var stick by remember { mutableStateOf(true) }
    LaunchedEffect(list.isScrollInProgress) { if (list.isScrollInProgress) stick = false }
    LaunchedEffect(atBottom) { if (atBottom) stick = true }
    val last = vm.messages.lastOrNull()
    LaunchedEffect(vm.scrollToBottom) { stick = true }
    LaunchedEffect(vm.messages.size, last, vm.phase, stick) {
        if (stick && vm.messages.isNotEmpty()) list.scrollToItem(vm.messages.size) // trailing spacer item
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column(Modifier.clickable { vm.modelPicker = true }) {
                        Text(vm.chatTitle.ifEmpty { "Session" }, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Dim("${vm.modelLabel} ▾ · ${pathBase(vm.chatCwd)}", size = 12)
                    }
                },
                navigationIcon = { IconButton({ vm.back() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
                actions = { IconButton(vm::reloadChat) { Icon(Icons.Filled.Refresh, "Reload") } },
            )
        },
        bottomBar = { Composer(vm) },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            ConnBanner(vm)
            if (vm.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
            Box(Modifier.weight(1f)) {
                if (!vm.loading && vm.messages.isEmpty()) Dim("No messages yet.", Modifier.padding(24.dp))
                LazyColumn(Modifier.fillMaxSize(), list, contentPadding = PaddingValues(12.dp)) {
                    items(vm.messages, key = { it.uid }) { m -> MessageView(vm, m) }
                    item { Spacer(Modifier.height(4.dp)) }
                }
                if (!stick && vm.messages.isNotEmpty()) {
                    SmallFloatingActionButton(
                        { stick = true }, Modifier.align(Alignment.BottomEnd).padding(12.dp),
                    ) { Icon(Icons.Filled.KeyboardArrowDown, "Jump to bottom") }
                }
            }
            if (vm.running && vm.phase.isNotEmpty()) {
                Row(Modifier.padding(horizontal = 16.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(8.dp))
                    Dim(vm.phase)
                }
            }
        }
    }
}

@Composable
private fun Composer(vm: AppViewModel) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainer) {
        Row(
            Modifier.navigationBarsPadding().imePadding().padding(8.dp).fillMaxWidth(),
            verticalAlignment = Alignment.Bottom,
        ) {
            OutlinedTextField(
                vm.composer, { vm.composer = it }, Modifier.weight(1f).heightIn(max = 200.dp),
                placeholder = { Text(if (vm.running) "Queue a follow-up…" else "Message Pi…") },
                maxLines = 8,
            )
            Spacer(Modifier.width(6.dp))
            if (vm.running && vm.composer.isBlank()) {
                FilledIconButton(vm::abort, colors = IconButtonDefaults.filledIconButtonColors(containerColor = MaterialTheme.colorScheme.error)) {
                    Icon(Icons.Filled.Close, "Stop")
                }
            } else {
                FilledIconButton(vm::send, enabled = vm.composer.isNotBlank()) {
                    Icon(Icons.AutoMirrored.Filled.Send, "Send")
                }
            }
        }
    }
}

@Composable
private fun MessageView(vm: AppViewModel, m: Message) {
    if (m.role == Role.ToolResult && vm.calls.containsKey(m.toolCallId)) return // shown inside its call
    val clip = LocalClipboardManager.current
    val copy = { clip.setText(AnnotatedString(m.plainText())); vm.toast("Copied message") }
    when (m.role) {
        Role.User -> Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), horizontalArrangement = Arrangement.End) {
            Surface(
                Modifier.widthIn(max = 320.dp).combinedClickable(onClick = {}, onLongClick = copy),
                shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh,
            ) {
                Text(m.plainText(), Modifier.padding(horizontal = 14.dp, vertical = 10.dp), fontSize = 15.sp)
            }
        }
        Role.ToolResult -> ToolView(vm, m.toolName.ifEmpty { "tool result" }, "", m.toolCallId, "", m)
        else -> Column(Modifier.fillMaxWidth().padding(vertical = 6.dp).combinedClickable(onClick = {}, onLongClick = copy)) {
            if (m.label.isNotEmpty()) Dim(m.label.uppercase(), size = 11)
            m.blocks.forEachIndexed { i, b ->
                when (b.kind) {
                    BlockKind.Text -> if (m.role == Role.Assistant) MarkdownText(b.text)
                        else Text(b.text, fontFamily = Mono, fontSize = 13.sp)
                    BlockKind.Thinking -> ThinkingView("think:${m.uid}:$i", b.text)
                    BlockKind.ToolCall -> ToolView(vm, b.name, b.summary, b.callId, b.text, null)
                    BlockKind.Image -> Dim(b.text)
                    BlockKind.Error -> Text(b.text, color = MaterialTheme.colorScheme.error, fontSize = 14.sp)
                }
            }
        }
    }
}

@Composable
private fun MarkdownText(text: String) {
    SelectionContainer { Markdown(text, modifier = Modifier.fillMaxWidth()) }
}

@Composable
private fun ThinkingView(key: String, text: String) {
    var open by rememberSaveable(key) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Row(Modifier.clickable { open = !open }.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(if (open) Icons.Filled.KeyboardArrowDown else Icons.Filled.KeyboardArrowRight, null, Modifier.size(18.dp))
            Dim("Thinking")
        }
        if (open) Dim(text, Modifier.padding(start = 18.dp), size = 13, maxLines = Int.MAX_VALUE)
    }
}

@Composable
private fun ToolView(vm: AppViewModel, name: String, summary: String, callId: String, args: String, orphan: Message?) {
    var open by rememberSaveable("tool:$callId") { mutableStateOf(false) }
    val result = orphan ?: vm.results[callId]
    val runningTool = vm.runningTools[callId] == true
    val statusColor = when {
        runningTool -> MaterialTheme.colorScheme.primary
        result?.isError == true -> MaterialTheme.colorScheme.error
        result != null -> Color(0xFF81C995)
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Surface(
        Modifier.fillMaxWidth().padding(vertical = 4.dp),
        shape = RoundedCornerShape(10.dp), color = MaterialTheme.colorScheme.surfaceContainer,
    ) {
        Column {
            Row(
                Modifier.fillMaxWidth().clickable { open = !open }.padding(horizontal = 10.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (runningTool) CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp)
                else Box(Modifier.size(8.dp).clip(CircleShape).background(statusColor))
                Spacer(Modifier.width(8.dp))
                Text(name, fontFamily = Mono, fontSize = 13.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.width(8.dp))
                Dim(summary, Modifier.weight(1f), size = 12)
            }
            if (open) {
                if (args.isNotEmpty()) CodeSection("INPUT", args)
                result?.let {
                    CodeSection(if (it.isError) "ERROR" else "OUTPUT", it.plainText(), if (it.isError) MaterialTheme.colorScheme.error else null)
                }
            }
        }
    }
}

@Composable
private fun CodeSection(label: String, text: String, color: Color? = null) {
    Column(Modifier.padding(start = 10.dp, end = 10.dp, bottom = 8.dp)) {
        Dim(label, size = 11)
        val shown = if (text.length > MAX_TOOL_CHARS) text.take(MAX_TOOL_CHARS) + "\n… (${text.length - MAX_TOOL_CHARS} more chars)" else text
        SelectionContainer {
            Text(
                shown, Modifier.horizontalScroll(rememberScrollState()).padding(top = 4.dp),
                fontFamily = Mono, fontSize = 12.sp, color = color ?: MaterialTheme.colorScheme.onSurface, softWrap = false,
            )
        }
    }
}

// --- Model picker & extension dialogs -------------------------------------------------

@Composable
private fun ModelPicker(vm: AppViewModel) {
    var filter by remember { mutableStateOf("") }
    ModalBottomSheet({ vm.modelPicker = false }) {
        Column(Modifier.padding(horizontal = 16.dp)) {
            Text("Choose model", fontSize = 18.sp, fontWeight = FontWeight.Bold)
            OutlinedTextField(filter, { filter = it }, Modifier.fillMaxWidth().padding(vertical = 8.dp),
                singleLine = true, placeholder = { Text("Filter models") })
            val f = filter.trim().lowercase()
            val shown = vm.models.filter {
                f.isEmpty() || it.id.lowercase().contains(f) || it.name.lowercase().contains(f) || it.provider.lowercase().contains(f)
            }
            LazyColumn(Modifier.heightIn(max = 480.dp)) {
                items(shown, key = { it.provider + "/" + it.id }) { m ->
                    val sel = m.id == vm.modelId && m.provider == vm.provider
                    Column(
                        Modifier.fillMaxWidth().clickable { vm.chooseModel(m) }
                            .background(if (sel) MaterialTheme.colorScheme.surfaceContainerHigh else Color.Transparent)
                            .padding(vertical = 10.dp, horizontal = 8.dp),
                    ) {
                        Text(m.name.ifEmpty { m.id }, fontSize = 15.sp)
                        Dim("${m.provider} · ${m.id}", size = 12)
                    }
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun ExtensionDialog(vm: AppViewModel, d: Dialog) {
    var value by remember(d.id) { mutableStateOf(d.prefill) }
    AlertDialog(
        onDismissRequest = { vm.respondDialog(cancelled = true) },
        title = { if (d.title.isNotEmpty()) Text(d.title) },
        text = {
            Column {
                if (d.message.isNotEmpty()) Text(d.message, Modifier.padding(bottom = 8.dp))
                when (d.method) {
                    "select" -> LazyColumn(Modifier.heightIn(max = 360.dp)) {
                        items(d.options) { o ->
                            Text(o, Modifier.fillMaxWidth().clickable { vm.respondDialog(value = o) }.padding(vertical = 12.dp))
                        }
                    }
                    "input" -> OutlinedTextField(value, { value = it }, Modifier.fillMaxWidth(), singleLine = true)
                    "editor" -> OutlinedTextField(
                        value, { value = it }, Modifier.fillMaxWidth().heightIn(min = 160.dp, max = 360.dp),
                        textStyle = LocalTextStyle.current.copy(fontFamily = Mono, fontSize = 13.sp),
                    )
                }
            }
        },
        confirmButton = {
            when (d.method) {
                "confirm" -> TextButton({ vm.respondDialog(confirmed = true) }) { Text("Confirm") }
                "input", "editor" -> TextButton({ vm.respondDialog(value = value) }) { Text("OK") }
            }
        },
        dismissButton = {
            if (d.method == "confirm") TextButton({ vm.respondDialog(confirmed = false) }) { Text("No") }
            else TextButton({ vm.respondDialog(cancelled = true) }) { Text("Cancel") }
        },
    )
}
