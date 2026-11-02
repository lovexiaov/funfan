import Foundation

/// 采样频率策略：按「用户是否在看」分档，避免常驻后台时白烧 CPU。
///
/// 实测依据（M4 Pro，107 个已知传感器）：单帧 ≈ 19.5 ms / 107 次 IPC，
/// 平均每次 IPC ≈ 180 µs（AppleSMC 内核调用成本，App 侧无法优化掉）。
///
/// | 可见性 | 间隔 | 稳态占用 |
/// |---|---|---|
/// | Popover 打开 | 1.0 s | ≈ 2.0% 单核 |
/// | 仅菜单栏 | 2.0 s | ≈ 1.0% 单核 |
/// | 空闲（面板关、无规则） | 5.0 s | ≈ 0.4% 单核 |
///
/// 面板打开曾用 0.5 s，后降为 1.0 s：温度是慢变量，1 s 刷新肉眼无感；
/// 且规则/曲线引擎的档位本来就是 1 Hz——面板打开没有理由比引擎还快。
/// （issue #3 实测的另一面：面板打开期间的大头是 SwiftUI 渲染显示周期，
/// 采样只占零头，但这零头也该省。）
///
/// 规则引擎激活时由控制层单独持有 1 Hz 采样，不受此处影响。
public enum SamplingPolicy {

    /// 当前 UI 可见性。
    public enum Visibility: Sendable {
        /// Popover 面板展开——用户在盯着看。
        case popoverOpen
        /// 仅菜单栏图标显示（需要刷新图标上的温度数字）。
        case menuBarOnly
        /// 面板关闭，但规则自动化正在接管——需要足够快的响应，又不能像面板打开那样费电。
        case automation
        /// 面板关闭且无规则在跑。
        case idle
    }

    /// 采样间隔（秒）。
    public static func interval(for visibility: Visibility) -> TimeInterval {
        switch visibility {
        case .popoverOpen: return 1.0
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
