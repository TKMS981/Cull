import SwiftUI
import UIKit

extension View {
    /// Turns off the navigation stack's full-width "swipe back from anywhere in the content"
    /// gesture (iOS 26+) while this view is on screen. The edge swipe and Back button still work.
    ///
    /// UIKit bridge because SwiftUI has no modifier for it. On the culling screen it otherwise
    /// competes with the card's right swipe (trash) and can claim the start of the drag.
    func contentPopGestureDisabled() -> some View {
        background { ContentPopGestureDisabler().frame(width: 0, height: 0).accessibilityHidden(true) }
    }
}

private struct ContentPopGestureDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private weak var disabledRecognizer: UIGestureRecognizer?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let recognizer = navigationController?.interactiveContentPopGestureRecognizer else { return }
            recognizer.isEnabled = false
            disabledRecognizer = recognizer
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Other screens (setup, trash) keep the system behaviour.
            disabledRecognizer?.isEnabled = true
            disabledRecognizer = nil
        }
    }
}
