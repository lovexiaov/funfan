import Foundation

/// 「风扇正被别的程序控制」的证据。
///
/// 判定原则：**只信硬件事实，不信进程名单**。
/// 手动模式（`F0Md=1`）在系统自己控制时不可能出现——只要出现，就一定有程序
/// 写了模式键。至于那个程序是谁，进程名单只能提供**解释**，不能提供判据：
/// 名字可以随便改，也可以根本不在我们认识的名单里。
public struct ForeignControlEvidence: Equatable, Sendable {

    public let fanIndex: Int
    public let mode: FanMode
    public let targetRpm: Double

    public init(fanIndex: Int, mode: FanMode, targetRpm: Double) {
        self.fanIndex = fanIndex
        self.mode = mode
        self.targetRpm = targetRpm
    }

    /// 给用户看的一句话。
    public var summary: String {
        String(format: "Fan %d 处于手动模式（目标 %.0f RPM）", fanIndex, targetRpm)
    }
}

public enum ConflictDetector {

    /// 我们没有持有控制权时，任何「手动模式」的风扇都意味着有第三方在写。
    ///
    /// - Parameters:
    ///   - states: `listFans()` 拿到的状态快照。
    ///   - holdingControl: 本进程是否持有有效租约。持有期间手动模式是我们自己造成的，
    ///     不算冲突——否则每次用户自己调速都会弹一次「有别的软件在控制」。
    public static func foreignEvidence(
        in states: [FanState],
        holdingControl: Bool
    ) -> [ForeignControlEvidence] {
        guard !holdingControl else { return [] }
        return states
            .filter { $0.isManual }
            .map {
                ForeignControlEvidence(
                    fanIndex: $0.index,
                    mode: $0.mode,
                    targetRpm: $0.targetRpm
                )
            }
    }
}

/// 已知的第三方风扇控制软件，用于把「有东西在控制」解释成「大概是 Macs Fan Control」。
///
/// 名字匹配优先于 bundle id：bundle id 记错一个字母就永远匹配不上，
/// 而进程名里带 "Macs Fan Control" 是用户看得见、我们也靠得住的信息。
public enum KnownFanControllers {

    public struct App: Equatable, Sendable {
        public let name: String
        public let bundleIdentifier: String
        public let matchKeywords: [String]

        public init(name: String, bundleIdentifier: String, matchKeywords: [String]) {
            self.name = name
            self.bundleIdentifier = bundleIdentifier
            self.matchKeywords = matchKeywords
        }
    }

    public static let known: [App] = [
        App(name: "Macs Fan Control",
            bundleIdentifier: "com.crystalidea.macsfancontrol",
            matchKeywords: ["macsfancontrol", "macs fan control"]),
        App(name: "TG Pro",
            bundleIdentifier: "com.tunabelly.TGPro",
            matchKeywords: ["tgpro", "tg pro"]),
        App(name: "iStat Menus",
            bundleIdentifier: "com.bjango.istatmenus",
            matchKeywords: ["istatmenus", "istat menus"]),
        App(name: "smcFanControl",
            bundleIdentifier: "com.eidac.smcFanControl2",
            matchKeywords: ["smcfancontrol"]),
    ]

    /// 按 bundle id 或进程名识别；都不是则返回 nil（那就是「未知控制者」，也照样要拦）。
    public static func name(bundleIdentifier: String?, processName: String?) -> String? {
        if let identifier = bundleIdentifier, !identifier.isEmpty {
            if let hit = known.first(where: { $0.bundleIdentifier.caseInsensitiveCompare(identifier) == .orderedSame }) {
                return hit.name
            }
        }
        guard let processName, !processName.isEmpty else { return nil }
        let lowered = processName.lowercased()
        return known.first { app in
            app.matchKeywords.contains { lowered.contains($0) }
        }?.name
    }
}
