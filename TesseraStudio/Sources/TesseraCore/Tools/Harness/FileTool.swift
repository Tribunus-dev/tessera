import Foundation

// MARK: - File tools (general-purpose harness)

/// Read a file's contents. Read-only, so risk classifies `.low` (the verb
/// "read" matches the rule-based classifier) and Part 5's productive-for-reads
/// policy auto-approves it. Returns structured data: path, content, line count,
/// detected language.
public struct FileReadTool: TesseraTool {
    public let name = "file_read"
    public let description = "Read the full contents of a file at the given path."
    public let parameters: JSONSchema = {
        let pathProp = SchemaProperty(type: "string", description: "Absolute path to the file to read.")
        return JSONSchema(type: "object", properties: ["path": pathProp], required: ["path"])
    }()
    public let defaultApprovalLevel: ApprovalLevel = .auto

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let path = arguments["path"]?.stringValue else {
            return .fail("Missing 'path' argument.")
        }
        let url = URL(fileURLWithPath: path)
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.components(separatedBy: "\n").count
            let language = FileReadTool.detectLanguage(path: path)
            return .ok(
                "\(content)",
                data: [
                    "path": .string(path),
                    "lines": .number(Double(lines)),
                    "language": .string(language)
                ]
            )
        } catch {
            return .fail("Could not read '\(path)': \(error.localizedDescription)")
        }
    }

    /// Coarse extension-based language guess for syntax context.
    static func detectLanguage(path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "python"
        case "js", "mjs": return "javascript"
        case "ts": return "typescript"
        case "cpp", "cc", "cxx": return "cpp"
        case "c", "h": return "c"
        case "rs": return "rust"
        case "go": return "go"
        case "java": return "java"
        case "json": return "json"
        case "md", "markdown": return "markdown"
        case "sql": return "sql"
        case "sh", "bash": return "shell"
        default: return "text"
        }
    }
}

/// Write (create or overwrite) a file. Mutation (`.prompt`); action-class
/// machinery classifies it `file_write:<glob>` once registered.
public struct FileWriteTool: TesseraTool {
    public let name = "file_write"
    public let description = "Create or overwrite a file with the given content."
    public let parameters: JSONSchema = {
        let pathProp = SchemaProperty(type: "string", description: "Absolute path to the file to write.")
        let contentProp = SchemaProperty(type: "string", description: "The full file contents to write.")
        return JSONSchema(type: "object", properties: ["path": pathProp, "content": contentProp], required: ["path", "content"])
    }()
    public let defaultApprovalLevel: ApprovalLevel = .prompt

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let path = arguments["path"]?.stringValue,
              let content = arguments["content"]?.stringValue else {
            return .fail("Missing 'path' or 'content' argument.")
        }
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return .ok("Wrote \(content.count) bytes to \(path).", data: ["path": .string(path)])
        } catch {
            return .fail("Could not write '\(path)': \(error.localizedDescription)")
        }
    }
}

/// Apply a search-and-replace edit to a file. The apply-patch primitive: the
/// caller supplies an exact `find` string present in the file and its
/// `replace` replacement. Returns the diff when applied.
public struct FileEditTool: TesseraTool {
    public let name = "file_edit"
    public let description = "Edit a file by replacing an exact substring (the `find` text) with new text. Fails if `find` is not present or appears more than once."
    public let parameters: JSONSchema = {
        let pathProp = SchemaProperty(type: "string", description: "Absolute path to the file to edit.")
        let findProp = SchemaProperty(type: "string", description: "The exact substring to find. Must be unique in the file.")
        let replaceProp = SchemaProperty(type: "string", description: "The replacement text.")
        return JSONSchema(type: "object", properties: ["path": pathProp, "find": findProp, "replace": replaceProp], required: ["path", "find", "replace"])
    }()
    public let defaultApprovalLevel: ApprovalLevel = .prompt

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let path = arguments["path"]?.stringValue,
              let find = arguments["find"]?.stringValue,
              let replace = arguments["replace"]?.stringValue else {
            return .fail("Missing 'path', 'find', or 'replace' argument.")
        }
        let url = URL(fileURLWithPath: path)
        do {
            var content = try String(contentsOf: url, encoding: .utf8)
            let ranges = content.ranges(of: find)
            guard !ranges.isEmpty else {
                return .fail("The `find` text was not present in \(path).")
            }
            guard ranges.count == 1 else {
                return .fail("The `find` text appeared \(ranges.count) times in \(path); it must be unique. Include more surrounding context.")
            }
            content.replaceSubrange(ranges[0], with: replace)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return .ok("Edited \(path).", data: ["path": .string(path), "find": .string(find), "replace": .string(replace)])
        } catch {
            return .fail("Could not edit '\(path)': \(error.localizedDescription)")
        }
    }
}

