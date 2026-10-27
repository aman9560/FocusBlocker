import FocusCore
import SwiftUI

struct SchedulesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.state.schedules.isEmpty {
                    Text("No schedules yet.").foregroundStyle(.secondary)
                }
                ForEach(model.state.schedules) { rule in
                    ScheduleRow(rule: rule)
                }
                Divider()
                Text("New schedule").font(.headline)
                NewScheduleForm()
            }
            .padding(20)
        }
    }
}

struct ScheduleRow: View {
    @EnvironmentObject var model: AppModel
    let rule: ScheduleRule

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.name).font(.headline)
                Text("\(days) · \(Format.minutes(rule.startMinute))–\(Format.minutes(rule.endMinute)) · \(rule.timeZoneID)")
                Text("\(model.names(for: rule.blocklistIDs)) · \(rule.lock.rawValue) lock\(rule.strict ? " · strict" : "")")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                model.perform("Deleted \(rule.name).") { try $0.deleteSchedule(named: rule.name) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete schedule")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    var days: String {
        rule.weekdays.sorted().map { Format.weekdaySymbols[$0 - 1] }.joined(separator: " ")
    }
}

struct NewScheduleForm: View {
    @EnvironmentObject var model: AppModel
    @LocalState private var name = ""
    @LocalState private var lists: Set<UUID> = []
    @LocalState private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @LocalState private var start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
    @LocalState private var end = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date())!
    @LocalState private var lock: LockKind = .timer
    @LocalState private var strict = true

    var body: some View {
        Form {
            TextField("Name", text: $name)
            LabeledContent("Blocklists") {
                VStack(alignment: .leading) {
                    ForEach(model.sortedBlocklists) { list in
                        Toggle(list.name, isOn: Binding(get: { lists.contains(list.id) },
                                                        set: { if $0 { lists.insert(list.id) } else { lists.remove(list.id) } }))
                    }
                }
            }
            LabeledContent("Days") {
                HStack {
                    ForEach(1...7, id: \.self) { day in
                        Toggle(Format.weekdaySymbols[day - 1], isOn: Binding(
                            get: { weekdays.contains(day) },
                            set: { if $0 { weekdays.insert(day) } else { weekdays.remove(day) } }))
                            .toggleStyle(.button)
                    }
                }
            }
            DatePicker("From", selection: $start, displayedComponents: .hourAndMinute)
            DatePicker("To", selection: $end, displayedComponents: .hourAndMinute)
            Picker("Lock", selection: $lock) {
                Text("Timer").tag(LockKind.timer)
                Text("Password").tag(LockKind.password)
                Text("None").tag(LockKind.none)
            }
            Toggle("Strict", isOn: $strict)
            Button("Save schedule", action: save)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || lists.isEmpty || weekdays.isEmpty)
        }
        .formStyle(.grouped)
    }

    func minuteOfDay(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    func save() {
        let rule = ScheduleRule(name: name.trimmingCharacters(in: .whitespaces), blocklistIDs: Array(lists), weekdays: weekdays,
                                startMinute: minuteOfDay(start), endMinute: minuteOfDay(end), lock: lock, strict: strict)
        if model.perform("Saved \(rule.name).", { try $0.upsertSchedule(rule) }) { name = "" }
    }
}
