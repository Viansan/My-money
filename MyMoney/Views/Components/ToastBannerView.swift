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

/// 浮层 Toast 视图（位于 TabBar 上方，绝不打断用户当前操作）
struct ToastBannerView: View {
    let toast: AppToast
    let onAction: (() -> Void)?
    let onDismiss: () -> Void

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
                    .buttonStyle(.plain)
                }

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 4)
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
