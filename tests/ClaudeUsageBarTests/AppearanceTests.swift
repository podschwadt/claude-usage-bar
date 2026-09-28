import AppKit
import ClaudeUsageBarCore
import XCTest

/// Light/Dark Mode: every custom tint must resolve differently under the two
/// appearances, and the views that draw with them must come out dark-on-light
/// in Light Mode and light-on-dark in Dark Mode, so a light panel never gets
/// the dark appearance's white text.

/// Resolves `color` to sRGB under `appearance`, as AppKit does when a view
/// with that effective appearance sets it inside `draw(_:)`.
private func resolve(_ color: NSColor, under appearance: NSAppearance.Name) -> NSColor {
    var resolved = color
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        resolved = color.usingColorSpace(.sRGB)!
    }
    return resolved
}

/// Approximate luminance (0 = black, 1 = white) from the gamma-encoded
/// components, ignoring alpha; enough to tell a dark tint from a light one.
private func lightness(_ color: NSColor) -> CGFloat {
    0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
}

/// One rendered pixel as un-premultiplied sRGB.
private struct Pixel {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
    var lightness: CGFloat { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
}

/// Renders `view` with `appearance` set on it through `cacheDisplay`, which
/// like on-screen display calls `draw(_:)` with the view's effective
/// appearance current, and returns every pixel that was actually painted
/// (alpha above a hairline threshold). No `performAsCurrentDrawingAppearance`
/// wrapper: the point is that the view's dynamic colors resolve from its
/// effective appearance.
private func paintedPixels(of view: NSView, under appearance: NSAppearance.Name) -> [Pixel] {
    view.appearance = NSAppearance(named: appearance)
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    var pixels: [Pixel] = []
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.05
            else { continue }
            pixels.append(
                Pixel(
                    red: color.redComponent, green: color.greenComponent, blue: color.blueComponent,
                    alpha: color.alphaComponent))
        }
    }
    return pixels
}

/// Mean lightness of `pixels`; the sign of (mean - 0.5) says whether a
/// render is predominantly dark or light ink.
private func meanLightness(_ pixels: [Pixel]) -> CGFloat {
    pixels.reduce(0) { $0 + $1.lightness } / CGFloat(max(1, pixels.count))
}

/// Series/ring tint for renders that should measure only appearance-driven
/// ink. Stroking or filling with it paints nothing, but `.clear` is black at
/// alpha 0, so `withAlphaComponent` on it yields visible black: the ring
/// track (20%) and chart gradient fill (28% fading to 6%) still appear.
/// Tests that use it filter those low alphas out or avoid the fill.
private let clearTint = NSColor.clear

final class AppearanceTests: XCTestCase {

    // MARK: - Palette

    /// Text tints: dark in Light Mode, light in Dark Mode, translucent in both.
    func testPanelTintsInvertWithAppearance() {
        for (name, tint) in [
            ("panelCaption", NSColor.panelCaption),
            ("panelRule", NSColor.panelRule),
            ("chartGrid", NSColor.chartGrid),
        ] {
            let light = resolve(tint, under: .aqua)
            let dark = resolve(tint, under: .darkAqua)
            XCTAssertTrue(lightness(light) < 0.5, "\(name) is a dark tint in Light Mode")
            XCTAssertTrue(lightness(dark) > 0.5, "\(name) is a light tint in Dark Mode")
            XCTAssertTrue(light.alphaComponent < 1, "\(name) stays translucent in Light Mode")
            XCTAssertTrue(dark.alphaComponent < 1, "\(name) stays translucent in Dark Mode")
        }
    }

    /// The hover box backdrop is the appearance's base tone, the inverse of text.
    func testHoverBoxBackgroundMatchesAppearance() {
        let light = resolve(.chartHoverBoxBackground, under: .aqua)
        let dark = resolve(.chartHoverBoxBackground, under: .darkAqua)
        XCTAssertTrue(lightness(light) > 0.5, "hover box backdrop is light in Light Mode")
        XCTAssertTrue(lightness(dark) < 0.5, "hover box backdrop is dark in Dark Mode")
    }

