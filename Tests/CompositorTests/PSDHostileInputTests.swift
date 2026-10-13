import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Damaged and adversarial Photoshop files: every one must be refused with an error, never trap, and
/// anything that does read must come in as a document a project can save.
@MainActor
struct PSDHostileInputTests {
    private func colorImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func grayImage(width: Int, height: Int, value: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: value, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func layer(_ name: String, parent: UUID? = nil, at origin: CGPoint = .zero, size: Int = 2,
                       mask: CGImage? = nil) throws -> PSDRecord {
        var record = PSDRecord(id: UUID(), parentID: parent, name: name)
        record.bounds = CGRect(origin: origin, size: CGSize(width: size, height: size))
        record.image = try colorImage(width: size, height: size, red: 1, green: 0.5, blue: 0)
        record.mask = mask
        return record
    }

    private func folder(_ name: String, parent: UUID? = nil) -> PSDRecord {
        var record = PSDRecord(id: UUID(), parentID: parent, name: name)
        record.isGroup = true
        record.blendKey = "pass"
        return record
    }

    private func file(_ layers: [PSDRecord], width: Int = 4, height: Int = 4) throws -> Data {
        let composite = try colorImage(width: width, height: height, red: 0, green: 0, blue: 0)
        return try PSDFixture.data(PSDDocument(width: width, height: height, resolution: 72, layers: layers), composite: composite)
    }

    /// One plain layer; a folder with a masked base and a clipped layer; several layers over a wider canvas.
    private func fixtures() throws -> [(name: String, data: Data)] {
        let stack = folder("Stack")
        var clipped = try layer("Clipped", parent: stack.id)
        clipped.clipping = true
        return [
            ("single", try file([try layer("Sky", size: 4)])),
            ("grouped", try file([stack, try layer("Base", parent: stack.id, mask: try grayImage(width: 2, height: 2, value: 0.5)), clipped])),
            ("wide", try file((0..<5).map { try layer("Layer \($0)", at: CGPoint(x: $0 * 3, y: 1), size: 3) }, width: 16, height: 6)),
        ]
    }

    @Test func everyPrefixOfEveryFixtureIsRejected() throws {
        for fixture in try fixtures() {
            let data = fixture.data
            _ = try PSDReader.read(data)
            // Fixtures are small; the stride only keeps a larger one from slowing the suite.
            for count in stride(from: 0, to: data.count, by: max(1, data.count / 4_000)) {
                #expect(throws: PSDError.truncated, "\(fixture.name): prefix of \(count) of \(data.count) bytes") {
                    try PSDReader.read(data.prefix(count))
                }
            }
        }
    }

    // MARK: Lengths that lie

    /// Where things are in a fixture with no color-mode data, so tests can corrupt one field at a time.
    private struct Layout {
        let data: Data
        func u16(_ at: Int) -> Int { Int(data[at]) << 8 | Int(data[at + 1]) }
        func u32(_ at: Int) -> Int { u16(at) << 16 | u16(at + 2) }
        var resourcesLength: Int { 30 }
        var layerSection: Int { 34 + u32(resourcesLength) }
        var layerCount: Int { layerSection + 8 }
        var firstRecord: Int { layerSection + 10 }
        var channelCount: Int { u16(firstRecord + 16) }
        var firstChannelLength: Int { firstRecord + 18 + 2 }
        var extraLength: Int { firstRecord + 18 + 6 * channelCount + 12 }
        /// Only for a single-layer file, whose channel data follows its one record.
        var firstChannelData: Int { extraLength + 4 + u32(extraLength) }
        var imageData: Int { layerSection + 4 + u32(layerSection) }
    }

    private func patched(_ data: Data, at offset: Int, _ bytes: [UInt8]) -> Data {
        var copy = data
        copy.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
        return copy
    }

    @Test func lengthLiesAreTruncation() throws {
        let data = try file([try layer("Sky", size: 4)])
        let layout = Layout(data: data)
        #expect(try PSDReader.read(data).layers.count == 1)
        let lies: [(String, Int, [UInt8])] = [
            ("image resources length", layout.resourcesLength, [0x7F, 0xFF, 0xFF, 0xFF]),
            ("layer and mask section length", layout.layerSection, [0x00, 0x10, 0x00, 0x00]),
            ("first channel length", layout.firstChannelLength, [0xFF, 0xFF, 0xFF, 0x00]),
            ("extra data length", layout.extraLength, [0x7F, 0xFF, 0xFF, 0xFF]),
            ("merged image row count", layout.imageData + 2, [0xFF, 0xFF]),
        ]
        for (field, offset, bytes) in lies {
            #expect(throws: PSDError.truncated, "\(field)") { try PSDReader.read(patched(data, at: offset, bytes)) }
        }
        // Claiming more layers sends the reader into pixel data for the next record. In this file that reads as
        // a layer past the size limits, which is refused before anything is allocated for it.
        #expect(throws: ImageImportError.tooLarge) { try PSDReader.read(patched(data, at: layout.layerCount, [0x00, 0x09])) }
    }

