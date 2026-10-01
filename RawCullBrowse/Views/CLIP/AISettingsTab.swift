import SwiftUI

struct AISettingsTab: View {
    @Environment(FileBrowserViewModel.self) private var viewModel
    @State private var showModelDownloads = false

    var body: some View {
        Form {
            Section("AI Models") {
                ForEach(CLIPModelDownloadCatalog.production.models) { descriptor in
                    AIModelStatusRow(
                        name: descriptor.displayName,
                        state: viewModel.clipModelDownloadStates[descriptor.id] ?? .checking,
                    )
                }

                HStack {
                    Button("Download AI Models", systemImage: "arrow.down.circle") {
                        showModelDownloads = true
                    }

                    Button("Check Again", systemImage: "arrow.clockwise") {
                        Task { await viewModel.refreshCLIPModels() }
                    }

                    Spacer()
                }

                Text("""
                Downloaded models are used automatically. A folder selected in Manual AI overrides \
                the downloaded model until the selection is cleared.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .sheet(isPresented: $showModelDownloads) {
            CLIPModelDownloadsView(viewModel: viewModel)
        }
        .task { await viewModel.refreshCLIPModels() }
    }
}
