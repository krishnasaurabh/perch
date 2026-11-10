import Foundation

/// MCP over stdio (newline-delimited JSON-RPC 2.0). The app binary runs this when launched with `--mcp`.
public final class MCPServer {
    public struct MethodNotFound: Error { public let name: String }

    let tools: AgentTools
    let version: String
    private var clientName: String?
    /// Called after every successful mutating tool call (the app uses this to refresh / notify).
    public var onChange: (() -> Void)?

    public static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public init(tools: AgentTools, version: String) {
        self.tools = tools; self.version = version
    }

    /// Handles one JSON-RPC message. Returns nil for notifications.
    public func handle(_ msg: JSON) -> JSON? {
        // JSON-RPC 2.0: anything that is not a Request object is an Invalid Request
        // answered with a null id, so a client never waits forever.
        guard case .object = msg else { return invalidRequest() }
        let id = msg["id"]
        guard let method = msg["method"]?.string else {
            return id.map { error($0, -32600, "Invalid Request") } ?? invalidRequest()
        }
        let params = msg["params"] ?? .object([:])
        if id == nil { return nil }  // notifications/initialized etc.

        switch method {
        case "initialize":
            clientName = params["clientInfo"]?["name"]?.string
            let requested = params["protocolVersion"]?.string ?? Self.protocolVersions[0]
            let pv = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
            return result(
                id!,
                [
                    "protocolVersion": .string(pv),
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "perch", "version": .string(version)],
                    "instructions": .string(AgentTools.instructions),
                ])
        case "ping":
            return result(id!, .object([:]))
        case "tools/list":
            return result(id!, ["tools": .array(AgentTools.definitions)])
        case "tools/call":
            guard let name = params["name"]?.string else { return error(id!, -32602, "Missing tool name") }
            do {
                let text = try tools.call(name, params["arguments"] ?? .object([:]), agentID: clientName)
                let readOnly = AgentTools.isReadOnly(name)
                if !readOnly { onChange?() }
                return result(id!, ["content": [["type": "text", "text": .string(text)]], "isError": false])
            } catch let e as MethodNotFound {
                return error(id!, -32602, "Unknown tool: \(e.name)")
            } catch {
                let message = (error as? PlannerError)?.message ?? "\(error)"
                return result(id!, ["content": [["type": "text", "text": .string(message)]], "isError": true])
            }
        case "resources/list": return result(id!, ["resources": []])
        case "prompts/list": return result(id!, ["prompts": []])
        default:
            return error(id!, -32601, "Method not found: \(method)")
        }
    }

    func result(_ id: JSON, _ r: JSON) -> JSON { ["jsonrpc": "2.0", "id": id, "result": r] }
    func error(_ id: JSON, _ code: Int, _ message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
    /// Invalid Request (-32600) with a null id: the message or batch itself was unusable.
    func invalidRequest() -> JSON { error(.null, -32600, "Invalid Request") }

    /// Blocking stdio loop. Returns at EOF.
    public func runStdio(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) else { continue }
                let reply: JSON?
                do {
                    let msg = try JSON.parse(Data(line))
                    if case .array(let batch) = msg {
                        // An empty batch is answered with one error object, not an
                        // empty array; a batch of pure notifications stays silent.
                        if batch.isEmpty {
                            reply = invalidRequest()
                        } else {
                            let replies = batch.compactMap(handle)
                            reply = replies.isEmpty ? nil : .array(replies)
                        }
                    } else {
                        reply = handle(msg)
                    }
                } catch {
                    reply = ["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Parse error"]]
                }
                if let reply {
                    var out = reply.data()
                    out.append(0x0A)
                    output.write(out)
                }
            }
        }
    }
}
