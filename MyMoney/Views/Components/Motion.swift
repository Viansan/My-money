import SwiftUI

/// 全 App 统一动效语言（克制、可打断、尊重「减少动态效果」）
/// 同一类状态变化严格复用同一条弹簧曲线，避免各页面各自发明节奏
enum Motion {
    /// 高频微交互：按压反馈、胶囊切换、勾选图标、眼睛显隐（最快，绝不拖泥带水）
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

/// 苹果原生风格轻按反馈（跟手、可打断、不抢占 ScrollView 手势、兼容「减少动态效果」）
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

/// 共享导航栏隐私显隐按钮（图标平滑替换，全 App 位置与节奏一致）
struct PrivacyToggleButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var hideAmounts: Bool

    var body: some View {
        Button {
            Haptics.selection()
            withAnimation(Motion.micro(reduceMotion: reduceMotion)) {
                hideAmounts.toggle()
            }
        } label: {
            Image(systemName: hideAmounts ? "eye.slash" : "eye")
                .font(.subheadline)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 24)
        }
        .accessibilityLabel(hideAmounts ? "显示金额" : "隐藏金额")
    }
}

/// 共享导航栏刷新按钮（固定 24×24 占位，加载态平滑过渡，彻底杜绝右侧「+」按钮左右抖动）
struct RefreshToolbarButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isRefreshing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.72).combined(with: .opacity))
                } else {
                    Image(systemName: "arrow.clockwise")
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.72).combined(with: .opacity))
                }
            }
            .frame(width: 24, height: 24)
            .animation(Motion.micro(reduceMotion: reduceMotion), value: isRefreshing)
        }
        .disabled(isRefreshing)
        .accessibilityLabel(isRefreshing ? "正在刷新行情" : "刷新行情")
    }
}
