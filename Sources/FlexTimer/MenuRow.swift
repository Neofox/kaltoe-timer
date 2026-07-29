import SwiftUI

/// A full-bleed menu-style row: icon column, title, optional trailing accessory,
/// solid accent highlight on hover.
///
/// The horizontal padding lives here rather than on the parent stack because the
/// highlight has to reach the popover's edges while the text stays inset — one
/// shared padding cannot serve both.
struct MenuRow<Trailing: View>: View {
    private let icon: String
    private let title: String
    private let action: () -> Void
    private let trailing: Trailing

    @State private var hovering = false

    init(icon: String, title: String, action: @escaping () -> Void,
         @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.title = title
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        // A Button, not an .onTapGesture. A gesture would make the row mouse-only:
        // no button trait for VoiceOver to announce, no focusability, no
        // Space/Return. In the has-record state these rows are the *only* controls
        // in the popover, so a gesture would leave Quit unreachable by keyboard.
        // `.plain` suppresses every bit of default chrome, so the hover-driven
        // background below still owns the appearance.
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                Spacer(minLength: 8)
                trailing
            }
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hovering ? Color.accentColor : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension MenuRow where Trailing == EmptyView {
    init(icon: String, title: String, action: @escaping () -> Void) {
        self.init(icon: icon, title: title, action: action, trailing: { EmptyView() })
    }
}
