package io.antidrift.zeromcp;

import com.google.gson.Gson;
import com.google.gson.annotations.SerializedName;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Base64;
import java.util.List;
import java.util.Map;

/**
 * Configuration loaded from zeromcp.config.json.
 */
public class Config {

    private String transport = "stdio";
    private boolean logging = false;

    @SerializedName("bypass_permissions")
    private boolean bypassPermissions = false;

    private String separator = "_";
    private String name = "zeromcp";
    private String version = "0.1.0";
    private String title = "ZeroMCP";

    @SerializedName("execute_timeout")
    private long executeTimeout = 30000; // ms

    @SerializedName("cache_credentials")
    private boolean cacheCredentials = true;

    private List<RemoteServer> remote;

    @SerializedName("page_size")
    private int pageSize = 0;

    private String icon;

    private static final Gson GSON = new Gson();

    public String transport() { return transport; }
    public boolean logging() { return logging; }
    public boolean bypassPermissions() { return bypassPermissions; }
    public String separator() { return separator; }
    public String name() { return name; }
    public String version() { return version; }
    public String title() { return title != null ? title : "ZeroMCP"; }
    public long executeTimeout() { return executeTimeout; }
    public boolean cacheCredentials() { return cacheCredentials; }
    public List<RemoteServer> remote() { return remote != null ? remote : List.of(); }
    public int pageSize() { return pageSize; }
    public String icon() { return icon; }

    /**
     * Loads config from zeromcp.config.json in the given directory.
     * Returns defaults if the file does not exist.
     */
    public static Config load(String dir) {
        var path = Path.of(dir, "zeromcp.config.json");
        if (!Files.exists(path)) return new Config();

        try {
            var content = Files.readString(path);
            var config = GSON.fromJson(content, Config.class);
            return config != null ? config : new Config();
        } catch (IOException e) {
            System.err.println("[zeromcp] Warning: failed to parse config: " + e.getMessage());
            return new Config();
        }
    }

    /**
     * Loads config from the current directory.
     */
    public static Config load() {
        return load(".");
    }

    /**
     * Resolves an auth string -- if it starts with "env:", reads from environment.
     */
    public static String resolveAuth(String auth) {
        if (auth == null) return null;
        if (auth.startsWith("env:")) {
            var envVar = auth.substring(4);
            var value = System.getenv(envVar);
            if (value == null) {
                System.err.println("[zeromcp] Warning: environment variable " + envVar + " not set");
            }
            return value;
        }
        return auth;
    }

    private static final Map<String, String> ICON_MIME = Map.of(
        ".png", "image/png",
        ".jpg", "image/jpeg",
        ".jpeg", "image/jpeg",
        ".gif", "image/gif",
        ".svg", "image/svg+xml",
        ".ico", "image/x-icon",
        ".webp", "image/webp"
    );

    /**
     * Resolves an icon config value to a data URI. Accepts a data URI (passthrough),
     * an http(s) URL (fetched), or a file path (read; leading ~ is $HOME).
     * Returns null, with a warning on stderr, when the icon cannot be loaded.
     */
    static String resolveIcon(String icon) {
        if (icon == null || icon.isEmpty()) return null;

        if (icon.startsWith("data:")) return icon;

        if (icon.startsWith("http://") || icon.startsWith("https://")) {
            try {
                var client = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NORMAL).build();
                var res = client.send(HttpRequest.newBuilder(URI.create(icon)).GET().build(),
                    HttpResponse.BodyHandlers.ofByteArray());
                if (res.statusCode() < 200 || res.statusCode() > 299) {
                    System.err.println("[zeromcp] Warning: failed to fetch icon " + icon + ": " + res.statusCode());
                    return null;
                }
                var contentType = res.headers().firstValue("content-type").filter(v -> !v.isEmpty()).orElse("image/png");
                return "data:" + contentType + ";base64," + Base64.getEncoder().encodeToString(res.body());
            } catch (Exception e) {
                System.err.println("[zeromcp] Warning: failed to fetch icon " + icon + ": " + e.getMessage());
                return null;
            }
        }

        try {
            var home = System.getenv("HOME");
            var path = icon.startsWith("~") ? (home != null ? home : "") + icon.substring(1) : icon;
            var bytes = Files.readAllBytes(Path.of(path));
            var fileName = Path.of(path).getFileName();
            var name = fileName != null ? fileName.toString() : "";
            var dot = name.lastIndexOf('.');
            var ext = dot > 0 ? name.substring(dot).toLowerCase() : "";
            var mime = ICON_MIME.getOrDefault(ext, "image/png");
            return "data:" + mime + ";base64," + Base64.getEncoder().encodeToString(bytes);
        } catch (Exception e) {
            System.err.println("[zeromcp] Warning: failed to read icon file " + icon + ": " + e.getMessage());
            return null;
        }
    }
}
