import SwiftUI
import UniformTypeIdentifiers

/// A single project row in the sidebar with logo picker.
struct ProjectRow: View {
    let project: ProjectInfo
    @Environment(DashboardStore.self) private var store
    @State private var showImagePicker = false

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
        .contextMenu {
            Button("Set Logo...") {
                showImagePicker = true
            }
            if project.customLogoPath != nil {
                Button("Remove Logo") {
                    store.removeProjectLogo(for: project.id)
                }
            }
        }
        .fileImporter(
            isPresented: $showImagePicker,
            allowedContentTypes: [.png, .jpeg, .heic],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.setProjectLogo(for: project.id, imageURL: url)
            }
        }
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
