import AppKit
import CodoCore

// MARK: - Design Tokens

enum Banner {
    static let maxWidth: CGFloat = 400
    static let minHeight: CGFloat = 72
    static let cornerRadius: CGFloat = 16
    static let screenMargin: CGFloat = 24

    // Content insets
    static let paddingH: CGFloat = 14
    static let paddingTop: CGFloat = 10
    static let paddingBottom: CGFloat = 14

    // Icon — compact header row (icon + project name inline)
    static let iconSize: CGFloat = 20
    static let iconCornerRadius: CGFloat = 5
    static let iconTextGap: CGFloat = 6

    // Spacing between sections
    static let headerContentGap: CGFloat = 6    // header row → title
    static let titleBodyGap: CGFloat = 4        // title → body

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
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let headingFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    // Colors
    static let projectColor = NSColor.secondaryLabelColor
    static let titleColor = NSColor.labelColor
    static let bodyColor = NSColor.secondaryLabelColor
    static let codeColor = NSColor.tertiaryLabelColor
    static let codeBgColor = NSColor.quaternaryLabelColor
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

        let (_, contactShadow) = configureShadows(on: self)
        let glass = makeGlassBackground()
        addSubview(glass)

        // ── Close button (top-LEFT, hover-only) ──
        let closeBtn = makeCloseButton()
        addSubview(closeBtn)
        self.closeButton = closeBtn

        // ── Row 1: [AppIcon] [gap] ProjectName ──
        let iconView = NSImageView()
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            iconView.image = appIcon
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = Banner.iconCornerRadius
        iconView.layer?.masksToBounds = true
        addSubview(iconView)

        let projectLabel = makeBannerLabel(
            message.source ?? "Codo",
            font: Banner.projectFont,
            color: Banner.projectColor,
            maxLines: 1,
            wraps: false
        )
        addSubview(projectLabel)

        // ── Row 2: Title ──
        let titleLabel = makeBannerLabel(
            message.title,
            font: Banner.titleFont,
            color: Banner.titleColor,
            maxLines: 2,
            wraps: true
        )
        addSubview(titleLabel)

        // ── Row 3: Body with Markdown rendering (optional, max 8 lines) ──
        var bodyView: NSTextField?
        if let body = message.body, !body.isEmpty {
            let label = makeBannerAttributedLabel(
                MarkdownRenderer.render(body, maxLines: 8),
                maxLines: 8
            )
            addSubview(label)
            bodyView = label
        }

        activateLayout(
            glass: glass,
            views: LayoutViews(
                icon: iconView, project: projectLabel,
                title: titleLabel, body: bodyView, close: closeBtn
            ),
            contactShadow: contactShadow
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private struct LayoutViews {
        let icon: NSView
        let project: NSView
        let title: NSView
        let body: NSTextField?
        let close: NSButton
    }

    private func activateLayout(
        glass: NSView,
        views: LayoutViews,
        contactShadow: CALayer
    ) {
        let iconView = views.icon
        let projectLabel = views.project
        let titleLabel = views.title
        let bodyLabel = views.body
        let closeButton = views.close

        for view in [glass, iconView, projectLabel, titleLabel, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        bodyLabel?.translatesAutoresizingMaskIntoConstraints = false

        let pad = Banner.paddingH

        var constraints = [
            // Glass fills entire view
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Close button: top-LEFT
            closeButton.topAnchor.constraint(equalTo: glass.topAnchor, constant: Banner.closeButtonInset),
            closeButton.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Banner.closeButtonInset),
            closeButton.widthAnchor.constraint(equalToConstant: Banner.closeButtonSize),
            closeButton.heightAnchor.constraint(equalToConstant: Banner.closeButtonSize),

            // Row 1: [icon] [gap] ProjectName — left-aligned, compact
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: Banner.paddingTop),
            iconView.widthAnchor.constraint(equalToConstant: Banner.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Banner.iconSize),

            projectLabel.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor, constant: Banner.iconTextGap),
            projectLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            projectLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -pad),

            // Row 2: Title — full width below header row
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            titleLabel.topAnchor.constraint(
                equalTo: iconView.bottomAnchor, constant: Banner.headerContentGap)
        ]

        if let bodyLabel {
            constraints += [
                bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
                bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
                bodyLabel.topAnchor.constraint(
                    equalTo: titleLabel.bottomAnchor, constant: Banner.titleBodyGap),
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

    override func layout() {
        super.layout()
        // Keep contact shadow sublayer in sync with view bounds
        if let contactShadow = layer?.sublayers?.first(where: { $0.shadowRadius == 8 }) {
            contactShadow.frame = bounds
            contactShadow.shadowPath = CGPath(
                roundedRect: bounds,
                cornerWidth: Banner.cornerRadius,
                cornerHeight: Banner.cornerRadius,
                transform: nil
            )
        }
        // Update ambient shadow path for performance
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: Banner.cornerRadius,
            cornerHeight: Banner.cornerRadius,
            transform: nil
        )
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
}

// MARK: - Label Factory

private func makeBannerLabel(
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

private func makeBannerAttributedLabel(
    _ attributedString: NSAttributedString,
    maxLines: Int
) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: "")
    label.attributedStringValue = attributedString
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = maxLines
    label.isEditable = false
    label.isSelectable = false
    label.drawsBackground = false
    label.isBordered = false
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    label.setContentHuggingPriority(.required, for: .vertical)
    return label
}

// MARK: - View Factory

@discardableResult
private func configureShadows(on view: NSView) -> (ambient: CALayer, contact: CALayer) {
    let shadowLayer = view.layer ?? CALayer()
    if view.layer == nil { view.layer = shadowLayer }
    shadowLayer.shadowColor = NSColor.black.cgColor
    shadowLayer.shadowOpacity = 0.08
    shadowLayer.shadowRadius = 40
    shadowLayer.shadowOffset = CGSize(width: 0, height: -8)

    let contactShadow = CALayer()
    contactShadow.shadowColor = NSColor.black.cgColor
    contactShadow.shadowOpacity = 0.15
    contactShadow.shadowRadius = 8
    contactShadow.shadowOffset = CGSize(width: 0, height: -2)
    shadowLayer.addSublayer(contactShadow)

    return (shadowLayer, contactShadow)
}

private func makeGlassBackground() -> NSVisualEffectView {
    let glass = NSVisualEffectView()
    glass.material = .popover
    glass.state = .active
    glass.blendingMode = .behindWindow
    glass.wantsLayer = true
    glass.layer?.cornerRadius = Banner.cornerRadius
    glass.layer?.masksToBounds = true
    glass.layer?.borderWidth = 0.5
    glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
    return glass
}