    @Test func malformedPackBitsIsTruncation() throws {
        let data = try file([try layer("Sky", size: 4)])
        let channel = Layout(data: data).firstChannelData
        // Each channel is a compression word (1, PackBits), four row byte counts, then the rows.
        #expect(Layout(data: data).u16(channel) == 1)
        let rows = channel + 2 + 4 * 2
        let malformed: [(String, Int, [UInt8])] = [
            ("row count past the data", channel + 2, [0xFF, 0xFF]),
            ("row count of zero", channel + 2, [0x00, 0x00]),
            ("literal run longer than the row", rows, [0x7F]),
            ("repeat run longer than the row", rows, [0x81]),
        ]
        for (defect, offset, bytes) in malformed {
            #expect(throws: PSDError.truncated, "\(defect)") { try PSDReader.read(patched(data, at: offset, bytes)) }
        }
        #expect(throws: PSDError.unsupportedCompression) { try PSDReader.read(patched(data, at: channel, [0x00, 0x07])) }
    }

    /// Whatever a single damaged byte does, reading returns or throws, and a file that reads still imports
    /// as something a project can hold.
    @Test func singleByteDamageNeverTrapsOrYieldsAnUnsaveableDocument() throws {
        for fixture in try fixtures() {
            let data = fixture.data
            for offset in stride(from: 0, to: data.count, by: max(1, data.count / 1_500)) {
                for value: UInt8 in [0x00, 0x01, 0x7F, 0x80, 0xFF] where data[offset] != value {
                    guard let document = try? PSDReader.read(patched(data, at: offset, [value])) else { continue }
                    do {
                        _ = try PSDDocumentBuilder.makeImport(document)
                    } catch PSDError.unrepresentable {
                        Issue.record("\(fixture.name): byte \(offset) = \(value) read but can't be saved as a project")
                    } catch {}
                }
            }
        }
    }

    // MARK: Budgets and project rules

    /// Masks have a budget of their own, as projects do: 100 million mask pixels beside the image pixels.
    @Test func maskPixelsAreDeductedFromTheirOwnBudget() throws {
        let mask = try grayImage(width: 4, height: 4, value: 0.5)
        let data = try file([try layer("A", size: 4, mask: mask), try layer("B", size: 4, mask: mask)])
        let document = try PSDReader.read(data, remainingPixels: 32, remainingMaskPixels: 32)
        #expect(document.layers.allSatisfy { $0.mask != nil })
        // Each mask fits on its own; the second one doesn't fit in what the first left.
        #expect(throws: ImageImportError.tooLarge) { try PSDReader.read(data, remainingMaskPixels: 20) }
        #expect(throws: ImageImportError.tooLarge) { try PSDReader.read(data, remainingPixels: 20) }
    }

    @Test func foldersDeeperThanAProjectAllowsAreDissolved() throws {
        // 70 folders, each inside the last, with a layer at the bottom. The 66th is hidden and the 67th half
        // opaque; both are past the limit, so the layer takes on their visibility and opacity itself.
        var folders: [PSDRecord] = []
        for depth in 0..<70 {
            var next = folder("Folder \(depth)", parent: folders.last?.id)
            if depth == 65 { next.isVisible = false }
            if depth == 66 { next.opacity = 0.5 }
            folders.append(next)
        }
        let leaf = try layer("Leaf", parent: folders.last?.id)
        let data = try file(folders + [leaf])
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        let groups = imported.layers.filter(\.isGroup)
        #expect(groups.count == PSDReader.maximumFolderDepth)
        let importedLeaf = try #require(imported.layers.first { $0.name == "Leaf" })
        #expect(importedLeaf.parentID == groups.first { $0.name == "Folder 63" }?.id)
        #expect(!importedLeaf.isVisible)
        #expect(abs(importedLeaf.opacity - 0.5) < 0.01)
        #expect(imported.conversions.filter { $0.message.contains("nested") }.count == 6)
        try ProjectStore.validate(manifest(imported))
    }

