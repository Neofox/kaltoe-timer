import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @State private var manualTime = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .onBreak = state.menuDisplay.state {
                row("Back at", WorkCalculator.lunchWindow(on: Date(), rules: state.rules).endAt
                    .formatted(date: .omitted, time: .shortened))
            }

            if let today = state.today, state.hasSession {
                let off = WorkCalculator.timeOff(on: today.clockIn, in: state.timeOff)
                row("Started", today.clockIn.formatted(date: .omitted, time: .shortened))
                row("Leave at", WorkCalculator.leaveTime(clockIn: today.clockIn, rules: state.rules,
                                                         timeOff: off)
                    .formatted(date: .omitted, time: .shortened))
                row("Time left", Formatting.hms(WorkCalculator.timeLeft(
                    clockIn: today.clockIn, now: Date(), rules: state.rules, timeOff: off)))
            } else if state.hasSession {
                Text("Not clocked in yet").foregroundStyle(.secondary)
            } else {
                Text("Session expired — sign in below").foregroundStyle(.secondary)
            }

            if state.today == nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        DatePicker("Started at", selection: $manualTime, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.field)
                        Button("Set") {
                            SettingsStore.setManualStart(manualTime, on: Date())
                            state.recompute(now: Date())
                        }
                    }
                }
            }

            Divider()
            row("Week OT", Formatting.signedHM(WorkCalculator.weeklyOvertime(
                records: state.weekIncludingManual(now: Date()), dayOffs: state.dayOffDates,
                timeOff: state.timeOff, now: Date(), rules: state.rules)))

            if let error = state.syncError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let sync = state.lastSync {
                Text("Synced \(sync.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            if state.hasSession {
                Button("↻ Refresh from Flex") { Task { await state.refresh() } }
            } else {
                Button("Sign in to Flex…") { state.signIn() }
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 240)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}
