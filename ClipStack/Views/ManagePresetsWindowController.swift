import AppKit

@MainActor
final class ManagePresetsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var presets: [WidthPreset] = []

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClipStack Presets"
        window.center()
        self.init(window: window)
        configureContent()
        reloadPresets()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(presetsDidChange),
            name: .widthPresetsDidChange,
            object: nil
        )
    }

    @objc private func presetsDidChange() {
        reloadPresets()
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("preset"))
        column.title = "Preset"
        column.width = 280
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteSelected(_:)))
        deleteButton.bezelStyle = .rounded
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        let renameButton = NSButton(title: "Rename…", target: self, action: #selector(renameSelected(_:)))
        renameButton.bezelStyle = .rounded
        renameButton.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow(_:)))
        closeButton.bezelStyle = .rounded
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(scrollView)
        contentView.addSubview(deleteButton)
        contentView.addSubview(renameButton)
        contentView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: deleteButton.topAnchor, constant: -12),

            deleteButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            deleteButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            renameButton.leadingAnchor.constraint(equalTo: deleteButton.trailingAnchor, constant: 8),
            renameButton.centerYAnchor.constraint(equalTo: deleteButton.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            closeButton.centerYAnchor.constraint(equalTo: deleteButton.centerYAnchor),
        ])
    }

    private func reloadPresets() {
        presets = PresetStore.shared.presets
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        presets.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let preset = presets[row]
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let view = NSTableCellView()
            view.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(textField)
            view.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            return view
        }()

        cell.textField?.stringValue = "\(preset.name) — \(Int(preset.width)) px"
        return cell
    }

    @objc private func deleteSelected(_ sender: NSButton) {
        let row = tableView.selectedRow
        guard presets.indices.contains(row) else { return }
        PresetStore.shared.delete(id: presets[row].id)
    }

    @objc private func renameSelected(_ sender: NSButton) {
        let row = tableView.selectedRow
        guard presets.indices.contains(row) else { return }
        promptToRename(presets[row])
    }

    @objc private func closeWindow(_ sender: NSButton) {
        window?.close()
    }

    private func promptToRename(_ preset: WidthPreset) {
        let alert = NSAlert()
        alert.messageText = "Rename Preset"
        alert.informativeText = "Current width: \(Int(preset.width)) px"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = preset.name
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        var updated = preset
        updated.name = name
        PresetStore.shared.update(updated)
    }
}
