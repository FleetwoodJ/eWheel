import AppKit

// MARK: - The job that is running now (progress and Cancel in the menu)

@MainActor
final class Job {
    let detail: String          // "Convert to MP4"
    let subject: String         // "Holiday.mov" or "3 files"
    /// 0…1 when known; nil while it can't be measured (shown as "Working…").
    var fraction: Double?
    var task: Task<Void, Never>?
    private(set) var cancelled = false
    /// False while an interactive item (Trim) is still waiting for the user.
    var began = false

    init(detail: String, files: [URL]) {
        self.detail = detail
        subject = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
    }

    func cancel() {
        cancelled = true
        task?.cancel()
    }

    var menuTitle: String {
        let pct = fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
        return "\(detail): \(subject)…\(pct)"
    }

    /// The job shown in the menu (the most recent one still running).
    static var current: Job?
    /// The menu-bar icon, so an interactive job can start spinning once confirmed.
    static weak var status: StatusAnimator?
}

/// Converters call `report` with their own progress; it reaches the menu.
enum JobProgress {
    /// Set for each file of a multi-file job, which reports files done instead.
    @TaskLocal static var muted = false

    /// An interactive item calls this once the user has confirmed (e.g. clicked Trim).
    static func begin() {
        Task { @MainActor in
            guard let job = Job.current, !job.began else { return }
            job.began = true
            Job.status?.begin()
        }
    }

    static func report(_ fraction: Double) {
        guard !muted else { return }
        let f = min(max(fraction, 0), 1)
        Task { @MainActor in Job.current?.fraction = f }
    }
}

// MARK: - Recent conversions and Undo

struct HistoryEntry {
    let detail: String
    let outputs: [URL]
    let date: Date

    var existing: [URL] { outputs.filter { FileManager.default.fileExists(atPath: $0.path) } }

    var menuTitle: String {
        guard let first = existing.first ?? outputs.first else { return detail }
        let more = outputs.count > 1 ? " +\(outputs.count - 1)" : ""
        return "\(detail): \(first.lastPathComponent)\(more)"
    }
}

/// The last five conversions that made files. Undo moves the newest one's files to the Bin.
@MainActor
final class History {
    static let shared = History()
    /// How Undo removes files: to the Bin. The self-test swaps this so it never touches your Bin.
    var recycle: @MainActor ([URL]) async throws -> Void = { _ = try await NSWorkspace.shared.recycle($0) }
    private(set) var entries: [HistoryEntry] = []

    func add(_ detail: String, outputs: [URL]) {
        guard !outputs.isEmpty else { return }
        entries.insert(HistoryEntry(detail: detail, outputs: outputs, date: Date()), at: 0)
        if entries.count > 5 { entries.removeLast(entries.count - 5) }
    }

    /// Drops entries whose files have all been deleted or moved away.
    func prune() {
        entries.removeAll { $0.existing.isEmpty }
    }

    func reveal(_ index: Int) {
        prune()
        guard entries.indices.contains(index) else { return }
        NSWorkspace.shared.activateFileViewerSelecting(entries[index].existing)
    }

    /// Moves the newest conversion's files to the Bin (recoverable, never deleted outright).
    func undoLast() async throws -> String {
        prune()
        guard let entry = entries.first else { return "Nothing to undo" }
        try await recycle(entry.existing)
        entries.removeFirst()
        Log.wheel.notice("undo: moved \(entry.existing.count) file(s) from \"\(entry.detail)\" to the Bin")
        return "Moved \(entry.outputs.count == 1 ? entry.outputs[0].lastPathComponent : "\(entry.outputs.count) files") to the Bin"
    }
}
