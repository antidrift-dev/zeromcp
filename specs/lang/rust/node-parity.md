# Node parity — Rust

## Status
Not started. Spec only.

## Gaps
1. Remote federation (`remote` config) in the built-in server
2. Remote allowlist (`remote[].tools`)
3. Remote via `Server::handle_request` (the framework-agnostic handler)
4. Remote in the registry (`create_registry` becomes async, takes options)
5. Runtime context injection (`ctx.runtime`)
6. ~~Transport config: object or array, stdio + http together, http `auth`~~ (dropped: no built-in HTTP server)
7. `page_size` in config
8. `icon` in config

## 1. Remote federation in the built-in server
**Node does:** `serve()` connects each `config.remote` server before loading local tools (`nodejs/src/server.ts:23-28`), then lets local tools override with a log (`server.ts:33-36`). `RemoteManager` (`nodejs/src/remote.ts`) rejects non-http(s) URLs (`:41-43`), POSTs `initialize` (id 1) then `tools/list` (id 2) with `Content-Type: application/json` and `Authorization: Bearer <auth>` (`:52-59`, `:87-98`), throws on non-2xx (`:97`), converts each `inputSchema` back to input (`schemaToInput`, `:101-121`), and registers `<server>.<tool>` whose execute POSTs `tools/call` and returns `result.content[0].text` or else `result` (`:69-79`). A server that fails is logged and skipped (`:32-34`). `auth` goes through `resolveAuth` (`nodejs/src/config.ts:153-166`).

**Rust today:** No remote support. `Config` has no `remote` field (`rust/src/config.rs:6-30`); `grep -rn remote rust/src` finds nothing. No HTTP client dependency (`rust/Cargo.toml:14-17`: serde, serde_json, tokio only).

**Change:**
- `rust/Cargo.toml`: add `reqwest = { version = "0.13", default-features = false, features = ["json", "rustls"] }`. `cargo info reqwest@0.13.5` lists both features and `rust-version: 1.85.0`. `rust/README.md:47` says "works with Rust 1.78+", so update that line to 1.85+.
- `rust/src/config.rs`: add the `RemoteServer` type, a `remote` field, and `resolve_auth`:
  ```rust
  #[derive(Debug, Clone, Serialize, Deserialize)]
  pub struct RemoteServer {
      pub name: String,
      pub url: String,
      #[serde(default)] pub auth: Option<String>,
      #[serde(default)] pub tools: Option<Vec<String>>,
  }
  // in Config:
  #[serde(default)] pub remote: Vec<RemoteServer>,

  /// `env:VAR` -> value of VAR (warns `[zeromcp] Warning: environment variable VAR not set`
  /// and returns None if unset/empty); anything else -> the literal.
  pub fn resolve_auth(auth: Option<&str>) -> Option<String>;
  ```
- New `rust/src/remote.rs` (`pub(crate) mod remote;` in `lib.rs`):
  ```rust
  /// Connect every server, returning `("<server>.<tool>", Tool)` pairs. Never fails as a whole.
  pub(crate) async fn connect(servers: &[RemoteServer]) -> Vec<(String, Tool)>;
  fn schema_to_input(schema: &Value) -> Result<Input, String>;
  ```
  - URL must start with `http://` or `https://`, else that server fails with `Remote server "<name>" must have an HTTP/HTTPS URL, got: <url>`.
  - One `reqwest::Client` per server. Each RPC is a POST of `{"jsonrpc":"2.0","id":…,"method":…,"params":…}` with `Content-Type: application/json` and, if `resolve_auth` returns `Some`, `Authorization: Bearer <token>`. If the status is not 2xx, fail with `HTTP <status>`. Parse the body as `serde_json::Value`.
  - Send `initialize` (id 1, params `{}`), then `tools/list` (id 2, params `{}`). Read `result.tools`, treating it as empty if missing.
  - `schema_to_input`: for each `properties` entry, use `type` (default `"string"`) and `description` (if any), and mark the field optional if its name is not in `required`. Pick `Input::required` / `required_desc` / `optional` / `optional_desc` to match (`rust/src/schema.rs:46-88`). If `properties` is missing, the input is empty. `Input::to_json_schema` **panics** on a type outside string/number/boolean/object/array (`schema.rs:95-101`). So `schema_to_input` must check the type first and return `Err("Unknown type \"<t>\" for field \"<key>\"")`. That error fails only this server, the same as Node's throw inside `connectHttp`.
  - Each remote `Tool`: `description` copied, `input` from above, `cached_schema = input.to_json_schema()`, `permissions: Permissions::default()`, `route: None`. `execute` ignores `ctx` and POSTs `tools/call` with `id` = Unix millis and params `{name, arguments}`. It returns `Ok(Value::String(text))` if `result.content[0].text` is a non-empty string, `Ok(result)` otherwise, and `Ok(Value::Null)` if `result` is absent. HTTP and parse errors return `Err(msg)`.
  - Logs: `[mcp] Remote tool: <server>.<tool>` per tool, `[mcp] Connected to <name> (HTTP): <n> tool(s)` per server, and `[mcp] Failed to connect to <name>: <msg>` when a server fails, after which the others continue.
