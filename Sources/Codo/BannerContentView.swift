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

    // Left column: icon only, top-aligned
    static let iconSize: CGFloat = 40
    static let iconCornerRadius: CGFloat = 10
    static let leftColumnWidth: CGFloat = 40    // same as icon for icon-only column
    static let columnGap: CGFloat = 12          // left column → right content

    // Spacing between sections (right column)
    static let badgeTitleGap: CGFloat = 6       // badge → title (horizontal)
    static let titleBodyGap: CGFloat = 4        // title row → body

    // Project badge (capsule)
    static let badgePaddingH: CGFloat = 8
    static let badgePaddingV: CGFloat = 2
    static let badgeCornerRadius: CGFloat = 8
    static let badgeFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    // Close button — badge style, overlaps glass boundary
    static let closeButtonSize: CGFloat = 24

    // Timing
    static let displayDuration: TimeInterval = 5.0
    static let slideInDuration: TimeInterval = 0.3
    static let slideOutDuration: TimeInterval = 0.2

    // Typography
    static let titleFont = NSFont.systemFont(ofSize: 14, weight: .bold)
    static let bodyFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let headingFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    // Colors
    static let titleColor = NSColor.labelColor
    static let bodyColor = NSColor.secondaryLabelColor
    static let codeColor = NSColor.tertiaryLabelColor
    static let codeBgColor = NSColor.quaternaryLabelColor

    // Badge color palette — vibrant, white-text-friendly
    static let badgeColors: [NSColor] = [
        NSColor(red: 0.35, green: 0.56, blue: 0.98, alpha: 1),  // blue
        NSColor(red: 0.90, green: 0.42, blue: 0.45, alpha: 1),  // coral
        NSColor(red: 0.55, green: 0.78, blue: 0.25, alpha: 1),  // green
        NSColor(red: 0.80, green: 0.52, blue: 0.90, alpha: 1),  // purple
        NSColor(red: 0.95, green: 0.62, blue: 0.22, alpha: 1),  // orange
        NSColor(red: 0.25, green: 0.75, blue: 0.72, alpha: 1),  // teal
        NSColor(red: 0.92, green: 0.45, blue: 0.68, alpha: 1),  // pink
        NSColor(red: 0.60, green: 0.60, blue: 0.35, alpha: 1)   // olive
    ]
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

        // ── Left column: Icon only (top-aligned in glass) ──
        let iconView = NSImageView()
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            iconView.image = appIcon
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = Banner.iconCornerRadius
        iconView.layer?.masksToBounds = true
        addSubview(iconView)

        // ── Right column, row 1: [Badge] [Title] on one line ──
        let projectName = message.source ?? "Codo"
        let projectBadge = makeProjectBadge(projectName)
        addSubview(projectBadge)

        let titleLabel = makeBannerLabel(
            message.title,
            font: Banner.titleFont,
            color: Banner.titleColor,
            maxLines: 2,
            wraps: true
        )
        addSubview(titleLabel)

        // ── Right column, row 2: Body (optional) ──
        var bodyView: NSTextField?
        if let body = message.body, !body.isEmpty {
            let label = makeBannerAttributedLabel(
                MarkdownRenderer.render(body, maxLines: 12),
                maxLines: 12
            )
            addSubview(label)
            bodyView = label
        }

        activateLayout(
            glass: glass,
            views: LayoutViews(
                icon: iconView, badge: projectBadge,
                title: titleLabel, body: bodyView, close: closeBtn
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private struct LayoutViews {
        let icon: NSView
        let badge: NSView
        let title: NSView
        let body: NSTextField?
        let close: NSButton
    }

    private func activateLayout(
        glass: NSView,
        views: LayoutViews
    ) {
        let iconView = views.icon
        let badge = views.badge
        let titleLabel = views.title
        let bodyLabel = views.body
        let closeButton = views.close

        for view in [glass, iconView, badge, titleLabel, closeButton] as [NSView] {
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

            // Left column: icon top-aligned in glass
            iconView.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: pad),
            iconView.topAnchor.constraint(equalTo: glass.topAnchor, constant: Banner.paddingTop),
            iconView.widthAnchor.constraint(equalToConstant: Banner.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Banner.iconSize),

            // Row 1: [Badge] then [Title] — top-aligned on the same row
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: rightLeading),
            badge.topAnchor.constraint(equalTo: glass.topAnchor, constant: Banner.paddingTop),

            titleLabel.leadingAnchor.constraint(
                equalTo: badge.trailingAnchor, constant: Banner.badgeTitleGap),
            titleLabel.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -pad),
            titleLabel.topAnchor.constraint(equalTo: badge.topAnchor)
        ]

        if let bodyLabel {
            constraints += [
                bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: rightLeading),
                bodyLabel.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -pad),
                // Body must be below both the title and the badge
                bodyLabel.topAnchor.constraint(
                    greaterThanOrEqualTo: badge.bottomAnchor, constant: Banner.titleBodyGap),
                bodyLabel.topAnchor.constraint(
                    equalTo: titleLabel.bottomAnchor, constant: Banner.titleBodyGap),
                bodyLabel.bottomAnchor.constraint(
                    lessThanOrEqualTo: glass.bottomAnchor, constant: -Banner.paddingBottom)
            ]
        } else {
            constraints += [
                titleLabel.bottomAnchor.constraint(
                    lessThanOrEqualTo: glass.bottomAnchor, constant: -Banner.paddingBottom),
                badge.bottomAnchor.constraint(
                    lessThanOrEqualTo: glass.bottomAnchor, constant: -Banner.paddingBottom)
            ]
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
