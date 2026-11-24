import SwiftUI

/// 全 App 统一动效语言（克制、可打断、尊重「减少动态效果」）
/// 同一类状态变化严格复用同一条弹簧曲线，避免各页面各自发明节奏
enum Motion {
    /// 高频微交互：按压反馈、胶囊切换、勾选图标（最快，绝不拖泥带水）
    static func micro(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.14)
            : .spring(response: 0.20, dampingFraction: 0.90)
    }

    /// 标准状态转换：视图切换、表单展开收起、指示条滑动、进度条变化
    static func standard(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.28, dampingFraction: 0.88)
    }

    /// 浮层进出：Toast 弹出、撤销条出现与消失
    static func overlay(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.30, dampingFraction: 0.86)
    }

    /// 数值滚动：总资产、持仓市值、实时试算金额更新
    static func numeric(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.16)
            : .spring(response: 0.32, dampingFraction: 0.92)
    }
}

/// 苹果原生风格轻按反馈（用于 ScrollView 卡片、胶囊与网格选择器，兼容「减少动态效果」）
struct TactilePressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var pressedScale: CGFloat = 0.982
    var pressedOpacity: Double = 0.86

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1.0)
            .opacity(configuration.isPressed ? pressedOpacity : 1.0)
            .animation(Motion.micro(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// 共享导航栏隐私显隐按钮（适配 iOS 26 Liquid Glass 原生 UIBarButtonItem，不附加破坏性视图过渡）
struct PrivacyToggleButton: View {
    @Binding var hideAmounts: Bool

    var body: some View {
        Button {
            Haptics.selection()
            hideAmounts.toggle()
        } label: {
            Image(systemName: hideAmounts ? "eye.slash" : "eye")
                .font(.subheadline)
        }
        .accessibilityLabel(hideAmounts ? "显示金额" : "隐藏金额")
    }
}

/// 共享导航栏刷新按钮（适配 iOS 26 Liquid Glass 原生 UIBarButtonItem，避免过渡动画触发 UIKit 崩溃）
struct RefreshToolbarButton: View {
    let isRefreshing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(isRefreshing)
        .accessibilityLabel(isRefreshing ? "正在刷新行情" : "刷新行情")
    }
}

/// 表单键盘收起修饰器（仅使用原生交互式下拉收起，不在键盘动画期间向视图树动态增删浮层节点）
/// - 规避 iOS 26 下 `ToolbarItemGroup(placement: .keyboard)` 与聚焦瞬间动态插入 `.overlay` 触发 UIKit `inProcessAnimation` `NSArrayM nil` 崩溃
struct KeyboardDismissOverlayModifier: ViewModifier {
    let isVisible: Bool
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
    }
}

extension View {
    func keyboardDismissOverlay(isVisible: Bool = false, onDismiss: @escaping () -> Void = {}) -> some View {
        modifier(KeyboardDismissOverlayModifier(isVisible: isVisible, onDismiss: onDismiss))
    }
}

/// 金额输入框的大额读数辅助微标（如 1000000 显示「100万」胶囊，节点常驻不触发重排）
struct AmountUnitBadge: View {
    let text: String

    private var hint: String? {
        Formatters.amountReadingHint(text)
    }

    var body: some View {
        let label = hint ?? ""
        Text(label)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, hint == nil ? 0 : 6)
            .padding(.vertical, hint == nil ? 0 : 2)
            .background(
                Capsule()
                    .fill(Color.accentColor.opacity(hint == nil ? 0 : 0.12))
            )
            .fixedSize()
            .opacity(hint == nil ? 0 : 1)
            .accessibilityHidden(hint == nil)
    }
}


