// SPDX-License-Identifier: AGPL-3.0-only
#if os(iOS)
import UIKit

/// Reports every finger that lands in the app's windows, without taking part in
/// gesture recognition: an AI soundscape being composed yields the GPU for a
/// moment, so menus, sheets and scrolling animate smoothly.
@MainActor
enum TouchActivity {
    private static var observer: NSObjectProtocol?
    private static var onTouch: (@MainActor () -> Void)?

    static func start(_ handler: @escaping @MainActor () -> Void) {
        onTouch = handler
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated { attach(to: note.object as? UIWindow) }
        }
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] { attach(to: window) }
        }
    }

    private static func attach(to window: UIWindow?) {
        guard let window,
              !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchRecognizer }) else { return }
        window.addGestureRecognizer(TouchRecognizer())
    }

    fileprivate static func touched() { onTouch?() }
}

/// Fails as soon as a touch begins, so it never delays or cancels other gestures.
private final class TouchRecognizer: UIGestureRecognizer {
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        TouchActivity.touched()
        state = .failed
    }
}
#endif
