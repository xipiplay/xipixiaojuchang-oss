import SwiftUI
import AppKit

/// 应用内浮层弹窗 —— **替代 `.sheet`**。
///
/// **为什么要替代 sheet（有实测数据，不是审美偏好）**：
/// macOS 的 sheet 是独立 `NSWindow` + 模态会话。打开时主线程会被
/// `_beginWindowBlockingModalSessionForSheet` → `NSSheetMoveHelper openSheet`
/// → `NSMoveHelper _doAnimation` 的**滑入动画嵌套 run loop** 堵住
/// （`sample` 实测：单次打开约 0.9s 主线程完全不可用），
/// 表现为**鼠标转圈 + 按钮失效**——而且只在打开弹窗那一刻，所以看着像"偶发"。
///
/// 浮层没有模态会话、没有窗口动画，**不阻塞主线程**；并且天然支持「点外边关闭」
/// （sheet 在系统层面做不到这件事）。
///
/// **底 = `glassPanel`（液态玻璃；玻璃关闭时纯色）**，和下拉面板 / 预览窗 / 抽屉同一套（2026-10-08 由
/// `SolidTheme.overlay` + `.regularMaterial` 换过来）。不是 `SheetGlass`：
/// - `SheetGlass` 是 `.behindWindow`，采样的是**窗口后面**的桌面 —— 那是给独立窗口用的；
///   浮层坐在应用自己的内容之上，要糊的是**应用内容**。
/// - 液态玻璃也在 SwiftUI 自己的合成层里，**不会踩"AppKit 视图不跟着几何变换走"那个坑**
///   （任务抽屉就因为 `.offset` + `NSVisualEffectView` 出过残影）。
// MARK: - 真 AppKit 遮罩层
// 组件本体在 `Components.swift` 的 `OverlayEventShield`（浮层 / 两个抽屉 / 三个预览浮层共用）。
// 这里只留调用点 —— 位置在 `Color` 遮罩之后、面板之前，见下面 `body` 里的说明。

struct AppModal<Content: View>: View {
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    /// 是否由本层安装并处理 Esc（默认 true）。
    ///
    /// **叠层时必须关掉，改由外层装一个统一的路由**（见 `RootView` 的 `escRouter`）。
    /// 原因是 NSEvent 本地监听**不是互斥的**：每层各装一个的话，一次 Esc 会派发到所有监听，
    /// 而"该关哪一层"的判断会在两次回调**之间**因为状态已被上一层改写而失真 ——
    /// 结果是**一次 Esc 把两层一起关掉**。
    var handlesEsc: Bool = true
    var onClose: () -> Void
    /// Esc 的本地事件监听（见下面 `onAppear`；`.onExitCommand` 在浮层里拿不到焦点）
    @State private var escMonitor: Any?
    /// 遮罩淡入进度（**面板不能淡**，理由见 `content` 上的注释）。
    /// 弹窗插入本身是瞬时的（见 `appModal` 扩展里的 `.transition(.identity)`），
    /// 遮罩靠自己这一下淡入 —— 普通色块走 `.opacity` 是安全的。
    @State private var backdropOpacity: Double = 0
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            // 遮罩：压暗 + 接住"点外面"。与下拉面板/抽屉同一条规则——
            // 「弹层开着时，点外面只是关掉它，不再同时触发别的」，所以它会**消费掉**这一下点击。
            // 全窗压暗：这是"弹窗浮起来、界面退成背景"的主要手段（用户明确要求过）。
            // 已实测：把它换成透明**不影响卡顿**（154ms ↔ 150ms），所以保留它。
            Color.black.opacity(0.40)
                .opacity(backdropOpacity)
                // ⚠️ **必须显式铺满**。ZStack 的尺寸取子视图里的**最大**值，而面板是固定
                // 560×560 —— 不写这行，遮罩可能只有面板那么大，「点外面」的点击就会
                // **穿过去打到背后的按钮**；顶栏那个齿轮正好会把弹窗**重新打开**，
                // 表现为「怎么点都关不掉」（用户实测）。
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    AppLog.write("modal", "点遮罩")
                    onClose()
                }
                .ignoresSafeArea()

            // 真 AppKit 遮罩：让 hitTest 在 AppKit 层面成立 → 滚轮不再穿透。
            // 刻意**压在面板之下**（ZStack 里排在 `content` 之前）：面板在该层之上时
            // 仍然是 SwiftUI 自己的命中（点得动），遮罩区则落到这个 NSView 上。
            // 上面那层 `Color` 保留不动 —— 视觉（全窗压暗）与"点遮罩关闭"都有它兜底。
            OverlayEventShield { onClose() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            content
                .frame(width: width, height: height)
                // 面板空白处的点击在这里接住（2026-10-28 用户录屏：点生图弹窗的空白处，弹窗被关掉）——
                // 空白处没有东西接点击时，点击会往下落到上面那层 AppKit 遮罩上，被当成「点外面」
                .background(PanelEventSink())
                // 液态玻璃 + 圆角裁剪 + 浮层阴影（玻璃关闭时：纯色 + 描边，见 `GlassPanelModifier`）
                .glassPanel(cornerRadius: 18)
                // 面板原地出现，不再从下面 8pt 滑上来（2026-10-26 用户：弹出来再往上滑一下，要去掉）
                // ⚠️ 面板**绝不能做透明度过渡**（2026-09-19，用户实测"设置/提示弹窗的按钮还在闪"）：
                // 弹窗里的分段控件 / 有底色按钮的灰底是 **AppKit 材质**，透明度过渡时它**不跟着淡**
                // —— 淡入的中间帧里"面板半透明、控件灰底满不亮"就是那道闪。
                // 现在整个弹窗的插入/移除都是瞬时的（见 `appModal` 扩展的 `.transition(.identity)`），
                // 面板不需要也不能再挂过渡；遮罩的淡入由 `backdropOpacity` 单独负责。
        }
        // 整个 ZStack 也要铺满 overlay 给的空间（否则连"外面"都没有）
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Esc 关闭。
        // ⚠️ **不能用 `.onExitCommand`**：它靠**键盘焦点**分发，而浮层拿不到焦点 ——
        // 实测按 Esc 毫无反应（用户反馈）。改用本地事件监听，只在浮层存在期间挂着。
        .onAppear {
            // 遮罩淡入（面板本身瞬时出现，见 `backdropOpacity` / `content` 的注释）
            withAnimation(.easeOut(duration: 0.16)) { backdropOpacity = 1 }
            guard handlesEsc else { return }
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }   // 53 = Esc
                AppLog.write("modal", "Esc 关闭")
                onClose()
                return nil
            }
        }
        .onDisappear {
            if let escMonitor { NSEvent.removeMonitor(escMonitor) }
            escMonitor = nil
        }
    }
}

