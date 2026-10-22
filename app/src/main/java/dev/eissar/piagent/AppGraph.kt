package dev.eissar.piagent

import android.app.Application

/**
 * Process-wide [AppState]. Shared by [MainActivity] and [BubbleActivity] so a bubbled
 * chat uses the same RPC connection and shows the same messages as the main window.
 */
object AppGraph {
    @Volatile private var state: AppState? = null

    fun get(app: Application): AppState =
        state ?: synchronized(this) { state ?: AppState(app).also { state = it } }

    fun peek(): AppState? = state
}
