import AppKit

/// Borderless vibrant panel showing the usage history charts, styled after
/// iStat Menus / exelban-Stats popovers. `.titled` makes the panel
/// key-capable (needed so `windowDidResignKey` fires on click-outside)
/// while `.nonactivatingPanel` keeps the host app from activating when it
/// opens; with no in-panel controls in v1, there is no first-responder
/// complication either property would otherwise introduce.
final class UsagePanel: NSPanel {
    init(contentSize: CGSize) {
        super.init(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        level = .statusBar
    }

    required init?(coder: NSCoder) {
        fatalError("UsagePanel does not support coding")
    }
}

/// Owns the panel's lifecycle and content: opening positioned against the
/// status item button (native-menu style), closing on resign-key, and
/// rebuilding its content on demand.
package final class UsagePanelController: NSObject, NSWindowDelegate {
    /// The status button's action fires on mouseDown, so a click landing on
    /// the button while the panel is still closing from a resign-key
    /// (click-outside) would otherwise reopen it instantly. Debouncing a
    /// reopen this soon after a close fixes the flicker; the window is
    /// bounded by AppKit's event ordering, not by how long the user holds
    /// the click.
    ///
    /// `closedAt`/`Date()` below time this UI event, not domain state, so
    /// they stay off the injected clock (`StatusItemController.clock`).
    private static let reopenDebounce: TimeInterval = 0.2

    private var panel: UsagePanel?
    private var closedAt: Date?

    /// Notified whenever the panel closes, for any reason (a deliberate
    /// re-click of the status item, or resign-key from a click-outside) —
    /// lets `StatusItemController` mirror native menu highlight behavior
    /// without polling `isVisible`.
    var onClose: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Opens the panel positioned against `button`, or closes it if already
    /// open. Decided synchronously so two fast clicks cannot race.
    func toggle(model: PanelModel, relativeTo button: NSStatusBarButton) {
        if isVisible {
            closePanel()
            return
        }
        if let closedAt, Date().timeIntervalSince(closedAt) < Self.reopenDebounce {
            return
        }
        openPanel(model: model, relativeTo: button)
    }

    /// Rebuilds the panel's content in place; a no-op while the panel is
    /// closed. Rebuilding beats diffing for a view tree this small.
    func update(model: PanelModel) {
        guard let panel, panel.isVisible else { return }
        let layout = PanelGeometry.layout()
        panel.setContentSize(layout.size)
        panel.contentView = Self.buildContent(model: model, layout: layout)
    }

    private func openPanel(model: PanelModel, relativeTo button: NSStatusBarButton) {
        let layout = PanelGeometry.layout()

        // Fail hard: a live status item button always has a window, and
        // that window always has a screen.
        let buttonWindow = button.window!
        let screen = buttonWindow.screen!
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let origin = PanelGeometry.origin(
            buttonFrame: buttonFrame, panelSize: layout.size, visibleFrame: screen.visibleFrame)

        let panel = self.panel ?? UsagePanel(contentSize: layout.size)
        panel.delegate = self
        panel.setContentSize(layout.size)
        panel.contentView = Self.buildContent(model: model, layout: layout)
        panel.setFrameOrigin(origin)
        self.panel = panel

        panel.makeKeyAndOrderFront(nil)
    }

    /// `panel.close()` can itself trigger `windowDidResignKey` synchronously
    /// (resigning key status is part of closing a key window), which would
    /// call this method again before the outer call returns. The guard
    /// makes a second, re-entrant call a no-op instead of double-stamping
    /// `closedAt` and firing `onClose` twice.
    private func closePanel() {
        guard let panel, panel.isVisible else { return }
        panel.close()
        closedAt = Date()
        onClose?()
    }

    package func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }

    // MARK: - Content

    private static let footerFontSize: CGFloat = 11

    private static func buildContent(model: PanelModel, layout: PanelGeometry.PanelLayout) -> NSView {
        let container = FlippedView(frame: CGRect(origin: .zero, size: layout.size))

        container.addSubview(RingsRowView(rings: model.rings, frame: layout.ringsRow))

        container.addSubview(SectionHeaderView(title: "SESSION", frame: layout.sessionHeader))
        container.addSubview(
            ChartView(
                series: model.sessionSeries, window: model.sessionWindow,
                placeholder: model.sessionPlaceholder, spansDays: false, frame: layout.sessionChart))

        container.addSubview(SectionHeaderView(title: "THIS WEEK", frame: layout.weekHeader))
        container.addSubview(
            ChartView(
                series: model.weekSeries, window: model.weekWindow,
                placeholder: model.weekPlaceholder, spansDays: true, frame: layout.weekChart))

        let footer = NSTextField(labelWithString: model.footer)
        footer.font = .systemFont(ofSize: footerFontSize)
        footer.textColor = .secondaryLabelColor
        footer.frame = lineFrame(
            x: layout.footer.minX, width: layout.footer.width,
            in: layout.footer, font: footer.font!)
        container.addSubview(footer)

        return background(for: container, size: layout.size)
    }

    /// The glass backdrop behind `content` (`NSGlassEffectView`, macOS 26),
    /// deliberately stock: default style, no tint, no appearance override —
    /// the same blurred glass the system's own menu bar panels (Weather,
    /// Control Center) draw, following the system appearance as they do.
    /// Falls back to `legacyBackground` on older systems.
    private static func background(for content: NSView, size: CGSize) -> NSView {
        let frame = CGRect(origin: .zero, size: size)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = PanelGeometry.cornerRadius
            glass.contentView = content
            return glass
        }
        return legacyBackground(for: content, size: size)
    }

    /// The pre-macOS 26 backdrop: the `.popover` material, which like the
    /// glass follows the system appearance, as the content's dynamic colors
    /// require. Separate from `background` so tests can reach it on systems
    /// that take the glass path.
    package static func legacyBackground(for content: NSView, size: CGSize) -> NSVisualEffectView {
        let frame = CGRect(origin: .zero, size: size)
        let effectView = NSVisualEffectView(frame: frame)
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = PanelGeometry.cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.addSubview(content)
        return effectView
    }

    /// Single-line label frame vertically centered in `rect` at the font's
    /// natural line height.
    private static func lineFrame(x: CGFloat, width: CGFloat, in rect: CGRect, font: NSFont) -> CGRect {
        let height = ceil(font.ascender - font.descender)
        return CGRect(x: x, y: rect.midY - height / 2, width: width, height: height)
    }
}

/// Top-down layout (`PanelGeometry.layout`'s frames) assumes a flipped
/// container: y grows downward from the panel's top edge.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
