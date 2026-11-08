import AppKit
import SwiftUI

@main
struct MACDancerApp: App {
  @StateObject private var model = AppModel(
    client: DaemonClient(),
    service: ServiceController(),
    reader: BackgroundInterfaceReader(reader: SystemInterfaceReader())
  )
  @StateObject private var updates = UpdateController()
  @AppStorage(menuBarIconPreferenceKey) private var showMenuBarIcon = true

  var body: some Scene {
    // A single window: reopening it from the Dock or the menu bar brings the
    // same window back instead of stacking copies.
    Window(L("app.title", "MACDancer"), id: mainWindowID) {
      MainWindowView()
        .environmentObject(model)
        .environmentObject(updates)
        .task {
          model.start()
          updates.checkOnLaunchIfDue()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
          model.recheckService()
          model.refresh()
        }
    }
    .defaultSize(width: 1_000, height: 700)
    .commands { AppCommands(model: model, updates: updates) }

    MenuBarExtra(L("menu_bar.title", "MACDancer"), systemImage: "shuffle.circle.fill", isInserted: $showMenuBarIcon) {
      MenuBarContent()
        .environmentObject(model)
    }
  }
}

private struct MenuBarContent: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    ForEach(model.visibleInterfaces.filter(\.kind.isSupported)) { interface in
      Text("\(interface.displayName) · \(macText(interface.currentMAC))")
    }
    Divider()
    Button(L("menu_bar.open", "Open MACDancer")) { show(.dashboard) }
    Button(L("menu_bar.refresh", "Refresh MAC addresses")) { model.refresh() }
      .disabled(model.isRefreshing)
    Button(L("menu_bar.settings", "Settings…")) { show(.settings) }
    Divider()
    Button(L("menu_bar.quit", "Quit MACDancer")) { NSApplication.shared.terminate(nil) }
  }

  private func show(_ section: AppSection) {
    model.selection = section
    model.start()
    openWindow(id: mainWindowID)
    NSApplication.shared.activate()
  }
}

private struct AppCommands: Commands {
  @ObservedObject var model: AppModel
  @ObservedObject var updates: UpdateController
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .newItem) {}

    CommandGroup(after: .appInfo) {
      Button(L("command.check_updates", "Check for Updates…")) {
        updates.check(userInitiated: true)
        show(.settings)
      }
      .disabled(updates.isBusy)
      Button(L("command.open_settings", "Settings…")) { show(.settings) }
        .keyboardShortcut(",", modifiers: .command)
    }

    CommandGroup(after: .toolbar) {
      Button(L("command.refresh", "Refresh MAC addresses")) { model.refresh() }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(model.isRefreshing)
    }

    CommandMenu(L("command.navigate", "Navigate")) {
      ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
        Button(sectionTitle(section)) { show(section) }
          .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
      }
    }
  }

  private func show(_ section: AppSection) {
    model.selection = section
    openWindow(id: mainWindowID)
  }
}
