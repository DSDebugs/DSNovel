import SwiftUI

struct AuthPresenterModifier: ViewModifier {
    @State private var coordinator = AuthCoordinator.shared

    init() {}

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { coordinator.activeAuthRequest },
                set: { coordinator.activeAuthRequest = $0 }
            )) { req in
                WebAuthScreen(request: req)
            }
    }
}

extension View {
    func dsAuthPresenter() -> some View {
        modifier(AuthPresenterModifier())
    }
}
