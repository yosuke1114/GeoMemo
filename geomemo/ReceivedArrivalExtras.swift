import SwiftUI
import SwiftData

/// 受け取り画面だけに出す部分（「この依頼について」・足りない許可の案内・名前の行）。
/// 許可の状態・プロフィール・自分のメモを読むので、通常の詳細を重くしないよう別の View にしている。
/// 何を出すかは `ReceivedArrivalContent`（RecipientLogic.swift）が決める。
struct ReceivedArrivalExtras: View {
    let shared: SharedMemo
    /// 依頼者の名前（確認できた名前を優先したもの）。空なら nil。
    let requesterName: String?

    @Environment(\.scenePhase) private var scenePhase
    @Query private var profiles: [UserProfile]
    @Query private var ownMemos: [GeoMemo]
    @Query private var allShared: [SharedMemo]
    @ObservedObject private var locationManager = LocationManager.shared
    @ObservedObject private var notificationManager = NotificationManager.shared
    @State private var permissionPerformer = PermissionActionPerformer()
    @State private var showProfileSetup = false

    private var content: ReceivedArrivalContent {
        ReceivedArrivalContent.resolve(
            status: shared.status,
            permissions: PermissionSnapshot(
                location: LocationAccess(locationManager.authorizationStatus),
                isPreciseLocation: locationManager.isPreciseLocation,
                notification: NotificationAccess(notificationManager.authorizationStatus)),
            hasProfile: !profiles.isEmpty,
            requiredRegions: GeofenceRegistrar.requiredRegionCount(memos: ownMemos, sharedMemos: allShared))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if content.showsAbout { aboutSection }
            noticeBox
            namePromptRow
            yourNameRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { notificationManager.checkAuthorizationStatus() }
        .onChange(of: scenePhase) { _, phase in
            permissionPerformer.scenePhaseChanged(phase)
            if phase == .active { notificationManager.checkAuthorizationStatus() }
        }
        .onDisappear { permissionPerformer.cancel() }
        .sheet(isPresented: $showProfileSetup) {
            UserProfileSetupView()
        }
    }

    // MARK: - この依頼について

    /// 3 項目。「監視」「追跡」を連想させない言い方にする。現在地や経路は送らないことを先に置く。
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "About this request"))
                .font(.headline)
                .foregroundStyle(Brand.primaryText)
                .accessibilityAddTraits(.isHeader)
            aboutRow("lock.shield", String(localized: "Your current location and where you've been are never sent. Only your arrival and completion are shared."))
            aboutRow("mappin.and.ellipse", arrivalLine)
            aboutRow("hand.raised", String(localized: "You can decline at any time. Declining removes it from this device and stops the arrival alert."))
        }
    }

    private var arrivalLine: String {
        if let name = requesterName {
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

    // MARK: - 足りない許可の案内

    /// ボタンは地図のバナーと同じ `PermissionActionPerformer` で動かす。
    @ViewBuilder
    private var noticeBox: some View {
        if let notice = content.notice {
            let action = noticeAction(notice)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: noticeIcon(notice))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Brand.warning)
                        .accessibilityHidden(true)
                    Text(noticeText(notice))
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
            if let name = requesterName {
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

    // MARK: - 名前

    /// プロフィールが無いときだけ。名前を伝えるのは任意で、設定しなくても受け取れる。
    /// 設定すると、次の同期で今の（監視中の）依頼にも、今後受け取る依頼にも表示される。
    @ViewBuilder
    private var namePromptRow: some View {
        if content.showsNamePrompt {
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
        if let name = requesterName {
            return String(format: String(localized: "%@ will see this name on this request and on requests you receive later. You can skip this."), name)
        }
        return String(localized: "The person who sent the request will see this name on this request and on requests you receive later. You can skip this.")
    }

    /// プロフィールがあるとき、依頼者に表示される名前を伝える（受け取りは、名前が表示されることに同意することでもあるため）。
    @ViewBuilder
    private var yourNameRow: some View {
        if content.showsYourName, let profile = profiles.first {
            Text(yourNameText(profile.displayName))
                .font(.footnote)
                .foregroundStyle(Brand.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("arrival.yourName")
        }
    }

    private func yourNameText(_ myName: String) -> String {
        if let name = requesterName {
            return String(format: String(localized: "Your name (%1$@) is shown to %2$@."), myName, name)
        }
        return String(format: String(localized: "Your name (%@) is shown to the person who sent the request."), myName)
    }
}
