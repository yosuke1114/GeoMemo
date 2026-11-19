import Foundation

// UI の表示判断に使う純粋なロジック (テスト対象)。

/// リストタブが何を出すか。自分のメモが 0 件でも、受信した依頼があれば見せる。
enum ListContentState: Equatable {
    case empty          // 自分のメモも受信した依頼もない
    case receivedOnly   // 自分のメモは 0 件、受信した依頼だけある
    case memos          // 自分のメモがある

    static func resolve(ownMemoCount: Int, receivedCount: Int) -> ListContentState {
        if ownMemoCount > 0 { return .memos }
        return receivedCount > 0 ? .receivedOnly : .empty
    }
}
