import SwiftUI
import KaltoeCore

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @State private var manualTime = Date()

    var body: some View {
        // Read `state.today` exactly once per pass. It is computed — each access
        // mints a fresh Date() and re-reads UserDefaults — so reading it per call
        // site would decide the two mutually exclusive primary-action sites from
        // two different `now` values, which can disagree across a day boundary and
        // render the action twice or not at all. One read also collapses three
        // UserDefaults hits per second down to one on the 1-second tick.
        let today = state.today
        // With no record for today, the primary action moves up next to the status
        // message — waiting for a clock-in is exactly when you want it, and the
        // manual-entry field is only a fallback for when Flex is unreachable.
        let hasRecord = today != nil

        VStack(alignment: .leading, spacing: 0) {
            information(today)

            if !hasRecord {
                separator
                primaryAction
                separator
                manualEntry
            }

            separator
            weekSummary

            separator
            // The separator is conditional with the action: the preference row must
            // never sit flush against a command row, and the !hasRecord path must
            // not get a doubled divider.
            if hasRecord {
                primaryAction
                separator
            }
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

    /// Takes the record rather than reading `state.today` again — see `body`.
    @ViewBuilder private func information(_ today: WorkRecord?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .onBreak = state.menuDisplay.state {
                row("Back at", WorkCalculator.lunchWindow(on: Date(), rules: state.rules).endAt
                    .formatted(date: .omitted, time: .shortened))
            }
            if let today, state.hasSession {
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

    /// `.isToggle` is macOS 14+ and the deployment target is 13. On 13 the row still
    /// announces as a named button carrying an on/off value, which is the part that
    /// matters; only the trait refinement is unavailable. Split so neither path
    /// needs an AnyView.
    @ViewBuilder private var highContrastRow: some View {
        if #available(macOS 14.0, *) {
            highContrastRowBase.accessibilityAddTraits(.isToggle)
        } else {
            highContrastRowBase
        }
    }

    private var highContrastRowBase: some View {
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
                // Already inert to hit testing; hide it from VoiceOver too. The
                // state belongs on the row, which has the name — otherwise VoiceOver
                // reads a nameless switch sitting beside untitled text.
                .accessibilityHidden(true)
        }
        // Pointer tooltip. Not an accessibility label, and not a substitute for one.
        .help("Renders the icon and time at full contrast so they stay legible on the menu bar of a display that doesn't have focus.")
        .accessibilityValue(state.highContrastOnInactiveDisplays ? "on" : "off")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}
