import AppKit
import CodoCore

/// Programmatic settings window for Guardian configuration.
/// Uses NSWindow with a vertical stack of labeled form fields.
/// Provider selection auto-fills base URL, model, and SDK type from the registry.
final class SettingsWindowController: NSWindowController {
    private let viewModel: SettingsViewModel
    private var guardianSwitch: NSSwitch!
    private var providerPopup: NSPopUpButton!
    private var apiKeyField: NSSecureTextField!
    private var baseURLField: NSTextField!
    private var modelPopup: NSPopUpButton!
    private var modelCustomField: NSTextField!
    private var sdkTypePopup: NSPopUpButton!
    private var contextLimitField: NSTextField!

    // Rows that hide/show based on provider
    private var baseURLRow: NSStackView!
    private var sdkTypeRow: NSStackView!

    init(viewModel: SettingsViewModel = SettingsViewModel()) {
        self.viewModel = viewModel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codo Settings"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        setupContent()
        loadFromViewModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layout

    private func setupContent() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])

        // Guardian Enabled
        guardianSwitch = NSSwitch()
        guardianSwitch.controlSize = .regular
        stack.addArrangedSubview(makeRow(label: "AI Guardian", control: guardianSwitch))

        // Provider
        providerPopup = NSPopUpButton()
        providerPopup.removeAllItems()
        for info in GuardianSettings.builtinProviders {
            providerPopup.addItem(withTitle: info.label)
            providerPopup.lastItem?.representedObject = info.id
        }
        providerPopup.addItem(withTitle: "Custom")
        providerPopup.lastItem?.representedObject = "custom"
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged(_:))
        stack.addArrangedSubview(makeRow(label: "Provider", control: providerPopup))

        // API Key
        apiKeyField = NSSecureTextField()
        apiKeyField.placeholderString = "sk-..."
        stack.addArrangedSubview(makeRow(label: "API Key", control: apiKeyField))

        // Base URL (custom only)
        baseURLField = NSTextField()
        baseURLField.placeholderString = "https://api.openai.com/v1"
        baseURLRow = makeRow(label: "Base URL", control: baseURLField)
        stack.addArrangedSubview(baseURLRow)

        // Model (popup for built-in, text field for custom)
        modelPopup = NSPopUpButton()
        modelPopup.removeAllItems()
        stack.addArrangedSubview(makeRow(label: "Model", control: modelPopup))

        // SDK Type (custom only)
        sdkTypePopup = NSPopUpButton()
        sdkTypePopup.removeAllItems()
        sdkTypePopup.addItem(withTitle: "OpenAI")
        sdkTypePopup.lastItem?.representedObject = "openai"
        sdkTypePopup.addItem(withTitle: "Anthropic")
        sdkTypePopup.lastItem?.representedObject = "anthropic"
        sdkTypeRow = makeRow(label: "SDK Type", control: sdkTypePopup)
        stack.addArrangedSubview(sdkTypeRow)

        // Context Limit
        contextLimitField = NSTextField()
        contextLimitField.placeholderString = "160000"
        stack.addArrangedSubview(makeRow(label: "Context Limit", control: contextLimitField))

        // Buttons
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveAction))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        buttonRow.addArrangedSubview(NSView()) // spacer
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(saveButton)
        stack.addArrangedSubview(buttonRow)

        // Make button row fill width
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40)
        ])
    }

    private func makeRow(label text: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8

        // Fixed label width for alignment
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 100)
        ])

        // Expand control to fill
        if let textField = control as? NSTextField {
            textField.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                textField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
            ])
        }
        if let popup = control as? NSPopUpButton {
            popup.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
            ])
        }

        return row
    }

    // MARK: - Provider Linking

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        guard let providerId = sender.selectedItem?.representedObject as? String else { return }
        viewModel.provider = providerId
        viewModel.applyProviderDefaults()
        updateProviderUI()
    }

    private func updateProviderUI() {
        let isCustom = viewModel.isCustomProvider
        baseURLRow.isHidden = !isCustom
        sdkTypeRow.isHidden = !isCustom

        // Rebuild model popup
        modelPopup.removeAllItems()
        if let info = viewModel.currentProviderInfo {
            for modelName in info.models {
                modelPopup.addItem(withTitle: modelName)
            }
            modelPopup.addItem(withTitle: "Custom model...")
            // Select current model
            if let idx = info.models.firstIndex(of: viewModel.model) {
                modelPopup.selectItem(at: idx)
            } else {
                // Custom model — show as editable title
                modelPopup.selectItem(at: info.models.count)
            }
        } else {
            // Custom provider — show only editable text
            modelPopup.addItem(withTitle: viewModel.model.isEmpty ? "gpt-4o-mini" : viewModel.model)
        }

        // Sync fields
        baseURLField.stringValue = viewModel.baseURL

        // Select SDK type
        selectPopup(sdkTypePopup, value: viewModel.sdkType)
    }

    private func selectPopup(_ popup: NSPopUpButton, value: String) {
        for (idx, item) in popup.itemArray.enumerated()
            where item.representedObject as? String == value {
            popup.selectItem(at: idx)
            return
        }
    }

    private func selectProviderPopup() {
        for (idx, item) in providerPopup.itemArray.enumerated()
            where item.representedObject as? String == viewModel.provider {
            providerPopup.selectItem(at: idx)
            return
        }
    }

    // MARK: - Data Binding

    private func loadFromViewModel() {
        viewModel.reload()
        guardianSwitch.state = viewModel.guardianEnabled ? .on : .off
        apiKeyField.stringValue = viewModel.apiKey
        baseURLField.stringValue = viewModel.baseURL
        contextLimitField.integerValue = viewModel.contextLimit

        selectProviderPopup()
        updateProviderUI()
    }

    private func syncToViewModel() {
        viewModel.guardianEnabled = guardianSwitch.state == .on
        viewModel.apiKey = apiKeyField.stringValue
        viewModel.contextLimit = max(1, contextLimitField.integerValue)

        // Provider is already set via providerChanged
        if viewModel.isCustomProvider {
            viewModel.baseURL = baseURLField.stringValue
            viewModel.sdkType = sdkTypePopup.selectedItem?.representedObject as? String ?? "openai"
            viewModel.model = modelPopup.titleOfSelectedItem ?? ""
        } else {
            // Model from popup
            if let title = modelPopup.titleOfSelectedItem, title != "Custom model..." {
                viewModel.model = title
            }
            // baseURL and sdkType come from provider defaults (already set)
        }
    }

    // MARK: - Actions

    /// Posted after settings are persisted so AppDelegate can restart Guardian.
    static let settingsDidSave = Notification.Name("CodoSettingsDidSave")

    @objc private func saveAction() {
        syncToViewModel()
        do {
            try viewModel.save()
            NotificationCenter.default.post(name: Self.settingsDidSave, object: nil)
            close()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to save settings"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func cancelAction() {
        close()
    }

    /// Show the window, centering it if not already visible.
    func showWindow() {
        loadFromViewModel()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
