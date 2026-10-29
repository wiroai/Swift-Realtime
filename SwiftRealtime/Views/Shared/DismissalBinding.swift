import SwiftUI

@MainActor
extension Binding where Value == Bool {
    /// Presentation that the model raises and the user only lowers.
    ///
    /// `.alert` writes `false` when the person dismisses it; that is
    /// forwarded as a command. Nothing can present through the binding,
    /// so the model stays the only source of the alert.
    static func dismissal(
        isPresented: Bool,
        onDismiss: @escaping @MainActor () -> Void,
    ) -> Binding<Bool> {
        Binding(
            get: { isPresented },
            set: { presented in
                if !presented {
                    onDismiss()
                }
            },
        )
    }
}
