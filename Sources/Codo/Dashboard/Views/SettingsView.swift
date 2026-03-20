import CodoCore
import SwiftUI

/// SwiftUI Settings panel, replacing the old AppKit SettingsWindow.
struct SettingsView: View {
    @EnvironmentObject private var viewModel: SettingsViewModel

    @State private var showSaveError = false
    @State private var saveErrorMessage = ""

    var body: some View {
        Form {
            Section("AI Guardian") {
                Toggle("Enable AI Guardian", isOn: $viewModel.guardianEnabled)
            }

            Section("Provider") {
                Picker("Provider", selection: $viewModel.provider) {
                    ForEach(GuardianSettings.builtinProviders, id: \.id) { info in
                        Text(info.label).tag(info.id)
                    }
                    Text("Custom").tag("custom")
                }
                .onChange(of: viewModel.provider) { _, _ in
                    viewModel.applyProviderDefaults()
                }

                SecureField("API Key", text: $viewModel.apiKey)
                    .textFieldStyle(.roundedBorder)

                if viewModel.isCustomProvider {
                    TextField("Base URL", text: $viewModel.baseURL)
                        .textFieldStyle(.roundedBorder)
                }

                modelPicker

                if viewModel.isCustomProvider {
                    Picker("SDK Type", selection: $viewModel.sdkType) {
                        Text("OpenAI").tag("openai")
                        Text("Anthropic").tag("anthropic")
                    }
                }

                TextField(
                    "Context Limit",
                    value: $viewModel.contextLimit,
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Cancel") {
                        viewModel.reload()
                    }
                    Button("Save") {
                        saveSettings()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Failed to save settings", isPresented: $showSaveError) {
            Button("OK") {}
        } message: {
            Text(saveErrorMessage)
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        if let info = viewModel.currentProviderInfo {
            Picker("Model", selection: $viewModel.model) {
                ForEach(info.models, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
        } else {
            TextField("Model", text: $viewModel.model)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func saveSettings() {
        do {
            try viewModel.save()
            NotificationCenter.default.post(
                name: SettingsViewModel.settingsDidSave,
                object: nil
            )
        } catch {
            saveErrorMessage = error.localizedDescription
            showSaveError = true
        }
    }
}
