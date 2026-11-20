import SwiftUI

// 「文章でメモを作る」(L-4) の画面部品。作成画面 (MemoEditorView) の先頭に載せる。
// 入力欄は端末内モデルが使えるときだけ出す（使えない理由は案内しない）。
// 読み取った結果は、保存前に必ず地図で場所を確認してもらう (`NLPlaceConfirmationCard`)。

// MARK: - 入力欄

struct NaturalLanguageComposerView: View {
    /// 読み取り前のお気に入りの場所。
    let favorites: [PlaceCandidate]
    /// 場所の検索の起点（現在地。無ければ作成の地点）。
    let origin: NLPoint?
    let onOutcome: (NLMemoOutcome) -> Void

    @State private var text = ""
    @State private var isWorking = false
    @State private var notice: LocalizedStringKey?
    @State private var task: Task<Void, Never>?
    @FocusState private var isFocused: Bool
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 20

    var body: some View {
        // `availability` は Observable。準備中だったモデルが整うと、ここが自動で更新される。
        if NLMemoAvailability.isUsable() {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.body)
                        .foregroundColor(Brand.blue)
                        .frame(width: iconSize, height: iconSize)
                        .padding(.top, 2)
                        .accessibilityHidden(true)

                    TextField("e.g. Buy milk when I reach the station", text: $text, axis: .vertical)
                        .lineLimit(1...3)
                        .font(.body)
                        .foregroundColor(Brand.primaryText)
                        .submitLabel(.go)
                        .focused($isFocused)
                        .disabled(isWorking)
                        .onSubmit(run)
                        .accessibilityLabel(Text("Create from a sentence"))
                        .accessibilityIdentifier("nlInputField")

                    if isWorking {
                        ProgressView()
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel(Text("Reading…"))
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
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Brand.secondaryBackground)
            .onDisappear { task?.cancel() }
        }
    }

    private var canRun: Bool { !isWorking && NLInput.sanitize(text) != nil }

    private func run() {
        guard canRun, let sentence = NLInput.sanitize(text) else { return }
        isFocused = false
        isWorking = true
        notice = nil
        let composer = NLMemoComposer(parser: SystemLanguageModelParser(), searcher: NLMapSearcher())
        let favorites = favorites
        let origin = origin
        // View の Task は MainActor で動くが、compose は nonisolated なので、モデルとツールは MainActor の外で動く。
        task = Task {
            let outcome = await composer.compose(sentence, favorites: favorites, near: origin)
            isWorking = false
            switch outcome {
            case .cancelled:
                return
            case .draft:
                notice = "Read your sentence. Check the place on the map before saving."
                announce("Read your sentence. Check the place on the map before saving.")
                text = ""
            case .fallback(let title):
                notice = title.isEmpty ? nil : "Couldn't read that sentence. It was used as the title."
                if !title.isEmpty { announce("Couldn't read that sentence. It was used as the title.") }
                text = ""
            }
            onOutcome(outcome)
        }
    }

    private func announce(_ key: String.LocalizationValue) {
        AccessibilityNotification.Announcement(String(localized: key)).post()
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
