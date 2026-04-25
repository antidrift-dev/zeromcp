import io.antidrift.zeromcp.*;

import com.google.gson.*;
import java.nio.file.*;
import java.util.*;

public class CacheCredTest {

    private static String readTokenFromFile(String path) {
        try {
            var text = Files.readString(Path.of(path));
            var obj = new Gson().fromJson(text, JsonObject.class);
            var el = obj.get("token");
            return el != null && !el.isJsonNull() ? el.getAsString() : null;
        } catch (Exception e) {
            return null;
        }
    }

    public static void main(String[] args) {
        var configPath = System.getenv("ZEROMCP_CONFIG");
        if (configPath == null) configPath = "zeromcp.config.json";

        // Parse config to get credentials.tokenstore.file and cache_credentials.
        String credFile = "";
        boolean cacheCredentials = true;
        try {
            var text = Files.readString(Path.of(configPath));
            var cfg = new Gson().fromJson(text, JsonObject.class);
            if (cfg != null) {
                var creds = cfg.getAsJsonObject("credentials");
                if (creds != null) {
                    var tokenstore = creds.getAsJsonObject("tokenstore");
                    if (tokenstore != null && tokenstore.has("file")) {
                        credFile = tokenstore.get("file").getAsString();
                    }
                }
                if (cfg.has("cache_credentials")) {
                    cacheCredentials = cfg.get("cache_credentials").getAsBoolean();
                }
            }
        } catch (Exception ignored) {}

        final String finalCredFile = credFile;
        // When caching is enabled, read once at startup.
        final String[] cachedToken = { null };
        final boolean[] cached = { false };
        final boolean doCache = cacheCredentials;

        var server = new ZeroMcp();

        server.tool("tokenstore_check", Tool.builder()
            .description("Return the current token from credentials")
            .execute((a, ctx) -> {
                String token;
                if (doCache) {
                    if (!cached[0]) {
                        cachedToken[0] = readTokenFromFile(finalCredFile);
                        cached[0] = true;
                    }
                    token = cachedToken[0];
                } else {
                    token = readTokenFromFile(finalCredFile);
                }
                var result = new HashMap<String, Object>();
                result.put("token", token);
                return result;
            })
            .build());

        server.serve();
    }
}
