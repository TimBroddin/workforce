import AppKit
import SwiftUI
import Observation

/// Custom NSStatusItem that opens the main window on click instead of showing a menu.
/// Updates its icon color based on agent status.
@Observable
final class MenuBarStatusItem {
    private var statusItem: NSStatusItem?
    private let store: AgentStore

    init(store: AgentStore) {
        self.store = store
        setup()
    }

    private func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = item

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "person.3.fill", accessibilityDescription: "Workforce")
            button.action = #selector(StatusItemTarget.handleClick(_:))
            let target = StatusItemTarget()
            button.target = target
            // Keep target alive by associating it with the button
            objc_setAssociatedObject(button, "target", target, .OBJC_ASSOCIATION_RETAIN)
        }

        // Set up a menu for right-click
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Workforce", action: #selector(StatusItemTarget.handleClick(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = nil // No menu on left click

        // Observe store changes to update icon
        startObserving()
    }

    private func startObserving() {
        // Use a timer to poll status changes since we can't use withObservationTracking from MainActor easily
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateIcon()
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        let hasPermission = store.agents.values.contains { $0.status == .waitingForPermission }
        let hasWaiting = store.agents.values.contains { $0.status == .waitingForInput }

        let config: NSImage.SymbolConfiguration
        if hasPermission {
            config = NSImage.SymbolConfiguration(paletteColors: [.systemRed, .labelColor])
        } else if hasWaiting {
            config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange, .labelColor])
        } else {
            config = NSImage.SymbolConfiguration(paletteColors: [.labelColor])
        }

        button.image = NSImage(systemSymbolName: "person.3.fill", accessibilityDescription: "Workforce")?
            .withSymbolConfiguration(config)
    }
}

/// Target for the status item button action. Opens the main window.
final class StatusItemTarget: NSObject {
    @objc func handleClick(_ sender: Any?) {
        NSApp.activate()
        // Find or create the main window
        if let window = NSApp.windows.first(where: { $0.title == "Workforce" || $0.identifier?.rawValue.contains("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // If no window found, use openWindow environment action via notification
            NSApp.activate()
        }
    }
}