    /// The high-contrast and vibrant variants of each appearance resolve the
    /// same way as their base appearance.
    func testPanelTintsFoldAppearanceVariants() {
        for variant in [NSAppearance.Name.vibrantLight, .accessibilityHighContrastAqua] {
            XCTAssertTrue(
                resolve(.panelCaption, under: variant) == resolve(.panelCaption, under: .aqua),
                "\(variant.rawValue) resolves like aqua")
        }
        for variant in [NSAppearance.Name.vibrantDark, .accessibilityHighContrastDarkAqua] {
            XCTAssertTrue(
                resolve(.panelCaption, under: variant) == resolve(.panelCaption, under: .darkAqua),
                "\(variant.rawValue) resolves like darkAqua")
        }
    }

    /// System tints carry their own light and dark variants; a fixed sRGB
    /// value would resolve identically under both.
    func testBarColorsAreDynamic() {
        for c in BarColor.allCases {
            let light = resolve(c.nsColor, under: .aqua)
            let dark = resolve(c.nsColor, under: .darkAqua)
            XCTAssertTrue(light != dark, "\(c.rawValue) resolves differently in Light and Dark Mode")
        }
    }

    /// A `barColorHex` override is a fixed color by design.
    func testHexOverrideIsFixed() {
        let custom = NSColor(hexString: "0A84FF")!
        XCTAssertTrue(
            resolve(custom, under: .aqua) == resolve(custom, under: .darkAqua),
            "hex override is appearance-independent")
    }

    // MARK: - Panel views

    private static let ringsFrame = CGRect(x: 0, y: 0, width: 100, height: PanelGeometry.ringsRowHeight)

    /// The section title and its flanking rules draw in dark ink on a light
    /// appearance and light ink on a dark one.
    func testSectionHeaderInkInverts() {
        let view = SectionHeaderView(title: "session", frame: CGRect(x: 0, y: 0, width: 264, height: 20))
        let light = paintedPixels(of: view, under: .aqua)
        let dark = paintedPixels(of: view, under: .darkAqua)
        XCTAssertTrue(light.count > 100, "the header paints something in Light Mode")
        XCTAssertTrue(meanLightness(light) < 0.5, "header ink is dark in Light Mode")
        XCTAssertTrue(meanLightness(dark) > 0.5, "header ink is light in Dark Mode")
    }

    /// Ring labels, values and captions - the text the Light Mode bug made
    /// illegible - invert with the appearance. Only pixels above 50% alpha
    /// are measured: text cores are 60% or more, the `clearTint` track is 20%.
    func testRingsRowTextInverts() {
        let ring = RingModel(label: "SESSION", color: clearTint, fraction: 0.5, value: "41%", caption: "2h39m")
        let view = RingsRowView(rings: [ring], frame: Self.ringsFrame)
        let light = paintedPixels(of: view, under: .aqua).filter { $0.alpha > 0.5 }
        let dark = paintedPixels(of: view, under: .darkAqua).filter { $0.alpha > 0.5 }
        XCTAssertTrue(light.count > 100, "the rings row paints text in Light Mode")
        XCTAssertTrue(meanLightness(light) < 0.5, "ring text is dark in Light Mode")
        XCTAssertTrue(meanLightness(dark) > 0.5, "ring text is light in Dark Mode")
    }

