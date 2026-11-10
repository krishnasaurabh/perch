import Foundation

/// What typing or speaking a task line produces.
public struct CapturedTask: Equatable, Sendable {
    public var title: String
    /// nil means "not named": the caller decides (usually today). Use `inbox` for the Inbox.
    public var day: DayKey?
    public var inbox: Bool = false
    public var remindAt: Date?
    public var deadline: DayKey?
    public var priority: TaskPriority = .none
    public var projectName: String?
    public var repeatRule: TaskRepeat?
    public var minutes: Int?
}

/// Natural-language task capture: "water plants tomorrow at 6pm !high #home every tuesday for 25 min".
///
/// Only explicit metadata is removed; quoted text and title casing are preserved.
public struct TaskCapture {
    public let now: Date
    public let calendar: Calendar
    public let resetHour: Int

    public init(now: Date = Date(), resetHour: Int = 0, calendar: Calendar = .current) {
        self.now = now; self.calendar = calendar; self.resetHour = min(23, max(0, resetHour))
    }

    var today: DayKey { DayKey(now, resetHour: resetHour, calendar: calendar) }

    // MARK: Patterns

    private static func re(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    static let months = "january|february|march|april|may|june|july|august|september|sept|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec"
    static let dayLead = "(?:\\b(?:on|by|for|due|until)\\s+)?"

    static let timeAmPm = re("(?:\\b(?:at|by|around)\\s+|@\\s*)?(?<!:)\\b(\\d{1,2})(?::(\\d{2}))?\\s*(a\\.?m\\.?|p\\.?m\\.?)(?![a-z])")
    static let timeWords = re("(?:\\b(?:at|by|around)\\s+|@\\s*)?\\b(noon|midday|midnight)\\b")
    // Bare numbers followed by currency or quantity units are part of the title, not a clock time.
    static let timeBare = re("(?:\\b(?:at|by|around)\\s+|@\\s*)(\\d{1,2})(?::(\\d{2}))?\\b(?!:)(?!\\s*(?:%|percent|pages?|mins?|minutes?|hours?|hrs?|days?|dollars?|cents?|euros?|pounds?|rupees?|yen|usd|eur|gbp|inr|km|kg|lbs?|grams?|kilograms?|ounces?|oz|meters?|metres?|kilometers?|kilometres?|miles?|liters?|litres?|ml)\\b)")
    static let time24 = re("(?:\\b(?:at|by|around)\\s+|@\\s*)(\\d{1,2}):(\\d{2})\\b(?!:)")
    static let relative = re("\\bin\\s+(?:(half)\\s+an\\s+hour|(\\d{1,4}|an?|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty|thirty|forty-five|forty|fifty)\\s+(mins?|minutes?|hrs?|hours?))\\b")
    static let duration = re("(?:\\bfor\\s+|~\\s*|\\(\\s*)(\\d{1,3}(?:\\.\\d)?)\\s*(m|mins?|minutes?|h|hrs?|hours?)\\b\\)?")
    static let dayAfterTomorrow = re(dayLead + "\\b(?:the\\s+)?day\\s+after\\s+tomorrow\\b")
    static let todayWords = re(dayLead + "\\b(today|tonight|this\\s+evening)\\b")
    static let tomorrowWords = re(dayLead + "\\b(tomorrow|tmrw|tmr)\\b")
    static let inDays = re("\\bin\\s+(\\d{1,3}|an?|one|two|three|four|five|six|seven|eight|nine|ten)\\s+(days?|weeks?)\\b")
    static let monthDay = re(dayLead + "\\b(" + months + ")\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b(?:,?\\s+(\\d{4})\\b)?")
    static let dayMonth = re(dayLead + "\\b(?:the\\s+)?(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?(" + months + ")\\.?(?:,?\\s+(\\d{4})\\b)?")
    static let onThe = re("\\bon\\s+the\\s+(\\d{1,2})(?:st|nd|rd|th)\\b")
    static let weekdayLong = re("\\b(on|this|next)\\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\\b")
    static let weekdayLongDeadline = re("\\b(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\\b")
    static let weekdayShort = re("\\b(?:(on|this|next)\\s+)(sun|mon|tues?|wed|thu(?:rs?)?|fri|sat)\\b\\.?")
    static let weekdayShortDeadline = re("\\b(sun|mon|tues?|wed|thu(?:rs?)?|fri|sat)\\b\\.?")
    static let isoDate = re(dayLead + "\\b(\\d{4})-(\\d{2})-(\\d{2})\\b")
    static let deadlineLead = re("\\b(?:due(?:\\s+date)?|deadline)(?:\\s*:\\s*|\\s+)")
    static let project = re("(?:^|\\s)#([A-Za-z][\\w-]*)")
    static let priority = re("(?:^|\\s)(!!!|!!|!high|!urgent|!medium|!med|!low|!)(?=\\s|$)")
    static let inbox = re("(?:^|\\s)#inbox(?![\\w-])|\\bsomeday\\b")
    static let leadingConnector = re("^\\s*(?:(?:and|then|also|plus)\\s+)+")
    static let bullet = re("^\\s*(?:[-*•]|\\d{1,2}[.)])\\s+")

    static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
        "forty-five": 45, "fifty": 50,
    ]

