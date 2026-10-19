/// A keyboard request belongs to the shell session, not a transient container.
struct TerminalFocusIntent {
    private(set) var pending = true
    mutating func setFocused(_ focused: Bool) {
        if !focused { pending = false }
    }

    mutating func preserveActiveInput() { pending = true }

    mutating func acquired() { pending = false }
}
