package dev.eissar.piagent

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull

// Small null-safe readers for the server's loosely-typed JSON.

fun JsonElement?.bool(): Boolean = (this as? JsonPrimitive)?.booleanOrNull ?: false
fun JsonElement?.string(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
fun JsonObject?.str(key: String): String = this?.get(key).string() ?: ""
fun JsonObject?.bool(key: String): Boolean = this?.get(key).bool()
fun JsonObject?.num(key: String): Double = (this?.get(key) as? JsonPrimitive)?.doubleOrNull ?: 0.0
fun JsonObject?.obj(key: String): JsonObject? = this?.get(key) as? JsonObject
fun JsonObject?.list(key: String): List<JsonElement> = (this?.get(key) as? JsonArray) ?: emptyList()
fun JsonObject?.objs(key: String): List<JsonObject> = list(key).filterIsInstance<JsonObject>()
fun JsonObject?.strs(key: String): List<String> = list(key).mapNotNull { it.string() }
