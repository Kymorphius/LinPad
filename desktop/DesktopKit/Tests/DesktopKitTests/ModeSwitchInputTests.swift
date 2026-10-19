import XCTest
import UIKit
@testable import DesktopKit

@MainActor
final class ModeSwitchInputTests: XCTestCase {
    func testSuspendingDesktopRemovesOnlyItsInputHooksAndPreservesFocus() {
        let controller = DesktopController(host: MockLinuxHost(latency: .zero), apps: [])
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = root
        let anchor = UIView(frame: window.bounds)
        root.view.addSubview(anchor)
        let unrelated = UIKeyCommand(input: "z", modifierFlags: .alternate, action: #selector(UIResponder.copy(_:)))
        root.addKeyCommand(unrelated)
        let unrelatedGesture = UITapGestureRecognizer()
        window.addGestureRecognizer(unrelatedGesture)
        let desktopWindow = controller.windowManager.makeWindow(appID: "test", symbol: "terminal", title: "Test",
                                                                 preferredSize: CGSize(width: 400, height: 300))
        controller.windowManager.present(desktopWindow)
        controller.input.attach(to: anchor)
        XCTAssertTrue(DesktopKeyCommands.active === controller.keyCommands)
        XCTAssertGreaterThan(window.gestureRecognizers?.count ?? 0, 1)
        let desktopResponder = UIView()
        anchor.addSubview(desktopResponder)
        let classicRoot = UIViewController()
        let classicResponder = UIView()
        classicRoot.view.addSubview(classicResponder)
        window.rootViewController = classicRoot
        XCTAssertTrue(controller.input.ownsResponder(desktopResponder))
        XCTAssertFalse(controller.input.ownsResponder(classicResponder), "Do not resign the newly displayed classic interface")

        controller.input.setActive(false)
        XCTAssertFalse(controller.isDesktopActive)
        XCTAssertEqual(controller.windowManager.focusedWindowID, desktopWindow.id)
        XCTAssertNil(DesktopKeyCommands.active)
        XCTAssertEqual(window.gestureRecognizers?.count, 1)
        XCTAssertTrue(window.gestureRecognizers?.contains(unrelatedGesture) == true)
        XCTAssertTrue(root.keyCommands?.contains(unrelated) == true)

        window.rootViewController = root
        controller.input.setActive(true)
        XCTAssertTrue(controller.isDesktopActive)
        XCTAssertTrue(DesktopKeyCommands.active === controller.keyCommands)
        XCTAssertGreaterThan(window.gestureRecognizers?.count ?? 0, 1)
        XCTAssertEqual(controller.windowManager.focusedWindowID, desktopWindow.id)
        controller.input.setActive(false)
    }
}
