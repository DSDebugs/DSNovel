import SwiftUI

struct WebAuthScreen: View {
    let request: WebAuthSessionRequest

    init(request: WebAuthSessionRequest) {
        self.request = request
    }

    var body: some View {
        WebAuthSheet(session: request)
            .overlay(alignment: .bottom) {
                Text("登录后会自动返回并继续")
                    .font(DSTypography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.s4)
                    .padding(.vertical, Spacing.s2)
                    .background(Capsule().fill(.regularMaterial))
                    .padding(.bottom, Spacing.s3)
                    .allowsHitTesting(false)
            }
    }
}
