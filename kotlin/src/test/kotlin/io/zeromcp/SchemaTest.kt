package io.zeromcp

import kotlinx.serialization.json.*
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SchemaTest {

    @Test
    fun `empty input produces empty schema`() {
        val schema = toJsonSchema(emptyMap())
        assertEquals("object", schema["type"]?.jsonPrimitive?.content)
        assertTrue(schema["properties"]?.jsonObject?.isEmpty() == true)
        assertTrue(schema["required"]?.jsonArray?.isEmpty() == true)
    }

    @Test
    fun `simple fields are required by default`() {
        val input: InputSchema = mapOf(
            "name" to InputField(SimpleType.STRING),
            "age" to InputField(SimpleType.NUMBER)
        )
        val schema = toJsonSchema(input)
        val required = schema["required"]?.jsonArray?.map { it.jsonPrimitive.content } ?: emptyList()
        assertTrue("name" in required)
        assertTrue("age" in required)
    }

    @Test
    fun `optional fields are not required`() {
        val input: InputSchema = mapOf(
            "name" to InputField(SimpleType.STRING),
            "nickname" to InputField(SimpleType.STRING, optional = true)
        )
        val schema = toJsonSchema(input)
        val required = schema["required"]?.jsonArray?.map { it.jsonPrimitive.content } ?: emptyList()
        assertTrue("name" in required)
        assertTrue("nickname" !in required)
    }

    @Test
    fun `descriptions are included`() {
        val input: InputSchema = mapOf(
            "name" to InputField(SimpleType.STRING, description = "The user's name")
        )
        val schema = toJsonSchema(input)
        val desc = schema["properties"]?.jsonObject?.get("name")?.jsonObject?.get("description")
        assertEquals("The user's name", desc?.jsonPrimitive?.content)
    }

    @Test
    fun `validate catches missing required fields`() {
        val input: InputSchema = mapOf(
            "name" to InputField(SimpleType.STRING)
        )
        val schema = toJsonSchema(input)
        val errors = validate(emptyMap(), schema)
        assertEquals(1, errors.size)
        assertTrue(errors[0].contains("Missing required field: name"))
    }

    @Test
    fun `validate catches type mismatches`() {
        val input: InputSchema = mapOf(
            "count" to InputField(SimpleType.NUMBER)
        )
        val schema = toJsonSchema(input)
        val errors = validate(mapOf("count" to "not-a-number"), schema)
        assertEquals(1, errors.size)
        assertTrue(errors[0].contains("expected number"))
    }

    @Test
    fun `validate passes for correct input`() {
        val input: InputSchema = mapOf(
            "name" to InputField(SimpleType.STRING),
            "age" to InputField(SimpleType.NUMBER)
        )
        val schema = toJsonSchema(input)
        val errors = validate(mapOf("name" to "Alice", "age" to 30), schema)
        assertTrue(errors.isEmpty())
    }
}
