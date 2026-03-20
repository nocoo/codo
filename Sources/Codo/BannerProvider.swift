import AppKit
import CodoCore
import os

private let logger = Logger(subsystem: "ai.hexly.codo.04", category: "banner")

/// Custom banner notification provider using a floating NSPanel.
/// Replaces UNUserNotificationCenter to avoid system notification grouping/suppression.
public final class BannerProvider: NotificationProvider, @unchecked Sendable {
    private var currentBanner: BannerWindow?

    public var isAvailable: Bool { true }

    public init() {}

    public func requestPermission() async -> Bool { true }

    public func post(message: CodoMessage) async -> String? {
        await MainActor.run {
            showBanner(message: message)
        }
        return nil
    }

    @MainActor
    private func showBanner(message: CodoMessage) {
        if let existing = currentBanner {
            existing.dismissImmediately()
            currentBanner = nil
        }

        let banner = BannerWindow(message: message)
        currentBanner = banner
        banner.onDismiss = { [weak self] in
            self?.currentBanner = nil
        }
        banner.show()
    }
}

// MARK: - Design Tokens

private enum Banner {
    static let maxWidth: CGFloat = 380
    static let minHeight: CGFloat = 72
    static let cornerRadius: CGFloat = 14
    static let screenMargin: CGFloat = 16

    // Content insets
    static let paddingH: CGFloat = 16
    static let paddingTop: CGFloat = 12
    static let paddingBottom: CGFloat = 14

    // Icon — first row, next to project name
    static let iconSize: CGFloat = 36
    static let iconCornerRadius: CGFloat = 8
    static let iconTextGap: CGFloat = 10

    // Spacing between rows
    static let headerContentGap: CGFloat = 8    // header row → title
    static let titleBodyGap: CGFloat = 3        // title → body

    // Timing
    static let displayDuration: TimeInterval = 5.0
    static let slideInDuration: TimeInterval = 0.35
    static let slideOutDuration: TimeInterval = 0.25

    // Typography
    static let projectFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: 13, weight: .regular)

    // Colors
    static let projectColor = NSColor.secondaryLabelColor
    static let titleColor = NSColor.labelColor
    static let bodyColor = NSColor.secondaryLabelColor
}

// MARK: - BannerWindow

private final class BannerWindow: NSPanel {
    private var dismissTimer: Timer?
    private var slideOutOrigin: NSPoint = .zero
    var onDismiss: (() -> Void)?

    init(message: CodoMessage) {
        let frame = NSRect(x: 0, y: 0, width: Banner.maxWidth, height: Banner.minHeight)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        let content = BannerContentView(message: message)
        self.contentView = content

        let targetSize = NSSize(width: Banner.maxWidth, height: 0)
        let fittingHeight = content.fittingSize(for: targetSize).height
        let finalHeight = max(fittingHeight, Banner.minHeight)
        setContentSize(NSSize(width: Banner.maxWidth, height: finalHeight))
    }

    func show() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let size = frame.size

        let targetX = visibleFrame.maxX - size.width - Banner.screenMargin
        let posY = visibleFrame.minY + Banner.screenMargin
        let targetOrigin = NSPoint(x: targetX, y: posY)
        slideOutOrigin = NSPoint(x: visibleFrame.maxX + 20, y: posY)

        setFrameOrigin(slideOutOrigin)
        alphaValue = 1
        orderFrontRegardless()

        let targetFrame = NSRect(origin: targetOrigin, size: size)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Banner.slideInDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        }
        setFrame(targetFrame, display: true, animate: true)

        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: Banner.displayDuration,
            repeats: false
        ) { [weak self] _ in
            self?.dismissAnimated()
        }
    }

    func dismissAnimated() {
        dismissTimer?.invalidate()
        dismissTimer = nil

        let offFrame = NSRect(origin: slideOutOrigin, size: frame.size)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Banner.slideOutDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        setFrame(offFrame, display: true, animate: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + Banner.slideOutDuration + 0.05) { [weak self] in
            self?.close()
            self?.onDismiss?()
        }
    }

    func dismissImmediately() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        close()
        onDismiss?()
    }
}

// MARK: - BannerContentView

private final class BannerContentView: NSView {

