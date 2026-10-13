import Foundation
import CoreGraphics
import Observation

/// Value snapshots share immutable CGImages; no pixel copies for layer edits.
@Observable
final class DocumentHistory {
    struct Snapshot {
        let document: CanvasDocument?
        let activeLayerID: UUID?
        let revision: UUID
    }
    private struct Entry {
        let name: String
        let before: Snapshot
        let after: Snapshot
        /// Set while later edits of the same kind may still fold into this entry (see `begin`'s `coalescing`).
        var coalescing: AnyHashable?
        /// Every image either snapshot holds, once each, with its size: counted when the entry is made, so the byte
        /// limit never walks the whole history again.
        let images: [ObjectIdentifier: Int]
        init(name: String, before: Snapshot, after: Snapshot, coalescing: AnyHashable? = nil) {
            self.name = name; self.before = before; self.after = after; self.coalescing = coalescing
            var images: [ObjectIdentifier: Int] = [:]
            for snapshot in [before, after] {
                DocumentHistory.forEachImage(in: snapshot.document) { images[ObjectIdentifier($0)] = $0.bytesPerRow * $0.height }
            }
            self.images = images
        }
    }
    private var past: [Entry] = []
    private var future: [Entry] = []
    /// How many entries hold each image, and the bytes of every image any entry holds, counted once however many
    /// entries share it. Kept up to date as entries come and go.
    @ObservationIgnored private var holders: [ObjectIdentifier: (entries: Int, bytes: Int)] = [:]
    @ObservationIgnored private var heldBytes = 0
    /// Changes with every edit, undo and redo; crash recovery compares it to skip rewriting an unchanged snapshot.
    private(set) var revision = UUID()
    private var savedRevision: UUID?
    private var pending: Snapshot?
    private var pendingName = "Edit"
    private var pendingCoalescing: AnyHashable?
    private var depth = 0
    let entryLimit: Int
    let retainedByteLimit: Int

    init(entryLimit: Int = 100, retainedByteLimit: Int = 256 * 1024 * 1024) {
        self.entryLimit = max(0, entryLimit)
        self.retainedByteLimit = max(0, retainedByteLimit)
        savedRevision = revision
    }

    var canUndo: Bool { depth == 0 && !past.isEmpty }
    var canRedo: Bool { depth == 0 && !future.isEmpty }
    var undoName: String { past.last?.name ?? "" }
    var redoName: String { future.last?.name ?? "" }
    var isModified: Bool { revision != savedRevision }
    var undoCount: Int { past.count }
    func markSaved() { savedRevision = revision }
    /// Unsaved whatever is undone or redone, until the next save: a document restored after a crash.
    func markUnsaved() { savedRevision = nil }
    func reset() {
        past.removeAll()
        future.removeAll()
        holders.removeAll()
        heldBytes = 0
        pending = nil
        pendingCoalescing = nil
        depth = 0
        revision = UUID()
        savedRevision = revision
    }

    /// An edit made with a `coalescing` key folds into the last entry when that entry was made with the same key
    /// and nothing has happened since, so a panel whose every slider tick is an edit leaves one step to undo, not a
    /// hundred that push everything else out of the history. `stopCoalescing` closes the entry to later edits.
    func begin(_ name: String, document: CanvasDocument?, selection: UUID?, coalescing: AnyHashable? = nil) {
        if depth == 0 {
            pending = Snapshot(document: document, activeLayerID: selection, revision: revision)
            pendingName = name
            pendingCoalescing = coalescing
        }
        depth += 1
    }

