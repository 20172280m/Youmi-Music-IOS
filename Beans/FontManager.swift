import SwiftUI
import UIKit
import CoreText

/// 全局字体管理：把用户上传的 ttf/otf 复制到 Documents/Fonts 并动态注册，App 重启后自动重新注册
enum FontManager {
    static let storedFontNameKey = "beans.globalFont"
    static let storedGreetingFontNameKey = "beans.homeGreetingFont"

    private static var cachedInstalledFontName: String? = UserDefaults.standard.string(forKey: storedFontNameKey)

    static var installedFontName: String? {
        get { cachedInstalledFontName }
        set {
            cachedInstalledFontName = newValue
            UserDefaults.standard.set(newValue, forKey: storedFontNameKey)
        }
    }

    static var greetingFontName: String? {
        get { UserDefaults.standard.string(forKey: storedGreetingFontNameKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: storedGreetingFontNameKey)
            } else {
                UserDefaults.standard.removeObject(forKey: storedGreetingFontNameKey)
            }
        }
    }

    private static var fontsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var greetingFontsDirectory: URL {
        let dir = fontsDirectory.appendingPathComponent("Greeting", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 启动时重新注册已安装的字体（覆盖安装后 Documents 保留，字体继续生效）
    static func reinstallIfNeeded() {
        guard installedFontName != nil else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(at: fontsDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
            register(file)
        }
        if greetingFontName != nil,
           let files = try? FileManager.default.contentsOfDirectory(at: greetingFontsDirectory, includingPropertiesForKeys: nil) {
            for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
                register(file)
            }
        }
    }

    /// 安装用户选择的字体文件（先清空旧字体再复制注册），返回注册成功后的字体名
    @discardableResult
    static func install(from sourceURL: URL) -> String? {
        let file = fontsDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        if let files = try? FileManager.default.contentsOfDirectory(at: fontsDirectory, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        if FileManager.default.fileExists(atPath: file.path) { try? FileManager.default.removeItem(at: file) }
        guard (try? FileManager.default.copyItem(at: sourceURL, to: file)) != nil else { return nil }
        guard let name = register(file) else { return nil }
        installedFontName = name
        return name
    }

    /// 导出字体信息（字体名 + 字体文件数据），供配置备份使用
    static func exportFontData() -> (name: String, data: Data)? {
        guard installedFontName != nil else { return nil }
        guard let files = try? FileManager.default.contentsOfDirectory(at: fontsDirectory, includingPropertiesForKeys: nil) else { return nil }
        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
            if let data = try? Data(contentsOf: file) { return (installedFontName ?? "", data) }
        }
        return nil
    }

    /// 从备份恢复字体：清空旧字体 → 写回字体文件 → 重新注册
    @discardableResult
    static func restoreFont(name: String, data: Data) -> Bool {
        clear()
        let file = fontsDirectory.appendingPathComponent("beans-restored-font.ttf")
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            return false
        }
        if let registered = register(file) {
            installedFontName = registered
            return true
        }
        // 注册被拒（同一次运行里这份字体早就进过 CoreText）：只要这个名字现在真能解析出字形，
        // 界面就能用它，按成功处理。判「能不能解析」比逐条猜 CoreText 的错误码可靠。
        if !name.isEmpty, UIFont(name: name, size: 12) != nil {
            installedFontName = name
            lastRegisterError = nil
            return true
        }
        return false
    }

    static func clear() {
        installedFontName = nil
        if let files = try? FileManager.default.contentsOfDirectory(at: fontsDirectory, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// 安装仅用于主页问候语的字体，不影响全局字体。
    @discardableResult
    static func installGreeting(from sourceURL: URL) -> String? {
        let file = greetingFontsDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        if let files = try? FileManager.default.contentsOfDirectory(at: greetingFontsDirectory, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        guard (try? FileManager.default.copyItem(at: sourceURL, to: file)) != nil else { return nil }
        guard let name = register(file) else { return nil }
        greetingFontName = name
        return name
    }

    static func clearGreeting() {
        greetingFontName = nil
        if let files = try? FileManager.default.contentsOfDirectory(at: greetingFontsDirectory, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// 最近一次注册失败的原因，供恢复备份的提示与日志使用
    private(set) static var lastRegisterError: String?

    @discardableResult
    private static func register(_ url: URL) -> String? {
        // 用 Data 读取避免安全作用域/CGDataProvider(url:) 兼容问题，iOS 上更稳
        lastRegisterError = nil
        guard let data = try? Data(contentsOf: url) else {
            lastRegisterError = "读不到字体文件"
            return nil
        }
        guard let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider) else {
            lastRegisterError = "字体数据无法解析"
            return nil
        }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterGraphicsFont(font, &error) {
            return postScriptName(of: font)
        }
        // clear()/「恢复默认字体」只删文件、不向 CoreText 注销，所以同一次运行里再恢复同一份字体时，
        // 注册会回 alreadyRegistered。这里直接按「已安装」算：字体在本进程里本来就能用，
        // 文件也已写回 Documents/Fonts，下次启动会照常重新注册。
        //
        // 曾经试过「先 unregister 再注册」，在模拟器上卸不掉（重注册仍报 alreadyRegistered）；
        // 现在连 alreadyRegistered 也不认作成功了，所以把 CoreText 的原话留在 lastRegisterError 里。
        //
        // 所有权：注册失败时 error 是 +1 的，由 ctError 里的 takeRetainedValue 消费，这里不能再次 release。
        if let failure = ctError(error) {
            // 域在系统里写作 com.apple.CoreText.CTFontManagerErrorDomain，常量是 CTFontManagerErrorDomain，
            // 比较后缀更稳。105=已注册、304=PostScript 名重复，都等于「这份字体本进程已有」。
            if failure.domain.hasSuffix("CTFontManagerErrorDomain"),
               failure.code == CTFontManagerError.alreadyRegistered.rawValue || failure.code == 304 {
                return postScriptName(of: font)
            }
            lastRegisterError = "\(failure.domain) \(failure.code)"
        } else {
            lastRegisterError = "注册返回失败但没有错误对象"
        }
        return nil
    }

    private static func postScriptName(of font: CGFont) -> String? {
        guard let name = font.postScriptName as String?, !name.isEmpty else {
            lastRegisterError = "字体没有 PostScript 名称"
            return nil
        }
        return name
    }

    /// 取 CoreText 错误域与码；takeRetainedValue 会消费掉注册失败时 +1 的那份引用
    private static func ctError(_ error: Unmanaged<CFError>?) -> (domain: String, code: Int)? {
        guard let cfError = error?.takeRetainedValue() else { return nil }
        return (CFErrorGetDomain(cfError) as String, CFErrorGetCode(cfError))
    }

}

/// 全局字体快捷入口：已上传字体时全局使用自定义字体，否则回退系统字体（支持 design 回退）
enum BeansFont {
    static func appFont(_ size: CGFloat, _ weight: Font.Weight = .regular, _ design: Font.Design = .default) -> Font {
        if let name = FontManager.installedFontName {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight, design: design)
    }

    static func greetingFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let name = FontManager.greetingFontName {
            return .custom(name, size: size)
        }
        return appFont(size, weight)
    }

    /// UIKit 版字体（UITextField 等 SwiftUI 不覆盖的控件用）
    static func appUIFont(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        if let name = FontManager.installedFontName {
            return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
        }
        return .systemFont(ofSize: size, weight: weight)
    }
}
