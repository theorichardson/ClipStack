import SwiftUI

extension View {
    func keyboardNavigationHandlers(
        onUp: @escaping () -> Void,
        onDown: @escaping () -> Void,
        onEscape: @escaping () -> Void,
        onReturn: @escaping () -> Void
    ) -> some View {
        self
            .onKeyPress(.upArrow) {
                onUp()
                return .handled
            }
            .onKeyPress(.downArrow) {
                onDown()
                return .handled
            }
            .onKeyPress(.escape) {
                onEscape()
                return .handled
            }
            .onKeyPress(.return) {
                onReturn()
                return .handled
            }
    }
}