    func end(document: CanvasDocument?, selection: UUID?) {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0, let before = pending else { return }
        pending = nil
        let key = pendingCoalescing
        pendingCoalescing = nil
        // Selecting, navigating, and no-op edits must preserve redo history.
        guard before.document != document else { return }
        if let key, future.isEmpty, let last = past.last, last.coalescing == key, last.after.revision == before.revision {
            past.removeLast()
            release(last)
            // Back where the entry began, as when a panel's changes are all cancelled: nothing is left to undo, and
            // the document is as unmodified as it was then.
            guard last.before.document != document else {
                revision = last.before.revision
                return
            }
            revision = UUID()
            let entry = Entry(name: last.name, before: last.before,
                after: Snapshot(document: document, activeLayerID: selection, revision: revision), coalescing: key)
            past.append(entry)
            hold(entry)
            trim(current: document)
            return
        }
        revision = UUID()
        let entry = Entry(name: pendingName, before: before,
            after: Snapshot(document: document, activeLayerID: selection, revision: revision), coalescing: key)
        past.append(entry)
        hold(entry)
        future.forEach(release)
        future.removeAll()
        trim(current: document)
    }

    /// The last entry takes no more edits into it; the next one with the same key starts an entry of its own.
    func stopCoalescing() {
        guard !past.isEmpty else { return }
        past[past.count - 1].coalescing = nil
    }

    func undo() -> Snapshot? {
        guard canUndo, var entry = past.popLast() else { return nil }
        entry.coalescing = nil
        future.append(entry)
        revision = entry.before.revision
        trim(current: entry.before.document)
        return entry.before
    }

    func redo() -> Snapshot? {
        guard canRedo, let entry = future.popLast() else { return nil }
        past.append(entry)
        revision = entry.after.revision
        trim(current: entry.after.document)
        return entry.after
    }

    /// Bytes retained only by history, excluding images in the live document.
    func retainedBytes(current: CanvasDocument?) -> Int { retained(excluding: Self.imageIDs(in: current)) }

    /// The byte limit never takes the last step: an edit to one very large image can exceed it by itself, and
    /// dropping the step just made would leave nothing to undo, with no sign anything was lost.
    private func trim(current: CanvasDocument?) {
        let live = Self.imageIDs(in: current)
        while past.count + future.count > entryLimit
                || (past.count + future.count > 1 && retained(excluding: live) > retainedByteLimit) {
            if !past.isEmpty { release(past.removeFirst()) }
            else if !future.isEmpty { release(future.removeFirst()) }
            else { break }
        }
    }

    private func retained(excluding live: Set<ObjectIdentifier>) -> Int {
        heldBytes - live.reduce(0) { $0 + (holders[$1]?.bytes ?? 0) }
    }

    private func hold(_ entry: Entry) {
        for (id, bytes) in entry.images {
            if let held = holders[id] { holders[id] = (held.entries + 1, held.bytes) }
            else { holders[id] = (1, bytes); heldBytes += bytes }
        }
    }

    /// An image stops counting once the last entry holding it is gone; the entries alone keep it alive, so its
    /// identifier can't be reused for another image while it is still listed.
    private func release(_ entry: Entry) {
        for id in entry.images.keys {
            guard let held = holders[id] else { continue }
            if held.entries > 1 { holders[id] = (held.entries - 1, held.bytes) }
            else { holders[id] = nil; heldBytes -= held.bytes }
        }
    }

    private static func imageIDs(in document: CanvasDocument?) -> Set<ObjectIdentifier> {
        var ids = Set<ObjectIdentifier>()
        forEachImage(in: document) { ids.insert(ObjectIdentifier($0)) }
        return ids
    }

    /// Every layer's pixels and mask, and their thumbnails. A painted layer's pixels are its raster snapshot's
    /// base and tiles, which successive paint steps share: counting its whole-image view instead charged every step
    /// the full size of the layer, so a large photo kept only a couple of steps after painting. That view holds no
    /// pixels of its own until something asks for its bytes.
    private static func forEachImage(in document: CanvasDocument?, _ body: (CGImage) -> Void) {
        for layer in document?.layers ?? [] {
            for asset in [layer.asset, layer.mask?.asset].compactMap({ $0 }) {
                if let raster = asset.raster {
                    if let base = raster.base { body(base) }
                    for patch in raster.patches { body(patch.image) }
                } else {
                    body(asset.image)
                }
                body(asset.thumbnail)
            }
        }
    }
}
