import SwiftUI

struct AuthPresenterModifier: ViewModifier {
    @State private var coordinator = AuthCoordinator.shared
    @State private var router = AppRouter.shared
    let suppressWhenPlayerPresented: Bool

    init(suppressWhenPlayerPresented: Bool = false) {
        self.suppressWhenPlayerPresented = suppressWhenPlayerPresented
    }

    private var isSuppressed: Bool {
        suppressWhenPlayerPresented && router.isPlayerPresented
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { isSuppressed ? nil : coordinator.activeAuthRequest },
                set: { newValue in
                    guard !isSuppressed else { return }
                    let previous = coordinator.activeAuthRequest
                    coordinator.activeAuthRequest = newValue
                    // 9-5：用户通过下拉手势关闭登录页时补发 onCancelled（已完成/按钮关闭的请求由单次终态守护自动去重）
                    if newValue == nil, let dismissed = previous {
                        dismissed.onCancelled?()
                    }
                }
            )) { req in
                WebAuthScreen(request: req)
            }
    }
}

extension View {
    func dsAuthPresenter(suppressWhenPlayerPresented: Bool = false) -> some View {
        modifier(AuthPresenterModifier(suppressWhenPlayerPresented: suppressWhenPlayerPresented))
    }
}
