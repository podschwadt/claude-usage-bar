import AppKit
import ClaudeUsageBarCore
import Foundation
import XCTest

// Helpers and fixtures shared across the ClaudeUsageBarTests target.

/// Tolerance for `Double` floating-point comparisons.
private let doubleEpsilon = 0.0001

/// Tolerance for `CGFloat` floating-point comparisons.
private let cgFloatEpsilon: CGFloat = 0.001

func approxEqual(_ a: Double, _ b: Double) -> Bool {
    abs(a - b) < doubleEpsilon
}

func approxEqual(_ a: CGFloat, _ b: CGFloat) -> Bool {
    abs(a - b) < cgFloatEpsilon
}

/// Renders `image` into an offscreen bitmap once, so the drawing handler
/// actually executes (an `NSImage(size:flipped:drawingHandler:)` only builds
/// a lazy stub otherwise). Asserts nothing about pixels — just that the
/// handler runs without crashing.
func forceDraw(_ image: NSImage) {
    let width = max(1, Int(image.size.width.rounded(.up)))
    let height = max(1, Int(image.size.height.rounded(.up)))
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep)
    else {
        XCTFail("bitmap context creation failed")
        return
    }

    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = context
    image.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.current = previous
}

/// Fixture `queried_at`, matching the shape emitted by the real parser
/// (fractional seconds, explicit offset - see `SnapshotDecodingTests`).
let queriedAtFixture = "2026-09-04T13:23:00.123456-06:00"
let queriedAtUnixFixture = Int(Display.iso8601Date(queriedAtFixture)!.timeIntervalSince1970)

/// Builds a `Metric` fixture with a bare `ResetInfo` (no raw reset phrase) -
/// the shape every `PanelTests`/`UsageMachineTests` fixture needs.
func metricFixture(key: String, usedPct: Double, secondsUntil: Int?) -> Metric {
    Metric(
        key: key, usedPct: usedPct, remainingPct: 100 - usedPct,
        reset: ResetInfo(raw: nil, secondsUntil: secondsUntil))
}
