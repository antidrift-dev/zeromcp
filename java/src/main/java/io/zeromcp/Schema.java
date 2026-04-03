package io.zeromcp;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Converts simplified Input definitions to JSON Schema and validates arguments.
 */
public final class Schema {

    private Schema() {}

    /**
     * Converts a list of Input fields to a JSON Schema object.
     */
    public static JsonObject toJsonSchema(List<Input> inputs) {
        var schema = new JsonObject();
        schema.addProperty("type", "object");

        var properties = new JsonObject();
        var required = new JsonArray();

        for (var input : inputs) {
            var prop = new JsonObject();
            prop.addProperty("type", input.type().jsonType());
            if (input.description() != null) {
                prop.addProperty("description", input.description());
            }
            properties.add(input.name(), prop);
            if (!input.optional()) {
                required.add(input.name());
            }
        }

        schema.add("properties", properties);
        schema.add("required", required);
        return schema;
    }

    /**
     * Validates arguments against a JSON Schema. Returns a list of error messages.
     */
    public static List<String> validate(Map<String, Object> args, JsonObject schema) {
        var errors = new ArrayList<String>();
        var properties = schema.getAsJsonObject("properties");
        var required = schema.getAsJsonArray("required");

        if (required != null) {
            for (var elem : required) {
                var key = elem.getAsString();
                if (!args.containsKey(key) || args.get(key) == null) {
                    errors.add("Missing required field: " + key);
                }
            }
        }

        if (properties != null) {
            for (var entry : args.entrySet()) {
                var prop = properties.getAsJsonObject(entry.getKey());
                if (prop == null) continue;

                var expectedType = prop.get("type").getAsString();
                var actualType = jsonTypeOf(entry.getValue());
                if (!actualType.equals(expectedType)) {
                    errors.add("Field \"%s\" expected %s, got %s"
                        .formatted(entry.getKey(), expectedType, actualType));
                }
            }
        }

        return errors;
    }

    private static String jsonTypeOf(Object value) {
        if (value == null) return "null";
        if (value instanceof String) return "string";
        if (value instanceof Boolean) return "boolean";
        if (value instanceof Number) return "number";
        if (value instanceof List<?>) return "array";
        if (value instanceof Map<?,?>) return "object";
        if (value instanceof JsonElement je) {
            if (je.isJsonPrimitive()) {
                var p = je.getAsJsonPrimitive();
                if (p.isString()) return "string";
                if (p.isBoolean()) return "boolean";
                if (p.isNumber()) return "number";
            }
            if (je.isJsonArray()) return "array";
            if (je.isJsonObject()) return "object";
        }
        return "object";
    }
}
