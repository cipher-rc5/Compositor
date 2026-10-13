import AppKit
import Testing
@testable import Compositor

/// What the Camera Raw kernels write, not only where: the same input gives the same bytes every time, flat color
/// stays flat, and a transparent hole neither changes nor bleeds into the pixels around it. The padding checks in
/// `PixelKernelTests` passed while Color Noise Reduction read heap memory it had never written.
struct CameraRawKernelTests {
    typealias Padded = PixelKernelTests.Padded
    typealias Kernel = @Sendable (UnsafeMutablePointer<UInt8>, Int, Int, Int) -> Int32

    /// Frees blocks of `bytes` filled with `fill`, so the kernel's next allocations of that size come back holding
    /// it. A plane read before it is written then shows up as output that depends on what the heap held.
    private static func seedHeap(bytes: Int, fill: Int32) {
        let blocks = (0..<24).compactMap { _ in malloc(bytes) }
        for block in blocks { memset(block, fill, bytes) }
        for block in blocks { free(block) }
    }

    /// Runs `kernel` once after the heap is seeded with NaN bit patterns and once after zeros.
    private static func twice(_ source: Padded, _ kernel: Kernel) -> (first: Padded, second: Padded, status: [Int32]) {
        var first = source, second = source
        var status: [Int32] = []
        let plane = source.width * source.height * MemoryLayout<Float>.size
        seedHeap(bytes: plane, fill: 0xFF)
        first.run { status.append(kernel($0, source.width, source.height, $1)) }
        seedHeap(bytes: plane, fill: 0)
        second.run { status.append(kernel($0, source.width, source.height, $1)) }
        return (first, second, status)
    }

    /// A busy, colorful 48×40 pattern with a transparent 10×8 hole and a transparent left column.
    private static let pattern = Padded(width: 48, height: 40) { x, y in
        if x == 0 || (18..<28).contains(x) && (14..<22).contains(y) { return [0, 0, 0, 0] }
        let alpha = (x + y) % 7 == 0 ? 128 : 255
        let r = (x * 37 + y * 11) % 256, g = (x * 5 + y * 23) % 256, b = (x * y + 40) % 256
        return [r, g, b].map { UInt8($0 * alpha / 255) } + [UInt8(alpha)]
    }

    /// One flat, saturated orange with the same hole and column.
    private static let flat = Padded(width: 48, height: 40) { x, y in
        x == 0 || (18..<28).contains(x) && (14..<22).contains(y) ? [0, 0, 0, 0] : [200, 120, 60, 255]
    }

    private static func isHole(_ x: Int, _ y: Int) -> Bool { x == 0 || (18..<28).contains(x) && (14..<22).contains(y) }

    static let kernels: [(String, Kernel)] = [
        ("effects", { adjust_camera_raw_effects($0, $1, $2, $3, 40, 60, 30, 50, 1, 50, 50, 20, -40, 50, 0, 50, 20, 0, 1) }),
        ("luminance noise", { adjust_camera_raw_detail($0, $1, $2, $3, 0, 10, 25, 0, 70, 30, 20, 0, 50, 50, 1) }),
        ("color noise", { adjust_camera_raw_detail($0, $1, $2, $3, 0, 10, 25, 0, 0, 50, 0, 80, 30, 70, 1) }),
        ("sharpening", { adjust_camera_raw_detail($0, $1, $2, $3, 120, 40, 60, 10, 0, 50, 0, 0, 50, 50, 1) }),
        ("all detail", { adjust_camera_raw_detail($0, $1, $2, $3, 80, 30, 40, 20, 50, 50, 20, 40, 50, 50, 1.5) }),
        ("sharpen mask", { adjust_camera_raw_sharpen_mask_overlay($0, $1, $2, $3, 30, 40, 20, 1) }),
        ("optics", { adjust_camera_raw_optics($0, $1, $2, $3, 1, 1, 30, 50, 0.1, 50, 270, 330, 50, 90, 150, 30, 50, 1) }),
    ]

    @Test(arguments: kernels.map(\.0))
    func sameInputGivesTheSameBytes(_ name: String) throws {
        let kernel = try #require(Self.kernels.first { $0.0 == name }?.1)
        let (first, second, status) = Self.twice(Self.pattern, kernel)
        #expect(status == [0, 0], "\(name) reported a failure")
        #expect(first.bytes == second.bytes, "\(name) depends on memory it never wrote")
        #expect(first.bytes != Self.pattern.bytes, "\(name) changed something")
        for y in 0..<40 { for x in 0..<48 where Self.isHole(x, y) && name != "optics" {
            #expect(first.pixel(x, y) == [0, 0, 0, 0], "\(name) painted the transparent pixel (\(x), \(y))")
        } }
    }

    /// Smoothing, sharpening and local contrast have nothing to do on one flat color; a transparent hole is not an
    /// edge to sharpen or a black to blur into the pixels beside it.
    @Test(arguments: ["luminance noise", "color noise", "sharpening", "all detail"])
    func flatColorAroundAHoleIsLeftAlone(_ name: String) throws {
        let kernel = try #require(Self.kernels.first { $0.0 == name }?.1)
        let (first, second, _) = Self.twice(Self.flat, kernel)
        #expect(first.bytes == second.bytes)
        var changed: [String] = []
        for y in 0..<40 { for x in 0..<48 where first.pixel(x, y) != Self.flat.pixel(x, y) {
            changed.append("(\(x), \(y)) \(first.pixel(x, y))")
        } }
        #expect(changed.isEmpty, "\(name) changed \(changed.count) pixels, first \(changed.prefix(4))")
    }

    /// A plane the kernel can't allocate is reported, and the pixels are left as they were rather than half graded.
    /// Here the planes' byte counts overflow a size, so no allocation is even tried (a sanitizer would stop the run
    /// on a request it can't meet); the pixels passed are a stand-in that nothing reads.
    @Test func memoryTheKernelCannotGetIsReportedBeforeAnyPixelChanges() {
        let width = Int.max / 2, height = 8, stride = Int.max / 2
        var bytes = [UInt8](repeating: 7, count: 64)
        bytes.withUnsafeMutableBufferPointer { buffer in
            let p = buffer.baseAddress!
            #expect(adjust_camera_raw_effects(p, width, height, stride, 40, 40, 0, 0, 0, 0, 0, 0, 0, 50, 0, 50, 0, 0, 1) == -1)
            #expect(adjust_camera_raw_detail(p, width, height, stride, 80, 10, 25, 0, 50, 50, 0, 50, 50, 50, 1) == -1)
            #expect(adjust_camera_raw_sharpen_mask_overlay(p, width, height, stride, 10, 25, 0, 1) == -1)
            #expect(adjust_camera_raw_optics(p, width, height, stride, 1, 0, 100, 100, 0.2, 0, 270, 310, 0, 60, 120, 0, 50, 1) == -1)
        }
        #expect(bytes.allSatisfy { $0 == 7 })
    }

    @Test func clarityAndTextureLeaveAFlatOpaqueFieldAlone() {
        var image = Padded(width: 20, height: 12) { _, _ in [90, 160, 30, 255] }
        image.run { #expect(adjust_camera_raw_effects($0, 20, 12, $1, 60, 80, 0, 0, 0, 0, 0, 0, 0, 50, 0, 50, 0, 0, 1) == 0) }
        #expect((0..<12).allSatisfy { y in (0..<20).allSatisfy { image.pixel($0, y) == [90, 160, 30, 255] } })
    }
}
