import Foundation
import Network

// MARK: - HTTP route dispatch for ZeroMcp

extension ZeroMcp {
    /// Start a minimal HTTP server that dispatches registered tool routes.
    /// Tools with a `route` field are reachable at their defined method+path.
    /// The /mcp endpoint accepts POST for JSON-RPC (same as stdio but over HTTP).
    ///
    /// - Parameter port: TCP port to listen on (default 3000).
    public func serveHttp(port: UInt16 = 3000) async {
        fputs(stderr, "[zeromcp] HTTP server listening on port \(port)\n")
        fputs(stderr, "[zeromcp] \(tools.filter { $0.value.route != nil }.count) route(s) registered\n")

        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            fputs(stderr, "[zeromcp] Failed to create listener: \(error)\n")
            return
        }

        let queue = DispatchQueue(label: "zeromcp.http")
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            connection.start(queue: queue)
            self.handleHttpConnection(connection)
        }
        listener.start(queue: queue)

        // Park the current async task indefinitely while the listener runs.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    fputs(stderr, "[zeromcp] Listener failed: \(err)\n")
                    cont.resume()
                }
            }
        }
    }

    // MARK: - Connection handling

    private func handleHttpConnection(_ connection: NWConnection) {
        readHttpRequest(connection) { [weak self] requestLine, headers, body in
            guard let self = self else { return }
            Task {
                let response = await self.dispatchHttpRequest(
                    requestLine: requestLine,
                    headers: headers,
                    body: body
                )
                self.writeHttpResponse(connection, response: response)
            }
        }
    }

    private func readHttpRequest(
        _ connection: NWConnection,
        completion: @escaping (String, [String: String], Data) -> Void
    ) {
        var buffer = Data()

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data = data { buffer.append(data) }

                // Wait until we have the full headers (double CRLF)
                guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if !isComplete && error == nil { receive() }
                    return
                }

                let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
                let headerString = String(data: headerData, encoding: .utf8) ?? ""
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

                let bodyStart = headerEnd.upperBound
                var body = Data(buffer[bodyStart...])
                let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0

                if body.count >= contentLength {
                    completion(requestLine, headers, Data(body.prefix(contentLength)))
                } else {
                    // Read remaining body bytes
                    let remaining = contentLength - body.count
                    connection.receive(
                        minimumIncompleteLength: remaining,
                        maximumLength: remaining
                    ) { extra, _, _, _ in
                        if let extra = extra { body.append(extra) }
                        completion(requestLine, headers, Data(body.prefix(contentLength)))
                    }
                }
            }
        }
        receive()
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
    ) async -> (status: Int, body: Data) {
        let req = parseRequestLine(requestLine)

        // /mcp — JSON-RPC over HTTP
        if req.path == "/mcp" && req.method == "POST" {
            guard let rpcObj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return jsonResponse(status: 400, object: ["error": "Invalid JSON"])
            }
            if let resp = await handleRequest(rpcObj),
               let data = try? JSONSerialization.data(withJSONObject: resp) {
                return (200, data)
            }
            return jsonResponse(status: 204, object: [:] as [String: Any])
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

    // MARK: - Response helpers

    private func jsonResponse(status: Int, object: Any) -> (status: Int, body: Data) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return (status, data)
    }

    private func writeHttpResponse(_ connection: NWConnection, response: (status: Int, body: Data)) {
        let statusText = response.status == 200 ? "OK"
            : response.status == 204 ? "No Content"
            : response.status == 400 ? "Bad Request"
            : response.status == 404 ? "Not Found"
            : "Internal Server Error"

        let header = "HTTP/1.1 \(response.status) \(statusText)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(response.body.count)\r\n" +
            "Connection: close\r\n\r\n"

        var responseData = header.data(using: .utf8)!
        responseData.append(response.body)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private func fputs(_ stream: UnsafeMutablePointer<FILE>, _ string: String) {
    #if canImport(Darwin)
    Darwin.fputs(string, stream)
    #elseif canImport(Glibc)
    Glibc.fputs(string, stream)
    #endif
}
