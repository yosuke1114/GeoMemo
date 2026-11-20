import SwiftUI
import SwiftData
import MapKit

/// 受信した依頼 (SharedMemo) の詳細。場所・範囲・依頼者・期限を表示する。
/// 受信側は依頼元の GeoMemo を持たないため、SharedMemo の内容だけで構成する。
struct ReceivedSharedMemoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let shared: SharedMemo
    /// 削除が確定したときに呼ぶ (呼び出し側でローカル削除と共有解除を行う)。
    var onDelete: (() -> Void)? = nil
    /// 「完了にする」で呼ぶ (リスト行の完了と同じ処理)。到着済みのときだけボタンを出す。
    var onComplete: (() -> Void)? = nil
    /// true のとき、受諾した直後の「受け取り画面」として出す（依頼者・伝わること・足りない許可・断る）。
    var isArrival: Bool = false
    @State private var confirmingDelete = false
    @Query private var friends: [FriendConnection]
    @AccessibilityFocusState private var headingFocused: Bool

    private var coordinate: CLLocationCoordinate2D { shared.memoCoordinate }
    private var note: String { SharedMemoNoteStore.note(for: shared.ckRecordName) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if isArrival {
                        Text(arrivalHeading)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Brand.primaryText)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($headingFocused)
                    }

                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: coordinate,
                        latitudinalMeters: max(shared.memoRadius * 6, 600),
                        longitudinalMeters: max(shared.memoRadius * 6, 600)
                    ))) {
                        MapCircle(center: coordinate, radius: shared.memoRadius)
                            .foregroundStyle(Brand.blue.opacity(0.15))
                            .stroke(Brand.blue, lineWidth: 1.5)
                        Marker(shared.memoLocationName, coordinate: coordinate)
                            .tint(Brand.blue)
                    }
                    .frame(height: isArrival ? 220 : 360)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(String(localized: "依頼の場所の地図"))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(shared.memoTitle.isEmpty ? String(localized: "（タイトルなし）") : shared.memoTitle)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Brand.primaryText)
                        Text(shared.memoLocationName)
                            .font(.subheadline)
                            .foregroundStyle(Brand.secondaryText)
                    }

                    if !isArrival && (shared.status == .active || shared.status == .fired) {
                        Text(String(format: String(localized: "この場所に着くと、依頼した人（%@）に通知されます。伝わるのは到着と完了だけで、現在地は共有されません。"),
                                    requesterLabel))
                            .font(.footnote)
                            .foregroundStyle(Brand.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if shared.status == .fired, let onComplete {
                        Button {
                            HapticManager.notification(.success)
                            onComplete()
                        } label: {
                            Text(String(localized: "完了にする"))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Brand.onAccent)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Brand.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }

                    if !note.isEmpty {
                        Text(note)
                            .font(.body)
                            .foregroundStyle(Brand.primaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Brand.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // 受け取り用の部分（許可の状態・プロフィールなどを読む）は別の View にして、通常の詳細を重くしない
                    if isArrival {
                        ReceivedArrivalExtras(shared: shared, requesterName: identity.displayName.isEmpty ? nil : identity.displayName)
                    }

                    VStack(spacing: 0) {
                        infoRow(String(localized: "依頼者"), requesterLabel)
                        if let written = identity.writtenName {
                            infoRow(String(localized: "Name the sender wrote"), written)
                        }
                        infoRow(String(localized: "範囲"), "\(Int(shared.memoRadius))m")
                        if let deadline = shared.memoDeadline {
                            if RequestDeadline.isOverdue(deadline, now: Date()) {
                                infoRow(String(localized: "期限"),
                                        String(format: String(localized: "Overdue (was due %@)"),
                                               deadline.formatted(date: .abbreviated, time: .shortened)),
                                        valueColor: Brand.warning)
                            } else {
                                infoRow(String(localized: "期限"),
                                        deadline.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        infoRow(String(localized: "状態"), statusText)
                    }
                    .background(Brand.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    if isArrival {
                        Button {
                            dismiss()
                        } label: {
                            Text(String(localized: "Got It"))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Brand.onAccent)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Brand.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("arrival.gotIt")
                    }

                    if onDelete != nil {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label(isArrival ? String(localized: "Decline This Request") : String(localized: "この依頼を削除"),
                                  systemImage: isArrival ? "hand.raised" : "trash")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(isArrival ? "arrival.decline" : "received.delete")
                        .confirmationDialog(
                            isArrival ? String(localized: "Decline this request?") : String(localized: "この依頼を削除しますか？"),
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible
                        ) {
                            Button(isArrival ? String(localized: "Decline This Request") : String(localized: "削除"),
                                   role: .destructive) {
                                onDelete?()
                                dismiss()
                            }
                            Button(String(localized: "キャンセル"), role: .cancel) {}
                        } message: {
                            Text((isArrival
                                  ? String(localized: "It will be removed from this device and you'll leave the share. The person who sent it isn't notified.")
                                  : String(localized: "この端末から削除し、共有から抜けます。依頼した人の側には残ります。"))
                                 + " " + String(localized: "To receive it again, the sender needs to send it again."))
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
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
        .onAppear {
            // 開いた依頼は既読にする（端末ごとの記録。バッジの「新着」に使う）
            ReceivedRequestSeenStore.shared.markSeen(shared.ckRecordName)
            if isArrival { headingFocused = true }
        }
    }

    // MARK: - 依頼者の名前

    /// CloudKit の共有で確認できた依頼者の名前（確認済みのフレンドの表示名）。
    private var verifiedRequesterName: String? {
        guard VerifiedFriendStore.shared.contains(shared.requesterRecordID) else { return nil }
        return friends.first { $0.friendRecordID == shared.requesterRecordID }?.friendDisplayName
    }

    private var identity: RequesterIdentity {
        RequesterIdentity.resolve(writtenName: shared.requesterName, verifiedName: verifiedRequesterName)
    }

    /// 名前が空のときは「依頼した人」に置き換える。
    private var requesterLabel: String {
        identity.displayName.isEmpty ? String(localized: "The person who sent it") : identity.displayName
    }

    private var arrivalHeading: String {
        if !identity.displayName.isEmpty {
            return String(format: String(localized: "%@ sent you a request"), identity.displayName)
        }
        return String(localized: "You received a request")
    }

    private var statusText: String {
        switch shared.status {
        case .active:    return String(localized: "到着待ち")
        case .fired:     return String(localized: "到着済み")
        case .completed: return String(localized: "完了")
        case .cancelled: return String(localized: "取り消し")
        }
    }

    private func infoRow(_ label: String, _ value: String, valueColor: Color = Brand.primaryText) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Brand.secondaryText)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

extension SharedMemo {
    /// 依頼者の名前。空のときは「依頼した人」に置き換える。
    var requesterLabel: String {
        let trimmed = requesterName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "The person who sent it") : trimmed
    }

    /// 受け取った依頼の表示判断（`RecipientLogic.swift`）に渡す要約。
    var summary: ReceivedSummary {
        ReceivedSummary(recordName: ckRecordName, zoneOwner: requesterRecordID, status: status,
                        deadline: memoDeadline, createdAt: createdAt, completedAt: completedAt)
    }

    var memoCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: memoLatitude, longitude: memoLongitude)
    }
}
