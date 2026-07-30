import SwiftUI
import KaltoeCore

/// Menu bar label geometry picker.
///
/// A segmented `Picker` rather than a `MenuRow` toggle, because Ring and Track are
/// peer choices: a toggle would have to nominate one of them as the "on" state and
/// name itself after it.
struct LabelGeometryRow: View {
    @Binding var geometry: LabelGeometry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Label style").font(.caption).foregroundStyle(.secondary)
            Picker("Label style", selection: $geometry) {
                Text("Ring").tag(LabelGeometry.ring)
                Text("Track").tag(LabelGeometry.track)
            }
            .pickerStyle(.segmented)
            // The visible heading above already names the control; without this the
            // Picker draws its own title beside the segments and shows it twice.
            // Drawing only — `.labelsHidden()` does not suppress the label for
            // VoiceOver, which is what the accessibility label below is for.
            .labelsHidden()
            // On the Picker, not the enclosing VStack: the VStack's two children are
            // each already their own accessibility element, so a label on that bare
            // container does not attach. Here it replaces the hidden "Label style"
            // title rather than fighting the container. `.accessibilityElement(
            // children: .ignore)` is not the fix — unlike WeekBarRow's static row,
            // this container holds an interactive control, and collapsing it would
            // take the segments out of the accessibility tree entirely.
            .accessibilityLabel("Menu bar label style")
        }
        .padding(.horizontal, 12)
        .help("Ring draws a closing arc around the icon; Track fills a capsule behind the whole label. Both stay legible on the menu bar of a display that doesn't have focus.")
    }
}
