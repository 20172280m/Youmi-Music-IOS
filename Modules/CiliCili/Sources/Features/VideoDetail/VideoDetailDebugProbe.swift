import UIKit

/// 临时取证探针：把详情页控件/旋转状态写进隐藏无障碍元素，供 simulator describe-ui 读取。
/// 定位完成后删除，不进入最终提交。
@MainActor
enum VideoDetailDebugProbe {
    private static weak var label: UILabel?
    private static var lines: [String] = []

    static func install(_ label: UILabel) {
        self.label = label
        label.isAccessibilityElement = true
        label.accessibilityLabel = "详情页探针"
        label.accessibilityIdentifier = "ui.videoDetail.controlTrace"
        label.font = .systemFont(ofSize: 1)
        label.textColor = .clear
        label.backgroundColor = .clear
        label.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        label.isUserInteractionEnabled = false
        label.accessibilityValue = lines.suffix(16).joined(separator: " | ")
    }

    static func record(_ line: String) {
        let stamp = String(format: "%.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 10000))
        lines.append("\(stamp) \(line)")
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        label?.accessibilityValue = lines.suffix(16).joined(separator: " | ")
    }
}
