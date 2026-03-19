import AppKit
import CodoCore

/// Programmatic settings window for Guardian configuration.
/// Uses NSWindow with a vertical stack of labeled form fields.
final class SettingsWindowController: NSWindowController {
    private let viewModel: SettingsViewModel
    private var guardianSwitch: NSSwitch!
    private var apiKeyField: NSSecureTextField!
    private var baseURLField: NSTextField!
    private var modelField: NSTextField!
    private var contextLimitField: NSTextField!

    init(viewModel: SettingsViewModel = SettingsViewModel()) {
        self.viewModel = viewModel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
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

        // API Key
        apiKeyField = NSSecureTextField()
        apiKeyField.placeholderString = "sk-..."
        stack.addArrangedSubview(makeRow(label: "API Key", control: apiKeyField))

        // Base URL
        baseURLField = NSTextField()
        baseURLField.placeholderString = "https://api.openai.com/v1"
        stack.addArrangedSubview(makeRow(label: "Base URL", control: baseURLField))

        // Model
        modelField = NSTextField()
        modelField.placeholderString = "gpt-4o-mini"
        stack.addArrangedSubview(makeRow(label: "Model", control: modelField))

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

        return row
    }

    // MARK: - Data Binding

    private func loadFromViewModel() {
        viewModel.reload()
        guardianSwitch.state = viewModel.guardianEnabled ? .on : .off
        apiKeyField.stringValue = viewModel.apiKey
        baseURLField.stringValue = viewModel.baseURL
        modelField.stringValue = viewModel.model
        contextLimitField.integerValue = viewModel.contextLimit
    }

    private func syncToViewModel() {
        viewModel.guardianEnabled = guardianSwitch.state == .on
        viewModel.apiKey = apiKeyField.stringValue
        viewModel.baseURL = baseURLField.stringValue
        viewModel.model = modelField.stringValue
        viewModel.contextLimit = max(1, contextLimitField.integerValue)
    }

    // MARK: - Actions

    @objc private func saveAction() {
        syncToViewModel()
        do {
            try viewModel.save()
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