    // MARK: Parse

    /// Parse one task line.
    public func parse(_ input: String) -> CapturedTask {
        var text = Self.cleanLine(input)
        var out = CapturedTask(title: "")

        // Repeat ("every monday") before weekday parsing so "monday" isn't read as a day.
        if let (rule, range) = TaskRepeat.find(in: Self.unquoted(text)) {
            out.repeatRule = rule
            text = Self.remove(range, from: text)
        }
        // Deadline: "due friday", "deadline: nov 20".
        if let lead = Self.first(Self.deadlineLead, in: text) {
            let tail = lead.range.location + lead.range.length
            if let (day, range) = matchDay(in: text, anchoredAt: lead.range.location...tail) {
                out.deadline = day
                let start = min(lead.range.location, range.location)
                let full = NSRange(location: start, length: range.location + range.length - start)
                text = Self.remove(full, from: text)
            }
        }
        if let m = Self.first(Self.inbox, in: text) {
            out.inbox = true
            text = Self.remove(m.range, from: text)
        }
        if let m = Self.first(Self.priority, in: text) {
            out.priority = Self.priority(token: Self.group(m, 1, text)!)
            text = Self.remove(m.range, from: text)
        }
        if let m = Self.first(Self.project, in: text) {
            out.projectName = Self.group(m, 1, text)
            text = Self.remove(m.range, from: text)
        }
        if let m = Self.first(Self.duration, in: text) {
            let n = Double(Self.group(m, 1, text)!) ?? 0
            let unit = Self.group(m, 2, text)!.lowercased()
            let mins = unit.hasPrefix("h") ? Int((n * 60).rounded()) : Int(n.rounded())
            if mins > 0 { out.minutes = min(mins, 720) }
            text = Self.remove(m.range, from: text)
        }

        var explicitDay: DayKey?
        var time: (h: Int, m: Int)?

        if let m = Self.first(Self.relative, in: text) {
            let mins: Int
            if Self.group(m, 1, text) != nil { mins = 30 } else {
                let raw = Self.group(m, 2, text)!.lowercased()
                let n = Int(raw) ?? Self.numberWords[raw] ?? 1
                mins = Self.group(m, 3, text)!.lowercased().hasPrefix("h") ? n * 60 : n
            }
            out.remindAt = now.addingTimeInterval(Double(mins) * 60)
            explicitDay = DayKey(out.remindAt!, resetHour: resetHour, calendar: calendar)
            text = Self.remove(m.range, from: text)
        } else if let (t, range) = matchTime(in: text) {
            time = t
            text = Self.remove(range, from: text)
        }

        if let (day, range) = matchDay(in: text, anchoredAt: nil) {
            explicitDay = day
            text = Self.remove(range, from: text)
        }

        if let t = time {
            var day = explicitDay ?? today
            var at = day.reminderDate(hour: t.h, minute: t.m, resetHour: resetHour, calendar: calendar)
            if explicitDay == nil && at <= now {
                // "call mom at 9am" typed at 3pm means tomorrow morning.
                day = today.adding(days: 1, calendar: calendar)
                at = day.reminderDate(hour: t.h, minute: t.m, resetHour: resetHour, calendar: calendar)
            }
            out.remindAt = at
            explicitDay = day
        }

        out.day = out.inbox ? nil : explicitDay
        out.title = Self.tidy(text)
        if out.title.isEmpty { out.title = input.trimmingCharacters(in: .whitespacesAndNewlines) }
        return out
    }

