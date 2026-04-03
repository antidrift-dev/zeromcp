package io.zeromcp;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class SchemaTest {

    @Test
    void emptyInputProducesEmptySchema() {
        var schema = Schema.toJsonSchema(List.of());
        assertEquals("object", schema.get("type").getAsString());
        assertTrue(schema.getAsJsonObject("properties").isEmpty());
        assertEquals(0, schema.getAsJsonArray("required").size());
    }

    @Test
    void simpleFieldsAreRequiredByDefault() {
        var schema = Schema.toJsonSchema(List.of(
            Input.required("name", "string"),
            Input.required("age", "number")
        ));
        var required = schema.getAsJsonArray("required");
        assertEquals(2, required.size());
        assertTrue(required.contains(new com.google.gson.JsonPrimitive("name")));
        assertTrue(required.contains(new com.google.gson.JsonPrimitive("age")));
    }

    @Test
    void optionalFieldsAreNotRequired() {
        var schema = Schema.toJsonSchema(List.of(
            Input.required("name", "string"),
            Input.optional("nickname", "string")
        ));
        var required = schema.getAsJsonArray("required");
        assertEquals(1, required.size());
        assertTrue(required.contains(new com.google.gson.JsonPrimitive("name")));
    }

    @Test
    void descriptionsAreIncluded() {
        var schema = Schema.toJsonSchema(List.of(
            Input.required("name", "string", "The user's name")
        ));
        var desc = schema.getAsJsonObject("properties")
            .getAsJsonObject("name")
            .get("description").getAsString();
        assertEquals("The user's name", desc);
    }

    @Test
    void validateCatchesMissingRequiredFields() {
        var schema = Schema.toJsonSchema(List.of(Input.required("name", "string")));
        var errors = Schema.validate(Map.of(), schema);
        assertEquals(1, errors.size());
        assertTrue(errors.get(0).contains("Missing required field: name"));
    }

    @Test
    void validateCatchesTypeMismatches() {
        var schema = Schema.toJsonSchema(List.of(Input.required("count", "number")));
        var errors = Schema.validate(Map.of("count", "not-a-number"), schema);
        assertEquals(1, errors.size());
        assertTrue(errors.get(0).contains("expected number"));
    }

    @Test
    void validatePassesForCorrectInput() {
        var schema = Schema.toJsonSchema(List.of(
            Input.required("name", "string"),
            Input.required("age", "number")
        ));
        var errors = Schema.validate(Map.of("name", "Alice", "age", 30), schema);
        assertTrue(errors.isEmpty());
    }
}
