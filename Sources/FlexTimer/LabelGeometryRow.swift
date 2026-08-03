import SwiftUI
import KaltoeCore

/// Menu bar label geometry picker.
///
/// A segmented `Picker` rather than a `MenuRow` toggle, because Ring and Track are
/// peer choices: a toggle would have to nominate one of them as the "on" state and
/// name itself after it.
///
/// Laid out as one row rather than a caption above the control. This is a preference
/// you set once and then see every time you open the popover for something else, and
/// stacked it was two full lines plus their spacing — the largest block of chrome in
/// the menu for the least-used thing in it. Side by side with a small control it is a
/// single quiet line, and the label still reads as the control's name rather than as
/// a section heading.
struct LabelGeometryRow: View {
    @Binding var geometry: LabelGeometry

    var body: some View {
        HStack(spacing: 8) {
            Text("라벨 스타일").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Picker("라벨 스타일", selection: $geometry) {
                // 링/트랙 rather than Ring/Track: the Korean install guide already
                // introduces them as 링(Ring) and 트랙(Track), so this is the name it
                // teaches. Both guides' "Label style" references move with it.
                Text("링").tag(LabelGeometry.ring)
                Text("트랙").tag(LabelGeometry.track)
            }
            .pickerStyle(.segmented)
            // `.fixedSize()`, not a fixed width. A segmented Picker draws at its
            // intrinsic size and centres itself in whatever it is given, so the 128pt
            // frame this used to carry left the control floating short of the popover's
            // trailing edge with dead space either side of it — the Spacer above was
            // pushing the *frame* right, not the segments. Hugging the content lets it
            // sit flush against the 12pt padding.
            .fixedSize()
            .controlSize(.small)
            // The visible caption beside it already names the control; without this
            // the Picker draws its own title too and shows it twice. Drawing only —
            // `.labelsHidden()` does not suppress the label for VoiceOver, which is
            // what the accessibility label below is for.
            .labelsHidden()
            // On the Picker, not the enclosing HStack: the row's children are each
            // already their own accessibility element, so a label on that bare
            // container does not attach. Here it replaces the hidden "Label style"
            // title rather than fighting the container. `.accessibilityElement(
            // children: .ignore)` is not the fix — unlike WeekBarRow's static row,
            // this container holds an interactive control, and collapsing it would
            // take the segments out of the accessibility tree entirely.
            // Translated with the visible caption, unlike the menu bar label's spoken
            // vocabulary, which stays English. Those are phrases VoiceOver invents for
            // a rasterised image; this one is the accessible *name of a control whose
            // visible name is right beside it*, and announcing a different name than
            // the one on screen is a defect rather than a scoping choice.
            .accessibilityLabel("메뉴 바 라벨 스타일")
        }
        .padding(.horizontal, 12)
        .help("링은 아이콘 둘레를 도는 호로, 트랙은 라벨 뒤를 채우는 캡슐로 남은 시간을 보여 줍니다. 둘 다 포커스가 없는 화면의 메뉴 바에서도 잘 보입니다.")
    }
}
