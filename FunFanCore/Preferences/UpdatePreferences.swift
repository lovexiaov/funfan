import Foundation

/// 检查更新的偏好：自动检查开关、上次检查时间、被忽略的版本。
///
/// **默认关闭自动检查**，这是产品决策而不是偷懒：
/// App 的免责声明写着「FunFan 不收集任何数据」，而自动检查会向 api.github.com
/// 发请求（带 IP、本机版本号、UA）。默认替用户联网与那句话是冲突的，
/// 所以做成「默认手动点，想自动就自己打开」，并在开关说明里写明它会联网。
public struct UpdatePreferences {

    public static let autoCheckKey = "FunFan.updateAutoCheck"
    public static let lastCheckedAtKey = "FunFan.updateLastCheckedAt"
    public static let skippedVersionKey = "FunFan.updateSkippedVersion"

    public static let defaultAutoCheck = false

    /// 自动检查的最小间隔。没做「每天几点」的定时——那不是用户关心的粒度，
    /// 而且会引入一个常驻计时器；用「距上次检查超过 24h 就顺手查一次」即可。
    public static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var autoCheckEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.autoCheckKey) != nil else {
                return Self.defaultAutoCheck
            }
            return defaults.bool(forKey: Self.autoCheckKey)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.autoCheckKey)
        }
    }

    public var lastCheckedAt: Date? {
        get { defaults.object(forKey: Self.lastCheckedAtKey) as? Date }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: Self.lastCheckedAtKey)
            } else {
                defaults.removeObject(forKey: Self.lastCheckedAtKey)
            }
        }
    }

    /// 用户点了「忽略此版本」的那个版本号（`1.0.0-alpha.8`）。
    public var skippedVersion: String? {
        get { defaults.string(forKey: Self.skippedVersionKey) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: Self.skippedVersionKey)
            } else {
                defaults.removeObject(forKey: Self.skippedVersionKey)
            }
        }
    }

    /// 这次启动该不该自动查一次。
    ///
    /// 时间戳落在「未来」（用户改过系统时间、时区跳变）时不查：
    /// 否则每次启动都联网，节流等于没有。
    public func shouldAutoCheck(now: Date) -> Bool {
        guard autoCheckEnabled else { return false }
        guard let lastCheckedAt else { return true }
        let elapsed = now.timeIntervalSince(lastCheckedAt)
        guard elapsed >= 0 else { return false }
        return elapsed >= Self.autoCheckInterval
    }
}