    /// Split pasted or dictated text into task lines.
    public static func splitLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { cleanLine(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Strip explicit list bullets; leading connectors are list syntax only after a bullet.
    public static func cleanLine(_ s: String) -> String {
        var t = s
        if first(bullet, in: t) != nil {
            for r in [bullet, leadingConnector] {
                t = r.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Time

    func matchTime(in text: String) -> ((h: Int, m: Int), NSRange)? {
        if let m = Self.first(Self.timeAmPm, in: text) {
            var h = Int(Self.group(m, 1, text)!)!
            let mm = Int(Self.group(m, 2, text) ?? "0")!
            let pm = Self.group(m, 3, text)!.lowercased().hasPrefix("p")
            guard (1...12).contains(h), (0...59).contains(mm) else { return nil }
            if pm && h != 12 { h += 12 }
            if !pm && h == 12 { h = 0 }
            return ((h, mm), m.range)
        }
        if let m = Self.first(Self.timeWords, in: text) {
            let w = Self.group(m, 1, text)!.lowercased()
            return ((w == "midnight" ? 0 : 12, 0), m.range)
        }
        if let m = Self.first(Self.time24, in: text) {
            let h = Int(Self.group(m, 1, text)!)!, mm = Int(Self.group(m, 2, text)!)!
            guard (0...23).contains(h), (0...59).contains(mm) else { return nil }
            // "at 5:30" with no am/pm: read 1-7 as afternoon.
            return ((h >= 1 && h <= 7 ? h + 12 : h, mm), m.range)
        }
        if let m = Self.first(Self.timeBare, in: text) {
            let h = Int(Self.group(m, 1, text)!)!
            let mm = Int(Self.group(m, 2, text) ?? "0")!
            guard (0...23).contains(h), (0...59).contains(mm) else { return nil }
            return ((h >= 1 && h <= 7 ? h + 12 : h, mm), m.range)
        }
        return nil
    }

    // MARK: Days

    /// Finds a day phrase. With `anchoredAt`, only a phrase starting in that span counts (for "due ...").
    func matchDay(in text: String, anchoredAt anchor: ClosedRange<Int>?) -> (DayKey, NSRange)? {
        let resolvers: [(NSRegularExpression, (NSTextCheckingResult) -> DayKey?)] = [
            (Self.isoDate, { m in DayKey(String(format: "%@-%@-%@", Self.group(m, 1, text)!, Self.group(m, 2, text)!, Self.group(m, 3, text)!)) }),
            (Self.dayAfterTomorrow, { _ in self.today.adding(days: 2, calendar: self.calendar) }),
            (Self.todayWords, { _ in self.today }),
            (Self.tomorrowWords, { _ in self.today.adding(days: 1, calendar: self.calendar) }),
            (Self.inDays, { m in
                let raw = Self.group(m, 1, text)!.lowercased()
                let n = Int(raw) ?? Self.numberWords[raw] ?? 1
                let weeks = Self.group(m, 2, text)!.lowercased().hasPrefix("w")
                return self.today.adding(days: weeks ? n * 7 : n, calendar: self.calendar)
            }),
            (Self.monthDay, { m in self.resolve(month: Self.group(m, 1, text)!, day: Self.group(m, 2, text)!, year: Self.group(m, 3, text)) }),
            (Self.dayMonth, { m in self.resolve(month: Self.group(m, 2, text)!, day: Self.group(m, 1, text)!, year: Self.group(m, 3, text)) }),
            (Self.onThe, { m in self.resolve(dayOfMonth: Int(Self.group(m, 1, text)!)!) }),
            (Self.weekdayLong, { m in self.resolve(weekday: Self.group(m, 2, text)!, modifier: Self.group(m, 1, text)) }),
            (Self.weekdayShort, { m in self.resolve(weekday: Self.group(m, 2, text)!, modifier: Self.group(m, 1, text)) }),
        ] + (anchor == nil ? [] : [
            (Self.weekdayLongDeadline, { m in self.resolve(weekday: Self.group(m, 1, text)!, modifier: nil) }),
            (Self.weekdayShortDeadline, { m in self.resolve(weekday: Self.group(m, 1, text)!, modifier: nil) }),
        ])
        for (regex, resolve) in resolvers {
            let ns = text as NSString
            for m in regex.matches(in: Self.unquoted(text), range: NSRange(location: 0, length: ns.length)) {
                if let a = anchor {
                    guard a.contains(m.range.location) else { continue }
                }
                if let d = resolve(m) { return (d, m.range) }
            }
        }
        return nil
    }

    func resolve(weekday: String, modifier: String?) -> DayKey? {
        guard let target = TaskRepeat.weekdayIndex(weekday) else { return nil }
        let current = today.weekday(calendar: calendar)
        var delta = (target - current + 7) % 7
        if modifier?.lowercased() == "next" { delta = delta == 0 ? 7 : delta + 7 }
        return today.adding(days: delta, calendar: calendar)
    }

    func resolve(month: String, day: String, year: String?) -> DayKey? {
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let mi = names.firstIndex(of: String(month.lowercased().prefix(3))), let d = Int(day), (1...31).contains(d) else { return nil }
        let thisYear = calendar.component(.year, from: today.date(calendar: calendar))
        let firstYear = year.flatMap(Int.init) ?? thisYear
        // A Gregorian leap day can be eight years away across a non-leap century.
        // Reconstruct each candidate: adding a year to Feb 29 can silently clamp to Feb 28.
        let lastYear = year == nil ? firstYear + 8 : firstYear
        for candidateYear in firstYear...lastYear {
            guard let date = calendar.date(from: DateComponents(year: candidateYear, month: mi + 1, day: d)) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard parts.year == candidateYear, parts.month == mi + 1, parts.day == d else { continue }
            let key = DayKey(date, calendar: calendar)
            if year != nil || key >= today { return key }
        }
        return nil
    }

    func resolve(dayOfMonth d: Int) -> DayKey? {
        guard (1...31).contains(d) else { return nil }
        var comps = calendar.dateComponents([.year, .month], from: today.date(calendar: calendar))
        for _ in 0..<12 {
            comps.day = d
            if let date = calendar.date(from: comps), calendar.component(.day, from: date) == d {
                let key = DayKey(date, calendar: calendar)
                if key >= today { return key }
            }
            comps.day = 1
            let next = calendar.date(byAdding: .month, value: 1, to: calendar.date(from: comps)!)!
            comps = calendar.dateComponents([.year, .month], from: next)
        }
        return nil
    }

    // MARK: Helpers

    static func priority(token: String) -> TaskPriority {
        switch token.lowercased() {
        case "!!!", "!high", "!urgent": return .high
        case "!!", "!medium", "!med": return .medium
        default: return .low
        }
    }

    static func first(_ r: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        r.firstMatch(in: unquoted(text), range: NSRange(location: 0, length: (text as NSString).length))
    }

    static func group(_ m: NSTextCheckingResult, _ i: Int, _ text: String) -> String? {
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : (text as NSString).substring(with: r)
    }

    static func remove(_ r: NSRange, from text: String) -> String {
        let ns = text as NSString
        var start = r.location, end = NSMaxRange(r)
        let whitespace = CharacterSet.whitespacesAndNewlines
        while start > 0, let scalar = UnicodeScalar(ns.character(at: start - 1)), whitespace.contains(scalar) { start -= 1 }
        while end < ns.length, let scalar = UnicodeScalar(ns.character(at: end)), whitespace.contains(scalar) { end += 1 }
        let separator = start > 0 && end < ns.length ? " " : ""
        return ns.replacingCharacters(in: NSRange(location: start, length: end - start), with: separator)
    }

    /// Preserve title spelling, punctuation and interior whitespace.
    static func tidy(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mask quoted spans without changing UTF-16 offsets used by Foundation regexes.
    /// Quote marks remain title text. An unmatched opening quote protects the rest of the line.
    static func unquoted(_ text: String) -> String {
        guard text.contains(where: { $0 == "\"" || $0 == "“" || $0 == "'" || $0 == "‘" }) else { return text }
        var masked = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let previous = index == text.startIndex ? nil : text[text.index(before: index)]
            let singleQuote = character == "'" || character == "‘"
            let wordApostrophe = singleQuote && previous.map { $0.isLetter || $0.isNumber } == true
            guard character == "\"" || character == "“" || (singleQuote && !wordApostrophe) else {
                masked.append(character)
                index = text.index(after: index)
                continue
            }
            let closing: Character = character == "“" ? "”" : (character == "‘" ? "’" : character)
            let start = index
            index = text.index(after: index)
            while index < text.endIndex {
                let current = text[index]
                index = text.index(after: index)
                if current == "\\", index < text.endIndex {
                    index = text.index(after: index)
                } else if current == closing {
                    // An apostrophe within a quoted word is not the closing delimiter.
                    if (current == "'" || current == "’"), index < text.endIndex, text[index].isLetter {
                        let beforeQuote = text.index(index, offsetBy: -2)
                        if text[beforeQuote].isLetter { continue }
                    }
                    break
                }
            }
            masked += String(repeating: "\u{FFFC}", count: text[start..<index].utf16.count)
        }
        return masked
    }
}
