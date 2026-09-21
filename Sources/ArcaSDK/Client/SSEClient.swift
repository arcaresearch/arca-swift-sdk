import Foundation

/// One server-sent event: the `id:`, `event:` and joined `data:` lines of a
/// block ended by a blank line. Comment lines (`: heartbeat`) never produce
/// a frame; a block with no `data:` line is dropped, as the spec requires.
struct SSEFrame: Equatable, Sendable {
    var id: String?
    var event: String?
    var data: String
}

/// Incremental server-sent-event parser. Feed it bytes (or whole lines
/// without their terminator); it returns a frame whenever a block completes.
///
/// Bytes are split on `\n` here rather than through `AsyncBytes.lines`,
/// which never yields the empty line that terminates an SSE block — a frame
/// would then complete only when the connection closed.
struct SSEParser {
    private var id: String?
    private var event: String?
    private var data: [String] = []
    private var pending: [UInt8] = []

    /// Consume one byte of the stream. Returns a frame when the byte
    /// completed the blank line that ends a block carrying data.
    mutating func consume(byte: UInt8) -> SSEFrame? {
        guard byte == 0x0A else {
            pending.append(byte)
            return nil
        }
        if pending.last == 0x0D { pending.removeLast() }
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        return consume(line: line)
    }

    /// Consume one line. Returns a frame when the line was the blank line
    /// that ends a block carrying data.
    mutating func consume(line: String) -> SSEFrame? {
        if line.isEmpty {
            defer { id = nil; event = nil; data = [] }
            guard !data.isEmpty else { return nil }
            return SSEFrame(id: id, event: event, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") {
            return nil // comment / heartbeat
        }
        let field: Substring
        let value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var rest = line[line.index(after: colon)...]
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            value = rest
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "id": id = String(value)
        case "event": event = String(value)
        case "data": data.append(String(value))
        default: break // `retry` and unknown fields are ignored
        }
        return nil
    }
}

/// Reconnect schedule for streams: 1 s, 2 s, 4 s, … capped at 30 s — the
/// schedule the SDK's WebSocket uses.
enum SSEBackoff {
    static func delay(attempt: Int) -> TimeInterval {
        min(pow(2.0, Double(max(0, attempt))), 30)
    }
}
