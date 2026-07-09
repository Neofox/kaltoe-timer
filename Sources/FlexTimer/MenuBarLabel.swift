import AppKit
import SwiftUI

/// Menu bar label: template-rendered icon+text normally; at warning/critical
/// urgency, pre-renders a colored capsule pill (white icon+text on
/// orange/red) to a non-template NSImage, because the menu bar ignores
/// colors on plain label views.
struct MenuBarLabel: View {
    let display: MenuDisplay
    let text: String

    var body: some View {
        if let pill = display.urgency.pillColor {
            PillLabelImage(icon: display.state.iconName, text: text, background: pill)
        } else {
            HStack(spacing: 3) {
                Image(systemName: display.state.iconName)
                Text(text)
            }
        }
    }
}

extension Urgency {
    var pillColor: Color? {
        switch self {
        case .normal: return nil
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

private struct PillLabelImage: View {
    let icon: String
    let text: String
    let background: Color

    var body: some View {
        Image(nsImage: renderedImage())
    }

    @MainActor private func renderedImage() -> NSImage {
        let content = HStack(spacing: 3) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(background))
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = false
        return image
    }
}
