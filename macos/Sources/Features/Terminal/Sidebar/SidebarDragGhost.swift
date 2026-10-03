import Cocoa
import SwiftUI

/// A small floating label that follows the cursor while a sidebar tab card
/// is dragged out of its sidebar, naming what a drop would do.
@MainActor
final class SidebarDragGhost {
    static let shared = SidebarDragGhost()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<GhostLabel>?

    private init() {}

    func show(title: String, hint: String, at point: NSPoint) {
        let label = GhostLabel(title: title, hint: hint)
        if let hostingView {
            hostingView.rootView = label
        } else {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .popUpMenu
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            let hosting = NSHostingView(rootView: label)
            panel.contentView = hosting
            self.panel = panel
            self.hostingView = hosting
        }
        move(to: point)
        panel?.orderFrontRegardless()
    }

    func move(to point: NSPoint) {
        guard let panel, let hostingView else { return }
        let size = hostingView.fittingSize
        // Sit just below-right of the cursor so it never hides the pointer.
        let origin = NSPoint(x: point.x + 14, y: point.y - size.height - 14)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct GhostLabel: View {
    let title: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .fixedSize()
    }
}
