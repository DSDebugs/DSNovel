import SwiftUI

struct AboutView: View {
    @State private var showResetConfirm = false
    private let onResetAll: () -> Void

    init(onResetAll: @escaping () -> Void) {
        self.onResetAll = onResetAll
    }

    var body: some View {
        Group {
            DSSettingsRow(
                icon: "info.circle",
                title: "版本",
                valueText: "2.0 (iOS 26)"
            )

            DSSettingsRow(
                icon: "doc.text",
                title: "书源免责声明",
                subtitle: "内容均由用户启用或导入的书源实时解析提供"
            )

            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Text("重置所有设置")
            }
            .confirmationDialog(
                "确认重置所有偏好设置？您的书架与书源数据将完整保留。",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("重置所有设置", role: .destructive, action: onResetAll)
                Button("取消", role: .cancel) {}
            }
        }
    }
}
