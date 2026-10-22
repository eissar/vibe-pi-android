package dev.eissar.piagent

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge

/**
 * Hosts a chat in a floating bubble window. Shares [AppGraph]'s single [AppState]
 * with [MainActivity], so the bubble and the full app see the same messages and
 * one RPC connection.
 *
 * Back (or the system's collapse affordance) finishes the activity, which returns
 * the chat to its bubble.
 */
class BubbleActivity : ComponentActivity() {
    private val state: AppState get() = AppGraph.get(application)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Notifier.init(this)
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { finish() }
        })
        val sid = intent?.getStringExtra(Notifier.EXTRA_SESSION)
        if (sid != null) state.openById(sid)
        setContent { PiTheme { BubbleRoot(state) } }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.getStringExtra(Notifier.EXTRA_SESSION)?.let { sid ->
            if (state.chat?.sessionId != sid) state.openById(sid)
        }
    }

    override fun onStart() { super.onStart(); state.foreground = true }
    override fun onStop() { super.onStop(); state.foreground = false }
}
