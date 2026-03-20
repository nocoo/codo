import AppKit
import CodoCore

// MARK: - Design Tokens

enum Banner {
    static let maxWidth: CGFloat = 360
    static let minHeight: CGFloat = 72
    static let cornerRadius: CGFloat = 18
    static let screenMargin: CGFloat = 12

    // Content insets
    static let paddingH: CGFloat = 14
    static let paddingTop: CGFloat = 10
    static let paddingBottom: CGFloat = 12

    // Icon — header row, small icon next to app name
    static let iconSize: CGFloat = 20
    static let iconCornerRadius: CGFloat = 5
    static let iconTextGap: CGFloat = 6

    // Spacing between rows
    static let headerContentGap: CGFloat = 6    // header row → title
    static let titleBodyGap: CGFloat = 2        // title → body

    // Close button
    static let closeButtonSize: CGFloat = 20
    static let closeButtonInset: CGFloat = 8

    // Timing
    static let displayDuration: TimeInterval = 5.0
    static let slideInDuration: TimeInterval = 0.3
    static let slideOutDuration: TimeInterval = 0.2

    // Typography
    static let projectFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let titleFont = NSFont.systemFont(ofSize: 14, weight: .bold)
    static let bodyFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let timestampFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    // Colors
    static let projectColor = NSColor.secondaryLabelColor
    static let titleColor = NSColor.labelColor
    static let bodyColor = NSColor.secondaryLabelColor
    static let timestampColor = NSColor.tertiaryLabelColor
}

// MARK: - BannerContentView

final class BannerContentView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onCloseClicked: (() -> Void)?
    private var closeButton: NSButton!
    private var currentTrackingArea: NSTrackingArea?

    init(message: CodoMessage) {
        super.init(frame: .zero)
        wantsLayer = true

        // ── Shadow ──
        let shadowLayer = layer ?? CALayer()
        if layer == nil { layer = shadowLayer }
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.12
        shadowLayer.shadowRadius = 30
        shadowLayer.shadowOffset = CGSize(width: 0, height: -4)

        // ── Frosted glass background ──
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.state = .active
        glass.blendingMode = .behindWindow
        glass.wantsLayer = true
        glass.layer?.cornerRadius = Banner.cornerRadius
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0.5
        glass.layer?.borderColor = NSColor.separatorColor.cgColor
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

        let projectLabel = makeLabel(
            message.source ?? "Codo",
            font: Banner.projectFont,
            color: Banner.projectColor,
            maxLines: 1,
            wraps: false
        )
        addSubview(projectLabel)

        // ── "now" timestamp (right-aligned in header) ──
        let timestampLabel = makeLabel(
            "now",
            font: Banner.timestampFont,
            color: Banner.timestampColor,
            maxLines: 1,
            wraps: false
        )
        addSubview(timestampLabel)

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
            let label = makeLabel(body, font: Banner.bodyFont, color: Banner.bodyColor, maxLines: 4, wraps: true)
            addSubview(label)
            bodyLabel = label
        }

        // ── Close button (hidden by default, shown on hover) ──
        let closeBtn = makeCloseButton()
        addSubview(closeBtn)
        self.closeButton = closeBtn

        activateLayout(
            glass: glass,
            header: HeaderViews(icon: iconView, project: projectLabel, timestamp: timestampLabel),
            titleLabel: titleLabel,
            bodyLabel: bodyLabel,
            closeButton: closeBtn
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private struct HeaderViews {
        let icon: NSView
        let project: NSView
        let timestamp: NSView
    }

    private func activateLayout(
        glass: NSView,
        header: HeaderViews,
        titleLabel: NSView,
        bodyLabel: NSTextField?,
        closeButton: NSButton
    ) {
        let iconView = header.icon
        let projectLabel = header.project
        let timestampLabel = header.timestamp

        for view in [glass, iconView, projectLabel, timestampLabel, titleLabel, closeButton] as [NSView] {
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

            // Close button: top-right inside glass
            closeButton.topAnchor.constraint(equalTo: glass.topAnchor, constant: Banner.closeButtonInset),
            closeButton.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Banner.closeButtonInset),
            closeButton.widthAnchor.constraint(equalToConstant: Banner.closeButtonSize),
            closeButton.heightAnchor.constraint(equalToConstant: Banner.closeButtonSize),

            // Row 1: [icon] [gap] AppName ── (spring) ── now
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: Banner.paddingTop),
            iconView.widthAnchor.constraint(equalToConstant: Banner.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Banner.iconSize),

            projectLabel.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor, constant: Banner.iconTextGap),
            projectLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            // Timestamp right-aligned, same baseline as project name
            timestampLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            timestampLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            // Spring: project label doesn't overlap timestamp
            projectLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: timestampLabel.leadingAnchor, constant: -6),

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

    // MARK: - Hover Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = currentTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        currentTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
        onHoverChanged?(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    @objc private func closeButtonClicked() {
        onCloseClicked?()
    }

    // MARK: - Sizing

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

    private func makeCloseButton() -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.title = ""
        if let img = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close") {
            btn.image = img.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        }
        btn.contentTintColor = .tertiaryLabelColor
        btn.target = self
        btn.action = #selector(closeButtonClicked)
        btn.isHidden = true
        return btn
    }

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
