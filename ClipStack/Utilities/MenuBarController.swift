import AppKit
import SwiftData

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let menuLimit = 25

    private override init() {
        super.init()
        menu.delegate = self
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "doc.on.clipboard.fill",
            accessibilityDescription: "ClipStack"
        )
        item.button?.image?.isTemplate = true
        statusItem = item
        statusItem?.menu = menu
        populateMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        populateMenu()
    }

    private func populateMenu() {
        menu.removeAllItems()

        let entries = fetchRecentEntries()
        let totalCount = fetchEntryCount()

        if entries.isEmpty {
            let emptyItem = NSMenuItem(title: "No clips yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            let menuItemWidth = MenuBarMenuFormatting.preferredMenuItemWidth(for: entries)

            for entry in entries {
                let item = MenuBarMenuFormatting.makeMenuItem(for: entry, menuItemWidth: menuItemWidth)
                item.target = self
                item.action = #selector(copyEntry(_:))
                menu.addItem(item)
            }

            if totalCount > menuLimit {
                let moreItem = NSMenuItem(
                    title: "\(totalCount - menuLimit) more in history",
                    action: nil,
                    keyEquivalent: ""
                )
                moreItem.isEnabled = false
                menu.addItem(moreItem)
            }
        }

        menu.addItem(.separator())

        let clearItem = NSMenuItem(
            title: "Clear History",
            action: #selector(clearHistory(_:)),
            keyEquivalent: ""
        )
        clearItem.target = self
        clearItem.isEnabled = !entries.isEmpty
        menu.addItem(clearItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "Quit ClipStack",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func fetchRecentEntries() -> [ClipboardEntry] {
        let context = AppModelContainer.shared.mainContext
        var descriptor = FetchDescriptor<ClipboardEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = menuLimit
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchEntryCount() -> Int {
        let context = AppModelContainer.shared.mainContext
        let descriptor = FetchDescriptor<ClipboardEntry>()
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    private func fetchEntry(id: UUID) -> ClipboardEntry? {
        let context = AppModelContainer.shared.mainContext
        var descriptor = FetchDescriptor<ClipboardEntry>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    @objc private func copyEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let entry = fetchEntry(id: id) else { return }
        ClipboardStore.shared.copyEntry(entry)
    }

    @objc private func clearHistory(_ sender: NSMenuItem) {
        ClipboardStore.shared.clearAll()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        SettingsWindowController.shared.open()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
