import Foundation

/// 采样频率策略：按「用户是否在看」分档，避免常驻后台时白烧 CPU。
///
/// 实测依据（Mac mini M4，107 个采样键）：全量单帧 ≈ 21.5 ms / 107 次 IPC，
/// 平均每次 IPC ≈ 200 µs（AppleSMC 内核调用成本，App 侧无法优化掉）。
///
/// | 可见性 | 间隔 | 稳态占用 |
/// |---|---|---|
/// | Popover 打开 | 2.0 s | ≈ 1.1% 单核（两层采样后更低） |
/// | 仅菜单栏 | 2.0 s | ≈ 1.1% 单核 |
/// | 自动化接管（规则/曲线引擎） | 1.0 s | ≈ 2.2% 单核 |
/// | 空闲（面板关、无规则） | 5.0 s | ≈ 0.4% 单核 |
///
/// 面板打开的演进：0.5 s（「用户在看 = 最高频」的惯性）→ 1.0 s（M13，引擎档
/// 是频率上限）→ 2.0 s（M14，温度是慢变量、2 s 刷新肉眼无感，且两层采样让
/// 单帧成本本身也降下来了）。频率上真正没有商量余地的只剩引擎档：控制响应
/// 需要 1 Hz。
public enum SamplingPolicy {

    /// 当前 UI 可见性。
    public enum Visibility: Sendable {
        /// Popover 面板展开——用户在盯着看。
        case popoverOpen
        /// 仅菜单栏图标显示（需要刷新图标上的温度数字）。
        case menuBarOnly
        /// 规则/曲线自动化正在接管——控制响应需要 1 Hz，是全部档位里唯一的高频需求方。
        case automation
        /// 面板关闭且无规则在跑。
        case idle
    }

    /// 采样间隔（秒）。
    public static func interval(for visibility: Visibility) -> TimeInterval {
        switch visibility {
        case .popoverOpen: return 2.0
        case .menuBarOnly: return 2.0
        case .automation: return 1.0
        case .idle: return 5.0
        }
    }

    /// 是否到达下一次采样时刻。
    ///
    /// 时钟回拨（`now < last`，睡眠唤醒常见）或长时间挂起后应立即采样，
    /// 否则唤醒后界面会显示过期数据最长 5 秒。
    public static func shouldSample(last: Date, now: Date, visibility: Visibility) -> Bool {
        let elapsed = now.timeIntervalSince(last)
        guard elapsed >= 0 else { return true }
        return elapsed >= interval(for: visibility)
    }
}
