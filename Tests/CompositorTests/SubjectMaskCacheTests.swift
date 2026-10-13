import CoreGraphics
import Testing
@testable import Compositor

/// Remove Background keeps Vision's mask for the image it was made from, so moving a slider only redoes the refining.
/// It was once keyed by the image's address: a freed image's address taken by a new image handed back the wrong mask.
@MainActor
struct SubjectMaskCacheTests {
    private func image(_ gray: CGFloat) throws -> CGImage {
        let context = try BrushRaster.context(width: 8, height: 8, mask: false)
        context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try #require(context.makeImage())
    }

    @Test func aMaskIsOnlyHandedBackForTheVeryImageItWasMadeFor() throws {
        let cache = SubjectRemoval.MaskCache()
        let first = try image(0.5), mask = try image(1)
        var made = 0
        func lookUp(_ image: CGImage) throws -> CGImage {
            try cache.mask(for: image) { made += 1; return mask }
        }
        #expect(try lookUp(first) === mask && made == 1)
        #expect(try lookUp(first) === mask && made == 1)   // The same image: kept.
        // An image equal in every pixel is still another image.
        _ = try lookUp(try image(0.5))
        #expect(made == 2)
    }

    /// Images made and dropped one after another, the same size, are where an allocator hands a freed address to the
    /// next one. Each is a different image, so each must miss: identity, not address.
    @Test func aNewImageNeverInheritsAFreedImagesMask() throws {
        let cache = SubjectRemoval.MaskCache()
        var made = 0
        for index in 0..<200 {
            let fresh = try image(CGFloat(index % 2))
            _ = try cache.mask(for: fresh) { made += 1; return fresh }
            #expect(made == index + 1, "image \(index) was handed another image's mask")
        }
    }

    /// The panel closing lets go of the image and its mask; a mask still being made then isn't kept either.
    @Test func forgettingLetsGoAndAMaskMadeMeanwhileIsNotKept() throws {
        let cache = SubjectRemoval.MaskCache()
        let source = try image(0.3), mask = try image(1)
        _ = try cache.mask(for: source) { mask }
        #expect(!cache.isEmpty)
        cache.forget()
        #expect(cache.isEmpty)
        // Forgotten while it was being made, as when the panel closes during a preview.
        _ = try cache.mask(for: source) { cache.forget(); return mask }
        #expect(cache.isEmpty)
        var made = 0
        _ = try cache.mask(for: source) { made += 1; return mask }
        #expect(made == 1 && !cache.isEmpty)
    }

    /// The shared cache: other suites may fill it meanwhile, so this checks only for its own image.
    @Test func closingAFilterPanelReleasesTheSharedMask() throws {
        let session = EditorSession()
        session.createDocument(width: 20, height: 20)
        let source = try image(0.4)
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Gray"))
        _ = try SubjectRemoval.cache.mask(for: source) { source }
        var made = 0
        session.beginFilter(.gaussianBlur)
        #expect(session.filterEdit != nil)
        session.cancelFilter()
        #expect(session.filterEdit == nil)
        _ = try SubjectRemoval.cache.mask(for: source) { made += 1; return source }
        #expect(made == 1)
        SubjectRemoval.forgetMask()
    }
}
