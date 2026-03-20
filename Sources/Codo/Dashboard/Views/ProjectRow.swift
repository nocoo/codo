import SwiftUI

/// A single project row in the sidebar.
struct ProjectRow: View {
    let project: ProjectInfo

    var body: some View {
        HStack(spacing: 8) {
            projectIcon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)
                Text(project.lastSeen, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var projectIcon: some View {
        if let logoPath = project.customLogoPath,
           let nsImage = NSImage(contentsOfFile: logoPath) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 16))
        }
    }
}
