import OSLog

/// Same subsystem and category as the app's `Log.audio`, so one `log stream` filter shows
/// both sides of a capture.
let audioLog = Logger(subsystem: "ai.pivotstudio.murmur", category: "audio")
