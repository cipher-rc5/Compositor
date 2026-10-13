import AppKit
import Testing
@testable import Compositor

/// Clicking a slider's track must snap the knob to the click, not glide it there.
@MainActor
@Suite(.serialized)
struct SliderSnapTests {
    /// Records the value each of the slider's actions carried.
    @MainActor private final class Recorder: NSObject {
        var values: [Double] = []
        @objc func changed(_ sender: NSSlider) { values.append(sender.doubleValue) }
    }

    /// Left edge of the knob as drawn, in slider coordinates. The drawn knob is the slider's only
    /// small subview; `knobRect` can't be used, since it follows the value, not the animation.
    private func drawnKnobX(in slider: NSSlider) -> CGFloat? {
        func find(_ view: NSView) -> NSView? {
            for sub in view.subviews {
                if sub.frame.width < 60 { return sub }
                if let found = find(sub) { return found }
            }
            return nil
        }
        return find(slider).map { $0.convert($0.bounds, to: slider).minX }
    }

    /// Polls `condition` until it holds or `timeout` passes, letting the main run loop turn in between.
    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// A slider in a window, and a press on its track at 90% of its width, sent through the window as a real
    /// click would be. Drives an AppKit `NSSlider`, which is what the swizzle changes: SwiftUI's `Slider` was
    /// one on macOS 26, but from macOS 27 SwiftUI draws it itself, so hosting one yields no `NSSlider` to press.
    private func pressTrack() async throws -> (slider: NSSlider, recorder: Recorder, window: NSWindow, knobBefore: CGFloat?) {
        #expect(SliderSnap.install())
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 260, height: 50), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let recorder = Recorder()
        let slider = NSSlider(value: 0.1, minValue: 0, maxValue: 1, target: recorder, action: #selector(Recorder.changed(_:)))
        slider.isContinuous = true
        slider.frame = CGRect(x: 30, y: 17, width: 200, height: 16)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 260, height: 50))
        content.addSubview(slider)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        // Laid out and drawn now rather than after a wait, so the knob is where the value puts it before the press.
        // The window needn't be key: `sendEvent` hands the press to the slider either way.
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let before = drawnKnobX(in: slider)
        let point = slider.convert(NSPoint(x: slider.bounds.width * 0.9, y: slider.bounds.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        window.sendEvent(down) // tracks the whole click, since the real mouse button is up
        return (slider, recorder, window, before)
    }

    @Test func installsOnlyWhereVerifiedAndNotSwitchedOff() throws {
        let defaults = try #require(UserDefaults(suiteName: "SliderSnapTests"))
        defer { defaults.removePersistentDomain(forName: "SliderSnapTests") }
        func os(_ major: Int) -> OperatingSystemVersion { OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0) }
        #expect(SliderSnap.shouldInstall(osVersion: os(26), defaults: defaults))
        #expect(SliderSnap.shouldInstall(osVersion: os(27), defaults: defaults))
        #expect(!SliderSnap.shouldInstall(osVersion: os(25), defaults: defaults))
        #expect(!SliderSnap.shouldInstall(osVersion: os(28), defaults: defaults))
        defaults.set(true, forKey: SliderSnap.disableDefaultsKey)
        #expect(!SliderSnap.shouldInstall(osVersion: os(26), defaults: defaults))
    }

    @Test func replacesOnlyTheSliderCellsOwnMethod() throws {
        let selector = #selector(NSSliderCell.startTracking(at:in:))
        let method = try #require(SliderSnap.ownMethod(selector, of: NSSliderCell.self))
        #expect(SliderSnap.hasExpectedSignature(method))
        // Never NSCell's version, which every other kind of cell would share.
        #expect(method != class_getInstanceMethod(NSCell.self, selector))
    }

    @Test(.enabled(if: SliderSnap.shouldInstall(), "installed only on verified macOS versions"))
    func clickingTheTrackSetsTheValueUnderThePointer() async throws {
        let (slider, recorder, window, _) = try await pressTrack()
        defer { window.orderOut(nil) }
        #expect(abs(slider.doubleValue - 0.94) < 0.02, "value \(slider.doubleValue)")
        #expect(abs((recorder.values.last ?? 0) - slider.doubleValue) < 0.001, "actions \(recorder.values)")
    }

    /// The glide this works around is AppKit's knob animation on macOS 26, where the knob is a subview whose
    /// frame can be watched. macOS 27 draws the knob without one, so there is nothing to measure there.
    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27,
                   "the knob is only a measurable subview through macOS 26"))
    func clickingTheTrackSnapsTheKnobWithoutGliding() async throws {
        let (slider, _, window, knobBefore) = try await pressTrack()
        defer { window.orderOut(nil) }
        let start = try #require(knobBefore)
        // Straight after the press: a glide would still have the knob near where it started.
        slider.layoutSubtreeIfNeeded()
        let early = try #require(drawnKnobX(in: slider))
        // Then wait for it to come to rest (the same place twice running), however long the machine takes.
        var last: CGFloat?, settled: CGFloat?
        _ = await waitUntil {
            let now = drawnKnobX(in: slider)
            defer { last = now }
            guard let now, let last, abs(now - last) < 0.5 else { return false }
            settled = now
            return true
        }
        let rest = try #require(settled, "the knob never came to rest")
        #expect(rest - start > 100, "the knob never moved: \(start) → \(rest)")
        #expect(abs(early - rest) <= 2, "the knob glided: \(early) straight after the press, \(rest) at rest")
    }
}
