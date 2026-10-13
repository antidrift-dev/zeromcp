// Route conformance harness (tests/conformance/run-route.js, port 14258).
//
// ZeroMCP Swift ships no HTTP server. This test-only binary builds a registry
// with createRegistry and mounts it on a tiny POSIX-socket listener, the way a
// user would mount it in their own framework:
//   POST /mcp          → registry.mcp
//   GET  /openapi.json → registry.openapi
//   each registry.routes entry → route.tool.execute, returning {ok, result}
//   GET  /health, GET /docs (static Swagger page) — harness-only
import ZeroMcp
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

let tools: [String: ToolDefinition] = [
    "greet": ToolDefinition(
        description: "Greet a person by name",
        input: ["name": .simple(.string)],
        route: RouteDefinition(method: "GET", path: "/greet/:name")
    ) { args, _ in
        let name = args["name"] as? String ?? "world"
        return "Hello, \(name)!"
    },
    "echo": ToolDefinition(
        description: "Echo a message back",
        input: ["message": .simple(.string)],
        route: RouteDefinition(method: "POST", path: "/echo")
    ) { args, _ in
        return ["message": args["message"] as Any, "echoed": true] as [String: Any]
    },
]

let registry = await createRegistry(tools)

// MARK: - HTTP plumbing

struct Request {
    let method: String
    let path: String
    let query: [String: String]
    let body: Data
}

typealias Response = (status: Int, body: Data, contentType: String)

func json(_ status: Int, _ object: Any) -> Response {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return (status, data, "application/json")
}

func readRequest(fd: Int32) -> Request? {
    var buffer = Data()
    let chunk = 4096
    let separator = Data("\r\n\r\n".utf8)
    while buffer.range(of: separator) == nil {
        var tmp = [UInt8](repeating: 0, count: chunk)
        let n = recv(fd, &tmp, chunk, 0)
        if n <= 0 { break }
        buffer.append(contentsOf: tmp[0..<n])
    }
    guard let headerEnd = buffer.range(of: separator) else { return nil }

    let headerString = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) ?? ""
    let lines = headerString.components(separatedBy: "\r\n")
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
            headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespaces)
        }
    }

    var body = Data(buffer[headerEnd.upperBound...])
    let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
    while body.count < contentLength {
        var tmp = [UInt8](repeating: 0, count: min(chunk, contentLength - body.count))
        let n = recv(fd, &tmp, tmp.count, 0)
        if n <= 0 { break }
        body.append(contentsOf: tmp[0..<n])
    }

    let requestLine = (lines.first ?? "").split(separator: " ")
    let method = requestLine.count > 0 ? String(requestLine[0]) : "GET"
    let rawPath = requestLine.count > 1 ? String(requestLine[1]) : "/"
    var path = rawPath
    var query: [String: String] = [:]
    if let qi = rawPath.firstIndex(of: "?") {
        path = String(rawPath[rawPath.startIndex..<qi])
        for pair in rawPath[rawPath.index(after: qi)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0) }
            let key = kv[0].removingPercentEncoding ?? kv[0]
            query[key] = kv.count == 2 ? (kv[1].removingPercentEncoding ?? kv[1]) : ""
        }
    }
    return Request(method: method, path: path, query: query, body: Data(body.prefix(contentLength)))
}

func writeResponse(fd: Int32, _ response: Response) {
    let statusText: String
    switch response.status {
    case 200: statusText = "OK"
    case 204: statusText = "No Content"
    case 400: statusText = "Bad Request"
    case 404: statusText = "Not Found"
    default: statusText = "Internal Server Error"
    }
    let header = "HTTP/1.1 \(response.status) \(statusText)\r\n" +
        "Content-Type: \(response.contentType)\r\n" +
        "Content-Length: \(response.body.count)\r\n" +
        "Connection: close\r\n\r\n"
    var data = Data(header.utf8)
    data.append(response.body)
    data.withUnsafeBytes { ptr in
        var sent = 0
        while sent < data.count {
            let n = send(fd, ptr.baseAddress! + sent, data.count - sent, 0)
            if n <= 0 { break }
            sent += n
        }
    }
}

