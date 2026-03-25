import AppKit

// MARK: - Project Badge (Capsule)

/// Stable hash for strings (including CJK). Uses FNV-1a 32-bit.
func stableStringHash(_ string: String) -> UInt32 {
    var hash: UInt32 = 2_166_136_261 // FNV offset basis
    for byte in string.utf8 {
        hash ^= UInt32(byte)
        hash &*= 16_777_619 // FNV prime
    }
    return hash
}

func badgeColorForProject(_ name: String) -> NSColor {
    let hash = stableStringHash(name)
    let index = Int(hash % UInt32(Banner.badgeColors.count))
    return Banner.badgeColors[index]
}

/// Creates a capsule badge view: colored background + white text
func makeProjectBadge(_ name: String) -> NSView {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.cornerRadius = Banner.badgeCornerRadius
    container.layer?.masksToBounds = true
    container.layer?.backgroundColor = badgeColorForProject(name).cgColor

    let label = NSTextField(labelWithString: name)
    label.font = Banner.badgeFont
    label.textColor = .white
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.isEditable = false
    label.isSelectable = false
    label.drawsBackground = false
    label.isBordered = false
    label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    label.setContentHuggingPriority(.required, for: .horizontal)
    label.setContentHuggingPriority(.required, for: .vertical)
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    label.translatesAutoresizingMaskIntoConstraints = false

    container.addSubview(label)

    NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(
            equalTo: container.leadingAnchor, constant: Banner.badgePaddingH),
        label.trailingAnchor.constraint(
            equalTo: container.trailingAnchor, constant: -Banner.badgePaddingH),
        label.topAnchor.constraint(
            equalTo: container.topAnchor, constant: Banner.badgePaddingV),
        label.bottomAnchor.constraint(
            equalTo: container.bottomAnchor, constant: -Banner.badgePaddingV)
    ])

    container.setContentHuggingPriority(.required, for: .horizontal)
    container.setContentHuggingPriority(.required, for: .vertical)
    container.setContentCompressionResistancePriority(.required, for: .horizontal)
    container.setContentCompressionResistancePriority(.required, for: .vertical)

    return container
}

// MARK: - Label Factory

func makeBannerLabel(
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

func makeBannerAttributedLabel(
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

// MARK: - Glass Background

func makeGlassBackground() -> NSVisualEffectView {
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
