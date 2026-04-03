package io.zeromcp

import kotlinx.serialization.json.*

/**
 * Converts a simplified InputSchema to JSON Schema format.
 */
fun toJsonSchema(input: InputSchema): JsonObject {
    if (input.isEmpty()) {
        return buildJsonObject {
            put("type", "object")
            put("properties", JsonObject(emptyMap()))
            put("required", JsonArray(emptyList()))
        }
    }

    val properties = mutableMapOf<String, JsonElement>()
    val required = mutableListOf<String>()

    for ((key, field) in input) {
        val prop = buildJsonObject {
            put("type", field.type.jsonType)
            field.description?.let { put("description", it) }
        }
        properties[key] = prop
        if (!field.optional) {
            required.add(key)
        }
    }

    return buildJsonObject {
        put("type", "object")
        put("properties", JsonObject(properties))
        put("required", JsonArray(required.map { JsonPrimitive(it) }))
    }
}

/**
 * Validates arguments against a JSON Schema. Returns a list of error messages.
 */
fun validate(args: Map<String, Any?>, schema: JsonObject): List<String> {
    val errors = mutableListOf<String>()
    val properties = schema["properties"]?.jsonObject ?: return errors
    val required = schema["required"]?.jsonArray?.map { it.jsonPrimitive.content } ?: emptyList()

    for (key in required) {
        if (args[key] == null) {
            errors.add("Missing required field: $key")
        }
    }

    for ((key, value) in args) {
        val prop = properties[key]?.jsonObject ?: continue
        val expectedType = prop["type"]?.jsonPrimitive?.content ?: continue
        val actualType = jsonTypeOf(value)
        if (actualType != expectedType) {
            errors.add("Field \"$key\" expected $expectedType, got $actualType")
        }
    }

    return errors
}

private fun jsonTypeOf(value: Any?): String = when (value) {
    null -> "null"
    is String -> "string"
    is JsonPrimitive -> {
        when {
            value.isString -> "string"
            value.booleanOrNull != null -> "boolean"
            value.doubleOrNull != null -> "number"
            else -> "string"
        }
    }
    is Boolean -> "boolean"
    is Number -> "number"
    is List<*>, is JsonArray -> "array"
    is Map<*, *>, is JsonObject -> "object"
    else -> "object"
}