/// Match a route pattern (`:param` segments) against a path.
func matchRoutePath(pattern: String, path: String) -> [String: String]? {
    let patternParts = pattern.split(separator: "/", omittingEmptySubsequences: false)
    let pathParts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard patternParts.count == pathParts.count else { return nil }
    var params: [String: String] = [:]
    for (pp, ap) in zip(patternParts, pathParts) {
        if pp.hasPrefix(":") {
            params[String(pp.dropFirst())] = ap.removingPercentEncoding ?? String(ap)
        } else if pp != ap {
            return nil
        }
    }
    return params
}

let swaggerHtml = """
<!DOCTYPE html>
<html>
<head>
  <title>ZeroMCP API</title>
  <meta charset="utf-8"/>
  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css">
</head>
<body>
<div id="swagger-ui"></div>
<script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
<script>SwaggerUIBundle({ url: '/openapi.json', dom_id: '#swagger-ui' })</script>
</body>
</html>
"""

func dispatch(_ req: Request, _ registry: Registry) async -> Response {
    if req.method == "POST" && req.path == "/mcp" {
        guard let rpc = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            return json(400, ["error": "Invalid JSON"])
        }
        if let resp = await registry.mcp(rpc) { return json(200, resp) }
        return (204, Data(), "application/json")
    }
    if req.method == "GET" && req.path == "/health" { return json(200, ["ok": true]) }
    if req.method == "GET" && req.path == "/openapi.json" { return json(200, registry.openapi) }
    if req.method == "GET" && req.path == "/docs" {
        return (200, Data(swaggerHtml.utf8), "text/html; charset=utf-8")
    }

    for route in registry.routes where route.method == req.method {
        guard let pathParams = matchRoutePath(pattern: route.path, path: req.path) else { continue }
        var args: [String: Any] = [:]
        if req.method == "GET" {
            for (k, v) in req.query { args[k] = v }
        } else if !req.body.isEmpty,
                  let parsed = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] {
            for (k, v) in parsed { args[k] = v }
        }
        for (k, v) in pathParams { args[k] = v }

        do {
            let ctx = ToolContext(toolName: route.name, permissions: route.tool.permissions)
            let result = try await route.tool.execute(args, ctx)
            return json(200, ["ok": true, "result": result])
        } catch {
            return json(500, ["ok": false, "error": error.localizedDescription] as [String: Any])
        }
    }
    return json(404, ["error": "Not found"])
}

// MARK: - Listener

func runListener(port: UInt16, registry: Registry) -> Never {
    signal(SIGPIPE, SIG_IGN)
    #if os(Linux)
    let sockStream = Int32(SOCK_STREAM.rawValue)
    #else
    let sockStream = SOCK_STREAM
    #endif
    let sockfd = socket(AF_INET, sockStream, 0)
    guard sockfd >= 0 else {
        fputs("[route-test] socket() failed\n", stderr)
        exit(1)
    }
    var yes: Int32 = 1
    setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = INADDR_ANY
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(sockfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else {
        fputs("[route-test] bind() failed on port \(port)\n", stderr)
        exit(1)
    }
    _ = listen(sockfd, 64)
    fputs("[route-test] listening on port \(port)\n", stderr)

    while true {
        let clientfd = accept(sockfd, nil, nil)
        guard clientfd >= 0 else { continue }
        Task.detached {
            defer { close(clientfd) }
            guard let req = readRequest(fd: clientfd) else { return }
            writeResponse(fd: clientfd, await dispatch(req, registry))
        }
    }
}

// The accept loop gets its own thread: the tool closures above were created
// in top-level code, so they run on the main actor, which must stay free.
Thread { runListener(port: 14258, registry: registry) }.start()
while true {
    try? await Task.sleep(nanoseconds: 3_600_000_000_000)
}
