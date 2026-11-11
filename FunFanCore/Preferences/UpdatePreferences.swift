import Foundation

/// 检查更新的偏好：自动检查开关、上次检查时间、被忽略的版本。
///
/// **默认关闭自动检查**，这是产品决策而不是偷懒：
/// App 的免责声明写着「FunFan 不收集任何数据」，而自动检查会向 GitHub
/// 发请求（带 IP、本机版本号、UA）。默认替用户联网与那句话是冲突的，
/// 所以做成「默认手动点，想自动就自己打开」，并在开关说明里写明它会联网。
public struct UpdatePreferences {

    public static let autoCheckKey = "FunFan.updateAutoCheck"
    public static let lastCheckedAtKey = "FunFan.updateLastCheckedAt"
    public static let autoCheckFailedAtKey = "FunFan.updateAutoCheckFailedAt"
    public static let skippedVersionKey = "FunFan.updateSkippedVersion"

    public static let defaultAutoCheck = false

    /// 自动检查的最小间隔。没做「每天几点」的定时——那不是用户关心的粒度，
    /// 而且会引入一个常驻计时器；用「距上次检查超过 24h 就顺手查一次」即可。
    public static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    /// 自动检查失败后的重试间隔。
    ///
    /// 失败不写 `lastCheckedAt`（一次断网不该吃掉当天的额度），但如果什么都不记，
    /// 开着自动检查的用户在故障窗口内**每次启动都会重试、每次都失败**。
    /// 单独记一个时间戳做短退避，成功时清掉，回到 24h 节流。
    /// 手动点「检查更新」不受它限制——用户主动重试不该被拦。
    public static let autoCheckRetryInterval: TimeInterval = 30 * 60

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

    /// 上一次**自动检查**失败的时间。成功时清空，手动检查不写也不读它。
    public var lastAutoCheckFailedAt: Date? {
        get { defaults.object(forKey: Self.autoCheckFailedAtKey) as? Date }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: Self.autoCheckFailedAtKey)
            } else {
                defaults.removeObject(forKey: Self.autoCheckFailedAtKey)
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
    /// 否则每次启动都联网，节流等于没有。失败后的短退避同理。
    public func shouldAutoCheck(now: Date) -> Bool {
        guard autoCheckEnabled else { return false }
        if let failedAt = lastAutoCheckFailedAt {
            guard now.timeIntervalSince(failedAt) >= Self.autoCheckRetryInterval else { return false }
        }
        guard let lastCheckedAt else { return true }
        let elapsed = now.timeIntervalSince(lastCheckedAt)
        guard elapsed >= 0 else { return false }
        return elapsed >= Self.autoCheckInterval
    }
}
