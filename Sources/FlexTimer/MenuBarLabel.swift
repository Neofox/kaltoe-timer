import AppKit
import SwiftUI
import KaltoeCore

/// Menu bar label. Normally a template icon+text view; for the alerting
/// urgencies, and for the whole label when high contrast is on, a pre-rendered
/// non-template NSImage.
///
/// Non-template is the entire mechanism. macOS greys out template images on the
/// menu bar of a display that does not hold the active window, and also ignores
/// colours on plain label views — rendering to pixels sidesteps both.
struct MenuBarLabel: View {
    let display: MenuDisplay
    let text: String
    let highContrast: Bool

    /// Resolves against the menu bar's appearance, so the solid fill opposes
    /// whatever the bar is drawn in.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch MenuLabelStyle.resolve(urgency: display.urgency, highContrast: highContrast) {
        case .pill(let urgency):
            MenuBarLabelImage(icon: display.state.iconName, text: text,
                              foreground: .white,
                              background: urgency == .critical ? .red : .orange,
                              font: .system(size: 12, weight: .medium))
        case .solid:
            MenuBarLabelImage(icon: display.state.iconName, text: text,
                              foreground: colorScheme == .dark ? .white : .black,
                              background: nil,
                              font: Font(NSFont.menuBarFont(ofSize: 0)))
        case .plain:
            HStack(spacing: 3) {
                Image(systemName: display.state.iconName)
                Text(text)
            }
        }
    }
}

/// Renders icon+text to a non-template NSImage, with an optional capsule behind
/// it. A nil background draws the glyphs alone at the menu bar's own metrics, so
/// that toggling high contrast should not shift the label's width or position —
/// pending visual confirmation on hardware.
private struct MenuBarLabelImage: View {
    let icon: String
    let text: String
    let foreground: Color
    let background: Color?
    let font: Font

    var body: some View {
        Image(nsImage: renderedImage())
            .accessibilityLabel(text)
    }

    @MainActor private func renderedImage() -> NSImage {
        let content = HStack(spacing: 3) {
            Image(systemName: icon)
            Text(text)
        }
        .font(font)
        .foregroundStyle(foreground)
        .padding(.horizontal, background == nil ? 0 : 7)
        .padding(.vertical, background == nil ? 0 : 2)
        .background {
            if let background {
                Capsule().fill(background)
            }
        }
        let renderer = ImageRenderer(content: content)
        // Render at the highest scale factor across all screens, not
        // NSScreen.main (the screen with the active window — precisely the
        // display this feature is not about). MenuBarExtra draws one image on
        // every menu bar, so rasterizing at the active display's scale would
        // upscale a 1x bitmap onto a 2x bar on mixed-DPI setups, blurring the
        // countdown on the very screen we're trying to keep legible.
        // Downsampling a high-res rep onto a 1x bar is fine; the reverse isn't.
        renderer.scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = false
        return image
    }
}
