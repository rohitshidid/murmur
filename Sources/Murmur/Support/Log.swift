import OSLog

enum Log {
    static let audio = Logger(subsystem: "ai.pivotstudio.murmur", category: "audio")
    static let speech = Logger(subsystem: "ai.pivotstudio.murmur", category: "speech")
    static let hotkey = Logger(subsystem: "ai.pivotstudio.murmur", category: "hotkey")
    static let inject = Logger(subsystem: "ai.pivotstudio.murmur", category: "inject")
    static let app = Logger(subsystem: "ai.pivotstudio.murmur", category: "app")
}
