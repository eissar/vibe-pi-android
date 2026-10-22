package dev.eissar.piagent

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts

class MainActivity : ComponentActivity() {
    private val state: AppState get() = AppGraph.get(application)
    private val askNotify = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Notifier.init(this)
        if (Build.VERSION.SDK_INT >= 33 && savedInstanceState == null) askNotify.launch(Manifest.permission.POST_NOTIFICATIONS)
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { if (!state.back()) moveTaskToBack(true) }
        })
        setContent { PiTheme { Root(state) } }
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); handle(intent) }

    private fun handle(i: Intent?) {
        i?.getStringExtra(Notifier.EXTRA_SESSION)?.let { state.openById(it); i.removeExtra(Notifier.EXTRA_SESSION) }
    }

    override fun onStart() { super.onStart(); state.foreground = true }
    override fun onStop() { super.onStop(); state.foreground = false }
    override fun onResume() { super.onResume(); state.resume() }
}
