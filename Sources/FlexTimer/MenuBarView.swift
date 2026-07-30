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
        let hasRecord = today != nil
        // The primary action moves up next to the status message whenever the
        // message alone leaves you with nothing to act on. Two such states:
        //
        // - No record yet — waiting for a clock-in is exactly when you want the
        //   action to hand.
        // - No session — `information` then shows only `Session expired`, and the
        //   action is `Sign in to Flex…`, the one thing that fixes it. This is the
        //   non-obvious half: `refresh()` never clears `week` on session loss, so
        //   cookies expiring mid-day leave `hasRecord` true with no session, and
        //   gating on the record alone buried the sign-in row below the week
        //   summary with two words of explanation pointing nowhere.
        let actionMovesUp = !hasRecord || !state.hasSession

        VStack(alignment: .leading, spacing: 0) {
            information(today)

            if actionMovesUp {
                separator
                primaryAction
            }
            // Still gated on the record alone: a stale record means manual entry is
            // not the fallback you want — the day is already accounted for.
            if !hasRecord {
                separator
                manualEntry
            }

            separator
            weekSection

            separator
            // The separator is conditional with the action: the preference row must
            // never sit flush against a command row, and the moved-up path must
            // not get a doubled divider.
            if !actionMovesUp {
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

    /// Vertical gap between the information rows. One number so it stays
    /// consistent across the three stacks and is trivial to nudge.
    private let rowSpacing: CGFloat = 9

    private var separator: some View {
        Divider().padding(.vertical, 4)
    }

    /// Takes the record rather than reading `state.today` again — see `body`.
    @ViewBuilder private func information(_ today: WorkRecord?) -> some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
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
                // Only present when something shortened the day. Family day and
                // approved time off both move Leave at with no other explanation,
                // and when they stack the break vanishes too, so the row moves
                // five hours rather than the four the target change alone implies.
                if let note = state.weekSummary.targetNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                row("Time left", Formatting.hms(WorkCalculator.timeLeft(
                    clockIn: today.clockIn, now: Date(), rules: state.rules, timeOff: off)))
            } else if state.hasSession {
                Text(state.weekSummary.todayIsDayOff ? "Day off" : "Not clocked in yet")
                    .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: rowSpacing) {
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

    /// Named for the section, not for `state.weekSummary` — this is the view, that
    /// is the data it reads.
    private var weekSection: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            // Rendered whenever the week holds any record, signed out included —
            // the same rule Week OT already followed, so stale-but-real data stays
            // on screen instead of blanking.
            if state.weekSummary.days.contains(where: { $0.worked != nil }) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.weekSummary.days, id: \.date) { WeekBarRow(day: $0) }
                }
            }
            row("Week OT", "\(Formatting.hm(state.weekSummary.overtime)) / "
                + Formatting.hm(state.weekSummary.cap))
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
                // Already inert to hit testing; hide it from VoiceOver too. The
                // state belongs on the row, which has the name — otherwise VoiceOver
                // reads a nameless switch sitting beside untitled text.
                .accessibilityHidden(true)
        }
        // Pointer tooltip. Not an accessibility label, and not a substitute for one.
        .help("Renders the icon and time at full contrast so they stay legible on the menu bar of a display that doesn't have focus.")
        .accessibilityValue(state.highContrastOnInactiveDisplays ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}
