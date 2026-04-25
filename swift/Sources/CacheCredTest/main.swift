import ZeroMcp
import Foundation

let configPath = ProcessInfo.processInfo.environment["ZEROMCP_CONFIG"] ?? "zeromcp.config.json"

// Parse config to get credentials.tokenstore.file and cache_credentials.
var credFile = ""
var cacheCredentials = true
if let data = FileManager.default.contents(atPath: configPath),
   let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    if let creds = cfg["credentials"] as? [String: Any],
       let tokenstore = creds["tokenstore"] as? [String: Any],
       let file = tokenstore["file"] as? String {
        credFile = file
    }
    if let flag = cfg["cache_credentials"] as? Bool {
        cacheCredentials = flag
    }
}

func readTokenFromFile(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return obj["token"] as? String
}

let server = ZeroMcp()
var cachedToken: String?? = nil  // outer Optional = whether we've cached yet

server.tool(
    "tokenstore_check",
    description: "Return the current token from credentials",
    input: [:]
) { args, ctx in
    let token: String?
    if cacheCredentials {
        if cachedToken == nil {
            cachedToken = readTokenFromFile(credFile)
        }
        token = cachedToken!
    } else {
        token = readTokenFromFile(credFile)
    }
    return ["token": token as Any] as [String: Any]
}

await server.serve()
