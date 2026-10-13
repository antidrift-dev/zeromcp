# Composability

Connect multiple MCP servers into one process. Auto-namespaced. Layer your own local tools on top. The official SDK can't do this.

## The problem

MCP servers today are isolated. Each one is its own process, its own dependencies, its own config. If you run GitHub MCP, Jira MCP, and Stripe MCP, that's three separate processes your client manages individually.

## The solution

ZeroMCP treats MCP servers as building blocks. Connect them into one process:

```json
// zeromcp.config.json
{
  "tools": "./tools",
  "remote": [
    {
      "name": "github",
      "url": "http://localhost:3001/mcp"
    },
    {
      "name": "jira",
      "url": "http://localhost:3002/mcp"
    },
    {
      "name": "stripe",
      "url": "http://localhost:3003/mcp",
      "auth": "env:STRIPE_MCP_TOKEN"
    }
  ]
}
```

```
$ zeromcp serve
[zeromcp] Connected to github (HTTP): 15 tool(s)
[zeromcp] Connected to jira (HTTP): 12 tool(s)
[zeromcp] Connected to stripe (HTTP): 17 tool(s)
[zeromcp] Loaded: my_custom_tool
[zeromcp] 1 local + 44 remote = 45 tool(s)
[zeromcp] stdio transport ready
```

## How it works

1.  **Remote tools load first.** ZeroMCP connects to each remote server via HTTP, runs the MCP handshake (initialize → tools/list), and imports all tools.
2.  **Auto-namespacing.** Tools are prefixed with the server name: `github.create_issue`, `jira.list_tickets`, `stripe.list_customers`.
3.  **Local tools load on top.** Your file-based tools merge into the same tool map. If a local tool has the same name as a remote tool, local wins.
4.  **Single tool map.** Clients see one flat list of tools, regardless of source.

## Authentication

Remote server auth resolves from environment variables:

```json
{ "auth": "env:STRIPE_MCP_TOKEN" }
```

This reads `STRIPE_MCP_TOKEN` from your environment and sends it as a Bearer token. Auth is never stored in the config file itself.

## Use cases

-   **Consolidation.** Replace N separate MCP processes with one.
-   **Extension.** Add custom tools on top of existing MCP servers.
-   **Override.** Replace a remote tool with a local version (same name = local wins).
-   **Federation.** Expose multiple teams' MCP servers behind one endpoint.
-   **Migration.** Start by composing, rewrite to local files incrementally.

## Local overrides

If your local tool has the same name as a remote tool, the local version takes priority:

```
// Remote: github.list_issues (from GitHub MCP server)
// Local:  tools/github/list_issues.js → github_list_issues

// If names match, local wins with a warning:
// [zeromcp] Local tool "github_list_issues" overrides remote
```

This lets you wrap, extend, or replace any remote tool without modifying the remote server.
