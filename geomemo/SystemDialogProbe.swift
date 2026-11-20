import SwiftUI

/// システムの許可ダイアログが実際に出たかを、scenePhase で判定する。
///
/// 「常に」への昇格などは、iOS が既に 1 回尋ねていると何も出さず、結果も通知されない。
/// ダイアログが出れば scene は inactive になり、閉じると active に戻る。
/// - inactive を検知したら、タイマーより優先して active に戻るのを待つ（ダイアログ表示が遅れても進まない）。
/// - inactive にならないまま `noDialogTimeout` が過ぎたら「出なかった」とみなす。
@MainActor
final class SystemDialogProbe {
    private var timer: Task<Void, Never>?
    private var completion: ((_ dialogShown: Bool) -> Void)?
    private var sawInactive = false

    var isWaiting: Bool { completion != nil }

    /// 待ち始める。`completion` は dialogShown（ダイアログが出て閉じた）を渡して 1 度だけ呼ばれる。
    /// `requested` が false なら、要求自体が出ていないので、すぐ「出なかった」で完了する。
    func begin(requested: Bool = true,
               noDialogTimeout: Duration = .seconds(2),
               completion: @escaping (_ dialogShown: Bool) -> Void) {
        cancel()
        guard requested else {
            completion(false)
            return
        }
        self.completion = completion
        sawInactive = false
        timer = Task { [weak self] in
            try? await Task.sleep(for: noDialogTimeout)
            guard !Task.isCancelled else { return }
            self?.finish(dialogShown: false)
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard isWaiting else { return }
        if phase == .inactive {
            sawInactive = true
            timer?.cancel() // 出た。閉じる（active に戻る）のを待つ
            timer = nil
        } else if phase == .active && sawInactive {
            finish(dialogShown: true)
        }
    }

    /// 待ちをやめる（completion は呼ばない）。
    func cancel() {
        timer?.cancel()
        timer = nil
        completion = nil
        sawInactive = false
    }

    private func finish(dialogShown: Bool) {
        let done = completion
        cancel()
        done?(dialogShown)
    }
}
