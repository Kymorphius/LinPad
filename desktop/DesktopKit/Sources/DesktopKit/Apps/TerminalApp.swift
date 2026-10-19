import GameController
import Perception
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

enum TerminalApp {
    static func descriptor() -> DesktopAppDescriptor {
        DesktopAppDescriptor(
            id: AppID.terminal, name: "Terminal", symbol: "terminal", category: .system,
            defaultSize: CGSize(width: 760, height: 480), showsOnDesktop: true
        ) { context in
            AnyView(TerminalAppView(context: context))
        }
    }
}

/// Owns the terminal view controller for one window. SwiftUI may rebuild the
/// representable at any time; the session (a live shell) must outlive that.
@MainActor
final class TerminalSession {
    private let host: any LinuxHost
    private let command: String?
    private let cwd: String?
    private var cachedController: UIViewController?
    fileprivate weak var container: TerminalContainerController?
    fileprivate(set) var isLeased = false
    private var focusOnReclaim = false
    var focusIntent = TerminalFocusIntent()

    init(context: AppLaunchContext, controller: UIViewController? = nil) {
        host = context.host
        command = context.arguments[AppArgument.command]
        cwd = context.arguments[AppArgument.cwd]
        cachedController = controller
    }

    fileprivate func lease() -> UIViewController {
        let content = controller
        isLeased = true
        // Entering terminal mode is an explicit request to use this terminal.
        focusIntent.preserveActiveInput()
        if content.isViewLoaded {
            content.view.endEditing(true)
        }
        if content.parent != nil {
            content.willMove(toParent: nil)
            content.view.removeFromSuperview()
            content.removeFromParent()
        }
        return content
    }

    fileprivate func reclaim() {
        isLeased = false
        container?.mountContent()
        if focusOnReclaim { container?.setKeyboardFocus(true) }
        focusOnReclaim = false
    }

    func requestDesktopFocusOnReclaim() { focusOnReclaim = true }

    var controller: UIViewController {
        if let cachedController { return cachedController }
        let controller = host.makeTerminalViewController(command: command, cwd: cwd)
        cachedController = controller
        return controller
    }

    var workingDirectory: String? { cwd }

    /// Types text into the shell as if it were typed.
    func type(_ text: String) {
        guard let view = cachedController?.view, let input = TerminalContainerController.textInputView(in: view) as? UIKeyInput else { return }
        input.insertText(text)
    }

    /// Drops become text, like GNOME Terminal: files as quoted paths separated by spaces
    /// (files from other apps are copied into ~/Downloads first), links and text as is.
    func insert(_ items: [DragItem]) {
        Task {
            var words: [String] = []
            for item in items {
                switch item {
                case .guestFile(let path, _):
                    words.append(ShellQuote.quote(path))
                case .hostFile(let url):
                    let downloads = AppPath.join(host.homeDirectory, "Downloads")
                    _ = await host.run("mkdir -p -- \(ShellQuote.quote(downloads))", cwd: nil, stdin: nil)
                    if let path = try? await GuestTransferService(host: host).importItem(at: url, into: downloads) {
                        words.append(ShellQuote.quote(path))
                    }
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                case .data(let data, let name):
                    let downloads = AppPath.join(host.homeDirectory, "Downloads")
                    _ = await host.run("mkdir -p -- \(ShellQuote.quote(downloads))", cwd: nil, stdin: nil)
                    if let path = try? await GuestTransferService(host: host).importData(data, named: name, into: downloads) {
                        words.append(ShellQuote.quote(path))
                    }
                case .url(let url):
                    words.append(url.absoluteString)
                case .text(let text):
                    words.append(text)
                }
            }
            guard !words.isEmpty else { return }
            type(words.joined(separator: " ") + " ")
        }
    }
}

struct TerminalAppView: View {
    @State private var session: TerminalSession
    @Environment(\.desktopWindowIsFocused) private var isFocused
    private let window: any WindowHandle
    private let desktop: any DesktopActions

    init(context: AppLaunchContext) {
        _session = State(initialValue: TerminalSession(context: context))
        window = context.window
        desktop = context.desktop
    }

    init(context: AppLaunchContext, session: TerminalSession) {
        _session = State(initialValue: session)
        window = context.window
        desktop = context.desktop
    }

    var body: some View {
        WithPerceptionTracking {
            TerminalControllerView(session: session, isFocused: isFocused) { [desktop, session] in
                var arguments: [String: String] = [:]
                if let cwd = session.workingDirectory { arguments[AppArgument.cwd] = cwd }
                desktop.open(appID: AppID.terminal, arguments: arguments)
            }
            .background(Color.black)
            .onAppear { window.setTitle("Terminal") }
            .nativeDropTarget(window: window.id) { [session] items, _ in session.insert(items) }
        }
    }
}

