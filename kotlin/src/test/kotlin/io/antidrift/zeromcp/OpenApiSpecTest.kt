package io.antidrift.zeromcp

import kotlinx.serialization.json.*
import java.net.HttpURLConnection
import java.net.URI
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Regression coverage for the non-GET path-param bug in `buildOpenApiSpec` (Server.kt):
 * routes like `PUT /items/:id` used to document `id` only as a request-body property and
 * never as a path parameter. `buildOpenApiSpec` is file-private, so this exercises it the
 * only way available from outside `Server.kt`: over the real `/openapi.json` HTTP route.
 */
class OpenApiSpecTest {

    @Test
    fun `non-GET route with path param documents it as path, not body`() {
        val port = 18471
        val server = ZeroMcp()
        server.tool("updateItem") {
            description = "Update an item"
            input {
                "id" to "string"
                "name" to "string"
            }
            route("PUT", "/items/:id")
            execute { args, _ ->
                mapOf("id" to args.getString("id"), "name" to args.getString("name"))
            }
        }

        val thread = Thread { server.serveHttp(port) }
        thread.isDaemon = true
        thread.start()

        val spec = fetchOpenApiSpec(port)
        assertTrue(spec != null, "server never became reachable on port $port")

        val putOp = spec!!["paths"]!!.jsonObject["/items/{id}"]!!.jsonObject["put"]!!.jsonObject

        val parameters = putOp["parameters"]?.jsonArray
        assertTrue(parameters != null && parameters.isNotEmpty(), "expected a non-empty parameters array")
        val idParam = parameters!!.map { it.jsonObject }.first { it["name"]!!.jsonPrimitive.content == "id" }
        assertEquals("path", idParam["in"]!!.jsonPrimitive.content)
        assertEquals(true, idParam["required"]!!.jsonPrimitive.boolean)

        val bodySchema = putOp["requestBody"]!!.jsonObject["content"]!!.jsonObject["application/json"]!!.jsonObject["schema"]!!.jsonObject
        val bodyProps = bodySchema["properties"]!!.jsonObject
        assertFalse(bodyProps.containsKey("id"), "path param 'id' must not be duplicated into the request body schema")
        assertTrue(bodyProps.containsKey("name"), "non-path field 'name' must still be documented in the request body schema")
    }

    private fun fetchOpenApiSpec(port: Int): JsonObject? {
        repeat(50) {
            try {
                val conn = URI("http://localhost:$port/openapi.json").toURL().openConnection() as HttpURLConnection
                conn.connectTimeout = 200
                conn.readTimeout = 200
                val body = conn.inputStream.bufferedReader().readText()
                return Json.parseToJsonElement(body).jsonObject
            } catch (_: Exception) {
                Thread.sleep(50)
            }
        }
        return null
    }
}
