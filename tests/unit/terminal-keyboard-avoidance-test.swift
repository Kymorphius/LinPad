import CoreGraphics
import Foundation

private let titleBarHeight: CGFloat = 56

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private func keyboard(in desktop: CGSize, height: CGFloat, shown: Bool) -> CGRect {
    CGRect(x: 0, y: shown ? desktop.height - height : desktop.height,
           width: desktop.width, height: height)
}

private func nativeGeometry(frame: CGRect, keyboard: CGRect, desktop: CGSize) -> TerminalKeyboardGeometry {
    let origin = CGPoint(x: frame.minX, y: frame.minY + titleBarHeight)
    return TerminalKeyboardGeometryForFrames(
        keyboard, CGRect(origin: .zero, size: desktop),
        keyboard.offsetBy(dx: -origin.x, dy: -origin.y),
        CGRect(x: 0, y: 0, width: frame.width, height: frame.height - titleBarHeight), 0, 0)
}

private func visibleHeight(frame: CGRect, padding: CGFloat) -> CGFloat {
    max(0, frame.height - titleBarHeight - padding)
}

private func distinct(_ values: [CGFloat]) -> [CGFloat] {
    values.reduce(into: []) { result, value in
        if result.last.map({ abs($0 - value) > 0.001 }) ?? true { result.append(value) }
    }
}

private func interpolate(_ start: CGRect, _ end: CGRect, progress: CGFloat) -> CGRect {
    CGRect(x: start.minX + (end.minX - start.minX) * progress,
           y: start.minY + (end.minY - start.minY) * progress,
           width: start.width + (end.width - start.width) * progress,
           height: start.height + (end.height - start.height) * progress)
}

private struct Cycle {
    let shown: CGRect
    let padding: CGFloat
    let showingHeights: [CGFloat]
    let hidingHeights: [CGFloat]
}

// The model starts with a settled hidden keyboard and ends with it hidden again.
// Interpolated frame samples stand in for the desktop's existing withAnimation.
// WillChange retains the old native padding; DidChange uses the actual C helper.
private func cycle(manager: WindowManager, window: DesktopWindow, keyboardHeight: CGFloat) -> Cycle {
    require(manager.keyboard.overlap == 0, "cycle starts with keyboard hidden")
    let original = manager.displayFrame(for: window)
    let stored = window.frame
    let snap = window.snap
    let maximized = window.isMaximized
    let tiles = manager.tileFrames
    let shownKeyboard = keyboard(in: manager.desktopSize, height: keyboardHeight, shown: true)
    manager.keyboard.keyboardChanged(to: shownKeyboard, desktop: CGRect(origin: .zero, size: manager.desktopSize),
                                     hardwareKeyboard: false, focusedWindow: manager.focusedWindowID)
    let shown = manager.displayFrame(for: window)
    var showing = [visibleHeight(frame: original, padding: 0)]
    let animationProgress: [CGFloat] = [1 / 3, 2 / 3, 1]
    require(!TerminalKeyboardShouldApplyLocalPadding(true, false), "embedded WillChange must defer native padding")
    for progress in animationProgress {
        let intermediate = interpolate(original, shown, progress: progress)
        // Computing a WillChange result is harmless: production does not apply it.
        _ = nativeGeometry(frame: intermediate, keyboard: shownKeyboard, desktop: manager.desktopSize)
        showing.append(visibleHeight(frame: intermediate, padding: 0))
    }
    require(TerminalKeyboardShouldApplyLocalPadding(true, true), "DidChange owns the final native padding")
    let finalPadding = nativeGeometry(frame: shown, keyboard: shownKeyboard, desktop: manager.desktopSize).padding
    showing.append(visibleHeight(frame: shown, padding: finalPadding))

    manager.keyboard.reset()
    let restored = manager.displayFrame(for: window)
    let hiddenKeyboard = keyboard(in: manager.desktopSize, height: keyboardHeight, shown: false)
    var hiding = [visibleHeight(frame: shown, padding: finalPadding)]
    for progress in animationProgress {
        let intermediate = interpolate(shown, restored, progress: progress)
        hiding.append(visibleHeight(frame: intermediate, padding: finalPadding))
    }
    let hiddenPadding = nativeGeometry(frame: restored, keyboard: hiddenKeyboard, desktop: manager.desktopSize).padding
    require(hiddenPadding == 0, "completed dismissal clears padding")
    hiding.append(visibleHeight(frame: restored, padding: hiddenPadding))
    require(restored == original, "keyboard hide restores exact rendered frame")
    require(window.frame == stored && window.snap == snap && window.isMaximized == maximized,
            "avoidance must not rewrite floating placement, snap or maximize state")
    require(manager.tileFrames == tiles, "avoidance must not rewrite tile placement")
    return Cycle(shown: shown, padding: finalPadding,
                 showingHeights: distinct(showing), hidingHeights: distinct(hiding))
}

