import AppKit
import FocusCore
import SwiftUI

struct BlocklistsView: View {
    @EnvironmentObject var model: AppModel
    @LocalState private var selection: UUID? = nil
    @LocalState private var newName = ""
    @LocalState private var pendingImport: [BlocklistImport.NamedResult] = []
    @LocalState private var confirmImport = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(model.sortedBlocklists, selection: $selection) { list in
                    HStack {
                        Text(list.name)
                        Spacer()
                        if model.isLocked(list) { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                    }
                    .tag(list.id)
                }
                HStack {
                    TextField("New blocklist", text: $newName).textFieldStyle(.roundedBorder).onSubmit(create)
                    Button("Add", action: create).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                Button("Import from file…", action: chooseImport)
                    .help("A Cold Turkey JSON export, or a text file with one site per line")
                    .padding(8)
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)

            Group {
                if let id = selection, let list = model.state.blocklists.first(where: { $0.id == id }) {
                    BlocklistDetail(list: list).id(list.id)
                } else {
                    Text("Select or create a blocklist.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Import these blocklists?", isPresented: $confirmImport) {
            Button("Import", action: applyImport)
            Button("Cancel", role: .cancel) { pendingImport = [] }
        } message: {
            Text(importSummary)
        }
    }

    func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .data]
        panel.message = "Choose a Cold Turkey export or a text file with one site per line."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pendingImport = try BlocklistImport.load(Data(contentsOf: url))
            confirmImport = true
        } catch {
            model.errorMessage = (error as? BlocklistImport.ImportError)?.description ?? error.localizedDescription
        }
    }

    var importSummary: String {
        pendingImport.map { block in
            var line = "\(block.targetName(override: nil)): \(block.result.domains.count) site(s)"
            if !block.result.exceptions.isEmpty { line += ", \(block.result.exceptions.count) exception(s)" }
            if !block.result.skipped.isEmpty { line += "; skipping \(block.result.skipped.count) non-website rule(s)" }
            return line
        }.joined(separator: "\n") + "\n\nExisting blocklists with the same name keep their entries; new sites are added."
    }

    func applyImport() {
        let blocks = pendingImport
        pendingImport = []
        let names = blocks.map { $0.targetName(override: nil) }
        model.perform("Imported \(names.joined(separator: ", ")).") { engine in
            for block in blocks { try engine.importRules(block.result, intoBlocklistNamed: block.targetName(override: nil)) }
        }
        selection = model.state.blocklists.first { $0.name == names.first }?.id
    }

    func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        if model.perform("Created \(name).", { try $0.createBlocklist(name: name) }) {
            newName = ""
            selection = model.state.blocklists.first { $0.name == name }?.id
        }
    }
}

struct BlocklistDetail: View {
    @EnvironmentObject var model: AppModel
    let list: Blocklist
    @LocalState private var newDomain = ""
    @LocalState private var newException = ""
    @LocalState private var confirmDelete = false

    var body: some View {
        Form {
            if model.isLocked(list) {
                Label("A strict session is using this list: you can add sites and apps, but not remove them.",
                      systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
            Section("Blocked websites") {
                RuleList(items: list.domains) { domain in update { $0.domains.removeAll { $0 == domain } } }
                AddField(placeholder: "reddit.com, youtube.com/shorts, or * for all websites", text: $newDomain) {
                    if update({ $0.domains += splitEntries(newDomain) }) { newDomain = "" }
                }
            }
            Section("Exceptions (stay reachable)") {
                RuleList(items: list.exceptions) { rule in update { $0.exceptions.removeAll { $0 == rule } } }
                AddField(placeholder: "reddit.com/r/swift", text: $newException) {
                    if update({ $0.exceptions += splitEntries(newException) }) { newException = "" }
                }
            }
            Section("Blocked apps") {
                RuleList(items: list.apps.map(\.bundleID)) { id in update { $0.apps.removeAll { $0.bundleID == id } } }
                Button("Choose app…", action: chooseApp)
                Text("During a session the background agent closes these apps. Turn it on under Protection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Delete blocklist", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete \(list.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.perform("Deleted \(list.name).") { try $0.deleteBlocklist(named: list.name) } }
        }
    }

    /// Accepts several sites pasted at once, separated by spaces, commas or new lines.
    func splitEntries(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    /// Keeps typed text on failure (for example an invalid rule) so it can be corrected.
    @discardableResult
    func update(_ change: (inout Blocklist) -> Void) -> Bool {
        var copy = list
        change(&copy)
        return model.perform { try $0.updateBlocklist(copy) }
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        update { list in
            for id in ids where !list.apps.contains(where: { $0.bundleID == id }) { list.apps.append(AppRule(bundleID: id)) }
        }
    }
}

struct RuleList: View {
    let items: [String]
    let remove: (String) -> Void

    var body: some View {
        if items.isEmpty {
            Text("None").foregroundStyle(.secondary)
        }
        ForEach(items, id: \.self) { item in
            HStack {
                Text(item == DomainRule.allWebsites ? "All websites (*)" : item).textSelection(.enabled)
                Spacer()
                Button { remove(item) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove")
            }
        }
    }
}

struct AddField: View {
    let placeholder: String
    @Binding var text: String
    let add: () -> Void

    var body: some View {
        HStack {
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder).onSubmit(submit)
            Button("Add", action: submit).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    func submit() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        add()
    }
}