    @Test func blankAndOversizedNamesAndFarOriginsAreMadeSaveable() throws {
        let long = String(repeating: "é", count: 10_000) // 20,000 bytes of UTF-8
        let data = try file([try layer("   "), try layer(long), try layer("Far", at: CGPoint(x: 2_000_000, y: -3_000_000))])
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        #expect(imported.layers.map(\.name).first == "Layer")
        let trimmed = imported.layers[1].name
        #expect(trimmed.utf8.count == 16_384 && long.hasPrefix(trimmed))
        #expect(imported.layers[2].origin == CGPoint(x: 1_000_000, y: -1_000_000))
        try ProjectStore.validate(manifest(imported))
    }

    // MARK: Adjustment payloads, laid out as Adobe's specification gives them

    private func shorts(_ values: [Int16]) -> Data {
        var data = Data()
        for value in values {
            data.append(UInt8(truncatingIfNeeded: UInt16(bitPattern: value) >> 8))
            data.append(UInt8(truncatingIfNeeded: UInt16(bitPattern: value)))
        }
        return data
    }

    /// "Hue/Saturation file format": version 2, colorize flag, pad byte, colorization (6), Master (6), then
    /// Reds, Yellows, Greens, Cyans, Blues and Magentas, each four range values followed by three settings.
    private func huePayload(colorize: Bool, colorization: [Int16], master: [Int16],
                            ranges: [(band: [Int16], values: [Int16])]) -> Data {
        var data = shorts([2])
        data.append(contentsOf: [colorize ? 1 : 0, 0])
        data.append(shorts(colorization))
        data.append(shorts(master))
        for range in ranges { data.append(shorts(range.band + range.values)) }
        return data
    }

    private let photoshopBands: [[Int16]] = [
        [315, 345, 15, 45], [15, 45, 75, 105], [75, 105, 135, 165],
        [135, 165, 195, 225], [195, 225, 255, 285], [255, 285, 315, 345],
    ]

    @Test func hueSaturationReadsMasterAndEachRangeFromTheirOwnOffsets() throws {
        let ranges: [(band: [Int16], values: [Int16])] = [
            ([-45, -15, 15, 45], [10, 20, 30]),
            (photoshopBands[1], [-11, -21, -31]),
            (photoshopBands[2], [12, 22, 32]),
            (photoshopBands[3], [-13, -23, -33]),
            (photoshopBands[4], [14, 24, 34]),
            ([250, 280, 320, 350], [-15, -25, -35]),
        ]
        // Colorization values that would be read as Master by a reader starting at offset 4.
        let payload = huePayload(colorize: false, colorization: [99, 99, 99], master: [40, -50, 60], ranges: ranges)
        #expect(payload.count == 100)
        let adjustment = try #require(PSDAdjustments.parse(["hue2": payload]))
        let settings = adjustment.resolvedHSV
        #expect(!settings.colorize)
        #expect(settings.adjustments[.master] == RangeAdjustment(hue: 40, saturation: -50, lightness: 60))
        #expect(settings.adjustments[.reds] == RangeAdjustment(hue: 10, saturation: 20, lightness: 30))
        #expect(settings.adjustments[.yellows] == RangeAdjustment(hue: -11, saturation: -21, lightness: -31))
        #expect(settings.adjustments[.magentas] == RangeAdjustment(hue: -15, saturation: -25, lightness: -35))
        // Negative handles wrap onto the wheel.
        #expect(settings.bands[.reds] == HueBand(falloffStart: 315, rangeStart: 345, rangeEnd: 15, falloffEnd: 45))
        #expect(settings.bands[.magentas] == HueBand(falloffStart: 250, rangeStart: 280, rangeEnd: 320, falloffEnd: 350))
        #expect(adjustment.isValid)
    }

    @Test func hueSaturationColorizeUsesTheColorizationValues() throws {
        let neutral = photoshopBands.map { (band: $0, values: [Int16](repeating: 0, count: 3)) }
        let payload = huePayload(colorize: true, colorization: [-90, 40, -10], master: [25, 25, 25], ranges: neutral)
        let settings = try #require(PSDAdjustments.parse(["hue2": payload])).resolvedHSV
        #expect(settings.colorize)
        // Photoshop's −180…180 colorize hue lands on the 0…360 wheel Colorize uses here.
        #expect(settings.adjustments[.master] == RangeAdjustment(hue: 270, saturation: 40, lightness: -10))
    }

