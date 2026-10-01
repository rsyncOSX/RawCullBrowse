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

                Text("Downloaded models are used automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Semantic Search") {
                LabeledContent("Maximum results") {
                    Stepper(value: Binding(
                        get: { viewModel.semanticSearchLimit },
                        set: { viewModel.adjustSemanticSearchLimit(by: $0 - viewModel.semanticSearchLimit) },
                    ), in: 10 ... 500, step: 10) {
                        Text(viewModel.semanticSearchLimit, format: .number)
                            .monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showModelDownloads) {
            CLIPModelDownloadsView(viewModel: viewModel)
        }
        .task { await viewModel.refreshCLIPModels() }
    }
}

struct AIModelStatusRow: View {
    let name: String
    let state: CLIPModelDownloadState

    var body: some View {
        HStack(spacing: 8) {
            Text(name)

            Spacer()

            if state.isInstalled {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text(state.title)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) model")
        .accessibilityValue(String(localized: state.title))
    }
}
