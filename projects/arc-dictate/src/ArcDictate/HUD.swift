import AppKit

/// A small floating panel near the top of the screen. It exists so that dictation is never
/// silent: you can see the mic is live, see the level moving, and see the words that were
/// captured. A result that only ever lands on the clipboard is a result you can lose
/// without noticing.
final class HUD {

    static let shared = HUD()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var meter: NSLevelIndicator?
    private var caption: NSTextField?
    private var dismissWork: DispatchWorkItem?

    private init() {}

    /// Shows the panel, or updates it if already visible.
    /// - Parameters:
    ///   - text: the main line.
    ///   - meterDB: a level in dBFS to draw as a bar, or nil to hide the bar.
    ///   - caption: a smaller second line, such as the paste hint.
    func show(_ text: String, meterDB: Float? = nil, caption captionText: String? = nil) {
        dismissWork?.cancel()
        dismissWork = nil

        let panel = self.panel ?? makePanel()
        self.panel = panel

        label?.stringValue = text

        if let meterDB {
            meter?.isHidden = false
            // -60 dBFS to 0 dBFS across the bar.
            meter?.doubleValue = Double(max(0, min(60, meterDB + 60)))
        } else {
            meter?.isHidden = true
        }

        caption?.stringValue = captionText ?? ""
        caption?.isHidden = (captionText == nil)

        layout(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Fades the panel away after a delay.
    func dismiss(after delay: TimeInterval = 0) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Construction

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 92),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 14, weight: .medium)
        text.textColor = .labelColor
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        let indicator = NSLevelIndicator()
        indicator.levelIndicatorStyle = .continuousCapacity
        indicator.minValue = 0
        indicator.maxValue = 60
        indicator.warningValue = 48      // about -12 dBFS
        indicator.criticalValue = 57     // about -3 dBFS
        indicator.translatesAutoresizingMaskIntoConstraints = false

        let sub = NSTextField(labelWithString: "")
        sub.font = .systemFont(ofSize: 11, weight: .regular)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [text, indicator, sub])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(effect)
        content.addSubview(stack)
        panel.contentView = content

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: content.topAnchor),
            effect.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            indicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            indicator.heightAnchor.constraint(equalToConstant: 12),
        ])

        self.label = text
        self.meter = indicator
        self.caption = sub
        return panel
    }

    private func layout(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let width: CGFloat = 460
        let height: CGFloat = (caption?.isHidden ?? true) ? 78 : 96
        let frame = screen.visibleFrame
        let origin = NSPoint(x: frame.midX - width / 2,
                             y: frame.maxY - height - 12)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }
}
