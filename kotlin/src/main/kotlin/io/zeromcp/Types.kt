package io.zeromcp

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive

/**
 * Simple type names for input schema fields.
 */
enum class SimpleType(val jsonType: String) {
    STRING("string"),
    NUMBER("number"),
    BOOLEAN("boolean"),
    OBJECT("object"),
    ARRAY("array");

    companion object {
        fun fromString(s: String): SimpleType =
            entries.firstOrNull { it.jsonType == s }
                ?: throw IllegalArgumentException("Unknown type: $s")
    }
}

/**
 * A single input field definition.
 */
data class InputField(
    val type: SimpleType,
    val description: String? = null,
    val optional: Boolean = false
)

/**
 * Input schema — maps field names to their definitions.
 */
typealias InputSchema = Map<String, InputField>

/**
 * Permission declarations for a tool.
 */
data class Permissions(
    val network: NetworkPermission = NetworkPermission.Unset,
    val fs: FsPermission = FsPermission.None,
    val exec: Boolean = false
)

sealed class NetworkPermission {
    data object Unset : NetworkPermission()
    data object All : NetworkPermission()
    data object Denied : NetworkPermission()
    data class AllowList(val hosts: List<String>) : NetworkPermission()
}

enum class FsPermission {
    None, Read, Write, Full
}

/**
 * Context passed to tool execution.
 */
data class Ctx(
    val toolName: String,
    val permissions: Permissions = Permissions()
)

/**
 * Registered tool definition.
 */
data class ToolDefinition(
    val name: String,
    val description: String,
    val input: InputSchema,
    val permissions: Permissions,
    val execute: suspend (args: Map<String, Any?>, ctx: Ctx) -> Any?
)

/**
 * DSL builder for defining a tool.
 */
class ToolBuilder(private val name: String) {
    var description: String = ""
    private val inputFields = mutableMapOf<String, InputField>()
    private var perms = Permissions()
    private var executeFn: (suspend (Map<String, Any?>, Ctx) -> Any?)? = null

    fun input(block: InputBuilder.() -> Unit) {
        val builder = InputBuilder()
        builder.block()
        inputFields.putAll(builder.fields)
    }

    fun permissions(block: PermissionsBuilder.() -> Unit) {
        val builder = PermissionsBuilder()
        builder.block()
        perms = builder.build()
    }

    fun execute(fn: suspend (args: Map<String, Any?>, ctx: Ctx) -> Any?) {
        executeFn = fn
    }

    internal fun build(): ToolDefinition {
        return ToolDefinition(
            name = name,
            description = description,
            input = inputFields.toMap(),
            permissions = perms,
            execute = executeFn ?: throw IllegalStateException("Tool '$name' has no execute block")
        )
    }
}

class InputBuilder {
    internal val fields = mutableMapOf<String, InputField>()

    infix fun String.to(type: String) {
        fields[this] = InputField(SimpleType.fromString(type))
    }

    fun required(name: String, type: String, description: String? = null) {
        fields[name] = InputField(SimpleType.fromString(type), description, optional = false)
    }

    fun optional(name: String, type: String, description: String? = null) {
        fields[name] = InputField(SimpleType.fromString(type), description, optional = true)
    }
}

class PermissionsBuilder {
    private var net: NetworkPermission = NetworkPermission.Unset
    private var fsVal: FsPermission = FsPermission.None
    private var execVal: Boolean = false

    fun network(vararg hosts: String) {
        net = if (hosts.isEmpty()) NetworkPermission.All
        else NetworkPermission.AllowList(hosts.toList())
    }

    fun networkDeny() {
        net = NetworkPermission.Denied
    }

    fun fs(mode: String) {
        fsVal = when (mode) {
            "read" -> FsPermission.Read
            "write" -> FsPermission.Write
            else -> FsPermission.Full
        }
    }

    fun exec() {
        execVal = true
    }

    internal fun build(): Permissions = Permissions(net, fsVal, execVal)
}

/**
 * Helper to extract typed values from a JsonElement-based args map.
 */
fun Map<String, Any?>.getString(key: String): String? {
    val v = this[key] ?: return null
    return when (v) {
        is String -> v
        is JsonPrimitive -> v.content
        else -> v.toString()
    }
}

fun Map<String, Any?>.getNumber(key: String): Double? {
    val v = this[key] ?: return null
    return when (v) {
        is Number -> v.toDouble()
        is JsonPrimitive -> v.doubleOrNull
        else -> v.toString().toDoubleOrNull()
    }
}

fun Map<String, Any?>.getBoolean(key: String): Boolean? {
    val v = this[key] ?: return null
    return when (v) {
        is Boolean -> v
        is JsonPrimitive -> v.booleanOrNull
        else -> v.toString().toBooleanStrictOrNull()
    }
}
