import Foundation
import Combine

/// Popover 的临时 UI 状态（需要跨「关闭 → 重开」保留）。
///
/// 为什么不能放 `@State`：`AppDelegate.popoverDidClose` 为了压空闲 CPU，会把
/// rootView 换成同尺寸空白 `AnyView`（2529c69）。`AnyView` 会擦除视图身份，
/// 于是关闭后再打开时整棵 `MenuBarView` 被重建，`@State` 全部回到初始值 ——
/// 用户点开的「展开各核心温度」一关一开就丢了。
///
/// 把这类需要跨重开保留的状态放到这个对象里，视图只做读写；视图被重建也不丢，
/// 且完全不影响空白占位那套 CPU 修复（它是换视图，不是清状态）。
final class PopoverUIState: ObservableObject {
    /// 「展开各核心温度」是否展开。
    @Published var showCores: Bool = false

    init(showCores: Bool = false) {
        self.showCores = showCores
    }
}
