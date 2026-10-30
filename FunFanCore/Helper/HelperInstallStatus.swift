import Foundation

/// 特权组件（root LaunchDaemon）在系统里的注册状态。
///
/// 这里是 `SMAppService.Status` 的纯数据投影：放在 Core 里是为了能在没有
/// ServiceManagement 上下文（单测、CLI）时也表达状态、跑断言。
/// 映射关系取自 `SMAppService.Status` 的原始值，写死成数字是因为
/// Core 不想 import ServiceManagement（它需要 App 包上下文才有意义）。
public enum HelperInstallStatus: Equatable, Sendable {

    /// 还没注册过（或已卸载）。
    case notRegistered
    /// 已注册且系统已启用（daemon 应该正在跑）。
    case enabled
    /// 已注册，但等用户在「系统设置 → 通用 → 登录项与扩展」里批准。
    case requiresApproval
    /// 系统找不到这个 daemon（包内 plist 缺失、签名不被信任、App 被移动）。
    case notFound
    /// 系统给了个我们不认识的原始值（新系统新增状态时走这里）。
    case unknown(rawStatus: Int)

    /// `SMAppService.Status` 的原始值：0 notRegistered / 1 enabled / 2 requiresApproval / 3 notFound。
    public init(rawStatus: Int) {
        switch rawStatus {
        case 0: self = .notRegistered
        case 1: self = .enabled
        case 2: self = .requiresApproval
        case 3: self = .notFound
        default: self = .unknown(rawStatus: rawStatus)
        }
    }

    /// 系统层面已经就绪（daemon 可被启动）。
    public var isInstalled: Bool { self == .enabled }

    /// 需要用户去系统设置点一下批准。
    public var needsUserApproval: Bool { self == .requiresApproval }

    /// 界面上的短标题。
    public var title: String {
        switch self {
        case .notRegistered: return "未安装"
        case .enabled: return "已安装"
        case .requiresApproval: return "待批准"
        case .notFound: return "系统未找到"
        case .unknown: return "状态未知"
        }
    }

    /// 给用户的下一步动作；`nil` 表示不需要额外操作。
    public var guidance: String? {
        switch self {
        case .notRegistered:
            return "点「安装」后系统会弹一次授权，之后升级 App 不需要重新授权。"
        case .enabled:
            return nil
        case .requiresApproval:
            return "到「系统设置 → 通用 → 登录项与扩展」里批准 FunFan 的后台项，不批准则风扇无法接管。"
        case .notFound:
            return "系统找不到后台组件。确认是从 FunFan.app 里运行（而不是裸二进制），且 App 已正确签名。"
        case .unknown(let raw):
            return "系统返回了未知状态（\(raw)）。可在「登录项与扩展」里检查后台项。"
        }
    }
}
