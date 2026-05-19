import Foundation

/// Reads claude code's per-session JSONL transcript and produces a stream of
/// `Message` values for the Pager Watch live JSONL view (Phase 3 of the
/// stream-json migration).
///
/// Each line in the transcript is one event. We care about:
///   - `type: "user"`     — user turns. `message.content` is either a String
///                          (early format) or `[{type, text}]` block array
///                          (newer format with attachments / tool results).
///   - `type: "assistant"` — assistant turns. Same `content` shape but with
///                          tool_use / tool_result blocks interspersed.
///   - `type: "attachment"` — system attachments (hook output, etc.). Hidden
///                          from the bubble view; they pollute the UX and
///                          add no signal.
///
/// Everything else (queue-operation, last-prompt, permission-mode, system
/// init) is skipped — internal machinery, not user-visible.
///
/// Path encoding mirrors agent/topic-wrapper.sh:claude_project_dir_encode —
/// see `Self.encodeProjectDir` for the rule.
enum JsonlReader {

    /// A single user or assistant turn rendered as a bubble.
    struct Message: Identifiable, Equatable {
        let id: String       // event uuid; stable across re-reads
        let role: Role
        let text: String     // concatenated text blocks; empty for tool-only turns
        let toolNames: [String] // names of tools claude invoked during this turn
        let timestamp: Date?

        enum Role: Equatable { case user, assistant }
    }

    /// Encode a CWD into the directory name claude code uses under
    /// ~/.claude/projects. Rule: any byte outside [a-zA-Z0-9-] → '-'.
    /// Mirror of agent/topic-wrapper.sh's `claude_project_dir_encode` (which
    /// uses `LC_ALL=C sed` — i.e. byte-level substitution, not codepoint-
    /// level). For ASCII paths this is identical to per-character iteration;
    /// for paths containing multi-byte UTF-8 sequences (CJK, accented Latin)
    /// each byte becomes its own dash so the encoded name matches what claude
    /// code writes to disk.
    static func encodeProjectDir(_ cwd: String) -> String {
        var out = ""
        out.reserveCapacity(cwd.utf8.count)
        for byte in cwd.utf8 {
            let isAlnum = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D
            out.append(isAlnum ? Character(UnicodeScalar(byte)) : "-")
        }
        return out
    }

    /// Resolve the JSONL path for a given project + session UUID under a
    /// claude-home (~/.claude by default).
    static func transcriptPath(projectPath: String, sessionUuid: String, claudeHome: URL? = nil) -> URL {
        let home = claudeHome ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude", isDirectory: true)
        return home
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encodeProjectDir(projectPath), isDirectory: true)
            .appendingPathComponent("\(sessionUuid).jsonl", isDirectory: false)
    }

    /// Parse the full transcript at the given path. Returns an empty array
    /// when the file is missing — the session hasn't started yet, not an
    /// error condition. Partial / malformed last line is tolerated (claude
    /// occasionally truncates while writing).
    static func parseTranscript(at path: URL) -> [Message] {
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return parseTranscript(text)
    }

    /// Parse a transcript string. Pure — exposed for tests.
    static func parseTranscript(_ text: String) -> [Message] {
        var messages: [Message] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue } // partial / malformed line
            guard let role = parseRole(raw) else { continue }
            // Extract text + tool names from the message.content blocks.
            let (text, tools) = extractTextAndTools(raw)
            // Skip purely-empty rows that have neither text nor a tool call —
            // they're usually intermediate placeholder events.
            if text.isEmpty && tools.isEmpty { continue }
            let id = (raw["uuid"] as? String) ?? UUID().uuidString
            let ts = parseTimestamp(raw["timestamp"] as? String)
            messages.append(Message(id: id, role: role, text: text, toolNames: tools, timestamp: ts))
        }
        return messages
    }

    private static func parseRole(_ raw: [String: Any]) -> Message.Role? {
        guard let t = raw["type"] as? String else { return nil }
        switch t {
        case "user":      return .user
        case "assistant": return .assistant
        default:          return nil
        }
    }

    /// Pull readable text and tool-use names out of a single JSONL row. The
    /// content shape varies:
    ///   - `content: "plain string"` (early format)
    ///   - `content: [{type:"text", text:"..."}, {type:"tool_use", name:"Bash", input:{...}}, ...]`
    ///   - `content: [{type:"tool_result", tool_use_id:"…", content:"…"}]` (user role on tool results)
    /// Tool results are visible only via tool name (mirror of the assistant's
    /// previous tool_use) — we don't want to dump file diffs and Bash output
    /// into a "user" bubble.
    private static func extractTextAndTools(_ raw: [String: Any]) -> (text: String, tools: [String]) {
        guard let message = raw["message"] as? [String: Any] else {
            return ("", [])
        }
        // Plain-string content variant.
        if let plain = message["content"] as? String {
            return (plain, [])
        }
        guard let blocks = message["content"] as? [[String: Any]] else {
            return ("", [])
        }
        var textParts: [String] = []
        var tools: [String] = []
        for block in blocks {
            let type = block["type"] as? String ?? ""
            switch type {
            case "text":
                if let s = block["text"] as? String, !s.isEmpty {
                    textParts.append(s)
                }
            case "tool_use":
                if let name = block["name"] as? String {
                    tools.append(name)
                }
            default:
                continue // skip tool_result, thinking, redacted_thinking, etc.
            }
        }
        return (textParts.joined(separator: "\n\n"), tools)
    }

    private static func parseTimestamp(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // Older entries might omit fractional seconds.
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}
