@main
struct TerminalFocusIntentTest {
    static func main() {
        // Off-window and delayed child: focus does not consume the request.
        var intent = TerminalFocusIntent()
        intent.setFocused(true)
        precondition(intent.pending)
        // A failed responder acquisition leaves the request for the next readiness event.
        intent.setFocused(true)
        precondition(intent.pending)
        intent.acquired()
        precondition(!intent.pending)

        // Passive SwiftUI focus updates after a manual hide do not reopen it.
        intent.setFocused(true)
        precondition(!intent.pending)
        // Reparenting a currently active input preserves its request until reattached.
        intent.preserveActiveInput()
        precondition(intent.pending)
        intent.acquired()
        precondition(!intent.pending)

        // Blur cancels an outstanding request, including before a delayed child arrives.
        var delayed = TerminalFocusIntent()
        delayed.setFocused(true)
        delayed.setFocused(false)
        delayed.setFocused(true)
        precondition(!delayed.pending)

        // A restored background terminal must not open the software keyboard
        // when a later title-bar or taskbar action gives it focus.
        var restored = TerminalFocusIntent()
        restored.setFocused(false)
        restored.setFocused(true)
        precondition(!restored.pending)
        print("terminal focus intent tests passed")
    }
}
