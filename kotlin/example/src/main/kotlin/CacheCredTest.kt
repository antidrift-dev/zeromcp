import io.antidrift.zeromcp.*
import java.io.File

private fun readStringField(text: String, field: String): String? {
    val pattern = Regex("\"$field\"\\s*:\\s*\"([^\"]+)\"")
    return pattern.find(text)?.groupValues?.get(1)
}

private fun readBoolField(text: String, field: String): Boolean? {
    val pattern = Regex("\"$field\"\\s*:\\s*(true|false)")
    return pattern.find(text)?.groupValues?.get(1)?.toBooleanStrictOrNull()
}

private fun readTokenFromFile(path: String): String? {
    return try { readStringField(File(path).readText(), "token") } catch (e: Exception) { null }
}

fun cacheCredTestMain() {
    val configPath = System.getenv("ZEROMCP_CONFIG") ?: "zeromcp.config.json"

    var credFile = ""
    var cacheCredentials = true
    try {
        val text = File(configPath).readText()
        // Extract credentials.tokenstore.file — search for "file" after "tokenstore" key.
        val tokenstoreIdx = text.indexOf("\"tokenstore\"")
        if (tokenstoreIdx >= 0) {
            val after = text.substring(tokenstoreIdx)
            credFile = readStringField(after, "file") ?: ""
        }
        cacheCredentials = readBoolField(text, "cache_credentials") ?: true
    } catch (ignored: Exception) {}

    var cachedToken: String? = null
    var tokenCached = false
    val doCache = cacheCredentials
    val finalCredFile = credFile

    val server = ZeroMcp()

    server.tool("tokenstore_check") {
        description = "Return the current token from credentials"
        execute { _, _ ->
            val token = if (doCache) {
                if (!tokenCached) { cachedToken = readTokenFromFile(finalCredFile); tokenCached = true }
                cachedToken
            } else {
                readTokenFromFile(finalCredFile)
            }
            mapOf("token" to token)
        }
    }

    server.serve()
}
