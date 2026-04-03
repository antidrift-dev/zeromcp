package io.zeromcp;

import com.google.gson.Gson;
import com.google.gson.annotations.SerializedName;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Configuration loaded from zeromcp.config.json.
 */
public class Config {

    private String transport = "stdio";
    private int port = 4242;
    private boolean logging = false;

    @SerializedName("bypass_permissions")
    private boolean bypassPermissions = false;

    private String separator = "_";
    private String name = "zeromcp";
    private String version = "0.1.0";

    private static final Gson GSON = new Gson();

    public String transport() { return transport; }
    public int port() { return port; }
    public boolean logging() { return logging; }
    public boolean bypassPermissions() { return bypassPermissions; }
    public String separator() { return separator; }
    public String name() { return name; }
    public String version() { return version; }

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
}