private func setup(frame: CGRect, appID: String = AppID.terminal,
                   desktop: CGSize = CGSize(width: 1180, height: 760)) -> (WindowManager, DesktopWindow) {
    let manager = WindowManager()
    manager.desktopSize = desktop
    let window = DesktopWindow(appID: appID, frame: frame)
    manager.focusedWindowID = window.id
    return (manager, window)
}

@main
struct TerminalKeyboardAvoidanceTest {
    static func main() {
        #if TEST_LEGACY_HEIGHT
        negativeControl()
        #else
        productionRoutingAndGeometry()
        nativeHeightOwnership()
        snappedAndTiledRouting()
        rotationCycles()
        print("PASS: production terminal routing, preserved frames, and native-only completed height changes")
        #endif
    }

    private static func productionRoutingAndGeometry() {
        let upper = CGRect(x: 100, y: 20, width: 600, height: 300)
        let lower = CGRect(x: 100, y: 400, width: 600, height: 300)
        let tall = CGRect(x: 100, y: 20, width: 600, height: 700)
        for frame in [upper, lower, tall] {
            for available in [CGFloat(420), 150] {
                let lifted = WindowGeometry.liftingAboveKeyboard(frame, availableHeight: available)
                require(lifted.size == frame.size && lifted.minX == frame.minX, "terminal lift preserves both dimensions and X")
                require(lifted.minY == (frame.maxY > available ? max(0, available - frame.height) : frame.minY),
                        "terminal lift only translates an overlapping frame")
            }
            for available in [CGFloat(0), -100, 760] {
                require(WindowGeometry.liftingAboveKeyboard(frame, availableHeight: available) == frame,
                        "hidden/nonoverlapping keyboard does not move a frame")
            }
        }

        let (manager, terminal) = setup(frame: tall)
        manager.keyboard.keyboardChanged(to: keyboard(in: manager.desktopSize, height: 340, shown: true),
                                         desktop: CGRect(origin: .zero, size: manager.desktopSize),
                                         hardwareKeyboard: false, focusedWindow: terminal.id)
        require(manager.displayFrame(for: terminal) == CGRect(x: 100, y: 0, width: 600, height: 700),
                "actual displayFrame routes AppID.terminal to translation-only geometry")
        let files = DesktopWindow(appID: AppID.files, frame: tall)
        require(manager.displayFrame(for: files) == tall, "background windows retain their frame")
        manager.focusedWindowID = files.id
        manager.keyboard.focusChanged(to: files.id)
        require(manager.displayFrame(for: terminal) == tall, "focus release restores the terminal")
        manager.keyboard.keyboardChanged(to: keyboard(in: manager.desktopSize, height: 340, shown: true),
                                         desktop: CGRect(origin: .zero, size: manager.desktopSize),
                                         hardwareKeyboard: false, focusedWindow: files.id)
        require(manager.displayFrame(for: files) == WindowGeometry.avoidingKeyboard(tall, availableHeight: 420, minimumHeight: 200),
                "Files keeps the existing shrink policy")
        manager.keyboard.reset()
        require(manager.displayFrame(for: files) == tall, "Files restoration is unchanged")
    }

