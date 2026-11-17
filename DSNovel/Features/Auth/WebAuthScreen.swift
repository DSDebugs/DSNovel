import SwiftUI

struct WebAuthScreen: View {
    let request: WebAuthSessionRequest

    init(request: WebAuthSessionRequest) {
        self.request = request
    }

    var body: some View {
        WebAuthSheet(session: request)
    }
}
