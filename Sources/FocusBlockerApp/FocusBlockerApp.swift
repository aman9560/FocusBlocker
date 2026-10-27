import FocusCore
import SwiftUI

@main
struct FocusBlockerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Focus Blocker", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 900, height: 620)

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            if model.isActive {
                Label(Format.duration(model.longestRemaining), systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "lock.open")
            }
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case session = "Session"
    case blocklists = "Blocklists"
    case schedules = "Schedules"
    case protection = "Protection"
    case chrome = "Chrome"
    case accountability = "Accountability"
    case activity = "Activity"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .session: return "timer"
        case .blocklists: return "list.bullet.rectangle"
        case .schedules: return "calendar"
        case .protection: return "shield.lefthalf.filled"
        case .chrome: return "globe"
        case .accountability: return "key"
        case .activity: return "clock.arrow.circlepath"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @LocalState private var section: SidebarItem? = .session

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.startupError {
                    Banner(text: "Focus state couldn't be loaded: \(error)", style: .error)
                }
                if !model.agentEnabled {
                    Banner(text: "The background agent is off, so blocked apps and other browsers won't be closed. Turn it on under Protection.",
                           style: .error)
                }
                if let error = model.errorMessage {
                    Banner(text: error, style: .error) { model.errorMessage = nil }
                } else if let notice = model.notice {
                    Banner(text: notice, style: .notice) { model.notice = nil }
                }
                Group {
                    switch section ?? .session {
                    case .session: SessionView()
                    case .blocklists: BlocklistsView()
                    case .schedules: SchedulesView()
                    case .protection: ProtectionView()
                    case .chrome: ChromeView()
                    case .accountability: AccountabilityView()
                    case .activity: ActivityView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .navigationTitle(section?.rawValue ?? "Focus Blocker")
        }
    }
}

struct Banner: View {
    enum Style { case error, notice }
    let text: String
    let style: Style
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: style == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(text).textSelection(.enabled)
            Spacer()
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
        }
        .padding(10)
        .foregroundStyle(style == .error ? Color.red : Color.green)
        .background((style == .error ? Color.red : Color.green).opacity(0.1))
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.activeSessions.isEmpty {
            Text("No focus session")
        }
        ForEach(model.activeSessions) { session in
            Text("\(model.names(for: session.blocklistIDs)): \(Format.duration(session.remaining)) left")
        }
        Text(model.chromeConnected ? "Chrome extension connected" : "Chrome extension not connected")
        Divider()
        Button("Open Focus Blocker") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        Button("Quit Focus Blocker") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
