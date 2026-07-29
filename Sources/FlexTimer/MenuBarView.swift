import SwiftUI
import KaltoeCore

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @State private var manualTime = Date()

    /// With no record for today, the primary action moves up next to the status
    /// message — waiting for a clock-in is exactly when you want it, and the
    /// manual-entry field is only a fallback for when Flex is unreachable.
    private var hasRecord: Bool { state.today != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            information

            if !hasRecord {
                separator
                primaryAction
                separator
                manualEntry
            }

            separator
            weekSummary

            separator
            if hasRecord { primaryAction }
            highContrastRow
            separator
            MenuRow(icon: "power", title: "Quit") { NSApp.terminate(nil) }
        }
        .padding(.vertical, 6)
        .frame(width: 280)
    }

    private var separator: some View {
        Divider().padding(.vertical, 4)
    }

    @ViewBuilder private var information: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                Text("Session expired").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var primaryAction: some View {
        if state.hasSession {
            MenuRow(icon: "arrow.clockwise", title: "Flex re-sync") {
                Task { await state.refresh() }
            }
        } else {
            MenuRow(icon: "person.crop.circle", title: "Sign in to Flex…") { state.signIn() }
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Or set it manually").font(.caption).foregroundStyle(.secondary)
            HStack {
                DatePicker("Started at", selection: $manualTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.field)
                    .controlSize(.small)
                Button("Set") {
                    SettingsStore.setManualStart(manualTime, on: Date())
                    state.recompute(now: Date())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
    }

    private var weekSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            let weekOT = WorkCalculator.weeklyOvertime(
                records: state.weekIncludingManual(now: Date()),
                timeOff: state.timeOff, now: Date(), rules: state.rules)
            row("Week OT", "\(Formatting.hm(weekOT)) / \(Formatting.hm(state.rules.weeklyOvertimeCap))")
            if let error = state.syncError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let sync = state.lastSync {
                Text("Synced \(sync.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
    }

    private var highContrastRow: some View {
        MenuRow(icon: "circle.lefthalf.filled", title: "Stay readable when unfocused") {
            state.highContrastOnInactiveDisplays.toggle()
        } trailing: {
            Toggle("", isOn: $state.highContrastOnInactiveDisplays)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                // The row owns the tap. Without this, clicking the switch itself
                // fires both the switch and the row action, which cancel out.
                .allowsHitTesting(false)
        }
        .help("Renders the icon and time at full contrast so they stay legible on the menu bar of a display that doesn't have focus.")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}
