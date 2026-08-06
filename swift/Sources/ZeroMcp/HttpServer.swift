import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - HTTP route dispatch for ZeroMcp (POSIX sockets — works on Linux + macOS)

extension ZeroMcp {
    /// Start an HTTP server using POSIX sockets (cross-platform: Linux + macOS).
    /// Blocks until the socket fails. Run in a Task or background thread.
    public func serveHttp(port: UInt16 = 3000) {
        let sockfd = socket(AF_INET, SOCK_STREAM, 0)
        guard sockfd >= 0 else {
            fputs(stderr, "[zeromcp] socket() failed\n")
            return
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
            fputs(stderr, "[zeromcp] bind() failed on port \(port)\n")
            close(sockfd)
            return
        }
        listen(sockfd, 64)
        fputs(stderr, "[zeromcp] HTTP server listening on port \(port)\n")
        fputs(stderr, "[zeromcp] \(tools.filter { $0.value.route != nil }.count) route(s) registered\n")

        while true {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientfd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(sockfd, $0, &clientLen)
                }
            }
            guard clientfd >= 0 else { continue }
            Task { await self.handlePosixConnection(fd: clientfd) }
        }
    }

    // MARK: - Connection handling

    private func handlePosixConnection(fd: Int32) async {
        defer { close(fd) }
        guard let (requestLine, headers, body) = readPosixRequest(fd: fd) else { return }
        let response = await dispatchHttpRequest(requestLine: requestLine, headers: headers, body: body)
        writePosixResponse(fd: fd, response: response)
    }

    private func readPosixRequest(fd: Int32) -> (String, [String: String], Data)? {
        var buffer = Data()
        let chunk = 4096
        while true {
            var tmp = [UInt8](repeating: 0, count: chunk)
            let n = recv(fd, &tmp, chunk, 0)
            if n <= 0 { break }
            buffer.append(contentsOf: tmp[0..<n])
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }

        let headerString = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        let lines = headerString.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""

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
        return (requestLine, headers, Data(body.prefix(contentLength)))
    }

    // MARK: - Dispatch

    private struct HttpRequest {
        let method: String
        let path: String
        let query: [String: String]
    }

    private func parseRequestLine(_ line: String) -> HttpRequest {
        let parts = line.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : "GET"
        let rawPath = parts.count > 1 ? String(parts[1]) : "/"

        var path = rawPath
        var query: [String: String] = [:]
        if let qi = rawPath.firstIndex(of: "?") {
            path = String(rawPath[rawPath.startIndex..<qi])
            let qs = String(rawPath[rawPath.index(after: qi)...])
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                    let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                    query[k] = v
                } else if kv.count == 1 {
                    query[String(kv[0])] = ""
                }
            }
        }
        return HttpRequest(method: method, path: path, query: query)
    }

    private func dispatchHttpRequest(
        requestLine: String,
        headers: [String: String],
        body: Data
    ) async -> (status: Int, body: Data, contentType: String) {
        let req = parseRequestLine(requestLine)

        // /mcp — JSON-RPC over HTTP
        if req.path == "/mcp" && req.method == "POST" {
            guard let rpcObj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return jsonResponse(status: 400, object: ["error": "Invalid JSON"])
            }
            if let resp = await handleRequest(rpcObj),
               let data = try? JSONSerialization.data(withJSONObject: resp) {
                return (200, data, "application/json")
            }
            return jsonResponse(status: 204, object: [:] as [String: Any])
        }

        // /health
        if req.path == "/health" && req.method == "GET" {
            return jsonResponse(status: 200, object: ["ok": true])
        }

        // /openapi.json
        if req.path == "/openapi.json" && req.method == "GET" {
            let spec = buildOpenApiSpec()
            return jsonResponse(status: 200, object: spec)
        }

        // /docs — Swagger UI
        if req.path == "/docs" && req.method == "GET" {
            let html = buildSwaggerHtml()
            let data = html.data(using: .utf8) ?? Data()
            return (200, data, "text/html; charset=utf-8")
        }

        // Tool routes
        for (name, tool) in tools {
            guard let route = tool.route else { continue }
            guard route.method == req.method else { continue }
            guard let pathParams = matchRoutePath(pattern: route.path, path: req.path) else { continue }

            var args: [String: Any] = [:]

            if req.method == "GET" {
                for (k, v) in req.query { args[k] = v }
            } else {
                if !body.isEmpty,
                   let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    for (k, v) in parsed { args[k] = v }
                }
            }
            for (k, v) in pathParams { args[k] = v }

            let ctx = ToolContext(toolName: name, permissions: tool.permissions)
            do {
                let result = try await tool.execute(args, ctx)
                return jsonResponse(status: 200, object: ["ok": true, "result": result])
            } catch {
                return jsonResponse(
                    status: 500,
                    object: ["ok": false, "error": error.localizedDescription] as [String: Any]
                )
            }
        }

        return jsonResponse(status: 404, object: ["error": "Not found"])
    }

    // MARK: - Path matching

    /// Match a route pattern (`:param` segments) against an incoming path.
    /// Returns extracted params on match, nil on mismatch.
    private func matchRoutePath(pattern: String, path: String) -> [String: String]? {
        let patternParts = pattern.split(separator: "/", omittingEmptySubsequences: false)
        let pathParts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard patternParts.count == pathParts.count else { return nil }

        var params: [String: String] = [:]
        for (pp, ap) in zip(patternParts, pathParts) {
            if pp.hasPrefix(":") {
                let key = String(pp.dropFirst())
                params[key] = ap.removingPercentEncoding ?? String(ap)
            } else if pp != ap {
                return nil
            }
        }
        return params
    }

    // MARK: - OpenAPI spec builder

    private func buildOpenApiSpec() -> [String: Any] {
        let title = config.title ?? "ZeroMCP"
        var paths: [String: Any] = [:]

        for (name, tool) in tools.sorted(by: { $0.key < $1.key }) {
            guard let route = tool.route else { continue }

            let pathParams = extractPathParams(from: route.path)
            let isBodyMethod = route.method != "GET"
            let schema = tool.cachedSchema

            var operation: [String: Any] = [
                "operationId": name,
                "description": tool.description,
                "responses": [
                    "200": ["description": "Success"],
                    "500": ["description": "Error"]
                ] as [String: Any]
            ]

            if isBodyMethod {
                var props: [String: Any] = [:]
                for (key, prop) in schema.properties where !pathParams.contains(key) {
                    var p: [String: Any] = ["type": prop.type]
                    if let desc = prop.description { p["description"] = desc }
                    props[key] = p
                }
                var bodySchema: [String: Any] = ["type": "object", "properties": props]
                let bodyRequired = schema.required.filter { !pathParams.contains($0) }
                if !bodyRequired.isEmpty { bodySchema["required"] = bodyRequired }
                operation["requestBody"] = [
                    "required": true,
                    "content": ["application/json": ["schema": bodySchema]] as [String: Any]
                ] as [String: Any]
                if !pathParams.isEmpty {
                    operation["parameters"] = pathParams.sorted().map { key -> [String: Any] in
                        [
                            "name": key,
                            "in": "path",
                            "required": true,
                            "schema": ["type": "string"]
                        ]
                    }
                }
            } else {
                var parameters: [[String: Any]] = []
                for (key, prop) in schema.properties {
                    let location = pathParams.contains(key) ? "path" : "query"
                    let isRequired = schema.required.contains(key) || location == "path"
                    let paramSchema: [String: Any] = ["type": prop.type]
                    var param: [String: Any] = [
                        "name": key,
                        "in": location,
                        "required": isRequired,
                        "schema": paramSchema
                    ]
                    if let desc = prop.description { param["description"] = desc }
                    parameters.append(param)
                }
                operation["parameters"] = parameters
            }

            let openApiPath = route.path.replacingOccurrences(of: #":([\w]+)"#, with: "{$1}", options: .regularExpression)
            let methodKey = route.method.lowercased()

            if var existing = paths[openApiPath] as? [String: Any] {
                existing[methodKey] = operation
                paths[openApiPath] = existing
            } else {
                paths[openApiPath] = [methodKey: operation] as [String: Any]
            }
        }

        return [
            "openapi": "3.0.0",
            "info": ["title": title, "version": "0.5.0"] as [String: Any],
            "paths": paths
        ]
    }

    private func extractPathParams(from path: String) -> Set<String> {
        var params: Set<String> = []
        let pattern = try? NSRegularExpression(pattern: #":(\w+)"#)
        let ns = path as NSString
        pattern?.enumerateMatches(in: path, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            if let match = match, match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: path) {
                params.insert(String(path[range]))
            }
        }
        return params
    }

    private func buildSwaggerHtml() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
          <title>ZeroMCP API</title>
          <meta charset="utf-8"/>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css">
        </head>
        <body>
        <div id="swagger-ui"></div>
        <script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
        <script>SwaggerUIBundle({ url: '/openapi.json', dom_id: '#swagger-ui' })</script>
        </body>
        </html>
        """
    }

    // MARK: - Response helpers

    private func jsonResponse(status: Int, object: Any) -> (status: Int, body: Data, contentType: String) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return (status, data, "application/json")
    }

    private func writePosixResponse(fd: Int32, response: (status: Int, body: Data, contentType: String)) {
        let statusText = response.status == 200 ? "OK"
            : response.status == 204 ? "No Content"
            : response.status == 400 ? "Bad Request"
            : response.status == 404 ? "Not Found"
            : "Internal Server Error"

        let header = "HTTP/1.1 \(response.status) \(statusText)\r\n" +
            "Content-Type: \(response.contentType)\r\n" +
            "Content-Length: \(response.body.count)\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "Connection: close\r\n\r\n"

        var data = header.data(using: .utf8)!
        data.append(response.body)
        data.withUnsafeBytes { ptr in
            _ = send(fd, ptr.baseAddress!, data.count, 0)
        }
    }
}

private func fputs(_ stream: UnsafeMutablePointer<FILE>, _ string: String) {
    #if canImport(Darwin)
    Darwin.fputs(string, stream)
    #elseif canImport(Glibc)
    Glibc.fputs(string, stream)
    #endif
}
