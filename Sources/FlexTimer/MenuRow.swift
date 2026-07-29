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
        // A Button, not a Text with .onTapGesture, for assistive technology: a
        // Button exposes a button role and an activation action, where a tap
        // gesture exposes neither. VoiceOver navigates the accessibility
        // hierarchy rather than the key-window focus chain, and AXPress does not
        // need key status, so both work here.
        //
        // Tab traversal is *not* claimed. It is unverified and unlikely: this app
        // is LSUIElement/.accessory and never becomes active, a
        // MenuBarExtra(.window) popover is a non-activating panel that does not
        // take key status, macOS keeps plain buttons out of the Tab ring unless
        // "Use keyboard navigation to move focus between controls" is switched on
        // (off by default), and `.plain` draws no focus affordance anyway.
        //
        // `.plain` also suppresses every bit of default chrome, so the hover-driven
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
