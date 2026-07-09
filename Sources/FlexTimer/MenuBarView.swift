import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let today = state.today {
                row("Started", today.clockIn.formatted(date: .omitted, time: .shortened))
                row("Leave at", WorkCalculator.leaveTime(clockIn: today.clockIn, rules: state.rules)
                    .formatted(date: .omitted, time: .shortened))
                row("Time left", Formatting.hms(WorkCalculator.timeLeft(
                    clockIn: today.clockIn, now: Date(), rules: state.rules)))
            } else if state.hasSession {
                Text("Not clocked in yet").foregroundStyle(.secondary)
            }

            Divider()
            row("Week OT", Formatting.signedHM(WorkCalculator.weeklyOvertime(
                records: state.week, now: Date(), rules: state.rules)))

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