    init(message: CodoMessage) {
        super.init(frame: .zero)
        wantsLayer = true

        // ── Shadow ──
        let shadowLayer = layer ?? CALayer()
        if layer == nil { layer = shadowLayer }
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.18
        shadowLayer.shadowRadius = 24
        shadowLayer.shadowOffset = CGSize(width: 0, height: -6)

        // ── Frosted glass background ──
        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.state = .active
        glass.blendingMode = .behindWindow
        glass.wantsLayer = true
        glass.layer?.cornerRadius = Banner.cornerRadius
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0.5
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        addSubview(glass)

        // ── Row 1: App icon + project name ──
        let iconView = NSImageView()
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            iconView.image = appIcon
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = Banner.iconCornerRadius
        iconView.layer?.masksToBounds = true
        addSubview(iconView)

        let projectName = message.source ?? "Codo"
        let projectLabel = makeLabel(
            projectName,
            font: Banner.projectFont,
            color: Banner.projectColor,
            maxLines: 1,
            wraps: false
        )
        addSubview(projectLabel)

        // ── Row 2: Title ──
        let titleLabel = makeLabel(
            message.title,
            font: Banner.titleFont,
            color: Banner.titleColor,
            maxLines: 2,
            wraps: true
        )
        addSubview(titleLabel)

        // ── Row 3: Body (optional) ──
        var bodyLabel: NSTextField?
        if let body = message.body, !body.isEmpty {
            let label = makeLabel(
                body,
                font: Banner.bodyFont,
                color: Banner.bodyColor,
                maxLines: 4,
                wraps: true
            )
            addSubview(label)
            bodyLabel = label
        }

        activateLayout(
            glass: glass,
            iconView: iconView,
            projectLabel: projectLabel,
            titleLabel: titleLabel,
            bodyLabel: bodyLabel
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func activateLayout(
        glass: NSView,
        iconView: NSView,
        projectLabel: NSView,
        titleLabel: NSView,
        bodyLabel: NSTextField?
    ) {
        for view in [glass, iconView, projectLabel, titleLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        bodyLabel?.translatesAutoresizingMaskIntoConstraints = false

        let pad = Banner.paddingH

        var constraints = [
            // Glass fills view
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Row 1: icon (left) + project name (center-Y aligned to icon)
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: Banner.paddingTop),
            iconView.widthAnchor.constraint(equalToConstant: Banner.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Banner.iconSize),

            projectLabel.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor, constant: Banner.iconTextGap),
            projectLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            projectLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -pad),

            // Row 2: title — full width below header row
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            titleLabel.topAnchor.constraint(
                equalTo: iconView.bottomAnchor, constant: Banner.headerContentGap),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad)
        ]

        if let bodyLabel {
            constraints += [
                bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
                bodyLabel.topAnchor.constraint(
                    equalTo: titleLabel.bottomAnchor, constant: Banner.titleBodyGap),
                bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
                bodyLabel.bottomAnchor.constraint(
                    lessThanOrEqualTo: bottomAnchor, constant: -Banner.paddingBottom)
            ]
        } else {
            constraints.append(
                titleLabel.bottomAnchor.constraint(
                    lessThanOrEqualTo: bottomAnchor, constant: -Banner.paddingBottom)
            )
        }

        NSLayoutConstraint.activate(constraints)
    }

    func fittingSize(for targetSize: NSSize) -> NSSize {
        let constraint = NSLayoutConstraint(
            item: self, attribute: .width, relatedBy: .equal,
            toItem: nil, attribute: .notAnAttribute, multiplier: 1,
            constant: targetSize.width
        )
        addConstraint(constraint)
        let size = fittingSize
        removeConstraint(constraint)
        return size
    }

    override var fittingSize: NSSize {
        let size = super.fittingSize
        return NSSize(width: Banner.maxWidth, height: max(size.height, Banner.minHeight))
    }

    // MARK: - Helpers

    private func makeLabel(
        _ text: String,
        font: NSFont,
        color: NSColor,
        maxLines: Int,
        wraps: Bool
    ) -> NSTextField {
        let label: NSTextField
        if wraps {
            label = NSTextField(wrappingLabelWithString: text)
            label.lineBreakMode = .byWordWrapping
        } else {
            label = NSTextField(labelWithString: text)
            label.lineBreakMode = .byTruncatingTail
        }
        label.font = font
        label.textColor = color
        label.maximumNumberOfLines = maxLines
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
        return label
    }
}
