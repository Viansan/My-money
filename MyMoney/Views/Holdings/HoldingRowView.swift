import SwiftUI

/// 持仓页分组维度
enum HoldingsGroupMode: String, CaseIterable, Identifiable {
    case byCategory = "按类别"
    case byAccount = "按账户对账"

    var id: String { rawValue }
}

/// 单条资产列表行视图
struct HoldingRowView: View {
    let holding: AssetHolding
    let groupMode: HoldingsGroupMode
    let hideAmounts: Bool
    let pnlColorScheme: PnLColorScheme

    private var accentTint: Color {
        switch groupMode {
        case .byCategory:
            return holding.category?.tintColor ?? CategoryColorToken.slate.color
        case .byAccount:
            return holding.account?.tintColor ?? CategoryColorToken.slate.color
        }
    }

    private var crossDimensionTag: String? {
        switch groupMode {
        case .byCategory:
            return holding.account?.name
        case .byAccount:
            return holding.category?.name
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(holding.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if holding.effectivePool == .fixed {
                        Text("固定")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CategoryColorToken.amber.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(CategoryColorToken.amber.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    }
                }

                HStack(spacing: 6) {
                    if holding.valuationMode.usesSharesAndPrice && !holding.code.isEmpty {
                        Text(holding.code)
                            .font(.caption2.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(accentTint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(accentTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    } else {
                        Text(holding.valuationMode.shortBadge)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
                    }

                    if let tag = crossDimensionTag, !tag.isEmpty {
                        Text(tag)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if !holding.priceDateText.isEmpty && holding.valuationMode.usesSharesAndPrice {
                        Text("· \(holding.priceDateText)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(Formatters.currency(holding.marketValue, hidden: hideAmounts))
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)

                if holding.valuationMode.usesSharesAndPrice {
                    Text("\(Formatters.shares(holding.shares, hidden: hideAmounts)) × \(Formatters.unitPrice(holding.latestPrice))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if let pnl = holding.profitLoss {
                    HStack(spacing: 4) {
                        Text(Formatters.signedCurrency(pnl, hidden: hideAmounts))
                        if let rate = holding.profitLossRate {
                            Text("(\(Formatters.signedRate(rate, hidden: hideAmounts)))")
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(pnlColorScheme.color(for: pnl))
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
