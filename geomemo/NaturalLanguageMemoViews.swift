import SwiftUI
import SwiftData

// 「文章でメモを作る」(L-4) の画面部品。作成画面 (MemoEditorView) の先頭に載せる。
// 入力欄は端末内モデルが使えるときだけ出す（使えない理由は案内しない）。
// 読み取った結果は、保存前に必ず地図で場所を確認してもらう (`NLPlaceConfirmationCard`)。

// MARK: - 入力欄

struct NaturalLanguageComposerView: View {
    /// 場所の検索の起点（画面を開いたときの現在地。無ければ作成の地点）。読み取り中に動いても変えない。
    let origin: NLPoint
    /// 読み取りを始めるとき。呼び出し側は、そのときの題を控える。
    let onBegin: () -> Void
    /// 読み取りの結果を画面に写し、利用者に見せる一言を返す。
    let onOutcome: (NLMemoOutcome) -> NLFlowNotice

    // お気に入りの場所は、この部品を出したとき（作成のときだけ）に読む。編集画面では走らない。
    @Query(sort: \FavoritePlace.createdAt) private var favoritePlaces: [FavoritePlace]
    @State private var text = ""
    @State private var isWorking = false
    @State private var notice: String?
    @State private var task: Task<Void, Never>?
    /// 言語の対応は端末の設定で決まり、body のたびに調べる必要はない。最初に 1 回だけ調べる。
    @State private var localeSupported: Bool?
    @FocusState private var isFocused: Bool
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 20

    var body: some View {
        // `availability` は Observable。準備中だったモデルが整うと、ここが自動で更新される。
        Group {
            if localeSupported == true, NLMemoAvailability.isAvailable() {
                content
            }
        }
        .task {
            if localeSupported == nil { localeSupported = NLMemoAvailability.supportsLocale() }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.body)
                    .foregroundColor(Brand.blue)
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)

                // 1 行の入力。Return で送信する（複数行にすると Return が改行になる）。
                TextField("e.g. Buy milk when I reach the station", text: $text)
                    .font(.body)
                    .foregroundColor(Brand.primaryText)
                    .submitLabel(.go)
                    .focused($isFocused)
                    .disabled(isWorking)
                    .onSubmit(run)
                    .accessibilityLabel(Text("Create from a sentence"))
                    .accessibilityIdentifier("nlInputField")

                if isWorking {
                    // 読み取り中は止められる
                    ProgressView()
                        .accessibilityLabel(Text("Reading…"))
                    Button {
                        task?.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(Brand.secondaryText)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(Text("Cancel"))
                    .accessibilityIdentifier("nlCancelButton")
                } else {
                    Button(action: run) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundColor(canRun ? Brand.blue : Brand.tertiaryText)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(!canRun)
                    .accessibilityLabel(Text("Create from a sentence"))
                    .accessibilityIdentifier("nlSubmitButton")
                }
            }

            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundColor(Brand.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nlNotice")
            }
            // 場所の検索は Apple のマップに送られるので、入力欄のそばに一言添える
            Text("Place search uses Apple Maps.")
                .font(.caption2)
                .foregroundColor(Brand.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Brand.secondaryBackground)
        .onDisappear { task?.cancel() }
    }

    private var canRun: Bool { !isWorking && NLInput.sanitize(text) != nil }

    private func run() {
        guard canRun, let sentence = NLInput.sanitize(text) else { return }
        isFocused = false
        isWorking = true
        notice = nil
        onBegin()
        let composer = NLMemoComposer(parser: SystemLanguageModelParser(), searcher: NLMapSearcher())
        let favorites = favoritePlaces.map(PlaceCandidate.init)
        let origin = origin
        // View の Task は MainActor で動くが、compose は nonisolated なので、モデルとツールは MainActor の外で動く。
        task = Task {
            let outcome = await composer.compose(sentence, favorites: favorites, near: origin)
            isWorking = false
            let result = onOutcome(outcome)
            switch outcome {
            case .cancelled:
                return
            case .draft, .fallback:
                text = ""
            }
            notice = Self.message(for: result)
            if let notice { AccessibilityNotification.Announcement(notice).post() }
        }
    }

    private static func message(for notice: NLFlowNotice) -> String? {
        switch notice {
        case .none:
            return nil
        case .usedAsTitle:
            return String(localized: "Couldn't read that sentence. It was used as the title.")
        case .read(let dropped):
            guard !dropped.isEmpty else {
                return String(localized: "Read your sentence. Check the place on the map before saving.")
            }
            let names = dropped.sorted { $0.order < $1.order }.map { item -> String in
                switch item {
                case .timeWindow: return String(localized: "time of day")
                case .days: return String(localized: "days of the week")
                case .deadline: return String(localized: "expiry date")
                }
            }
            let list = ListFormatter.localizedString(byJoining: names)
            return String(format: String(localized: "Some details could not be set (%@). You can set them under Details. Check the place on the map before saving."), list)
        }
    }
}

// MARK: - 場所の確認

/// 読み取った場所を、地図と見比べて確かめてもらうカード。確認（または場所の選び直し）が済むまで保存させない。
struct NLPlaceConfirmationCard: View {
    let choices: [NLPlaceChoice]
    let selectedID: UUID?
    let isConfirmed: Bool
    let onSelect: (NLPlaceChoice) -> Void
    let onConfirm: () -> Void
    let onPickOnMap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(choices.isEmpty ? "No place found. Choose one on the map." : "CHECK THE PLACE")
                .font(choices.isEmpty ? .subheadline : .caption.weight(.bold))
                .foregroundColor(choices.isEmpty ? Brand.primaryText : Brand.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if !choices.isEmpty {
                VStack(spacing: 0) {
                    ForEach(choices) { choice in
                        Button { onSelect(choice) } label: {
                            row(choice)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(choice.id == selectedID ? .isSelected : [])
                        .accessibilityHint(Text(choice.source == .favorite ? "Saved place" : "Nearby"))
                        .accessibilityIdentifier("nlPlaceChoice")
                        if choice.id != choices.last?.id { MemoDivider() }
                    }
                }
            }

            HStack(spacing: 12) {
                Button(action: onPickOnMap) {
                    Text("Choose on map")
                        .font(.body.weight(.semibold))
                        .foregroundColor(Brand.blue)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("nlPickOnMapButton")

                Spacer(minLength: 0)

                if !isConfirmed {
                    Button(action: onConfirm) {
                        Text("This place is OK")
                            .font(.body.weight(.bold))
                            .foregroundColor(Brand.onAccent)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .background(Brand.blue, in: Capsule())
                    }
                    .accessibilityIdentifier("nlConfirmPlaceButton")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Brand.secondaryBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nlPlaceConfirmationCard")
    }

    private func row(_ choice: NLPlaceChoice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: choice.id == selectedID ? "checkmark.circle.fill" : "circle")
                .foregroundColor(choice.id == selectedID ? Brand.blue : Brand.tertiaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.place.name)
                    .font(.body.weight(.semibold))
                    .foregroundColor(Brand.primaryText)
                if !choice.place.subtitle.isEmpty {
                    Text(choice.place.subtitle)
                        .font(.footnote)
                        .foregroundColor(Brand.secondaryText)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if choice.source == .favorite {
                Image(systemName: "star.fill")
                    .font(.footnote)
                    .foregroundColor(Brand.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