- `rust/src/server.rs`:
  ```rust
  impl Server {
      /// Connect `config.remote` and resolve `config.icon` (§8). Idempotent.
      /// Called by serve/serve_http/run; call it yourself before using handle_request.
      pub async fn prepare(&mut self);
  }
  ```
  - Remote tools go straight into `self.tools` as `Arc<Tool>`, without `validate_permissions`. If a local tool already has that name, the local tool stays and `[zeromcp] Local tool "<name>" overrides remote` is logged. Keep a `remote_names: BTreeSet<String>`, so that when `Server::tool` (`server.rs:68`) later replaces a remote name it logs the same line. Local wins in either registration order.
  - `serve(&self)` → `serve(&mut self)` and `serve_http(self, …)` → `serve_http(mut self, …)`, each calling `self.prepare().await` first. Every in-repo caller binds `let mut server` (`grep -rn "let mut server" rust/examples rust/tests`), so they compile unchanged.
  - Remote tools have `route: None`, so `build_openapi` (`server.rs:612-617`, which skips route-less tools) never lists them.
- `rust/src/lib.rs`: `pub use config::{Config, RemoteServer};`.
- **N/A:** Node's "No tools directory and no remote servers configured" exit (`server.ts:37-41`). Rust has no tools directory to fail on (§ Already at parity).

**Tests:** New `rust/tests/remote.rs`, with a mock upstream on `tokio::net::TcpListener::bind("127.0.0.1:0")` that answers `initialize` / `tools/list` (two tools) / `tools/call` (like `nodejs/test/handler-remote.test.js:6-18`). It needs no new dev-dependencies. Cases:
- `tools/list` shows `<server>.<tool>`.
- `tools/call` returns the upstream `content[0].text`.
- A `ftp://` URL is skipped while a good server still connects.
- A non-2xx upstream is skipped.
- A local tool overrides a remote one of the same name.
- `auth: "env:VAR"` sends `Authorization: Bearer <value>`; the mock asserts it.

Unit tests in `remote.rs` for `schema_to_input`: default type, description kept, optional when not required, unknown type → `Err`.

## 2. Remote allowlist
**Node does:** `remote[].tools?: string[]` exposes only upstream tools whose name is in the list; omitting it exposes all (`nodejs/src/config.ts:9-10`, `nodejs/src/remote.ts:61`).

**Rust today:** No `remote` config at all (see §1).

**Change:** In `remote::connect`, after `tools/list`, drop any tool whose name is not in `server.tools` when that is `Some`. Match against the upstream name, before the `<server>.` prefix.

**Tests:** In `rust/tests/remote.rs`: `tools: Some(vec!["list_pages"])` against a two-tool upstream lists only `<server>.list_pages` (mirrors `handler-remote.test.js:30-33`). `tools: None` lists both.

## 3. Remote via `Server::handle_request`
**Node does:** `createHandler(config, options)` connects remotes and merges them local-over-remote, the same way `serve()` does (`nodejs/src/handler.ts:36-49`).

**Rust today:** Rust's framework-agnostic entry point is `Server::handle_request(&self, &Value)` (`rust/src/server.rs:192`; `rust/README.md:53-77` shows it embedded in axum). It only dispatches what was registered in code and cannot connect remotes.

**Change:** No new entry point. `Server::prepare().await` (§1) is the hook: `Server::from_config(path)` → register tools → `server.prepare().await` → `handle_request`. In `rust/README.md`'s "HTTP / Streamable HTTP" section, add a `server.prepare().await;` line before the axum handler is built.

**Tests:** In `rust/tests/remote.rs`: build a `Server` with a `remote` entry, call `prepare().await`, then drive `handle_request` with `tools/list` and `tools/call` without calling `serve`.

## 4. Remote in the registry
**Node does:** `createRegistry(tools, options)` is async. `options.remote` connects remotes first, and a local tool with the same name overrides with a log (`nodejs/src/registry.ts:42-65`). Remote tools are dispatchable through `mcp`. They never appear in `routes`, which is built from local tools only (`:67-74`), or in `openapi`, because they have no route.

