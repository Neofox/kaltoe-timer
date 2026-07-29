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
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

extension MenuRow where Trailing == EmptyView {
    init(icon: String, title: String, action: @escaping () -> Void) {
        self.init(icon: icon, title: title, action: action, trailing: { EmptyView() })
    }
}
