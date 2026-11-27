import SwiftUI

/// The background of Sage's own small pills and notes (the face's note, "Reconnecting…", "Lamp didn't respond",
/// "Checking…"). On watchOS 26 and later: the system's Liquid Glass in a capsule, so they sit with the system's own
/// controls; before that, the solid dark capsule. On the bedside clock always the near-black solid one: glass picks
/// up light from behind it, and at night nothing may light the room.
struct PillBackground: ViewModifier {
    var night = false

    func body(content: Content) -> some View {
        if #available(watchOS 26.0, *), !night {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(Capsule().fill(Color(white: night ? 0.05 : 0.12).opacity(0.95)))
        }
    }
}

extension View {
    func pill(night: Bool = false) -> some View { modifier(PillBackground(night: night)) }
}
