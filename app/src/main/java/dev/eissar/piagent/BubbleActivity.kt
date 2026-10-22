package dev.eissar.piagent

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent

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
        // A bubble window is resized by the IME (SOFT_INPUT_ADJUST_RESIZE), so the content is
        // already lifted; padding by ime() on top of that would push the composer up twice.
        androidx.core.view.WindowCompat.setDecorFitsSystemWindows(window, false)
        window.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        Notifier.init(this)
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { finish() }
        })
        val sid = intent?.getStringExtra(Notifier.EXTRA_SESSION)
        if (sid != null) state.openById(sid)
        setContent {
            androidx.compose.runtime.CompositionLocalProvider(LocalInBubble provides true) {
                PiTheme { BubbleRoot(state) }
            }
        }
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
