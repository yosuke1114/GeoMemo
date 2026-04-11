import SwiftUI

// MARK: - TagChip

struct TagChip: View {
    let label: String
    let iconName: String?
    let isSelected: Bool
    let isSuggested: Bool   // AI提案の場合は点線ボーダー
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if let iconName {
                    Image(iconName)
                        .resizable()
                        .frame(width: 12, height: 12)
                        .foregroundStyle(foregroundColor)
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(foregroundColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(backgroundFill)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        borderColor,
                        style: isSuggested && !isSelected
                            ? StrokeStyle(lineWidth: 1, dash: [4])
                            : StrokeStyle(lineWidth: isSelected ? 0 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var foregroundColor: Color {
        isSelected ? .white : Brand.primaryText
    }

    private var backgroundFill: some ShapeStyle {
        isSelected ? AnyShapeStyle(Brand.blue) : AnyShapeStyle(Color.clear)
    }

    private var borderColor: Color {
        if isSelected { return .clear }
        return isSuggested ? Brand.blue : Brand.primaryText.opacity(0.2)
    }
}

// MARK: - PresetTagChip（プリセット専用）

struct PresetTagChip: View {
    let tag: PresetTag
    let isSelected: Bool
    let isSuggested: Bool
    let onTap: () -> Void

    var body: some View {
        TagChip(
            label: tag.localizedName,
            iconName: tag.iconName,
            isSelected: isSelected,
            isSuggested: isSuggested,
            onTap: onTap
        )
    }
}

// MARK: - TagChipScrollRow（横スクロール列）

struct TagChipScrollRow: View {
    let presetTags: [Int]           // 選択済みプリセットID
    let customTags: [String]        // カスタムタグ
    let suggestedTags: [PresetTag]  // AI提案（未選択のみ）
    let onRemovePreset: ((Int) -> Void)?
    let onRemoveCustom: ((String) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // 選択済みプリセットタグ
                ForEach(presetTags.compactMap { PresetTag(rawValue: $0) }) { tag in
                    TagChip(
                        label: tag.localizedName,
                        iconName: tag.iconName,
                        isSelected: true,
                        isSuggested: false,
                        onTap: { onRemovePreset?(tag.rawValue) }
                    )
                }
                // カスタムタグ
                ForEach(customTags, id: \.self) { tag in
                    TagChip(
                        label: tag,
                        iconName: nil,
                        isSelected: true,
                        isSuggested: false,
                        onTap: { onRemoveCustom?(tag) }
                    )
                }
                // AI提案（まだ選択されていないもの）
                ForEach(suggestedTags) { tag in
                    PresetTagChip(
                        tag: tag,
                        isSelected: false,
                        isSuggested: true,
                        onTap: {}
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 12) {
        TagChip(label: "仕事", iconName: "ph-briefcase-bold",
                isSelected: true, isSuggested: false, onTap: {})
        TagChip(label: "食事", iconName: "ph-fork-knife-bold",
                isSelected: false, isSuggested: false, onTap: {})
        TagChip(label: "AI提案", iconName: "ph-note-bold",
                isSelected: false, isSuggested: true, onTap: {})
    }
    .padding()
    .background(Brand.background)
}
