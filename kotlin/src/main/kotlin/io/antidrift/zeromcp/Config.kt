package io.antidrift.zeromcp

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

@Serializable
data class ZeroMcpConfig(
    val transport: String = "stdio",
    val port: Int = 4242,
    val logging: Boolean = false,
    val bypass_permissions: Boolean = false,
    val separator: String = "_",
    val name: String = "zeromcp",
    val version: String = "0.1.0",
    val execute_timeout: Long = 30000, // ms
    val cache_credentials: Boolean = true
)

private val json = Json { ignoreUnknownKeys = true }

/**
 * Loads configuration from zeromcp.config.json in the given directory.
 * Returns defaults if the file does not exist.
 */
fun loadConfig(dir: String = "."): ZeroMcpConfig {
    val file = File(dir, "zeromcp.config.json")
    if (!file.exists()) return ZeroMcpConfig()

    return try {
        json.decodeFromString(ZeroMcpConfig.serializer(), file.readText())
    } catch (e: Exception) {
        System.err.println("[zeromcp] Warning: failed to parse config: ${e.message}")
        ZeroMcpConfig()
    }
}

/**
 * Resolves an auth string — if it starts with "env:", reads from environment.
 */
fun resolveAuth(auth: String?): String? {
    if (auth == null) return null
    if (auth.startsWith("env:")) {
        val envVar = auth.substring(4)
        val value = System.getenv(envVar)
        if (value == null) {
            System.err.println("[zeromcp] Warning: environment variable $envVar not set")
        }
        return value
    }
    return auth
}
