import SwiftUI
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
    @State private var confirmingDelete = false

    private var coordinate: CLLocationCoordinate2D { shared.memoCoordinate }
    private var note: String { SharedMemoNoteStore.note(for: shared.ckRecordName) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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
                    .frame(height: 360)
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

                    if shared.status == .active || shared.status == .fired {
                        Text(String(format: String(localized: "この場所に着くと、依頼した人（%@）に通知されます。伝わるのは到着と完了だけで、現在地は共有されません。"),
                                    shared.requesterName))
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
                                .foregroundStyle(.white)
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

                    VStack(spacing: 0) {
                        infoRow(String(localized: "依頼者"), shared.requesterName)
                        infoRow(String(localized: "範囲"), "\(Int(shared.memoRadius))m")
                        if let deadline = shared.memoDeadline {
                            infoRow(String(localized: "期限"),
                                    deadline.formatted(date: .abbreviated, time: .shortened))
                        }
                        infoRow(String(localized: "状態"), statusText)
                    }
                    .background(Brand.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    if onDelete != nil {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label(String(localized: "この依頼を削除"), systemImage: "trash")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .confirmationDialog(
                            String(localized: "この依頼を削除しますか？"),
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible
                        ) {
                            Button(String(localized: "削除"), role: .destructive) {
                                onDelete?()
                                dismiss()
                            }
                            Button(String(localized: "キャンセル"), role: .cancel) {}
                        } message: {
                            Text(String(localized: "この端末から削除し、共有から抜けます。依頼した人の側には残ります。"))
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
    }

    private var statusText: String {
        switch shared.status {
        case .active:    return String(localized: "到着待ち")
        case .fired:     return String(localized: "到着済み")
        case .completed: return String(localized: "完了")
        case .cancelled: return String(localized: "取り消し")
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Brand.secondaryText)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Brand.primaryText)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

extension SharedMemo {
    var memoCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: memoLatitude, longitude: memoLongitude)
    }
}
