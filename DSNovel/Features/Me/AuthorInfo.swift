import Foundation

/// 应用作者与动态版本信息（集中管理，后续增补主页/邮箱仅改此处）
enum AuthorInfo {
    static let name: String = "DS"
    static let initials: String = "DS"
    static let role: String = "设计与开发"
    static let homepageURL: URL? = nil
    static let email: String? = nil
    static let copyrightText: String = "© 2026 DS"

    static var shortVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
    }

    static var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }

    static var appVersionDisplay: String {
        "v\(shortVersion) (\(buildNumber))"
    }
}
