import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import ZeroMcp

/// A remote MCP server for federation tests: serves a JSON-RPC handler over
/// HTTP POST on 127.0.0.1:<random port>, mirroring python/tests/fake_upstream.py.
/// `requiredToken` makes it answer 401 unless `Authorization: Bearer <token>`
/// is sent; `status` forces every response to that HTTP status.
final class FakeUpstream {
    let url: String
    private let sockfd: Int32
    private let handler: McpHandler
    private let requiredToken: String?
    private let status: Int?
    private let lock = NSLock()
    private var _requests: [(method: String, auth: String?)] = []
    private var stopped = false

    var requests: [(method: String, auth: String?)] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    /// Upstream with the two tools the Node/Python tests use: list_pages, get_page.
    static func standardHandler() -> ZeroMcp {
        let up = ZeroMcp(config: ZeroMcpConfig())
        up.tool("list_pages", description: "Lists pages.", input: ["domain": .simple(.string)]) { args, _ in
            let data = try JSONSerialization.data(withJSONObject: ["pages": [] as [Any], "args": args])
            return String(data: data, encoding: .utf8)!
        }
        up.tool("get_page", description: "Gets a page.", input: ["url": .simple(.string)]) { args, _ in
            "page:\(args["url"] as? String ?? "")"
        }
        return up
    }

    convenience init(requiredToken: String? = nil, status: Int? = nil) {
        let up = FakeUpstream.standardHandler()
        self.init(handler: { await up.handleRequest($0) }, requiredToken: requiredToken, status: status)
    }

    init(handler: @escaping McpHandler, requiredToken: String? = nil, status: Int? = nil) {
        self.handler = handler
        self.requiredToken = requiredToken
        self.status = status
        signal(SIGPIPE, SIG_IGN)

        #if os(Linux)
        let sockStream = Int32(SOCK_STREAM.rawValue)
        #else
        let sockStream = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, sockStream, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        _ = listen(fd, 16)

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        sockfd = fd
        url = "http://127.0.0.1:\(UInt16(bigEndian: bound.sin_port))/mcp"

        let thread = Thread { [self] in self.acceptLoop() }
        thread.start()
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        _ = shutdown(sockfd, Int32(SHUT_RDWR))
        close(sockfd)
    }

    private func acceptLoop() {
        while true {
            let clientfd = accept(sockfd, nil, nil)
            lock.lock(); let done = stopped; lock.unlock()
            if done { if clientfd >= 0 { close(clientfd) }; return }
            guard clientfd >= 0 else { continue }
            handleConnection(clientfd)
            close(clientfd)
        }
    }

    private func handleConnection(_ fd: Int32) {
        guard let (headers, body) = readRequest(fd: fd) else { return }
        let auth = headers["authorization"]

        if let token = requiredToken, auth != "Bearer \(token)" {
            write(fd: fd, status: 401, body: Data(#"{"error":"Unauthorized"}"#.utf8))
            return
        }

        // Bodyless request (e.g. the GET from resolveIcon): plain 200.
        if body.isEmpty {
            write(fd: fd, status: status ?? 200, body: Data("{}".utf8))
            return
        }

        guard let rpc = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            write(fd: fd, status: 400, body: Data(#"{"error":"Invalid JSON"}"#.utf8))
            return
        }
        lock.lock(); _requests.append((rpc["method"] as? String ?? "", auth)); lock.unlock()

        let semaphore = DispatchSemaphore(value: 0)
        var response: [String: Any]?
        let handler = self.handler
        Task.detached {
            response = await handler(rpc)
            semaphore.signal()
        }
        semaphore.wait()

        let data = response.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        write(fd: fd, status: status ?? 200, body: data)
    }

    private func readRequest(fd: Int32) -> ([String: String], Data)? {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            var tmp = [UInt8](repeating: 0, count: 4096)
            let n = recv(fd, &tmp, tmp.count, 0)
            if n <= 0 { break }
            buffer.append(contentsOf: tmp[0..<n])
        }
        guard let headerEnd = buffer.range(of: separator) else { return nil }
        let headerString = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        var headers: [String: String] = [:]
        for line in headerString.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                    parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        var body = Data(buffer[headerEnd.upperBound...])
        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
        while body.count < contentLength {
            var tmp = [UInt8](repeating: 0, count: contentLength - body.count)
            let n = recv(fd, &tmp, tmp.count, 0)
            if n <= 0 { break }
            body.append(contentsOf: tmp[0..<n])
        }
        return (headers, body)
    }

    private func write(fd: Int32, status: Int, body: Data) {
        var data = Data(("HTTP/1.1 \(status) X\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n\r\n").utf8)
        data.append(body)
        data.withUnsafeBytes { ptr in
            var sent = 0
            while sent < data.count {
                let n = send(fd, ptr.baseAddress! + sent, data.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}

/// A TCP port on 127.0.0.1 with nothing listening (bound, then closed).
func unusedPort() -> UInt16 {
    #if os(Linux)
    let sockStream = Int32(SOCK_STREAM.rawValue)
    #else
    let sockStream = SOCK_STREAM
    #endif
    let fd = socket(AF_INET, sockStream, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &len)
        }
    }
    return UInt16(bigEndian: bound.sin_port)
}

/// Runs `body` with fd 2 redirected to a temp file and returns what was written.
func captureStderr(_ body: () async throws -> Void) async rethrows -> String {
    fflush(stderr)
    let path = NSTemporaryDirectory() + "zeromcp-stderr-\(UUID().uuidString).log"
    FileManager.default.createFile(atPath: path, contents: nil)
    let fileFd = open(path, O_WRONLY)
    let saved = dup(2)
    dup2(fileFd, 2)
    close(fileFd)
    defer {
        fflush(stderr)
        dup2(saved, 2)
        close(saved)
    }
    try await body()
    fflush(stderr)
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    try? FileManager.default.removeItem(atPath: path)
    return text
}