extension View {
    /// 挂载一个应用内浮层弹窗。
    ///
    /// 收 `Binding` 而不是 `Bool`：**"点遮罩 / Esc 关闭"由浮层自己写回**，
    /// 调用处只需把 `onClose` 传给它自己的内容视图即可（尾随闭包就干净地是内容）。
    ///
    /// 开 / 关本身不带动画（玻璃态会借动画模糊成形，见下面 `.transaction` 的注释）。
    func appModal<C: View>(
        isPresented: Binding<Bool>,
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        handlesEsc: Bool = true,
        @ViewBuilder content: () -> C
    ) -> some View {
        overlay {
            ZStack {
                if isPresented.wrappedValue {
                    AppModal(
                        width: width,
                        height: height,
                        handlesEsc: handlesEsc,
                        onClose: {
                            // 归因日志：区分"点击没到"和"到了但没生效"（排查浮层关不掉时靠它定位）
                            AppLog.write("modal", "onClose 执行 → 置 false")
                            isPresented.wrappedValue = false
                        },
                        content: content
                    )
                    // ⚠️ **必须瞬时插入/移除**（2026-09-19，用户实测"设置/提示弹窗的按钮还在闪"）：
                    // 默认过渡是 `.opacity`，而弹窗里的分段控件 / 有底色按钮的灰底是 **AppKit 材质**，
                    // 不跟随透明度过渡 → 打开/关闭时"面板半透明、控件灰底全亮"看着就是闪。
                    // ⚠️ 过渡要加在**插入点**（这里）—— 加在 `AppModal` 内部的面板上是无效的：
                    // 被插入的是整个 `AppModal`，内部视图的 transition 不参与。
                    // 遮罩的淡入改由 `AppModal` 内部的 `backdropOpacity` 自己播（色块淡入安全）。
                    .transition(.identity)
                }
            }
            // ⚠️ **没有弹窗时必须显式放行命中**（2026-09-12 补）。
            //
            // 症状：关掉弹窗后**整个窗口**的悬停高亮和按钮全部失效 —— 而事件确实到达了窗口
            // （诊断日志：clickProbe 有记录、isActive=true、key=主窗口、视图树里没有任何多余视图），
            // 滚一下、或切到别的 App 就恢复。**典型的"SwiftUI 内部留了一层看不见但可命中的残影"。**
            //
            // 弹窗现在是**瞬时插入/移除**（上面 `.transition(.identity)`，理由见那段注释）；
            // 这句兜底仍然保留：只要这一层没能正常收尾，整窗就全被它吃掉。
            // **`isPresented == false` 时这一层绝不参与命中** —— 残影在不在都不影响。
            .allowsHitTesting(isPresented.wrappedValue)
            // ⚠️ **开 / 关这一下不能带动画**（2026-10-26，用户录屏：玻璃态弹窗里的输入框闪黑）。
            // 原来这里挂着 `.animation(value: isPresented)`：`.identity` 管住了 SwiftUI 的过渡，
            // 但液态玻璃会借这次动画自己「模糊着成形」（约 5 帧），里面的 AppKit 文本框跟不上，
            // 深色底先露出来 —— 纯色模式没有这一下，所以两种模式的入场还不一样。
            // 这里把开 / 关的事务动画清掉（调用处包了 `withAnimation` 也一样），
            // 两种模式都是面板直接出现；遮罩淡入由 `AppModal` 在 onAppear 里另起一次动画，不受影响。
            .transaction(value: isPresented.wrappedValue) { $0.animation = nil }
        }
    }
}

