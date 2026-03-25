import AppKit
import CommonCrypto
import Foundation

// MARK: - Project Logo

extension DashboardStore {
    private static var logosDir: String {
        "\(NSHomeDirectory())/.codo/project-logos"
    }

    /// Set a custom logo for a project. Resizes to 64×64 PNG.
    func setProjectLogo(for projectId: String, imageURL: URL) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }),
              let nsImage = NSImage(contentsOf: imageURL) else { return }

        // Ensure logos directory exists
        let dir = Self.logosDir
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        // SHA256 prefix of cwd for unique filename
        let hash = sha256Prefix(projectId, length: 8)
        let logoPath = "\(dir)/\(hash).png"

        // Resize to 64×64 and save as PNG
        let resized = resizeImage(nsImage, to: NSSize(width: 64, height: 64))
        guard let tiffData = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(
                  using: .png,
                  properties: [:]
              ) else { return }

        try? pngData.write(to: URL(fileURLWithPath: logoPath))
        projects[idx].customLogoPath = logoPath
    }

    /// Remove the custom logo for a project.
    func removeProjectLogo(for projectId: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId })
        else { return }

        // Delete old file if it exists
        if let oldPath = projects[idx].customLogoPath {
            try? FileManager.default.removeItem(atPath: oldPath)
        }
        projects[idx].customLogoPath = nil
    }

    func sha256Prefix(_ input: String, length: Int) -> String {
        let data = Data(input.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.prefix(length / 2)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func resizeImage(
        _ image: NSImage,
        to size: NSSize
    ) -> NSImage {
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()
        return newImage
    }
}