/// List a directory's entries. Read-only.
public struct FileListTool: TesseraTool {
    public let name = "file_list"
    public let description = "List the entries in a directory."
    public let parameters: JSONSchema = {
        let pathProp = SchemaProperty(type: "string", description: "Absolute path to the directory to list.")
        return JSONSchema(type: "object", properties: ["path": pathProp], required: ["path"])
    }()
    public let defaultApprovalLevel: ApprovalLevel = .auto

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let path = arguments["path"]?.stringValue else {
            return .fail("Missing 'path' argument.")
        }
        let url = URL(fileURLWithPath: path)
        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: path)
            let lines = entries.sorted().joined(separator: "\n")
            return .ok(lines, data: ["path": .string(path), "count": .number(Double(entries.count))])
        } catch {
            return .fail("Could not list '\(path)': \(error.localizedDescription)")
        }
    }
}

/// Glob-search files under a root by a simple wildcard pattern. Read-only.
public struct FileSearchTool: TesseraTool {
    public let name = "file_search"
    public let description = "Find files under a root directory matching a glob pattern (e.g. '**/*.swift'). Returns up to 100 matches."
    public let parameters: JSONSchema = {
        let rootProp = SchemaProperty(type: "string", description: "Absolute path to search under.")
        let patternProp = SchemaProperty(type: "string", description: "Glob pattern ('*' segment, '**' recursive).")
        return JSONSchema(type: "object", properties: ["root": rootProp, "pattern": patternProp], required: ["root", "pattern"])
    }()
    public let defaultApprovalLevel: ApprovalLevel = .auto

    public init() {}

    public func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let root = arguments["root"]?.stringValue,
              let pattern = arguments["pattern"]?.stringValue else {
            return .fail("Missing 'root' or 'pattern' argument.")
        }
        var matches: [String] = []
        let fm = FileManager.default
        let isDirGlob = pattern.contains("**")
        // Walk the tree (capped) and match each path's extension/filename
        // against the non-recursive portion of the pattern.
        let leafPattern = isDirGlob
            ? (pattern.split(separator: "/").last.map(String.init) ?? pattern)
            : pattern
        let cap = 100
        if isDirGlob {
            let enumerator = fm.enumerator(atPath: root)
            while let entry = enumerator?.nextObject() as? String {
                let leaf = (entry as NSString).lastPathComponent
                if FileSearchTool.globMatch(leafPattern, leaf) {
                    matches.append((root as NSString).appendingPathComponent(entry))
                    if matches.count >= cap { break }
                }
            }
        } else {
            if let entries = try? fm.contentsOfDirectory(atPath: root) {
                for entry in entries where FileSearchTool.globMatch(leafPattern, entry) {
                    matches.append((root as NSString).appendingPathComponent(entry))
                    if matches.count >= cap { break }
                }
            }
        }
        return .ok(matches.joined(separator: "\n"), data: ["count": .number(Double(matches.count))])
    }

    /// Minimal `*`-wildcard match (no `?`/char classes). Sufficient for the
    /// common `*.swift` / `*.py` / `*.json` cases.
    static func globMatch(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern), n = Array(name)
        return match(p, 0, n, 0)
    }

    private static func match(_ p: [Character], _ pi: Int, _ n: [Character], _ ni: Int) -> Bool {
        if pi == p.count { return ni == n.count }
        if p[pi] == "*" {
            if match(p, pi + 1, n, ni) { return true }
            if ni < n.count, match(p, pi, n, ni + 1) { return true }
            return false
        }
        if ni < n.count, p[pi] == n[ni] { return match(p, pi + 1, n, ni + 1) }
        return false
    }
}
