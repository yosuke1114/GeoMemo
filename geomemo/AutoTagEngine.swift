import Foundation
import NaturalLanguage

// MARK: - AutoTagEngine

/// オフライン動作のタグ自動提案エンジン
/// キーワードマッチング（タイトル・場所名を重み2倍）+ NLTagger補助
struct AutoTagEngine {

    /// タイトル・ノート・場所名からプリセットタグを最大3件提案
    static func suggest(title: String, note: String, locationName: String) -> [PresetTag] {
        guard !title.isEmpty || !note.isEmpty || !locationName.isEmpty else { return [] }

        var scores: [PresetTag: Int] = [:]

        // 1. キーワードマッチ（タイトル・場所名は重み2、ノートは重み1）
        for tag in PresetTag.allCases {
            for keyword in tag.keywords {
                if title.localizedCaseInsensitiveContains(keyword) ||
                   locationName.localizedCaseInsensitiveContains(keyword) {
                    scores[tag, default: 0] += 2
                }
                if note.localizedCaseInsensitiveContains(keyword) {
                    scores[tag, default: 0] += 1
                }
            }
        }

        // 2. NLTagger で名詞抽出して補助スコアリング
        let combined = [title, locationName].joined(separator: " ")
        if !combined.trimmingCharacters(in: .whitespaces).isEmpty {
            let nouns = extractNouns(from: combined)
            for noun in nouns {
                for tag in PresetTag.allCases {
                    if tag.keywords.contains(where: {
                        $0.localizedCaseInsensitiveContains(noun) ||
                        noun.localizedCaseInsensitiveContains($0)
                    }) {
                        scores[tag, default: 0] += 1
                    }
                }
            }
        }

        // スコア上位3件（スコア1以上のみ）
        return scores
            .filter { $0.value >= 1 }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { $0.key }
    }

    // MARK: - Private

    /// NLTagger は初期化コストが高いため static で使い回す
    private static let tagger = NLTagger(tagSchemes: [.lexicalClass])

    private static func extractNouns(from text: String) -> [String] {
        tagger.string = text

        var nouns: [String] = []
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation]

        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word,
                             scheme: .lexicalClass,
                             options: options) { tag, tokenRange in
            if tag == .noun {
                nouns.append(String(text[tokenRange]))
            }
            return true
        }
        return nouns
    }
}
