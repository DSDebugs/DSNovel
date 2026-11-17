import SwiftUI

struct AppearancePrefsView: View {
    @Bindable var settings: AppSettingsStore

    init(settings: AppSettingsStore = .shared) {
        self.settings = settings
    }

    var body: some View {
        Group {
            Picker("外观模式", selection: $settings.appearanceMode) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Toggle("夜间降亮（深色模式更柔和）", isOn: $settings.nightDimEnabled)

            Toggle("触感反馈", isOn: $settings.hapticsEnabled)

            Picker("减弱动画", selection: $settings.reduceMotionOverride) {
                Text("跟随系统").tag(false)
                Text("始终减弱").tag(true)
            }
        }
    }
}
