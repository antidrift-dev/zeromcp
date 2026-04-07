import io.antidrift.zeromcp.*

fun main() {
    if (System.getenv("ZEROMCP_SANDBOX_TEST") == "true") {
        sandboxTestMain()
        return
    }
    if (System.getenv("ZEROMCP_CHAOS_TEST") == "true") {
        chaosTestMain()
        return
    }
    if (System.getenv("ZEROMCP_TIMEOUT_TEST") == "true") {
        timeoutTestMain()
        return
    }
    if (System.getenv("ZEROMCP_BYPASS_TEST") == "true") {
        bypassTestMain()
        return
    }
    if (System.getenv("ZEROMCP_CREDENTIAL_TEST") == "true") {
        credentialTestMain()
        return
    }
    if (System.getenv("ZEROMCP_RESOURCE_TEST") == "true") {
        resourceTestMain()
        return
    }

    val server = ZeroMcp()

    server.tool("hello") {
        description = "Say hello to someone"
        input {
            "name" to "string"
        }
        execute { args, _ ->
            "Hello, ${args.getString("name")}!"
        }
    }

    server.tool("add") {
        description = "Add two numbers together"
        input {
            "a" to "number"
            "b" to "number"
        }
        execute { args, _ ->
            val a = args.getNumber("a") ?: 0.0
            val b = args.getNumber("b") ?: 0.0
            mapOf("sum" to a + b)
        }
    }

    server.tool("fetch_url") {
        description = "Fetch a URL (with permission)"
        input {
            required("url", "string", "The URL to fetch")
        }
        permissions {
            network("api.example.com", "*.github.com")
        }
        execute { args, ctx ->
            val url = args.getString("url") ?: return@execute "No URL provided"
            val host = java.net.URI(url).host
            if (!checkNetworkAccess(ctx.toolName, host, ctx.permissions)) {
                return@execute "Network access denied for $host"
            }
            "Would fetch: $url"
        }
    }

    server.serve()
}
