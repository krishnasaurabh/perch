import Foundation

/// Data from another application, never instructions or a pre-authorized mutation.
public struct ExternalTaskRequest: Equatable, Sendable {
    public let title: String
    public let day: DayRef
    public var dateLabel: String { day.key?.raw ?? "Inbox" }
}

public enum ExternalURLRequest: Equatable, Sendable {
    case add(ExternalTaskRequest)
    case open(page: String)

    public static let maximumURLBytes = 16_384
    public static let maximumTitleBytes = 2_048

    /// A deliberately small URL grammar. Decode once, reject ambiguous fields, and resolve
    /// relative dates now so a later confirmation cannot silently change the destination.
    public static func parse(_ raw: String, now: Date, resetHour: Int = 0,
                             calendar: Calendar = .current) -> ExternalURLRequest? {
        guard raw.utf8.count <= maximumURLBytes,
              raw.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
              raw.prefix(8).lowercased() == "perch://", !raw.contains("#") else { return nil }
        let parts = raw.dropFirst(8).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let route = String(parts[0])
        guard route == "add" || route == "open" else { return nil }
        var fields: [String: String] = [:]
        if parts.count == 2 {
            guard !parts[1].isEmpty else { return nil }
            for field in parts[1].split(separator: "&", omittingEmptySubsequences: false) {
                let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, let key = decode(pair[0]), let value = decode(pair[1]),
                      !key.isEmpty, !value.isEmpty, fields[key] == nil else { return nil }
                fields[key] = value
            }
        }
        switch route {
        case "open":
            guard Set(fields.keys).isSubset(of: ["page"]) else { return nil }
            let page = fields["page"] ?? "home"
            guard ["home", "week", "clips", "insights"].contains(page) else { return nil }
            return .open(page: page)
        default:
            guard Set(fields.keys).isSubset(of: ["title", "date"]), let text = fields["title"],
                  text.utf8.count <= maximumTitleBytes, text.unicodeScalars.allSatisfy(isDisplayable) else { return nil }
            // Match the engine's literal insertion exactly; no task-language parsing follows.
            let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let date = fields["date"] ?? "today"
            guard date.utf8.count <= 10 else { return nil }
            let today = DayKey(now, resetHour: resetHour, calendar: calendar)
            let day: DayRef
            switch date {
            case "today": day = .day(today)
            case "tomorrow": day = .day(today.adding(days: 1, calendar: calendar))
            case "inbox": day = .inbox
            default:
                guard let key = DayKey(date), key >= today else { return nil }
                day = .day(key)
            }
            return .add(ExternalTaskRequest(title: title, day: day))
        }
    }

    private static func decode(_ raw: Substring) -> String? {
        let bytes = Array(raw.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25 {
                guard i + 2 < bytes.count, isHex(bytes[i + 1]), isHex(bytes[i + 2]) else { return nil }
                i += 3
            } else { i += 1 }
        }
        return String(raw).removingPercentEncoding
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private static func isDisplayable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\t" || scalar.value == 0x200d { return true } // Emoji joiner.
        // Bidi controls can disguise the title/date boundary or reverse visible content.
        let bidi: Set<UInt32> = [0x061c, 0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e,
                                0x2066, 0x2067, 0x2068, 0x2069]
        return !CharacterSet.controlCharacters.contains(scalar)
            && !CharacterSet.illegalCharacters.contains(scalar) && !bidi.contains(scalar.value)
    }
}
