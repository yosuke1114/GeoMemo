import WidgetKit
import SwiftUI
import ActivityKit

struct GeoMemoLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GeoMemoActivityAttributes.self) { context in
            // ロック画面・バナー（.medium）と、Apple Watch の Smart Stack・CarPlay（.small）
            ActivityContentView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded presentation
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        if context.state.isTriggered {
                            Circle()
                                .fill(memoColor(for: context.state.memoColorIndex))
                                .frame(width: 10, height: 10)
                        }
                        Image("ph-map-pin-fill")
                            .resizable()
                            .frame(width: 20, height: 20)
                            .foregroundStyle(Color(hex: "3D3BF3"))
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isTriggered, let time = context.state.triggeredAt {
                        Text(time, style: .time)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    if context.state.isTriggered {
                        VStack(spacing: 2) {
                            Text(context.state.memoTitle)
                                .font(.system(size: 15, weight: .bold))
                                .lineLimit(1)
                            Text(context.state.memoLocation.uppercased())
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else if let title = context.state.approachingTitle,
                              let dist = context.state.approachingDistance {
                        // 接近中
                        VStack(spacing: 2) {
                            Text(title)
                                .font(.system(size: 14, weight: .bold))
                                .lineLimit(1)
                            Text(activityDistanceText(dist, withPrefix: true))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(memoColor(for: context.state.approachingColorIndex))
                        }
                    } else if let cur = context.state.routeCurrentWaypoint,
                              let tot = context.state.routeTotalWaypoints {
                        VStack(spacing: 2) {
                            Text(context.state.memoTitle)
                                .font(.system(size: 14, weight: .bold))
                                .lineLimit(1)
                            Text("WP \(cur)/\(tot)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color(hex: "3D3BF3"))
                        }
                    } else {
                        Text(verbatim: "GEOMEMO")
                            .font(.system(size: 14, weight: .heavy))
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.isTriggered {
                        HStack {
                            Text("TAP TO OPEN", comment: "Dynamic Island prompt")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color(hex: "3D3BF3"))
                        }
                        .padding(.top, 4)
                    } else if let cur = context.state.routeCurrentWaypoint,
                              let tot = context.state.routeTotalWaypoints {
                        Text("Waiting for waypoint \(cur) of \(tot)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    } else {
                        Text("\(context.state.monitoredCount) memos active")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image("ph-map-pin-fill")
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(
                        context.state.approachingTitle != nil
                            ? memoColor(for: context.state.approachingColorIndex)
                            : Color(hex: "3D3BF3")
                    )
            } compactTrailing: {
                if context.state.isTriggered {
                    Text(context.state.memoTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                } else if let dist = context.state.approachingDistance {
                    // 接近中: 距離を表示
                    Text(activityDistanceText(dist, withPrefix: false))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(memoColor(for: context.state.approachingColorIndex))
                } else if let cur = context.state.routeCurrentWaypoint,
                          let tot = context.state.routeTotalWaypoints {
                    Text("WP\(cur)/\(tot)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(hex: "3D3BF3"))
                } else {
                    Text("\(context.state.monitoredCount)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } minimal: {
                if context.state.isTriggered {
                    Circle()
                        .fill(memoColor(for: context.state.memoColorIndex))
                        .frame(width: 10, height: 10)
                } else if context.state.approachingTitle != nil {
                    Circle()
                        .fill(memoColor(for: context.state.approachingColorIndex))
                        .frame(width: 10, height: 10)
                } else {
                    Image("ph-map-pin-fill")
                        .resizable()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(Color(hex: "3D3BF3"))
                }
            }
        }
        // iPhone のロック画面・Dynamic Island に加えて、Apple Watch の Smart Stack と CarPlay のダッシュボードにも出す。
        // .small を指定しないと、Watch では Dynamic Island のコンパクト表示が流用される。
        .supplementalActivityFamilies([.small])
    }

    private func memoColor(for index: Int) -> Color {
        activityMemoColor(index)
    }
}

// MARK: - Colors

/// メモの色（`MemoColor` の rawValue）。ロック画面・Dynamic Island・小さい表示で共通。
private func activityMemoColor(_ index: Int) -> Color {
    switch index {
    case 1: return Color(hex: "E5484D")  // red
    case 2: return Color(hex: "E5A000")  // amber
    case 3: return Color(hex: "30A46C")  // green
    case 4: return Color(hex: "8E4EC6")  // purple
    case 5: return Color(red: 0x8B/255.0, green: 0x8D/255.0, blue: 0x98/255.0) // gray
    default: return Color(hex: "3D3BF3") // blue
    }
}

/// 残りの距離。Dynamic Island（展開・コンパクト）と小さい表示で同じ書式にする（1km 未満は m、以上は小数 1 桁の km）。
/// `withPrefix` は「あと」を付ける（展開・小さい表示）。String(localized: "あと \(dist)m") は補間値がそのまま
/// キーに入ってしまい翻訳が引けないため format ベースにする。
private func activityDistanceText(_ dist: Int, withPrefix: Bool) -> String {
    if dist >= 1000 {
        let km = Double(dist) / 1000
        return withPrefix ? String(format: String(localized: "あと %.1fkm"), km) : String(format: "%.1fkm", km)
    }
    return withPrefix ? String(format: String(localized: "あと %dm"), dist) : "\(dist)m"
}

// MARK: - Family switch

/// 表示先（`activityFamily`）で出し分ける。.small は Apple Watch の Smart Stack と CarPlay。
private struct ActivityContentView: View {
    let context: ActivityViewContext<GeoMemoActivityAttributes>
    @Environment(\.activityFamily) private var activityFamily

    var body: some View {
        switch activityFamily {
        case .small:
            SmallActivityView(context: context)
        case .medium:
            LockScreenView(context: context)
        @unknown default:
            LockScreenView(context: context)
        }
    }
}

// MARK: - Small Presentation (Apple Watch Smart Stack / CarPlay)

/// 小さい表示。見るのは歩行中・運転中の一瞬なので、題（または次の経由地・距離）を大きく 1 つだけ出す。
/// 小さい Watch では縦が足りないので、2 行目があるときは題を 1 行にし、上下の余白は付けない（枠はシステムが付ける）。
/// 背景は暗いので、ブランドの青は明るい青に置き換え、題は `.primary` にする。文字は Dynamic Type に従う。
private struct SmallActivityView: View {
    let context: ActivityViewContext<GeoMemoActivityAttributes>
    /// Apple Watch の常時表示（手首を下ろした暗い状態）。色を落として白黒寄りにする。
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @ScaledMetric(relativeTo: .headline) private var iconSize: CGFloat = 18

    /// 暗い背景で読めるブランドの青（Dynamic Island の濃い青 3D3BF3 の明るい版）。
    private static let lightBrandBlue = Color(hex: "8B8AFF")

    var body: some View {
        let secondary = secondaryText
        HStack(alignment: .center, spacing: 8) {
            Image("ph-map-pin-fill")
                .resizable()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(isLuminanceReduced ? Color.secondary : accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(primaryText)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(secondary == nil ? 2 : 1)
                    .minimumScaleFactor(0.8)
                if let secondary {
                    secondary
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isLuminanceReduced ? Color.secondary : accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }

    private var state: GeoMemoActivityAttributes.ContentState { context.state }

    private var accent: Color {
        let index: Int
        if state.isTriggered { index = state.memoColorIndex }
        else if state.approachingTitle != nil { index = state.approachingColorIndex }
        else { return Self.lightBrandBlue }
        // 青（既定）は暗い背景で沈むので明るい青に。ほかの色はそのまま
        return index == 0 ? Self.lightBrandBlue : activityMemoColor(index)
    }

    /// 1 行目：着いたメモ → 近づいているメモ → ルートのメモ → アプリ名。
    private var primaryText: String {
        if state.isTriggered { return state.memoTitle }
        if let title = state.approachingTitle { return title }
        if state.routeCurrentWaypoint != nil, state.routeTotalWaypoints != nil { return state.memoTitle }
        return "GEOMEMO"
    }

    /// 2 行目：着いた時刻・残りの距離・経由地の進み具合・監視中の件数。
    private var secondaryText: Text? {
        if state.isTriggered {
            if let time = state.triggeredAt { return Text(time, style: .time) }
            return state.memoLocation.isEmpty ? nil : Text(verbatim: state.memoLocation)
        }
        if state.approachingTitle != nil, let dist = state.approachingDistance {
            return Text(activityDistanceText(dist, withPrefix: true))
        }
        if let cur = state.routeCurrentWaypoint, let tot = state.routeTotalWaypoints {
            return Text(verbatim: "WP \(cur)/\(tot)")
        }
        return Text("\(state.monitoredCount) memos active")
    }
}

// MARK: - Lock Screen Presentation

private struct LockScreenView: View {
    let context: ActivityViewContext<GeoMemoActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            // Left: Icon
            ZStack {
                Circle()
                    .fill(memoColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image("ph-map-pin-fill")
                    .resizable()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(memoColor)
            }

            // Center: Content
            VStack(alignment: .leading, spacing: 2) {
                if context.state.isTriggered {
                    HStack(spacing: 6) {
                        if context.state.memoColorIndex != 0 {
                            Circle()
                                .fill(memoColor)
                                .frame(width: 8, height: 8)
                        }
                        Text(context.state.memoTitle)
                            .font(.system(size: 15, weight: .bold))
                            .lineLimit(1)
                    }
                    Text(context.state.memoLocation.uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let cur = context.state.routeCurrentWaypoint,
                          let tot = context.state.routeTotalWaypoints {
                    Text(context.state.memoTitle)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                    Text("Waiting for waypoint \(cur) of \(tot)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "GEOMEMO")
                        .font(.system(size: 15, weight: .heavy))
                    Text("Monitoring \(context.state.monitoredCount) memos")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Right: Time, route progress badge, or memo count
            if context.state.isTriggered, let time = context.state.triggeredAt {
                Text(time, style: .time)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else if let cur = context.state.routeCurrentWaypoint,
                      let tot = context.state.routeTotalWaypoints {
                VStack(spacing: 1) {
                    Text("WP")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("\(cur)/\(tot)")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hex: "3D3BF3"))
                }
            } else {
                Text(String(format: "%02d", context.state.monitoredCount))
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(hex: "3D3BF3"))
            }
        }
        .padding(16)
    }

    private var memoColor: Color {
        activityMemoColor(context.state.memoColorIndex)
    }
}
