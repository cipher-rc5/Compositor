import AppKit
import ObjectiveC

/// On macOS 26, clicking a slider's track glides the knob to the click over about a quarter of a
/// second, even though the value changes at once. Setting a slider's value in code moves the knob
/// immediately, so this sets the value under the pointer just before the slider starts tracking the
/// press: tracking then begins with the knob already under the pointer, so it neither jumps nor
/// glides, and dragging carries on from there. Pressing the knob itself still drags it from where
/// it is. On macOS 26 SwiftUI's `Slider` is an `NSSlider`, so this covers every slider in the app;
/// from macOS 27 SwiftUI draws its own, and only the AppKit sliders (e.g. `CameraRawSliderView`) pass through here.
///
/// It replaces an AppKit method for the whole process, so it is fenced in: only on the macOS versions it has been
/// checked on, only when `NSSliderCell` itself implements the method with the signature expected, and never when
/// `disableDefaultsKey` is set (`defaults write <bundle id> DisableSliderSnap -bool YES`).
enum SliderSnap {
    /// The kill switch: set, sliders are left exactly as AppKit made them.
    nonisolated static let disableDefaultsKey = "DisableSliderSnap"
    /// The macOS major versions this has been verified on. A newer one goes without it until checked there too.
    nonisolated static let verifiedMajorVersions = 26...27

    /// Installs the replacement once; true if it is in place.
    @discardableResult
    static func install() -> Bool { installed }

    /// Whether this system and these defaults allow installing it at all.
    nonisolated static func shouldInstall(osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                              defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: disableDefaultsKey) && verifiedMajorVersions.contains(osVersion.majorVersion)
    }

    private static let installed: Bool = {
        let selector = #selector(NSSliderCell.startTracking(at:in:))
        guard shouldInstall(), let method = ownMethod(selector, of: NSSliderCell.self),
              hasExpectedSignature(method) else { return false }
        typealias Original = @convention(c) (NSSliderCell, Selector, NSPoint, NSView) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (NSSliderCell, NSPoint, NSView) -> Bool = { cell, point, view in
            cell.snapValue(to: point, in: view)
            return original(cell, selector, point, view)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        return true
    }()

    /// `cls`'s own implementation of `selector`. `class_getInstanceMethod` would also find one inherited from
    /// `NSCell`, and replacing that would change every kind of cell, not just sliders.
    static func ownMethod(_ selector: Selector, of cls: AnyClass) -> Method? {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return nil }
        defer { free(methods) }
        return UnsafeBufferPointer(start: methods, count: Int(count)).first { method_getName($0) == selector }
    }

    /// `- (BOOL)startTracking:(NSPoint)startPoint inView:(NSView *)controlView`, as the replacement block assumes:
    /// a BOOL back, and self, `_cmd`, a point and an object in.
    static func hasExpectedSignature(_ method: Method) -> Bool {
        func encoding(_ type: UnsafeMutablePointer<CChar>?) -> String {
            guard let type else { return "" }
            defer { free(type) }
            return String(cString: type)
        }
        guard method_getNumberOfArguments(method) == 4 else { return false }
        let returned = encoding(method_copyReturnType(method))
        let point = encoding(method_copyArgumentType(method, 2))
        let view = encoding(method_copyArgumentType(method, 3))
        // BOOL is encoded "B" on Apple silicon and "c" on Intel.
        return (returned == "B" || returned == "c") && point.hasPrefix("{CGPoint=") && view == "@"
    }
}

private extension NSSliderCell {
    /// When a press lands on the track rather than the knob, sets the value whose knob is centered
    /// on the press (the same place the slider's own jump would put it).
    func snapValue(to point: NSPoint, in view: NSView) {
        guard sliderType == .linear, !isVertical, isEnabled, maxValue > minValue else { return }
        let knob = knobRect(flipped: view.isFlipped)
        guard !knob.contains(point) else { return }
        let track = trackRect.isEmpty ? view.bounds : trackRect
        let travel = track.width - knob.width
        guard travel > 0 else { return }
        var fraction = min(1, max(0, (point.x - track.minX - knob.width / 2) / travel))
        if userInterfaceLayoutDirection == .rightToLeft { fraction = 1 - fraction }
        var value = minValue + Double(fraction) * (maxValue - minValue)
        if allowsTickMarkValuesOnly, numberOfTickMarks > 0 { value = closestTickMarkValue(toValue: value) }
        if let control = view as? NSControl { control.doubleValue = value } else { doubleValue = value }
    }
}