**Rust today:** `pub fn create_registry<I, S>(tools: I) -> Registry` is sync and takes no options (`rust/src/registry.rs:63-101`).

**Change:** `rust/src/registry.rs`, matching Node's async change:
```rust
#[derive(Debug, Clone, Default)]
pub struct RegistryOptions {
    /// Remote MCP servers to federate as `<server>.<tool>`; a local tool with the same name wins.
    pub remote: Vec<RemoteServer>,
}

pub async fn create_registry<I, S>(tools: I, options: RegistryOptions) -> Registry
where I: IntoIterator<Item = (S, Tool)>, S: Into<String>;
```
- Build the internal `Server` as today, set `server.config.remote = options.remote`, register the local tools, then call `server.prepare().await`. §1's override rule keeps the locals and logs.
- Compute `openapi` and `routes` after `prepare`, from `server.tools`. Remote tools have `route: None`, so the existing `filter_map` (`registry.rs:76-87`) and `build_openapi` exclude them without extra code.
- Existing tests in `registry.rs` call `create_registry(tools)`. Change them to `create_registry(tools, RegistryOptions::default()).await`, and make the four `#[test]` ones (`registry.rs:140,152,163,228`) `#[tokio::test]`.

**Tests:** In `rust/tests/remote.rs`, mirroring `nodejs/test/registry.test.js:180-227`:
- Remote tools are listed and callable through `registry.mcp`.
- A local `"probeo.list_pages"` overrides the remote one, and `tools/call` returns the local result.
- With only remote tools, `routes` is empty and `openapi["paths"]` is `{}`.

## 5. Runtime context injection
**Node does:** `createHandler(config, { getRuntime })` (`nodejs/src/handler.ts:19-23,44`). On every local tool execution it calls `getRuntime()` and, if the result is not `undefined`, sets it as `ctx.runtime` alongside `credentials` and `fetch` (`nodejs/src/scanner.ts:9-13,167-172`). `serve()` takes no `getRuntime`.

**Rust today:** `Ctx` is `{ permissions, logging, bypass }`, with no caller-supplied slot (`rust/src/types.rs:29-44`). `call_tool` builds it at `rust/src/server.rs:568-572`, and `Registry::ctx_for` builds it at `rust/src/registry.rs:51-57`.

**Change:** Use type-erased `Any` rather than a generic `Server<R>`. `Ctx` is a concrete non-generic struct used in `ExecuteFn` (`types.rs:53-54`), so a generic would spread through `Tool`, `Server` and `Registry`.
```rust
// rust/src/types.rs
pub type RuntimeValue = Arc<dyn Any + Send + Sync>;
pub type RuntimeFn = Arc<dyn Fn() -> Option<RuntimeValue> + Send + Sync>;

pub struct Ctx {
    pub permissions: Permissions,
    pub logging: bool,
    pub bypass: bool,
    pub runtime: Option<RuntimeValue>,   // Default: None
}
impl Ctx {
    pub fn runtime_as<T: Any>(&self) -> Option<&T>;   // downcast helper
}

// rust/src/server.rs
impl Server {
    pub fn set_runtime<F, T>(&mut self, get: F)
    where F: Fn() -> Option<T> + Send + Sync + 'static, T: Any + Send + Sync;
}
```
- `call_tool` calls the getter on every `tools/call` and stores the value in `ctx.runtime`, or `None` when unset or when the getter returns `None`. Remote tools ignore `ctx` (§1), the same as Node.
- Rust has one object for both handler and server, so `set_runtime` also applies under `serve`/`serve_http`/`run`. Node's `serve()` has no such option, but nothing in Rust calls `set_runtime` unless the user does.
- `Registry::ctx_for` sets `runtime: None`. Node's registry has no `getRuntime`; its `getEnv` is covered in Already at parity.
- Adding a public field breaks external `Ctx { … }` literals. The in-repo sites are `server.rs:568` and `registry.rs:52` (`grep -rn "Ctx {" rust/`).
- `lib.rs`: re-export `RuntimeFn` and `RuntimeValue` next to `Ctx`.

**Tests:** Unit tests in `server.rs`'s `mod tests`:
- With `set_runtime(|| Some(42u32))`, a tool reads `ctx.runtime_as::<u32>() == Some(&42)`.
- With no getter, `ctx.runtime.is_none()`.
- A getter returning `None` leaves `ctx.runtime` as `None`.
- The getter is called once per `tools/call` (counter).

## 6. Transport config: object or array, stdio + http together, http `auth` (dropped)
Dropped (2026-10-13): no language ships a built-in HTTP server (decisions log, 2026-10-13), so there's no HTTP transport to configure or run alongside stdio.

