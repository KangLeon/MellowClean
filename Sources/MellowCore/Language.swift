import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system, chinese = "zh-Hans", english = "en"

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        for language in preferredLanguages {
            if language == "zh" || language.hasPrefix("zh-") { return .chinese }
            if language == "en" || language.hasPrefix("en-") { return .english }
        }
        return .english
    }

    public func text(_ chinese: String, _ english: String) -> String {
        resolved() == .chinese ? chinese : english
    }
}

// Keep operation results in both languages so changing settings also updates existing results.
public struct Message: Codable, Sendable, ExpressibleByStringLiteral {
    public let chinese: String
    public let english: String

    public init(_ chinese: String, _ english: String) {
        self.chinese = chinese
        self.english = english
    }

    public init(stringLiteral value: String) { self.init(value, value) }
    public init(verbatim value: String) { self.init(value, value) }
    public init(error: Error) {
        if case let CleanError.unsafe(message) = error { self = message }
        else { self.init(verbatim: error.localizedDescription) }
    }

    public func rendered(in language: AppLanguage = .system) -> String {
        language.text(chinese, english)
    }

    public func prefixed(_ value: String) -> Message {
        Message("\(value)：\(chinese)", "\(value): \(english)")
    }
}
