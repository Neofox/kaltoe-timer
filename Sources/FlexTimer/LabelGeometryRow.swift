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
            Text("Label style").foregroundStyle(.secondary)
            Picker("Label style", selection: $geometry) {
                Text("Ring").tag(LabelGeometry.ring)
                Text("Track").tag(LabelGeometry.track)
            }
            .pickerStyle(.segmented)
            // The visible heading above already names the control; without this
            // the Picker draws its own title and says it twice.
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .help("Ring draws a closing arc around the icon; Track fills a capsule behind the whole label. Both stay legible on the menu bar of a display that doesn't have focus.")
        .accessibilityLabel("Menu bar label style")
    }
}
