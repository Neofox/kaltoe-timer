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
            LabelGeometryRow(geometry: $state.labelGeometry)
            separator
            MenuRow(icon: "power", title: "종료") { NSApp.terminate(nil) }
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
                row("복귀", WorkCalculator.lunchWindow(on: Date(), rules: state.rules).endAt
                    .formatted(date: .omitted, time: .shortened))
            }
            if let today, state.hasSession {
                let off = WorkCalculator.timeOff(on: today.clockIn, in: state.timeOff)
                // Ordered and weighted by why you opened the popover. The countdown is
                // the answer you came for, so it leads at `.hero`; leave time is the
                // fact behind it; clock-in is something you already know and only ever
                // check to confirm, so it recedes to a caption. They used to be three
                // identical rows in the opposite order, which made the least useful
                // line the first one read.
                row("남은 시간", Formatting.hms(WorkCalculator.timeLeft(
                    clockIn: today.clockIn, now: Date(), rules: state.rules, timeOff: off)),
                    .hero)
                row("퇴근 예정", WorkCalculator.leaveTime(clockIn: today.clockIn,
                                                       rules: state.rules, timeOff: off)
                    .formatted(date: .omitted, time: .shortened))
                // Only present when something shortened the day. Family day and
                // approved time off both move 퇴근 예정 with no other explanation,
                // and when they stack the break vanishes too, so the row moves
                // five hours rather than the four the target change alone implies.
                //
                // The one English string left in the popover: `TargetNote` composes it
                // inside KaltoeCore so the Linux tray need not carry a second copy of
                // the wording, which puts it on the daemon's wire. Translating it here
                // would mean translating it there too.
                if let note = state.weekSummary.targetNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                row("출근", today.clockIn.formatted(date: .omitted, time: .shortened))
            } else if state.hasSession {
                Text(state.weekSummary.todayIsDayOff ? "휴무" : "아직 출근 전")
                    .foregroundStyle(.secondary)
            } else {
                Text("세션 만료").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var primaryAction: some View {
        if state.hasSession {
            MenuRow(icon: "arrow.clockwise", title: "Flex 재동기화") {
                Task { await state.refresh() }
            } trailing: {
                // The last sync belongs beside the button that changes it, not under
                // the week's overtime total where it used to sit — there it read as a
                // footnote to a figure it has nothing to do with.
                //
                // Only on the signed-in variant: `lastSync` survives an expired
                // session, so on the sign-in row it would timestamp data you can no
                // longer refresh. Dimmed with opacity rather than `.secondary` so it
                // follows the row's foreground to white on hover instead of staying
                // grey against the accent fill.
                if let sync = state.lastSync {
                    Text(sync.formatted(date: .omitted, time: .shortened))
                        .font(.caption).opacity(0.7)
                }
            }
        } else {
            MenuRow(icon: "person.crop.circle", title: "Flex 로그인…") { state.signIn() }
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            Text("직접 입력").font(.caption).foregroundStyle(.secondary)
            HStack {
                DatePicker("출근 시각", selection: $manualTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.field)
                    .controlSize(.small)
                Button("설정") {
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
                    // One scale for the whole strip, read once here rather than per
                    // row: it is derived from all five days, so a row cannot compute
                    // it from the day it was handed.
                    let scale = state.weekSummary.barScale
                    ForEach(state.weekSummary.days, id: \.date) {
                        WeekBarRow(day: $0, scale: scale)
                    }
                }
            }
            row("주간 초과근무", "\(Formatting.hm(state.weekSummary.overtime)) / "
                + Formatting.hm(state.weekSummary.cap))
            // The error stays here while the sync timestamp moved to the re-sync row:
            // a failure is about the week's figures being stale, which is exactly the
            // claim the rows above it are making.
            if let error = state.syncError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
    }

    /// How loudly a row speaks. The popover is roughly half things you opened it to
    /// read and half things you will ignore all week; one uniform body font made the
    /// two indistinguishable, which is what made the menu feel busy for its size.
    private enum RowWeight {
        case hero      // the number you came for
        case normal

        var font: Font {
            switch self {
            case .hero: return .title3
            case .normal: return .body
            }
        }
    }

    private func row(_ label: String, _ value: String,
                     _ weight: RowWeight = .normal) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        // On the row rather than per Text, so the label and its figure always scale
        // together — a large figure beside a body-sized label reads as a mismatch
        // rather than as emphasis.
        .font(weight.font)
    }
}