// MARK: - 页面里的弹窗挂到整个窗口上

/// 页面里点开、但要盖住整个窗口的弹窗（2026-10-26 用户：工作台点开的段落详情和生视频页点开的不一样大——
/// 一个挂在页面里、按页面算大小、不盖左边图标栏，一个挂在整个窗口上）。
///
/// 页面照旧管开关和内容（状态、翻段、关了停在哪都在页面里），只把内容通过偏好值交给窗口那一层（`RootModals`）去弹；
/// 窗口那一层按窗口大小算尺寸、和其他浮层同一个遮罩、同一套层次（生图弹窗等照旧叠在它上面）。
struct WindowModalPortal {
    /// 拿窗口内容区大小算弹窗大小
    let size: (CGSize) -> CGSize
    let content: AnyView
    let close: () -> Void
}

struct WindowModalPortalKey: PreferenceKey {
    static var defaultValue: WindowModalPortal? { nil }
    static func reduce(value: inout WindowModalPortal?, nextValue: () -> WindowModalPortal?) {
        value = value ?? nextValue()
    }
}

extension EnvironmentValues {
    /// 外面有没有窗口那一层接着（`RootModals` 设）。单独测某一页时没有，就照旧弹在页面里
    @Entry var windowModalPortalAvailable = false
}

extension View {
    /// 像 `appModal` 一样挂一个弹窗，但外面有窗口那一层时交给它弹（盖住整个窗口）。
    /// `size` 拿可用的大小算弹窗大小：交给窗口那一层时是窗口内容区，页面里弹时是 `pageSize`。
    /// `pageVisible`：页面藏着（切到别的页但没拆掉）时不交过去——原来弹在页面里，跟着页面一起藏
    func windowModal<C: View>(
        isPresented: Binding<Bool>,
        pageVisible: Bool = true,
        pageSize: CGSize,
        size: @escaping (CGSize) -> CGSize,
        @ViewBuilder content: () -> C
    ) -> some View {
        modifier(WindowModalModifier(isPresented: isPresented, pageVisible: pageVisible, pageSize: pageSize, size: size, content: content()))
    }
}

private struct WindowModalModifier<C: View>: ViewModifier {
    @Environment(\.windowModalPortalAvailable) private var portalAvailable
    let isPresented: Binding<Bool>
    let pageVisible: Bool
    let pageSize: CGSize
    let size: (CGSize) -> CGSize
    let content: C

    func body(content page: Content) -> some View {
        if portalAvailable {
            page.background {
                WindowModalPortalEmitter(isPresented: isPresented, pageVisible: pageVisible, size: size, content: content)
            }
        } else {
            let local = size(pageSize)
            page.appModal(isPresented: isPresented, width: local.width, height: local.height, handlesEsc: false) { content }
        }
    }
}

/// 只挂偏好值的空视图。工作台状态在这里读：状态变了只有它跟着重算，页面本身不会因此重画
private struct WindowModalPortalEmitter<C: View>: View {
    @Environment(\.workbenchBoard) private var board
    let isPresented: Binding<Bool>
    let pageVisible: Bool
    let size: (CGSize) -> CGSize
    let content: C

    var body: some View {
        Color.clear.preference(key: WindowModalPortalKey.self, value: portal)
    }

    private var portal: WindowModalPortal? {
        guard pageVisible, isPresented.wrappedValue else { return nil }
        let binding = isPresented
        // 工作台状态从页面这里带过去：窗口那一层不在 `WorkbenchBoardProvider` 里面，不带的话弹窗里每块各算一遍
        return WindowModalPortal(size: size,
                                 content: AnyView(content.environment(\.workbenchBoard, board)),
                                 close: { binding.wrappedValue = false })
    }
}