private struct TerminalControllerView: UIViewControllerRepresentable {
    let session: TerminalSession
    let isFocused: Bool
    let openNewWindow: @MainActor () -> Void

    func makeUIViewController(context: Context) -> TerminalContainerController {
        let controller = TerminalContainerController(content: session.controller)
        controller.session = session
        controller.openNewWindow = openNewWindow
        return controller
    }

    func updateUIViewController(_ controller: TerminalContainerController, context: Context) {
        controller.setKeyboardFocus(isFocused)
    }
}

/// A fresh container per representable that re-parents the cached session controller.
/// It also owns the terminal's context menu (secondary click or long press) and drops.
final class TerminalContainerController: UIViewController, UIContextMenuInteractionDelegate, UIDropInteractionDelegate {
    private let content: UIViewController
    weak var session: TerminalSession?
    var openNewWindow: (@MainActor () -> Void)?
    private var windowIsFocused = false
    private var inputReadyObserver: NSObjectProtocol?

    init(content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        session?.container = self
        mountContent()
        view.addInteraction(UIContextMenuInteraction(delegate: self))
        view.addInteraction(UIDropInteraction(delegate: self))
        inputReadyObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("DesktopTerminalInputReady"), object: content, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPendingInput() }
        }
    }

    func mountContent() {
        guard isViewLoaded, session?.isLeased != true, content.parent !== self else { return }
        if content.parent != nil {
            if Self.textInputView(in: content.view)?.isFirstResponder == true {
                session?.focusIntent.preserveActiveInput()
            }
            content.willMove(toParent: nil)
            content.view.removeFromSuperview()
            content.removeFromParent()
        }
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = true
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content.view)
        content.didMove(toParent: self)
        // The terminal is drawn by a web view, which would take drops itself and turn text
        // into page content; drops belong to the shell.
        Self.removeWebDropInteractions(in: content.view)
    }

    deinit {
        if let inputReadyObserver { NotificationCenter.default.removeObserver(inputReadyObserver) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyPendingInput()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyPendingInput()
    }

    private func applyPendingInput() {
        guard session?.isLeased != true, windowIsFocused, session?.focusIntent.pending == true,
              isViewLoaded, view.window != nil, !view.isHidden,
              let input = Self.textInputView(in: content.view), input.window != nil,
              input.isDescendant(of: view), !input.isHidden else { return }
        if input.isFirstResponder || input.becomeFirstResponder() {
            session?.focusIntent.acquired()
        }
    }

    private static func removeWebDropInteractions(in root: UIView) {
        for subview in root.subviews {
            if subview is WKWebView || subview.superview is WKWebView || String(describing: type(of: subview)).hasPrefix("WK") {
                for interaction in subview.interactions where interaction is UIDropInteraction {
                    subview.removeInteraction(interaction)
                }
            }
            removeWebDropInteractions(in: subview)
        }
    }

    // MARK: Context menu

    private func perform(_ selector: Selector) {
        guard let input = Self.textInputView(in: content.view), input.responds(to: selector) else { return }
        input.perform(selector, with: nil)
    }

    private var webView: WKWebView? {
        func find(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return find(content.view)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let edit = UIMenu(options: .displayInline, children: [
                UIAction(title: "Copy", image: UIImage.themed(systemName: "doc.on.doc")) { _ in
                    self.perform(#selector(UIResponderStandardEditActions.copy(_:)))
                },
                UIAction(title: "Paste", image: UIImage.themed(systemName: "doc.on.clipboard"),
                         attributes: UIPasteboard.general.hasStrings ? [] : .disabled) { _ in
                    self.perform(#selector(UIResponderStandardEditActions.paste(_:)))
                },
                UIAction(title: "Select All", image: UIImage.themed(systemName: "checkmark.circle")) { _ in
                    self.webView?.evaluateJavaScript(
                        "(() => { const d = term.getDocument(); const r = d.createRange(); r.selectNodeContents(d.body); const s = d.getSelection(); s.removeAllRanges(); s.addRange(r); })()")
                },
            ])
            let terminal = UIMenu(options: .displayInline, children: [
                UIAction(title: "Clear Scrollback", image: UIImage.themed(systemName: "eraser")) { _ in
                    self.webView?.evaluateJavaScript("exports.clearScrollback()")
                },
                UIAction(title: "New Terminal Window", image: UIImage.themed(systemName: "plus.rectangle.on.rectangle")) { _ in
                    self.openNewWindow?()
                },
            ])
            return UIMenu(children: [edit, terminal])
        }
    }

    // MARK: Drops

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: DragItemProviders.acceptedTypes.map(\.identifier))
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        let providers = session.items.map(\.itemProvider)
        Task { [weak self] in
            let (_, items) = await DragItemProviders.loadItems(from: providers)
            self?.session?.insert(items)
        }
    }

    /// The initial focused launch may consume its pending request when attached.
    /// A blur cancels it, so later title-bar or taskbar focus does not show the
    /// software keyboard. Hardware keyboard focus still takes typing at once.
    func setKeyboardFocus(_ focused: Bool) {
        guard session?.isLeased != true else { return }
        windowIsFocused = focused
        session?.focusIntent.setFocused(focused)
        guard isViewLoaded else { return }
        if focused { applyPendingInput() }
        guard let input = Self.textInputView(in: content.view) else { return }
        if focused {
            guard GCKeyboard.coalesced != nil, !input.isFirstResponder else { return }
            DispatchQueue.main.async { [weak self, weak input] in
                guard let self, self.session?.isLeased != true, self.windowIsFocused, let input, input.window != nil,
                      input.isDescendant(of: self.view) else { return }
                input.becomeFirstResponder()
            }
        } else if input.isFirstResponder {
            input.resignFirstResponder()
        }
    }

    static func textInputView(in root: UIView) -> UIView? {
        if root.canBecomeFirstResponder { return root }
        for subview in root.subviews {
            if let found = textInputView(in: subview) { return found }
        }
        return nil
    }
}