    @Test func outOfRangeHueSaturationIsClampedToPhotoshopsRange() throws {
        let neutral = photoshopBands.map { (band: $0, values: [Int16](repeating: 0, count: 3)) }
        let payload = huePayload(colorize: false, colorization: [0, 0, 0], master: [500, -300, 32_000], ranges: neutral)
        let adjustment = try #require(PSDAdjustments.parse(["hue2": payload]))
        let master = try #require(adjustment.resolvedHSV.adjustments[.master])
        #expect(master.hue == 180 && master.saturation == -100 && master.lightness == 100)
        #expect(adjustment.isValid)
    }

    @Test func hueSaturationOfAnUnknownVersionIsNotGuessedAt() {
        var payload = huePayload(colorize: false, colorization: [0, 0, 0], master: [30, 0, 0],
                                 ranges: photoshopBands.map { (band: $0, values: [0, 0, 0]) })
        payload[1] = 3
        #expect(PSDAdjustments.parse(["hue2": payload]) == nil)
    }

    @Test func levelsGammaIsStoredTimesOneHundred() throws {
        // "Levels file format": version 2, then 29 records of five shorts; the first four are RGB, R, G, B.
        var payload = shorts([2])
        let records: [[Int16]] = [[0, 255, 0, 255, 100], [10, 245, 5, 250, 250], [0, 255, 0, 255, 10], [0, 255, 0, 255, 999]]
        for record in records { payload.append(shorts(record)) }
        for _ in records.count..<29 { payload.append(shorts([0, 255, 0, 255, 100])) }
        #expect(payload.count == 292)
        let adjustment = try #require(PSDAdjustments.parse(["levl": payload]))
        let ranges = adjustment.levels.ranges
        #expect(ranges[0] == LevelRange())
        #expect(ranges[1] == LevelRange(black: 10, gamma: 2.5, white: 245, outputBlack: 5, outputWhite: 250))
        #expect(abs(ranges[2].gamma - 0.1) < 1e-9 && abs(ranges[3].gamma - 9.99) < 1e-9)
        #expect(adjustment.isValid)
    }

    // MARK: Additional layer information

    /// Records whose one additional-info block claims to run far past the record, into the rest of the file.
    /// Read against the file rather than the record, each would copy most of the file and keep it.
    @Test func anAdditionalInfoBlockCannotReachPastItsRecord() throws {
        let records = 10_000, side = 64
        var data = Data("8BPS".utf8)
        data.append(shorts([1, 0, 0, 0, 3]))
        data.append(shorts([0, Int16(side), 0, Int16(side), 8, 3]))
        data.append(Data(count: 8)) // No color-mode data, no image resources.
        var record = Data(count: 16) // An empty layer: no bounds, no channels.
        record.append(shorts([0]))
        record.append(Data("8BIMnorm".utf8))
        record.append(contentsOf: [255, 0, 0, 0])
        let claimed = 3 * side * side - 64
        var extra = Data(count: 8) // No mask, no blending ranges.
        extra.append(contentsOf: [0, 0, 0, 0]) // Empty name, padded to four bytes.
        extra.append(Data("8BIMzzzz".utf8))
        extra.append(shorts([Int16(claimed >> 16), Int16(truncatingIfNeeded: claimed)]))
        record.append(shorts([0, Int16(extra.count)]))
        record.append(extra)
        var info = shorts([Int16(records)])
        for _ in 0..<records { info.append(record) }
        let infoLength = info.count
        data.append(shorts([Int16(truncatingIfNeeded: (infoLength + 4) >> 16), Int16(truncatingIfNeeded: infoLength + 4)]))
        data.append(shorts([Int16(truncatingIfNeeded: infoLength >> 16), Int16(truncatingIfNeeded: infoLength)]))
        data.append(info)
        data.append(shorts([0])) // Raw merged image: far more than any one block claims.
        data.append(Data(repeating: 0x80, count: 3 * side * side))
        let started = ContinuousClock.now
        #expect(throws: PSDError.truncated) { try PSDReader.read(data) }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    private func manifest(_ imported: PSDImport) -> ProjectManifest {
        ProjectManifest(documentID: UUID(), width: imported.width, height: imported.height, activeLayerID: nil,
                        layers: imported.layers.map(\.hierarchyRecord))
    }
}
