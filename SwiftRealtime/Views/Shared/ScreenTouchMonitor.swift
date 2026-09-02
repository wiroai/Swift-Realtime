import SwiftUI
import UIKit

/// Reports the moment any finger lands on the screen.
///
/// A recognizer sits on every window, including the ones UIKit
/// creates for a `Menu`, so a tap that opens the voice list or
/// dismisses it is seen too. The recognizer fails on the spot, so
/// nothing about how the touch is handled changes.
@MainActor
final class ScreenTouchMonitor {
    private var onTouch: (@MainActor () -> Void)?
    private var observer: NSObjectProtocol?
    private var recognizers: [PassiveTouchRecognizer] = []

    func start(onTouch: @escaping @MainActor () -> Void) {
        stop()
        self.onTouch = onTouch
        for window in visibleWindows() {
            attach(to: window)
        }
        observer = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            guard let window = notification.object as? UIWindow else {
                return
            }
            MainActor.assumeIsolated {
                self?.attach(to: window)
            }
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        for recognizer in recognizers {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        recognizers.removeAll()
        onTouch = nil
    }

    private func attach(to window: UIWindow) {
        // Menu windows go away with the menu; drop their recognizers.
        recognizers.removeAll { $0.view == nil }
        if recognizers.contains(where: { $0.view === window }) {
            return
        }
        let recognizer = PassiveTouchRecognizer { [weak self] in
            self?.onTouch?()
        }
        window.addGestureRecognizer(recognizer)
        recognizers.append(recognizer)
    }

    private func visibleWindows() -> [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden }
    }
}

/// Sees every touch begin and then steps aside.
private final class PassiveTouchRecognizer: UIGestureRecognizer,
    UIGestureRecognizerDelegate
{
    private let onTouch: @MainActor () -> Void

    init(onTouch: @escaping @MainActor () -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(
        _ touches: Set<UITouch>,
        with event: UIEvent,
    ) {
        onTouch()
        state = .failed
    }

    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer,
    ) -> Bool {
        true
    }
}

extension View {
    /// Calls `onTouch` when a finger lands anywhere on screen while
    /// this view is on screen.
    func onScreenTouch(
        _ onTouch: @escaping @MainActor () -> Void,
    ) -> some View {
        modifier(ScreenTouchModifier(onTouch: onTouch))
    }
}

private struct ScreenTouchModifier: ViewModifier {
    let onTouch: @MainActor () -> Void
    @State private var monitor = ScreenTouchMonitor()

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.start(onTouch: onTouch) }
            .onDisappear { monitor.stop() }
    }
}
