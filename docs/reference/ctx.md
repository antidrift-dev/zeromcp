# ctx API Reference

The `ctx` object is passed as the second argument to every tool's `execute` function.

```
execute: async (args, ctx) => {
  ctx.credentials  // mapped credentials for this tool's directory
  ctx.fetch(url)   // sandboxed fetch with domain allowlisting
}
```

## ctx.credentials

**Type:** `unknown` (depends on your credential source)

Contains the credentials mapped to this tool's directory in `zeromcp.config.json`.

### From environment variable

```bash
// Config: { "credentials": { "stripe": { "env": "STRIPE_KEY" } } }
// Tool at: tools/stripe/list.js

ctx.credentials  // → value of process.env.STRIPE_KEY
```

If the value is valid JSON, it's parsed automatically. Otherwise it's returned as a raw string.

### From file

```python
// Config: { "credentials": { "google": { "file": "~/.config/google/creds.json" } } }
// Tool at: tools/google/sheets.js

ctx.credentials  // → parsed JSON object from the file
```

### No credentials

If no credentials are configured for a tool's directory, `ctx.credentials` is `undefined`.

## ctx.fetch

**Type:** `(url: string, options?: RequestInit) => Promise<Response>`

Drop-in replacement for global `fetch` with two additions:

-   **Domain allowlisting:** Only domains listed in `permissions.network` are reachable. Requests to undeclared domains are blocked (or warned if `bypass_permissions` is true).
-   **Logging:** When `"logging": true` in config, all requests are logged to stderr with URL, method, and status code.

```
// Tool with permissions: { network: ["api.stripe.com"] }

// Allowed:
await ctx.fetch("https://api.stripe.com/v1/customers")

// Blocked:
await ctx.fetch("https://other-api.com/data")
// → Error: Network access to other-api.com not permitted
```

### Important

-   Always use `ctx.fetch` instead of global `fetch`. The audit CLI flags global fetch usage.
-   The domain check is on the hostname, not the full URL
-   `ctx.fetch` has the same API as the standard Fetch API
