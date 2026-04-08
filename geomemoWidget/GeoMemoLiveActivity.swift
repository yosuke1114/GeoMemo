import WidgetKit
import SwiftUI
import ActivityKit

struct GeoMemoLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GeoMemoActivityAttributes.self) { context in
            // Lock Screen / Banner presentation
            LockScreenView(context: context)
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
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 20))
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
                    } else {
                        Text("Monitoring \(context.attributes.monitoredCount) memos")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                // Compact leading: map pin icon
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(hex: "3D3BF3"))
            } compactTrailing: {
                // Compact trailing: memo title or monitoring status
                if context.state.isTriggered {
                    Text(context.state.memoTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                } else {
                    Text("Monitoring")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } minimal: {
                // Minimal: colored circle or brand icon
                if context.state.isTriggered {
                    Circle()
                        .fill(memoColor(for: context.state.memoColorIndex))
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "3D3BF3"))
                }
            }
        }
    }

    private func memoColor(for index: Int) -> Color {
        switch index {
        case 0: return Color(hex: "3D3BF3")  // blue
        case 1: return Color(hex: "E5484D")  // red
        case 2: return Color(hex: "E5A000")  // amber
        case 3: return Color(hex: "30A46C")  // green
        case 4: return Color(hex: "8E4EC6")  // purple
        case 5: return Color(red: 0x8B/255.0, green: 0x8D/255.0, blue: 0x98/255.0) // gray
        default: return Color(hex: "3D3BF3")
        }
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
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 18))
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
                } else {
                    Text(verbatim: "GEOMEMO")
                        .font(.system(size: 15, weight: .heavy))
                    Text("Monitoring \(context.attributes.monitoredCount) memos")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Right: Time or count
            if context.state.isTriggered, let time = context.state.triggeredAt {
                Text(time, style: .time)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text(String(format: "%02d", context.attributes.monitoredCount))
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(hex: "3D3BF3"))
            }
        }
        .padding(16)
    }

    private var memoColor: Color {
        let index = context.state.memoColorIndex
        switch index {
        case 0: return Color(hex: "3D3BF3")
        case 1: return Color(hex: "E5484D")
        case 2: return Color(hex: "E5A000")
        case 3: return Color(hex: "30A46C")
        case 4: return Color(hex: "8E4EC6")
        case 5: return Color(red: 0x8B/255.0, green: 0x8D/255.0, blue: 0x98/255.0)
        default: return Color(hex: "3D3BF3")
        }
    }
}
