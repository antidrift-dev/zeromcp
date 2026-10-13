import Foundation

// MARK: - OpenAPI spec builder (used by createRegistry)

extension ZeroMcp {
    func buildOpenApiSpec() -> [String: Any] {
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
}
