import SwiftUI
import SwiftData

// 受け取った依頼の一覧（地図のバッジから開くシート）と、その行・バッジ・簡易表示のカード。
// 何を出すか（節の分け方・バッジの状態・カードに出す 1 件）は RecipientLogic.swift が決める。

// MARK: - 行（リストタブと一覧のシートで共用）

struct ReceivedRequestRow: View {
    let shared: SharedMemo
    /// 完了にする（到着済みのときだけボタンを出す）。
    var onComplete: (() -> Void)?
    /// 場所の名前と期限も出す（一覧のシート）。リストタブは従来どおり依頼者だけ。
    var showsDetails: Bool = true
    var isUnseen: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if shared.status == .fired {
                    Image(systemName: "location.fill").foregroundStyle(Brand.warning)
                } else if shared.status == .active {
                    Image(systemName: "clock").foregroundStyle(Brand.blue)
                } else {
                    Image(systemName: "checkmark.circle").foregroundStyle(Brand.secondaryText)
                }
            }
            .font(.body)
            .frame(width: 24)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(shared.memoTitle.isEmpty ? String(localized: "（タイトルなし）") : shared.memoTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.primaryText)
                        .lineLimit(2)
                    if isUnseen {
                        Text(String(localized: "New"))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Brand.onAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Brand.blue)
                            .clipShape(Capsule())
                    }
                }
                Text(String(localized: "依頼: ") + shared.requesterName)
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(1)
                if showsDetails {
                    if !shared.memoLocationName.isEmpty {
                        Text(shared.memoLocationName)
                            .font(.caption)
                            .foregroundStyle(Brand.secondaryText)
                            .lineLimit(1)
                    }
                    if let deadline = shared.memoDeadline, shared.isActive {
                        if RequestDeadline.isOverdue(deadline, now: Date()) {
                            Text(String(format: String(localized: "Overdue (was due %@)"),
                                        deadline.formatted(date: .abbreviated, time: .shortened)))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.warning)
                        } else {
                            Text(String(localized: "期限") + " " + deadline.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(Brand.secondaryText)
                        }
                    }
                }
            }

            Spacer()

            if shared.status == .fired, let onComplete {
                Button {
                    HapticManager.notification(.success)
                    onComplete()
                } label: {
                    Text(String(localized: "完了"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.onAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(minHeight: 44)
                        .background(Brand.blue, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 「受信した依頼」の一覧シート

struct ReceivedRequestsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SharedMemo.createdAt, order: .reverse) private var allShared: [SharedMemo]
    /// 詳細を開いている依頼。
    @State private var selected: SharedMemo?
    @State private var seen = ReceivedRequestSeenStore.shared.all

    private var received: [SharedMemo] { allShared.filter { !$0.isMyRequest } }

    private var sections: ReceivedRequestSections {
        ReceivedRequestSections.resolve(received.map(\.summary), now: Date())
    }

    private func items(_ names: [String]) -> [SharedMemo] {
        names.compactMap { name in received.first { $0.ckRecordName == name } }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sections.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundStyle(Brand.secondaryText)
                            .accessibilityHidden(true)
                        Text(String(localized: "No requests right now"))
                            .font(.body.weight(.medium))
                            .foregroundStyle(Brand.secondaryText)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List {
                        section(String(localized: "Arrived — tap Done when finished"), items(sections.arrived))
                        section(String(localized: "Waiting for arrival"), items(sections.waiting))
                        section(String(localized: "Recently finished"), items(sections.recent))
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Brand.background)
            .navigationTitle(String(localized: "受信した依頼"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "閉じる")) { dismiss() }
                }
            }
        }
        .sheet(item: $selected, onDismiss: { seen = ReceivedRequestSeenStore.shared.all }) { shared in
            ReceivedSharedMemoDetailView(
                shared: shared,
                onDelete: { deleteReceivedSharedMemo(shared, in: modelContext) },
                onComplete: { completeReceivedSharedMemo(shared, in: modelContext) }
            )
        }
        .onAppear { seen = ReceivedRequestSeenStore.shared.all }
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [SharedMemo]) -> some View {
        if !list.isEmpty {
            Section {
                ForEach(list) { shared in
                    ReceivedRequestRow(
                        shared: shared,
                        onComplete: { completeReceivedSharedMemo(shared, in: modelContext) },
                        isUnseen: !seen.contains(shared.ckRecordName) && shared.isActive)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = shared }
                        .accessibilityAddTraits(.isButton)
                        .listRowBackground(Brand.surface)
                }
            } header: {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .textCase(nil)
            }
        }
    }
}

// MARK: - 地図左上のバッジ

struct ReceivedRequestsBadge: View {
    let state: ReceivedBadgeState
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if case .visible(let count, let hasArrived, let hasUnseen) = state {
            Button(action: {
                HapticManager.impact(.light)
                action()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                    Text(String(localized: "Requests \(count)"))
                    if hasArrived {
                        Text(verbatim: "・" + String(localized: "To finish"))
                    }
                    if hasUnseen {
                        Circle().fill(Brand.onAccent).frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.onAccent)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(hasArrived ? Brand.warning : Brand.blue, in: Capsule())
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText(count: count, hasArrived: hasArrived, hasUnseen: hasUnseen))
            .accessibilityHint(String(localized: "Shows the requests you received."))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("receivedRequestsBadge")
        }
    }

    private func accessibilityText(count: Int, hasArrived: Bool, hasUnseen: Bool) -> String {
        var parts = [String(localized: "Received requests, \(count).")]
        if hasArrived { parts.append(String(localized: "To finish")) }
        if hasUnseen { parts.append(String(localized: "New")) }
        return parts.joined(separator: " ")
    }
}

// MARK: - 受信だけの人の下部カード

struct ReceivedRequestCard: View {
    let highlight: SharedMemo?
    let otherCount: Int
    let onOpenDetail: () -> Void
    let onOpenList: () -> Void
    let onComplete: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let shared = highlight {
                HStack(alignment: .top) {
                    Button(action: onOpenDetail) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(shared.memoTitle.isEmpty ? String(localized: "（タイトルなし）") : shared.memoTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Brand.primaryText)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            fromLine(shared)
                            Text(shared.status == .fired ? String(localized: "到着済み") : String(localized: "到着待ち"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(shared.status == .fired ? Brand.warning : Brand.blue)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("receivedCard.open")

                    if otherCount > 0 {
                        Button(action: onOpenList) {
                            Text(String(localized: "\(otherCount) more"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.blue)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("receivedCard.more")
                    }
                }
                if shared.status == .fired {
                    Button {
                        HapticManager.notification(.success)
                        onComplete()
                    } label: {
                        Text(String(localized: "完了にする"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.onAccent)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Brand.blue, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button(action: onOpenList) {
                    Text(String(localized: "No requests right now"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Brand.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Brand.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.border, lineWidth: 2))
    }

    /// 「%@さんから・%@」。最大の文字サイズでは依頼者と場所を別の行に分ける。
    @ViewBuilder
    private func fromLine(_ shared: SharedMemo) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: String(localized: "From %@"), shared.requesterName))
                Text(shared.memoLocationName)
            }
            .font(.caption)
            .foregroundStyle(Brand.secondaryText)
        } else {
            Text(String(format: String(localized: "From %1$@ · %2$@"), shared.requesterName, shared.memoLocationName))
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
                .lineLimit(1)
        }
    }
}
