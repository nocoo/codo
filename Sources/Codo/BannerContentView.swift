import AppKit
import CodoCore

// MARK: - Design Tokens

enum Banner {
    static let maxWidth: CGFloat = 400
    static let minHeight: CGFloat = 72
    static let cornerRadius: CGFloat = 16
    static let screenMargin: CGFloat = 24

    // Shadow overflow — extra padding around glass for shadows to render
    static let shadowPadding: CGFloat = 48  // >= ambient shadowRadius(40) + offset(8)

    // Content insets (within glass)
    static let paddingH: CGFloat = 14
    static let paddingTop: CGFloat = 12
    static let paddingBottom: CGFloat = 14

    // Left column: icon only, vertically centered
    static let iconSize: CGFloat = 40
    static let iconCornerRadius: CGFloat = 10
    static let leftColumnWidth: CGFloat = 40    // same as icon for icon-only column
    static let columnGap: CGFloat = 12          // left column → right content

    // Spacing between sections (right column)
    static let projectTitleGap: CGFloat = 2     // source label → title
    static let titleBodyGap: CGFloat = 4        // title → body

    // Close button — badge style, overlaps glass boundary
    static let closeButtonSize: CGFloat = 24

    // Timing
    static let displayDuration: TimeInterval = 5.0
    static let slideInDuration: TimeInterval = 0.3
    static let slideOutDuration: TimeInterval = 0.2

    // Typography
    static let projectFont = NSFont.systemFont(ofSize: 12, weight: .medium)
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
        layer?.masksToBounds = false  // allow close button + shadows to overflow

        let glass = makeGlassBackground()
        addSubview(glass)

        // ── Close button (badge style, overlaps top-left corner of glass) ──
        let closeBtn = makeCloseButton()
        addSubview(closeBtn)
        self.closeButton = closeBtn

        // ── Left column: Icon only (vertically centered in glass) ──
        let iconView = NSImageView()
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            iconView.image = appIcon
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = Banner.iconCornerRadius
        iconView.layer?.masksToBounds = true
        addSubview(iconView)

        // ── Right column: Source → Title → Body ──
        let projectLabel = makeBannerLabel(
            message.source ?? "Codo",
            font: Banner.projectFont,
            color: Banner.projectColor,
            maxLines: 1,
            wraps: false
        )
        addSubview(projectLabel)

        let titleLabel = makeBannerLabel(
            message.title,
            font: Banner.titleFont,
            color: Banner.titleColor,
            maxLines: 2,
            wraps: true
        )
        addSubview(titleLabel)

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
            )
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
        views: LayoutViews
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
        let shadowPad = Banner.shadowPadding

        // Right column leading = shadowPadding + paddingH + leftColumn + columnGap
        let rightLeading = shadowPad + pad + Banner.leftColumnWidth + Banner.columnGap

        var constraints = [
            // Glass is inset from view edges by shadowPadding on all sides
            glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: shadowPad),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -shadowPad),
            glass.topAnchor.constraint(equalTo: topAnchor, constant: shadowPad),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -shadowPad),

            // Close button: badge centered on glass top-left corner
            closeButton.centerXAnchor.constraint(equalTo: glass.leadingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: glass.topAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: Banner.closeButtonSize),
            closeButton.heightAnchor.constraint(equalToConstant: Banner.closeButtonSize),

            // Left column: icon vertically centered in glass
            iconView.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: pad),
            iconView.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Banner.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Banner.iconSize),

            // Right column: Source label
            projectLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: rightLeading),
            projectLabel.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -pad),
            projectLabel.topAnchor.constraint(equalTo: glass.topAnchor, constant: Banner.paddingTop),

            // Right column: Title below source
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: rightLeading),
            titleLabel.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -pad),
            titleLabel.topAnchor.constraint(
                equalTo: projectLabel.bottomAnchor, constant: Banner.projectTitleGap)
        ]

        if let bodyLabel {
            constraints += [
                bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: rightLeading),
                bodyLabel.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -pad),
                bodyLabel.topAnchor.constraint(
                    equalTo: titleLabel.bottomAnchor, constant: Banner.titleBodyGap),
                bodyLabel.bottomAnchor.constraint(
                    lessThanOrEqualTo: glass.bottomAnchor, constant: -Banner.paddingBottom)
            ]
        } else {
            constraints.append(
                titleLabel.bottomAnchor.constraint(
                    lessThanOrEqualTo: glass.bottomAnchor, constant: -Banner.paddingBottom)
            )
        }

        // Left column bottom constraint (ensure glass tall enough for icon)
        constraints.append(
            iconView.bottomAnchor.constraint(
                lessThanOrEqualTo: glass.bottomAnchor, constant: -Banner.paddingBottom)
        )

        NSLayoutConstraint.activate(constraints)
    }

    override func layout() {
        super.layout()
        // Compute glass rect (inset by shadowPadding)
        let shadowPad = Banner.shadowPadding
        let glassRect = bounds.insetBy(dx: shadowPad, dy: shadowPad)

        // Apply ambient shadow on the view's own layer, matching glass shape
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.08
        layer?.shadowRadius = 40
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        layer?.shadowPath = CGPath(
            roundedRect: glassRect,
            cornerWidth: Banner.cornerRadius,
            cornerHeight: Banner.cornerRadius,
            transform: nil
        )

        // Keep contact shadow sublayer in sync with glass rect
        if let contactShadow = layer?.sublayers?.first(where: { $0.name == "contactShadow" }) {
            contactShadow.frame = bounds
            contactShadow.shadowPath = CGPath(
                roundedRect: glassRect,
                cornerWidth: Banner.cornerRadius,
                cornerHeight: Banner.cornerRadius,
                transform: nil
            )
        } else {
            // Create contact shadow on first layout
            let contactShadow = CALayer()
            contactShadow.name = "contactShadow"
            contactShadow.frame = bounds
            contactShadow.shadowColor = NSColor.black.cgColor
            contactShadow.shadowOpacity = 0.15
            contactShadow.shadowRadius = 8
            contactShadow.shadowOffset = CGSize(width: 0, height: -2)
            contactShadow.shadowPath = CGPath(
                roundedRect: glassRect,
                cornerWidth: Banner.cornerRadius,
                cornerHeight: Banner.cornerRadius,
                transform: nil
            )
            layer?.insertSublayer(contactShadow, at: 0)
        }
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
        let totalWidth = Banner.maxWidth + Banner.shadowPadding * 2
        let totalMinHeight = Banner.minHeight + Banner.shadowPadding * 2
        return NSSize(width: totalWidth, height: max(size.height, totalMinHeight))
    }

    // MARK: - Helpers

    private func makeCloseButton() -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.title = ""
        if let img = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close") {
            btn.image = img.withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        }
        btn.contentTintColor = .secondaryLabelColor
        btn.wantsLayer = true
        btn.layer?.cornerRadius = Banner.closeButtonSize / 2
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
