import XCTest
import UIKit
@testable import DesktopKit

@MainActor
private final class ModeLeaseHost: LinuxHost, ClassicTerminalSwitching {
    let hostName = "test"
    let homeDirectory = "/root"
    let terminal = UIViewController()
    var created = 0
    var fullscreen: TerminalFullscreenController?
    var canSwitchToClassicTerminal = true
    var acceptsSwitch = true
    func run(_ command: String, cwd: String?, stdin: Data?) async -> CommandResult { CommandResult(stdout: "") }
    func stream(_ command: String, cwd: String?, onOutput: @escaping @MainActor (String) -> Void) async -> Int32 { 0 }
    func makeTerminalViewController(command: String?, cwd: String?) -> UIViewController {
        created += 1
        return terminal
    }
    func switchToClassicTerminal(_ controller: UIViewController) -> Bool {
        guard acceptsSwitch else { return false }
        fullscreen = controller as? TerminalFullscreenController
        return fullscreen != nil
    }

    func switchToDesktop() { fullscreen?.releaseSession() }
}

@MainActor
final class TerminalModeLeaseTests: XCTestCase {
    func testRejectedSwitchReturnsControllerToDesktop() throws {
        let host = ModeLeaseHost()
        host.acceptsSwitch = false
        let controller = DesktopController(host: host, apps: BuiltinApps.all())
        controller.open(appID: AppID.terminal, arguments: [:])
        let session = try XCTUnwrap(controller.windowManager.focusedWindow?.terminalSession)
        let original = TerminalContainerController(content: session.controller)
        original.session = session
        original.loadViewIfNeeded()
        controller.switchToClassicTerminal()
        XCTAssertFalse(session.isLeased)
        XCTAssertTrue(host.terminal.parent === original)
        XCTAssertEqual(host.created, 1)
    }

    func testFullscreenBorrowsSameControllerAndReturnsItWithoutStartingAnotherShell() throws {
        let host = ModeLeaseHost()
        let controller = DesktopController(host: host, apps: BuiltinApps.all())
        controller.open(appID: AppID.terminal, arguments: [:])
        let window = try XCTUnwrap(controller.windowManager.focusedWindow)
        let session = try XCTUnwrap(window.terminalSession)
        XCTAssertTrue(session.controller === host.terminal)
        let original = TerminalContainerController(content: session.controller)
        original.session = session
        original.loadViewIfNeeded()
        XCTAssertTrue(host.terminal.parent === original)
        controller.switchToClassicTerminal()
        let fullscreen = try XCTUnwrap(host.fullscreen)
        fullscreen.loadViewIfNeeded()
        XCTAssertTrue(fullscreen.children.contains { $0 === host.terminal })
        XCTAssertTrue(session.isLeased)
        XCTAssertTrue(session.focusIntent.pending, "Switching to terminal mode requests input once when attached")
        let replacement = TerminalContainerController(content: session.controller)
        replacement.session = session
        replacement.loadViewIfNeeded()
        XCTAssertTrue(host.terminal.parent === fullscreen, "A hidden container must not steal the leased controller")
        fullscreen.releaseSession()
        XCTAssertFalse(session.isLeased)
        XCTAssertTrue(host.terminal.parent === replacement, "Return must attach to the current desktop container")
        XCTAssertTrue(session.controller === host.terminal)
        XCTAssertEqual(host.created, 1)
    }

    func testColdClassicControllerIsAdoptedWithoutCreatingAnotherShell() throws {
        let host = ModeLeaseHost()
        let controller = DesktopController(host: host, apps: BuiltinApps.all())
        controller.initialTerminal = host.terminal
        controller.open(appID: AppID.terminal, arguments: [:])
        let session = try XCTUnwrap(controller.windowManager.focusedWindow?.terminalSession)
        XCTAssertTrue(session.controller === host.terminal)
        XCTAssertEqual(host.created, 0)
    }
}
