import SwiftUI

/// Evaluates `content` in a body of its own, so the observable values it reads
/// (the narrated sentence, say) update only this view and not the screen around
/// it, whose menus and sheets would otherwise be rebuilt as playback moves.
struct ObservationScope<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}
