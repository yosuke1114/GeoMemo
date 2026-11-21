import Foundation

// 「文章でメモを作る」(L-4) の、作成画面の状態の遷移。純粋なロジック（テスト対象）。
// 読み取りの結果を画面の項目へ写すときの規則をここにまとめる:
// - 文章に無かった項目（nil）は、既存の設定を触らない。
// - 2 回目の読み取りは、1 回目が書いた項目だけを元に戻してから書く。失敗・取り消しで 1 回目の結果が残らない。
// - 読み取り中に手で打った題は上書きしない。
// - 仮置きの場所が残る間は「確認済み」にしない。

nonisolated struct NLPlace: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var name: String
}

/// 画面の項目のうち、読み取りが書き換えうるもの。
nonisolated struct NLEditorFields: Equatable, Sendable {
    var title: String
    var notifyOnEntry: Bool
    var notifyOnExit: Bool
    var timeWindow: NLTimeWindow?
    var activeDays: [Int]?
    var deadline: Date?
    var place: NLPlace
}

/// 読み取りが書いた内容。`before` は書く前の値、`after` は書いた直後の値。
nonisolated struct NLApplied: Equatable, Sendable {
    var before: NLEditorFields
    var after: NLEditorFields
}

nonisolated struct NLFlow: Equatable, Sendable {
    var applied: NLApplied?
    /// 場所を地図で確認するまで保存させない。
    var needsConfirmation = false
    var choices: [NLPlaceChoice] = []
    var selectedID: UUID?
}

nonisolated enum NLFlowNotice: Equatable, Sendable {
    case none
    /// 読み取れた。捨てた項目があれば添える。
    case read(dropped: [NLDroppedItem])
    /// 読み取れなかったので、入力文を題にした。
    case usedAsTitle
}

nonisolated struct NLReduction: Equatable, Sendable {
    var fields: NLEditorFields
    var flow: NLFlow
    var notice: NLFlowNotice
}

nonisolated enum NLFlowReducer {
    /// 前回の読み取りが書いた項目のうち、いまも書いたままの値のものを、書く前に戻す（手で直した項目は残す）。
    nonisolated static func revert(_ current: NLEditorFields, _ applied: NLApplied) -> NLEditorFields {
        var f = current
        if f.title == applied.after.title { f.title = applied.before.title }
        if f.notifyOnEntry == applied.after.notifyOnEntry { f.notifyOnEntry = applied.before.notifyOnEntry }
        if f.notifyOnExit == applied.after.notifyOnExit { f.notifyOnExit = applied.before.notifyOnExit }
        if f.timeWindow == applied.after.timeWindow { f.timeWindow = applied.before.timeWindow }
        if f.activeDays == applied.after.activeDays { f.activeDays = applied.before.activeDays }
        if f.deadline == applied.after.deadline { f.deadline = applied.before.deadline }
        if f.place == applied.after.place { f.place = applied.before.place }
        return f
    }

    /// 読み取りの結果を画面の項目に写す。`titleAtStart` は読み取りを始めたときの題。
    nonisolated static func reduce(flow: NLFlow, current: NLEditorFields, titleAtStart: String,
                                   outcome: NLMemoOutcome) -> NLReduction {
        if case .cancelled = outcome { return NLReduction(fields: current, flow: flow, notice: .none) }

        let titleEdited = current.title != titleAtStart
        let base = flow.applied.map { revert(current, $0) } ?? current
        var f = base
        var next = NLFlow()
        var notice: NLFlowNotice = .none

        switch outcome {
        case .cancelled:
            break
        case .fallback(let title):
            if !title.isEmpty {
                if !titleEdited { f.title = title }
                notice = .usedAsTitle
            }
            // 仮置きの場所は戻したので、確認は要らない（通常の作成画面に戻る）
        case .draft(let d):
            if !titleEdited { f.title = d.title }
            if let v = d.notifyOnEntry { f.notifyOnEntry = v }
            if let v = d.notifyOnExit { f.notifyOnExit = v }
            if let v = d.timeWindow { f.timeWindow = v }
            if let v = d.activeDays { f.activeDays = v }
            if let v = d.deadline { f.deadline = v }
            if let first = d.candidates.first {
                f.place = NLPlace(latitude: first.place.latitude, longitude: first.place.longitude, name: first.place.name)
                next.selectedID = first.id
            }
            next.choices = d.candidates
            next.needsConfirmation = true   // 地図で確かめるまで保存させない
            notice = .read(dropped: d.dropped)
        }
        next.applied = NLApplied(before: base, after: f)
        return NLReduction(fields: f, flow: next, notice: notice)
    }

    /// 候補を自分で選んだ。確認済みになる。
    nonisolated static func select(_ choice: NLPlaceChoice, flow: NLFlow, current: NLEditorFields) -> (fields: NLEditorFields, flow: NLFlow) {
        var f = current
        f.place = NLPlace(latitude: choice.place.latitude, longitude: choice.place.longitude, name: choice.place.name)
        var next = flow
        next.selectedID = choice.id
        next.needsConfirmation = false
        next.applied?.after.place = f.place
        return (f, next)
    }

    /// 「この場所でよい」。
    nonisolated static func confirm(_ flow: NLFlow) -> NLFlow {
        var next = flow
        next.needsConfirmation = false
        return next
    }

    /// 地図の選択画面で選び直した。自分で選んだので確認済み。
    nonisolated static func pickedOnMap(_ flow: NLFlow) -> NLFlow {
        var next = flow
        next.needsConfirmation = false
        next.selectedID = nil
        return next
    }

    /// 逆ジオコーディングの結果が返ってきた。`coordinate` の場所の名前が分かった。
    /// - 画面がその座標の場所のままなら、名前を入れる。
    /// - 読み取りが仮置きに変えていても、書く前の場所の名前は控えておく（戻したときに使う）。
    nonisolated static func geocoded(name: String, latitude: Double, longitude: Double,
                                     flow: NLFlow, current: NLEditorFields) -> (fields: NLEditorFields, flow: NLFlow) {
        var f = current
        var next = flow
        if f.place.latitude == latitude, f.place.longitude == longitude { f.place.name = name }
        if let applied = flow.applied {
            if applied.before.place.latitude == latitude, applied.before.place.longitude == longitude {
                next.applied?.before.place.name = name
            }
            if applied.after.place.latitude == latitude, applied.after.place.longitude == longitude {
                next.applied?.after.place.name = name
            }
        }
        return (f, next)
    }
}

/// 落とした項目を伝える一言に使う項目の並び。
nonisolated extension NLDroppedItem {
    nonisolated var order: Int {
        switch self { case .timeWindow: 0; case .days: 1; case .deadline: 2 }
    }
}
