import SwiftUI

// MARK: - Toast モデル

/// 一時的にユーザーへ通知を出すための軽量バナー。
/// 「同期失敗」「シェア受諾失敗」「キュー再送待ち」など、
/// アラートで遮るほどでもないが silent にしてはいけないイベントを表現する。
struct Toast: Identifiable, Equatable {
    enum Kind: Equatable {
        case info, success, warning, error

        var systemImage: String {
            switch self {
            case .info:    return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error:   return "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info:    return Brand.blue
            case .success: return .green
            case .warning: return .orange
            case .error:   return .red
            }
        }

        /// 視覚的にしか伝わらない種別を VoiceOver にも読ませる。
        var spokenPrefix: String {
            switch self {
            case .info:    return String(localized: "お知らせ")
            case .success: return String(localized: "完了")
            case .warning: return String(localized: "警告")
            case .error:   return String(localized: "エラー")
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let message: String
    let duration: TimeInterval

    static func info(_ message: String, duration: TimeInterval = 3) -> Toast {
        Toast(kind: .info, message: message, duration: duration)
    }
    static func success(_ message: String, duration: TimeInterval = 2.5) -> Toast {
        Toast(kind: .success, message: message, duration: duration)
    }
    static func warning(_ message: String, duration: TimeInterval = 3.5) -> Toast {
        Toast(kind: .warning, message: message, duration: duration)
    }
    static func error(_ message: String, duration: TimeInterval = 4) -> Toast {
        Toast(kind: .error, message: message, duration: duration)
    }
}

// MARK: - ToastCenter

/// アプリ全体で一つの Toast を表示する @Observable シングルトン。
/// 新しい toast が来ると前のものを置き換える（連投で詰まらない）。
@MainActor
@Observable
final class ToastCenter {
    static let shared = ToastCenter()

    var current: Toast?

    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ toast: Toast) {
        dismissTask?.cancel()
        current = toast
        let duration = toast.duration
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

// MARK: - View Modifier

private struct ToastOverlay: ViewModifier {
    @State private var center = ToastCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let toast = center.current {
                ToastBanner(toast: toast) { center.dismiss() }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.35), value: center.current)
    }
}

private struct ToastBanner: View {
    let toast: Toast
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.kind.systemImage)
                .foregroundStyle(toast.kind.tint)
                .font(.body.weight(.semibold))
                .imageScale(.large)
                .accessibilityHidden(true)
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Brand.primaryText)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(toast.kind.tint.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)
        .onTapGesture { onDismiss() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(toast.kind.spokenPrefix)、\(toast.message)")
        .accessibilityHint(String(localized: "タップで閉じる"))
        .accessibilityAddTraits(.isButton)
    }
}

extension View {
    /// 画面の上部に ToastCenter の現在 toast を重ねる。
    /// アプリ起動時のルートビューに一度だけ付ければよい。
    func toastOverlay() -> some View { modifier(ToastOverlay()) }
}