/// Presents the very same controller in a full-screen shell until the desktop reclaims it.
@MainActor
public final class TerminalFullscreenController: UIViewController {
    private let session: TerminalSession
    private let returnToDesktop: () -> Void
    private let sessionEnded: () -> Void
    private let content: UIViewController
    private var released = false
    private var exitObserver: NSObjectProtocol?
    private var inputReadyObserver: NSObjectProtocol?

    init(session: TerminalSession, returnToDesktop: @escaping () -> Void, sessionEnded: @escaping () -> Void) {
        self.session = session
        self.returnToDesktop = returnToDesktop
        self.sessionEnded = sessionEnded
        self.content = session.lease()
        super.init(nibName: nil, bundle: nil)
        exitObserver = NotificationCenter.default.addObserver(forName: Notification.Name("DesktopTerminalSessionExited"),
                                                               object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, !self.released, var owner = note.object as? UIViewController else { return }
                while owner !== self.content {
                    guard let parent = owner.parent else { return }
                    owner = parent
                }
                guard let state = note.userInfo?["handled"] as? NSMutableArray else { return }
                state[0] = true
                // Let the native exit handler clear its task/session before the window
                // and its controller can be released.
                DispatchQueue.main.async { self.sessionEnded() }
            }
        }
        inputReadyObserver = NotificationCenter.default.addObserver(forName: Notification.Name("DesktopTerminalInputReady"),
                                                                     object: content, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPendingInput() }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let exitObserver { NotificationCenter.default.removeObserver(exitObserver) }
        if let inputReadyObserver { NotificationCenter.default.removeObserver(inputReadyObserver) }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        let button = UIButton(type: .system)
        button.setTitle("Desktop", for: .normal)
        button.addTarget(self, action: #selector(backToDesktop), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content.view)
        content.didMove(toParent: self)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            button.heightAnchor.constraint(equalToConstant: 44),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            content.view.topAnchor.constraint(equalTo: button.bottomAnchor),
            content.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func backToDesktop() { returnToDesktop() }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyPendingInput()
    }

    private func applyPendingInput() {
        guard !released, isViewLoaded, view.window != nil,
              session.focusIntent.pending || GCKeyboard.coalesced != nil,
              let input = TerminalContainerController.textInputView(in: content.view),
              input.window != nil, input.isDescendant(of: view), !input.isHidden else { return }
        if input.isFirstResponder || input.becomeFirstResponder() {
            session.focusIntent.acquired()
        }
    }

    /// Called before the scene returns to the retained desktop root.
    @objc public func releaseSession() {
        guard !released else { return }
        released = true
        if content.parent === self {
            if TerminalContainerController.textInputView(in: content.view)?.isFirstResponder == true {
                session.focusIntent.preserveActiveInput()
            }
            content.view.endEditing(true)
            content.willMove(toParent: nil)
            content.view.removeFromSuperview()
            content.removeFromParent()
        }
        session.reclaim()
    }
}

#Preview("Terminal") {
    TerminalAppView(context: AppsPreview.context([AppArgument.cwd: "/root/app"]))
        .frame(width: 760, height: 480)
}
