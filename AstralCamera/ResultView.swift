import SwiftUI

struct ResultView: View {
    @ObservedObject var model: SessionModel
    @State private var showNotes = false

    var body: some View {
        if let result = model.result {
            ZStack {
                if let image = result.image {
                    Image(decorative: image, scale: 1, orientation: result.orientation)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityHidden(true)
                }
                VStack(spacing: 10) {
                    GlassGroup(spacing: 8) {
                        HStack(spacing: 8) {
                            if let export = result.export {
                                Label(export.savedToPhotos ? LocalizedStringKey("Saved to Photos.")
                                                           : LocalizedStringKey("No Photos access – the file is in the Files app."),
                                      systemImage: export.savedToPhotos ? "checkmark.circle.fill" : "folder")
                                    .font(.footnote.weight(.semibold))
                                    .lineLimit(2)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 36)
                                    .nightGlass(Capsule())
                            }
                            Spacer(minLength: 0)
                            Button { withAnimation(.snappy) { showNotes.toggle() } } label: {
                                Image(systemName: "doc.text.magnifyingglass")
                            }
                            .buttonStyle(GlassIconButtonStyle(size: 36, prominent: showNotes))
                            .accessibilityLabel("Details")
                        }
                    }
                    if showNotes {
                        notes(result)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    GlassGroup(spacing: 10) {
                        HStack(spacing: 10) {
                            if let export = result.export {
                                ShareLink(item: export.jpeg) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(GlassCapsuleButtonStyle())
                            }
                            Button { model.newSession() } label: {
                                Label("New session", systemImage: "camera.aperture")
                            }
                            .buttonStyle(GlassCapsuleButtonStyle(prominent: true))
                        }
                        .frame(maxWidth: 520)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .foregroundStyle(Theme.primary)
        }
    }

    private func notes(_ result: SessionResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let export = result.export {
                    Text("Files: \(export.folder.lastPathComponent) (JPEG + 32-bit linear TIFF)")
                        .foregroundStyle(Theme.primary)
                }
                ForEach(result.notes, id: \.self) { Text($0) }
            }
            .font(.caption.monospaced())
            .foregroundStyle(Theme.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .frame(maxHeight: 320)
        .nightGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
