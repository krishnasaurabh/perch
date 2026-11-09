import Foundation
import PlannerCore

// perch-cli: the MCP server and a scriptable CLI, built from the same PlannerCore as the app.
//   perch-cli --mcp                       stdio MCP server
//   perch-cli add "text dad tomorrow 6pm" add a task (parsed like typing)
//   perch-cli list [date|inbox]
//   perch-cli <tool> '<json args>'        call any MCP tool directly

let args = Array(CommandLine.arguments.dropFirst())
let tools = AgentTools(file: PlannerFile())

func run(_ tool: String, _ a: JSON) -> Int32 {
    do {
        print(try tools.call(tool, a))
        return 0
    } catch let e as PlannerError {
        FileHandle.standardError.write(Data((e.message + "\n").utf8)); return 1
    } catch is MCPServer.MethodNotFound {
        FileHandle.standardError.write(Data("Unknown command: \(tool)\n".utf8)); return 2
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1
    }
}

switch args.first {
case "--mcp", "mcp":
    MCPServer(tools: tools, version: "1.0.0").runStdio()
case "add":
    exit(run("add_tasks", ["titles": .array(args.dropFirst().map { .string($0) })]))
case "list":
    exit(run("list_tasks", args.count > 1 ? ["date": .string(args[1])] : [:]))
case "path":
    print(PlannerFile.defaultURL.path)
case .some(let tool) where !tool.hasPrefix("-"):
    let json = args.count > 1 ? ((try? JSON.parse(Data(args[1].utf8))) ?? [:]) : [:]
    exit(run(tool, json))
default:
    print("""
        usage: perch-cli --mcp | add <task>... | list [date|inbox] | path | <tool> '<json>'
        tools: \(AgentTools.definitions.compactMap { $0["name"]?.string }.joined(separator: ", "))
        """)
}
