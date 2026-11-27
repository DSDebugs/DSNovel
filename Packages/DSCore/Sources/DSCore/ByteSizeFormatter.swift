import Foundation

public extension Int64 {
    /// 紧凑无空格字节格式化（如 840KB / 7.1MB / 1.20GB），避免副标题在数字与单位间折行
    var dsCompactByteSize: String {
        guard self > 0 else { return "" }
        let mb = Double(self) / 1_048_576.0
        if mb >= 1024 {
            return String(format: "%.2fGB", mb / 1024.0)
        }
        if mb >= 0.1 {
            return String(format: "%.1fMB", mb)
        }
        let kb = max(1, Int((Double(self) / 1024.0).rounded()))
        return "\(kb)KB"
    }
}
