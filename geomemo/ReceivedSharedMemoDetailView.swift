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
    @Environment(\.scenePhase) private var scenePhase
    @Query private var profiles: [UserProfile]
    @Query private var ownMemos: [GeoMemo]
    @Query private var allShared: [SharedMemo]
    @ObservedObject private var locationManager = LocationManager.shared
    @ObservedObject private var notificationManager = NotificationManager.shared
    @State private var permissionPerformer = PermissionActionPerformer()
    @State private var showProfileSetup = false
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

                    if isArrival {
                        aboutSection
                        noticeBox
                        namePromptRow
                    }

                    VStack(spacing: 0) {
                        infoRow(String(localized: "依頼者"), shared.requesterName)
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
                        .accessibilityIdentifier("arrival.decline")
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
                            Text(isArrival
                                 ? String(localized: "It will be removed from this device and you'll leave the share. The person who sent it isn't notified.")
                                 : String(localized: "この端末から削除し、共有から抜けます。依頼した人の側には残ります。"))
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
            notificationManager.checkAuthorizationStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            permissionPerformer.scenePhaseChanged(phase)
            if phase == .active { notificationManager.checkAuthorizationStatus() }
        }
        .onDisappear { permissionPerformer.cancel() }
        .sheet(isPresented: $showProfileSetup) {
            UserProfileSetupView()
        }
    }

    // MARK: - 受け取り画面

    private var requesterNameOrNil: String? {
        let trimmed = shared.requesterName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var arrivalContent: ReceivedArrivalContent {
        ReceivedArrivalContent.resolve(
            requesterName: shared.requesterName,
            permissions: PermissionSnapshot(
                location: LocationAccess(locationManager.authorizationStatus),
                isPreciseLocation: locationManager.isPreciseLocation,
                notification: NotificationAccess(notificationManager.authorizationStatus)),
            hasProfile: !profiles.isEmpty,
            requiredRegions: GeofenceRegistrar.requiredRegionCount(memos: ownMemos, sharedMemos: allShared))
    }

    private var arrivalHeading: String {
        if let name = arrivalContent.headingRequesterName {
            return String(format: String(localized: "%@ sent you a request"), name)
        }
        return String(localized: "You received a request")
    }

    /// 「この依頼について」の 3 項目。「監視」「追跡」を連想させない言い方にする。
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "About this request"))
                .font(.headline)
                .foregroundStyle(Brand.primaryText)
                .accessibilityAddTraits(.isHeader)
            aboutRow("mappin.and.ellipse", arrivalLine)
            aboutRow("lock.shield", String(localized: "Only your arrival and completion are shared. Your current location and where you've been are never sent."))
            aboutRow("hand.raised", String(localized: "You can decline at any time. Declining removes it from this device and stops the arrival alert."))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var arrivalLine: String {
        if let name = requesterNameOrNil {
            return String(format: String(localized: "When you reach this place, %@ is told that you arrived."), name)
        }
        return String(localized: "When you reach this place, the person who sent the request is told that you arrived.")
    }

    private func aboutRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Brand.blue)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Brand.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// 足りない許可の案内（1 件）。ボタンは地図のバナーと同じ `PermissionActionPerformer` で動かす。
    @ViewBuilder
    private var noticeBox: some View {
        if let notice = arrivalContent.notice {
            let text = noticeText(notice)
            let action = noticeAction(notice)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: noticeIcon(notice))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Brand.warning)
                        .accessibilityHidden(true)
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(Brand.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action {
                    Button {
                        permissionPerformer.perform(action)
                    } label: {
                        Text(action.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Brand.blue)
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 36)
                    .accessibilityIdentifier("arrival.noticeAction")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.warning.opacity(0.5), lineWidth: 1))
            .accessibilityElement(children: .contain)
        }
    }

    private func noticeText(_ notice: ReceivedArrivalNotice) -> String {
        switch notice {
        case .whenInUseOnly:
            if let name = requesterNameOrNil {
                return String(format: String(localized: "To tell %@ when the app is closed, location must be set to “Always”."), name)
            }
            return String(localized: "To tell the person who sent the request when the app is closed, location must be set to “Always”.")
        case .permission(let permission):
            return MapGuidance.permission(permission).message
        case .monitoringLimit(let limit):
            return MapGuidance.monitoringLimit(limit).message
        }
    }

    private func noticeAction(_ notice: ReceivedArrivalNotice) -> PermissionNotice.Action? {
        switch notice {
        case .whenInUseOnly: return PermissionNotice.locationWhenInUseOnly.action
        case .permission(let permission): return permission.action
        case .monitoringLimit: return nil
        }
    }

    private func noticeIcon(_ notice: ReceivedArrivalNotice) -> String {
        switch notice {
        case .whenInUseOnly: return MapGuidance.permission(.locationWhenInUseOnly).iconName
        case .permission(let permission): return MapGuidance.permission(permission).iconName
        case .monitoringLimit(let limit): return MapGuidance.monitoringLimit(limit).iconName
        }
    }

    /// プロフィールが無いときだけ。名前を伝えるのは任意で、設定しなくても受け取れる。
    @ViewBuilder
    private var namePromptRow: some View {
        if arrivalContent.showsNamePrompt {
            Button {
                showProfileSetup = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle")
                        .font(.title3)
                        .foregroundStyle(Brand.blue)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Tell them your name"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.primaryText)
                        Text(nameCaption)
                            .font(.caption)
                            .foregroundStyle(Brand.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.secondaryText)
                        .accessibilityHidden(true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(Brand.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("arrival.namePrompt")
        }
    }

    private var nameCaption: String {
        if let name = requesterNameOrNil {
            return String(format: String(localized: "%@ will see this name. You can skip this."), name)
        }
        return String(localized: "The person who sent the request will see this name. You can skip this.")
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
    /// 受け取った依頼の表示判断（`RecipientLogic.swift`）に渡す要約。
    var summary: ReceivedSummary {
        ReceivedSummary(recordName: ckRecordName, zoneOwner: requesterRecordID, status: status,
                        deadline: memoDeadline, createdAt: createdAt, completedAt: completedAt)
    }

    var memoCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: memoLatitude, longitude: memoLongitude)
    }
}