## 7. `page_size` in config
**Node does:** `config.page_size` (default 0) feeds the dispatch state (`nodejs/src/config.ts:46`, `nodejs/src/server.ts:62`).

**Rust today:** Paging exists, but only through the `Server::set_page_size` setter (`rust/src/server.rs:61-63`). `Config` has no `page_size` (`config.rs:6-30`), and `from_config` hard-codes `page_size: 0` (`server.rs:55`).

**Change:** Add `#[serde(default)] pub page_size: usize` to `Config` (include it in `Default`). In `from_config`, set `page_size` from the loaded config. `set_page_size` still overrides it.

**Tests:** Unit test in `config.rs`: `{"page_size": 2}` deserializes to 2, and a missing value gives 0. Unit test in `server.rs`: a server built from a temp config file with `page_size: 1` paginates `tools/list`. The paging itself is already tested at `tools_list_pagination`.

## 8. `icon` in config
**Node does:** `config.icon` is turned into a data URI before serving (`nodejs/src/server.ts:53`, `nodejs/src/handler.ts:57`, `resolveIcon` in `nodejs/src/config.ts:66-102`):
- A `data:` value passes through unchanged.
- An http(s) URL is fetched, and the response becomes `data:<content-type or image/png>;base64,…`.
- Anything else is treated as a file path: a leading `~` expands to `$HOME`, and the mime type comes from the extension table at `config.ts:52-60`, defaulting to `image/png`.
- Failures warn and leave the icon unset.

**Rust today:** `Server.icon: Option<String>` is a public field set in code and emitted as-is (`rust/src/server.rs:25-26,267-268,296-297`). `Config` has no `icon` field, and `from_config` sets `icon: None` (`server.rs:56`).

**Change:**
- Add `#[serde(default)] pub icon: Option<String>` to `Config`.
- Add `pub(crate) async fn resolve_icon(icon: &str) -> Option<String>` in `config.rs`, implementing Node's three branches. Fetch URLs with the `reqwest` dependency from §1, and use `base64_encode` (`server.rs:863`, change it to `pub(crate)`).
- Use the same warning texts as Node:
  - `[zeromcp] Warning: failed to fetch icon <icon>: <status|msg>`
  - `[zeromcp] Warning: failed to read icon file <icon>: <msg>`
- `Server::prepare` (§1) sets `self.icon = resolve_icon(..)` only when `self.icon` is `None` and `config.icon` is `Some`, so an icon set in code wins.

**Tests:** Unit tests in `config.rs`:
- A `data:` value passes through.
- A temp `.svg` file gives a `data:image/svg+xml;base64,` prefix.
- A missing file gives `None`.
- An http URL served by a loopback `TcpListener` mock with `Content-Type: image/gif` gives a `data:image/gif;base64,` prefix.

## Already at parity
- `title`: `rust/src/config.rs:27-29`, used at `server.rs:613`.
- `logging`: `config.rs:8-9`, used at `server.rs:570`.
- `bypass_permissions`: `config.rs:12-13`, used at `server.rs:571`.
- `execute_timeout`: `config.rs:20-21`, with the per-tool override applied at `server.rs:575-576`.
- Registry `getEnv`: Rust tools are closures (`ExecuteFn`, `rust/src/types.rs:53-54`) and capture host state directly (e.g. `rust/examples/credential_test.rs:11-21`). This was the deliberate decision in `specs/lang/rust/registry.md` ("No `getEnv`/`TEnv` generic").
- N/A, hot reload (`autoload_tools`): tools are registered in code via `Server::tool` (`server.rs:68`), and Rust never loads them from a directory (`rust/README.md:3`). `Config` has no `autoload_tools`.
- N/A, tool sources / `separator` / `namespacing` / `prefix`: there is no directory scan to name tools from. `Config.separator` exists (`config.rs:15-17`), but nothing in `rust/src` reads it.
- N/A, `resources` / `prompts` directories: these are registered in code (`server.rs:97-112`).
- N/A, `credentials` / `cache_credentials`: Node keys credentials by tool subdirectory (`nodejs/src/scanner.ts:115-120`), which Rust has no equivalent of. `Config.cache_credentials` exists (`config.rs:23-25`), but nothing in `rust/src` reads it.
- N/A, the "No tools directory" startup exit: there is no tools directory to fail on.

## Verify
All build and test runs happen in the local all-language Docker image (repo-root `Dockerfile`, per `engineering/testing.md`), not on host toolchains. The image copies the source in at build time, so rebuild it after every change.

```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd rust && cargo build && cargo test && cargo clippy --all-targets'
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "Rust"
```
