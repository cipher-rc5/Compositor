import os

extension Logger {
    /// Every log line the app writes shares one subsystem, so `log stream --predicate
    /// 'subsystem == "com.wonderassembly.compositor"'` shows them all; the category says which part wrote it.
    nonisolated static func compositor(_ category: String) -> Logger {
        Logger(subsystem: "com.wonderassembly.compositor", category: category)
    }
}
