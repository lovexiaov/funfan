import Foundation

/// 采样新鲜度：面板头部那个「x 秒」到底是「正常在跳」还是「卡住了」。
///
/// 那个数字本身没有对错（它只是「上次采样距今多久」），有对错的是它涨到多大。
/// 采样周期由 `SamplingPolicy` 给（面板打开 2 s / 自动化接管 1 s），
/// 因此「超过一个周期再多几秒」就不再是「恰好卡在两次采样之间」，
/// 而是采样真的没在发生——SMC 读失败、helper 断开、进程被挂起都会这样。
///
/// 抽在 Core 而不是留在视图里，是因为阈值和「秒/分钟」换算都是会被写错的地方：
/// 四舍五入到 60 却还显示「60 秒」、睡眠唤醒后 `age` 为负被判成停住，都属于
/// 只在特定时刻出现、肉眼验收看不出来的错。
public enum SampleFreshness {

    /// 超出采样周期后的宽限。
    ///
    /// 不能取 0：一次采样本身要 4~26 ms，定时器还有 200 ms leeway，加上主线程
    /// 偶尔被 UI 排到后面，刚过周期就报警会闪出「采样已停止」，比不提示更糟。
    public static let staleGrace: TimeInterval = 3

    /// 是否已明显超出采样周期（判为「可能已停止」）。
    ///
    /// `age` 为负（睡眠唤醒后时钟回拨）不算停住——那只是时钟的事，不是采样的事。
    public static func isStale(age: TimeInterval, interval: TimeInterval) -> Bool {
        guard age > 0 else { return false }
        return age > interval + staleGrace
    }

    /// 时长文案：60 秒以下给秒（四舍五入），以上给分钟。
    ///
    /// 先四舍五入再决定单位，否则 59.6 s 会显示成「60 秒」——采样停住后这个数字
    /// 一直在涨，正好是最容易被盯着看的时候，单位不切换等于把换算丢给用户。
    public static func durationText(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let rounded = Int(clamped.rounded())
        if rounded < 60 { return "\(rounded) 秒" }
        return "\(Int((clamped / 60).rounded())) 分钟"
    }
}