    private static func nativeHeightOwnership() {
        let upper = CGRect(x: 100, y: 20, width: 600, height: 300)
        let lower = CGRect(x: 100, y: 400, width: 600, height: 300)
        let tall = CGRect(x: 100, y: 20, width: 600, height: 700)
        for frame in [upper, lower, tall] {
            for height in [CGFloat(340), 610] {
                let (manager, window) = setup(frame: frame)
                let result = cycle(manager: manager, window: window, keyboardHeight: height)
                require(result.shown.size == frame.size, "desktop animation never changes terminal size")
                require(result.showingHeights.count <= 2 && result.hidingHeights.count <= 2,
                        "only the completed native padding may change usable height")
                require(result.showingHeights.last == result.hidingHeights.first, "show/hide agree on the visible viewport")
            }
        }
        let (manager, window) = setup(frame: lower)
        let moved = cycle(manager: manager, window: window, keyboardHeight: 340)
        require(moved.shown.minY == 120 && moved.padding == 0 && moved.showingHeights.count == 1,
                "a lower window that fits is translated without any viewport resize")
        // The old policy also preserves this small frame's size. This candidate
        // makes no claim about jumping caused solely by its translation or tap Y.
        require(moved.shown == WindowGeometry.avoidingKeyboard(lower, availableHeight: 420, minimumHeight: 200),
                "small fitting windows are a deliberate unchanged control")
        let (tallManager, tallWindow) = setup(frame: tall)
        let squeezed = cycle(manager: tallManager, window: tallWindow, keyboardHeight: 610)
        require(squeezed.shown.height == 700 && squeezed.padding == 550,
                "native padding handles overlap even below the desktop's old minimum height")
    }

    private static func snappedAndTiledRouting() {
        let stored = CGRect(x: 70, y: 50, width: 600, height: 500)
        for zone in [SnapZone.rightHalf, .bottomRight, .maximize] {
            let (manager, window) = setup(frame: stored)
            if zone == .maximize { window.isMaximized = true } else { window.snap = zone }
            let before = manager.displayFrame(for: window)
            let result = cycle(manager: manager, window: window, keyboardHeight: 340)
            require(result.shown.size == before.size, "snap/maximize terminal frames must not shrink")
        }
        let (manager, window) = setup(frame: stored)
        manager.tileFrames[window.id] = CGRect(x: 20, y: 20, width: 550, height: 700)
        window.tileDragOffset = CGSize(width: 5, height: 10)
        let result = cycle(manager: manager, window: window, keyboardHeight: 340)
        require(result.shown == CGRect(x: 25, y: 0, width: 550, height: 700),
                "actual tiled frame routing preserves tile size and drag X")
    }

    private static func rotationCycles() {
        let (manager, window) = setup(frame: CGRect(x: 50, y: 20, width: 600, height: 700))
        window.isMaximized = true
        // Each orientation supplies a current keyboard frame. This does not
        // model rotation without a notification or UIKit's notification ordering.
        for desktop in [CGSize(width: 1180, height: 760), CGSize(width: 760, height: 1180),
                        CGSize(width: 1180, height: 760)] {
            manager.desktopSize = desktop
            for _ in 0..<2 {
                let result = cycle(manager: manager, window: window, keyboardHeight: 340)
                require(result.shown.size == desktop, "maximized orientation keeps full container size")
                require(result.showingHeights.count == 2 && result.hidingHeights.count == 2,
                        "each orientation has one completed show/hide viewport resize")
            }
        }
    }

    private static func negativeControl() {
        for height in [CGFloat(340), 610] {
            let (manager, window) = setup(frame: CGRect(x: 100, y: 20, width: 600, height: 700))
            let result = cycle(manager: manager, window: window, keyboardHeight: height)
            require(result.shown.height < window.frame.height, "negative control must restore old terminal shrinking")
            require(result.showingHeights.count > 2 && result.hidingHeights.count > 2,
                    "old actual displayFrame produces intermediate viewport heights before DidChange")
        }
        print("PASS: legacy routing negative control reproduces intermediate terminal heights on show and hide")
    }
}