    /// The ring's own tint is the model's color regardless of appearance, so
    /// a hex override keeps its color on both. The caching bitmap is Generic
    /// RGB, so pure sRGB red does not round-trip exactly; red-dominant is the
    /// check.
    func testRingTintIsTheModelColor() {
        let ring = RingModel(label: "", color: NSColor(hexString: "FF0000")!, fraction: 1, value: "", caption: "")
        let view = RingsRowView(rings: [ring], frame: Self.ringsFrame)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let opaque = paintedPixels(of: view, under: appearance).filter { $0.alpha > 0.95 }
            XCTAssertTrue(opaque.count > 100, "the full arc paints opaque pixels under \(appearance.rawValue)")
            XCTAssertTrue(
                opaque.allSatisfy { $0.red > 0.9 && $0.green < 0.25 && $0.blue < 0.1 },
                "the arc is the model's red under \(appearance.rawValue)")
        }
    }

    // MARK: - Chart view

    private static let chartFrame = CGRect(x: 0, y: 0, width: 264, height: 120)
    private static let chartWindow = TimeWindow(start: 0, end: 3600)

    private func chart(series: [ChartSeriesModel], placeholder: String? = nil) -> ChartView {
        ChartView(
            series: series, window: Self.chartWindow, placeholder: placeholder, spansDays: false,
            frame: Self.chartFrame)
    }

    /// Gridlines and axis labels draw in dark ink on a light appearance and
    /// light ink on a dark one. No series, so nothing else is painted.
    func testChartGridAndLabelsInvert() {
        let view = chart(series: [])
        let light = paintedPixels(of: view, under: .aqua)
        let dark = paintedPixels(of: view, under: .darkAqua)
        XCTAssertTrue(light.count > 100, "the chart paints grid and labels in Light Mode")
        XCTAssertTrue(meanLightness(light) < 0.5, "chart ink is dark in Light Mode")
        XCTAssertTrue(meanLightness(dark) > 0.5, "chart ink is light in Dark Mode")
    }

    /// The placeholder text follows the appearance too.
    func testChartPlaceholderInverts() {
        let view = chart(series: [], placeholder: "No active session")
        XCTAssertTrue(meanLightness(paintedPixels(of: view, under: .aqua)) < 0.5, "placeholder is dark in Light Mode")
        XCTAssertTrue(
            meanLightness(paintedPixels(of: view, under: .darkAqua)) > 0.5, "placeholder is light in Dark Mode")
    }

    /// Hovering draws the readout box; its backdrop is white at 80% under
    /// aqua and black at 80% under darkAqua. The box interior is by far the
    /// largest area painted at exactly that alpha (the `clearTint` fill
    /// peaks at 28%), so the mean lightness of those pixels is the backdrop's.
    func testChartHoverBoxBackdropMatchesAppearance() {
        let series = ChartSeriesModel(color: clearTint, points: [(ts: 0, value: 50), (ts: 3600, value: 60)])
        let view = chart(series: [series])
        let hover = NSEvent.mouseEvent(
            with: .mouseMoved, location: CGPoint(x: 130, y: 60), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        view.mouseMoved(with: hover)

        func backdropLightness(under appearance: NSAppearance.Name) -> CGFloat {
            let backdrop = paintedPixels(of: view, under: appearance).filter { abs($0.alpha - 0.8) < 0.01 }
            XCTAssertTrue(
                backdrop.count > 100, "the hover box paints an 80%-alpha backdrop under \(appearance.rawValue)")
            return meanLightness(backdrop)
        }
        XCTAssertTrue(backdropLightness(under: .aqua) > 0.5, "hover box backdrop is light in Light Mode")
        XCTAssertTrue(backdropLightness(under: .darkAqua) < 0.5, "hover box backdrop is dark in Dark Mode")
    }

    // MARK: - Panel backdrop

    /// The pre-macOS 26 backdrop uses an appearance-following material with
    /// no appearance override of its own.
    func testLegacyPanelBackdropFollowsAppearance() {
        let content = NSView(frame: .zero)
        let backdrop = UsagePanelController.legacyBackground(for: content, size: CGSize(width: 300, height: 200))
        XCTAssertTrue(backdrop.material == .popover, "legacy backdrop uses the popover material")
        XCTAssertTrue(backdrop.appearance == nil, "legacy backdrop does not pin an appearance")
        XCTAssertTrue(backdrop.subviews.contains(content), "legacy backdrop hosts the content")
    }

    // MARK: - Menu bar

    /// The gauge image must draw under either menu bar appearance.
    func testGaugeImageDrawsUnderBothAppearances() {
        let metric = Metric(key: MetricKey.session, usedPct: 40, remainingPct: 60, reset: nil)
        var state = UsageState.initial(now: 0, prefs: .standard)
        state.session = MetricState(metric: metric, resetAnchor: nil, remainingSeconds: nil)
        let gauges = StatusBarRenderer.gauges(
            presentations: state.presentations, layout: .columns, baseColor: BarColor.blue.nsColor)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                forceDraw(StatusBarRenderer.image(gauges: gauges, layout: .columns, countdownLines: ["2:39", "2.3d"]))
            }
        }
    }

    /// Changing the status button's effective appearance re-renders the
    /// menu bar image without waiting for a poll or tick.
    func testStatusItemRerendersOnAppearanceChange() throws {
        let controller = StatusItemController(clock: { 0 })
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        let button = try XCTUnwrap(controller.statusItem.button, "the test process can host a status item")
        controller.observeAppearance(of: button)
        XCTAssertTrue(button.image == nil, "nothing rendered before any appearance change")

        button.appearance = NSAppearance(named: .darkAqua)
        let first = try XCTUnwrap(button.image, "the first appearance change renders an image")

        button.appearance = NSAppearance(named: .aqua)
        let second = try XCTUnwrap(button.image, "the second appearance change renders an image")
        XCTAssertTrue(first !== second, "each appearance change regenerates the image")
    }
}
