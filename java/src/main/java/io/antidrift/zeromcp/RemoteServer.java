package io.antidrift.zeromcp;

import java.util.List;

/**
 * A remote MCP server whose tools are federated into this one, namespaced as
 * {@code <name>.<tool>}.
 *
 * @param name  namespace prefix for the server's tools
 * @param url   HTTP/HTTPS JSON-RPC endpoint
 * @param auth  bearer token, or {@code env:VAR} to read it from the environment; null for none
 * @param tools allowlist of upstream tool names to keep; null keeps all
 */
public record RemoteServer(String name, String url, String auth, List<String> tools) {
    public RemoteServer(String name, String url) {
        this(name, url, null, null);
    }
}
