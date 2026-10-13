import os

/// Work a tool finished off the main thread is dropped, not written, when the document changed while it ran.
/// Dropping it is right, but it shouldn't vanish without a trace.
nonisolated enum ToolLog {
    private static let logger = Logger.compositor("Tools")

    static func staleResult(_ work: String) {
        logger.notice("\(work, privacy: .public) finished after the document changed under it; the result was discarded.")
    }
}
