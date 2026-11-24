import SwiftUI

/// 全局非阻塞提示条模型（支持自动消失、撤销操作与错误重试）
struct AppToast: Identifiable, Equatable {
    enum Style: Equatable {
        case success
        case info
        case warning
    }

    let id = UUID()
    let style: Style
    let message: String
    let details: [String]
    let actionTitle: String?
    let autoDismissSeconds: TimeInterval?

    static func == (lhs: AppToast, rhs: AppToast) -> Bool {
        lhs.id == rhs.id
    }
}

/// 浮层 Toast 视图（位于 TabBar 上方，支持跟手向下轻扫关闭，绝不打断用户当前操作）
struct ToastBannerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let toast: AppToast
    let onAction: (() -> Void)?
    let onDismiss: () -> Void

    @State private var dragOffsetY: CGFloat = 0

    private var iconName: String {
        switch toast.style {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch toast.style {
        case .success: return .green
        case .info: return .accentColor
        case .warning: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(iconColor)
                    .contentTransition(.symbolEffect(.replace))

                Text(toast.message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer(minLength: 4)

                if let actionTitle = toast.actionTitle, let onAction {
                    Button(actionTitle) {
                        Haptics.lightImpact()
                        onAction()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .buttonStyle(TactilePressButtonStyle(pressedScale: 0.94))
                }

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(TactilePressButtonStyle(pressedScale: 0.90))
            }

            if !toast.details.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(toast.details.prefix(3), id: \.self) { line in
                        Text("• \(line)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if toast.details.count > 3 {
                        Text("另有 \(toast.details.count - 3) 项未更新")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 540)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 4)
        .padding(.horizontal, 16)
        .offset(y: dragOffsetY)
        .opacity(dragOffsetY > 0 ? max(1.0 - Double(dragOffsetY / 90.0), 0.25) : 1.0)
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .local)
                .onChanged { value in
                    let dy = value.translation.height
                    // 向下跟手滑动，向上轻阻尼回弹
                    dragOffsetY = dy >= 0 ? dy : dy * 0.22
                }
                .onEnded { value in
                    if value.translation.height > 28 || value.predictedEndTranslation.height > 60 {
                        onDismiss()
                    } else {
                        withAnimation(Motion.overlay(reduceMotion: reduceMotion)) {
                            dragOffsetY = 0
                        }
                    }
                }
        )
        .transition(
            reduceMotion
                ? .opacity
                : .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96))
        )
    }
}
