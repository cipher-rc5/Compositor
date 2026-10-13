import AppKit
import Testing
@testable import Compositor

/// What each modal state lets through: project operations (Save, Open…), Undo and Redo, and layer edits. The three
/// gates used to be separate `&&` chains that had drifted apart; they now come from `EditorModal`, and this pins them.
@MainActor
struct EditorGateTests {
    /// The decided matrix, written out independently of `EditorModal` so a change to it has to be made twice.
    private static let allowsProjectOperations: Set<EditorModal> = [.transform, .crop, .gradient]
    private static let allowsHistory: Set<EditorModal> = [.crop, .gradient]

    @Test func everyModalBlocksWhatTheMatrixSays() {
        for modal in EditorModal.allCases {
            #expect(modal.blocksProjectOperations == !Self.allowsProjectOperations.contains(modal), "\(modal)")
            #expect(modal.blocksHistory == !Self.allowsHistory.contains(modal), "\(modal)")
            #expect(modal.blocksLayerEdits, "\(modal)")
        }
    }

    /// A canvas with one opaque layer, so every panel and tool has pixels to work on.
    private func makeSession() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 40, height: 40)
        let context = try BrushRaster.context(width: 40, height: 40, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        return session
    }

    /// Puts a fresh session into each state the way the app does, wherever that is cheap enough to do.
    private static let states: [(EditorModal, (EditorSession) -> Void)] = [
        (.busy, { $0.isProjectBusy = true }),
        (.importing, { $0.isImporting = true }),
        (.dialog, { $0.showsNewDocument = true }),
        (.dialog, { $0.importError = "Unreadable" }),
        (.renamingLayer, { $0.renamingLayerID = $0.activeLayerID }),
        (.typing, { $0.selectTool(.type); $0.beginText(at: CGPoint(x: 5, y: 5), newLayer: true) }),
        (.selectionAmount, { $0.selectionAmountOperation = .feather }),
        (.levels, { $0.beginLevels() }),
        (.hueSaturation, { $0.beginHueSaturation() }),
        (.filter, { $0.beginFilter(.curves) }),
        (.adjustmentLayer, { $0.adjustmentEditingID = $0.activeLayerID }),
        (.pixelMove, { $0.selectAll(); _ = $0.beginPixelMove() }),
        (.transform, { $0.beginTransform() }),
        (.crop, { $0.selectTool(.crop) }),
        (.gradient, { $0.selectTool(.gradient); $0.beginGradient(at: CGPoint(x: 2, y: 2)) }),
        (.stroke, { $0.selectTool(.brush); $0.beginBrush(at: CGPoint(x: 10, y: 10)) }),
    ]

    @Test func eachStateIsTheModalItSaysAndGatesAccordingly() throws {
        for (modal, enter) in Self.states {
            let session = try makeSession()
            #expect(session.activeModals.isEmpty && session.canStartProjectOperation && session.canUseHistory
                    && session.canEditLayers)
            enter(session)
            #expect(session.activeModals == [modal], "\(modal): \(session.activeModals)")
            #expect(session.canStartProjectOperation == !modal.blocksProjectOperations, "\(modal)")
            #expect(session.canUseHistory == !modal.blocksHistory, "\(modal)")
            #expect(!session.canEditLayers, "\(modal)")
            if session.brushStroke != nil { session.cancelBrush() }
        }
    }

    /// Deliberately not a modal: the effects panel's changes are layer edits, which a modal would block. Instead it
    /// closes when its tab goes out of view (see `ProjectWorkspaceTests`).
    @Test func theEffectsPanelGatesNothing() throws {
        let session = try makeSession()
        session.addEffect(.shadow)
        #expect(session.effectsEditing != nil)
        #expect(session.activeModals.isEmpty)
        #expect(session.canStartProjectOperation && session.canUseHistory && session.canEditLayers)
    }

    /// Divergences the shared derivation closed: Undo used to stay on under an open adjustment panel, and a Save
    /// could start while Hue/Saturation or a filter was previewing.
    @Test func adjustmentPanelsHoldUndoAndSavesBack() throws {
        for open in [{ (s: EditorSession) in s.beginHueSaturation() }, { $0.beginFilter(.curves) }] {
            let session = try makeSession()
            open(session)
            #expect(!session.canUndo)
            #expect(!session.canStartProjectOperation)
        }
    }

    /// A file opened from Finder waits for the editor; closing a panel that holds it up must let it through. Watched
    /// synchronously: an awaiting task has to queue for the main actor behind every other suite, which under the
    /// sanitizers took longer than any time limit.
    @Test func closingAPanelLetsAWaitingFileRequestThrough() throws {
        let session = try makeSession()
        session.beginHueSaturation()
        var released = 0
        session.whenFileRequestsAllowed { released += 1 }
        #expect(released == 0)
        session.cancelHueSaturation()
        #expect(released == 1)
        #expect(session.canStartProjectOperation)
        // Nothing holds it up now, so a new request goes straight through.
        session.whenFileRequestsAllowed { released += 1 }
        #expect(released == 2)
    }

    /// The async form the Finder queue awaits returns at once when nothing holds it up, without suspending.
    @Test func anUnblockedFileRequestDoesNotWait() async throws {
        let session = try makeSession()
        await session.waitForFileRequest()
        #expect(session.canStartProjectOperation)
    }

    @Test func hasDocumentFollowsTheCanvasNotItsPixels() throws {
        let session = EditorSession()
        #expect(!session.hasDocument)
        session.createDocument(width: 10, height: 10)
        #expect(session.hasDocument)
        session.document = nil
        #expect(!session.hasDocument)
    }
}

/// The canvas's transparency checkerboard, drawn as one tiled image.
@MainActor
struct CheckerboardTests {
    @Test(arguments: [CGFloat(1), 2])
    func lightSquaresStartAtTheTopLeft(scale: CGFloat) throws {
        let side = Int(40 * scale)
        let space = try #require(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                             space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue))
        // Flipped, as the canvas view's context is.
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: scale, y: -scale)
        CanvasView.drawCheckerboard(anchoredAt: .zero, in: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // Rows in memory run top-down. Sample the middle of each 10-point square.
        func gray(_ column: Int, _ row: Int) -> UInt8 {
            bytes[Int((CGFloat(row) * 10 + 5) * scale) * side + Int((CGFloat(column) * 10 + 5) * scale)]
        }
        let light = gray(0, 0), dark = gray(1, 0)
        #expect(light > dark)
        for row in 0..<4 {
            for column in 0..<4 {
                #expect(gray(column, row) == ((row + column).isMultiple(of: 2) ? light : dark), "square \(column), \(row)")
            }
        }
    }
}

/// The status bar's hint follows the tool and the mode it is in.
@MainActor
struct StatusHintTests {
    @Test func everyToolHasItsOwnHint() {
        let session = EditorSession()
        var hints: [NavigationTool: String] = [:]
        for tool in NavigationTool.allCases {
            session.tool = tool
            hints[tool] = EditorStatusBar.hint(for: session)
        }
        #expect(Set(hints.values).count == NavigationTool.allCases.count)
        session.tool = .brush
        session.brushMode = .erase
        #expect(EditorStatusBar.hint(for: session).hasPrefix("Drag to erase"))
        session.tool = .shape
        session.shapeKind = .line
        #expect(EditorStatusBar.hint(for: session).contains("Shift 45°"))
    }
}
