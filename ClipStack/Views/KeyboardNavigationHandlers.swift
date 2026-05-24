import SwiftUI

extension View {
    func keyboardNavigationHandlers(
        onUp: @escaping (EventModifiers) -> Void,
        onDown: @escaping (EventModifiers) -> Void,
        onEscape: @escaping () -> Void,
        onReturn: @escaping () -> Void
    ) -> some View {
        self.onKeyPress(phases: .down) { press in
            switch press.key {
            case .upArrow:
                onUp(press.modifiers)
                return .handled
            case .downArrow:
                onDown(press.modifiers)
                return .handled
            case .escape:
                onEscape()
                return .handled
            case .return:
                onReturn()
                return .handled
            default:
                return .ignored
            }
        }
    }
}
