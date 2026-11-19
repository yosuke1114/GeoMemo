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

/// 時刻に添える日付の区分 (今日・昨日・明日・それ以外)。
enum RelativeDay: Equatable {
    case today, yesterday, tomorrow, other

    static func of(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> RelativeDay {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        guard let startOfNow = calendar.dateInterval(of: .day, for: now)?.start,
              let startOfDate = calendar.dateInterval(of: .day, for: date)?.start
        else { return .other }
        let days = calendar.dateComponents([.day], from: startOfNow, to: startOfDate).day
        switch days {
        case -1: return .yesterday
        case 1:  return .tomorrow
        default: return .other
        }
    }
}

/// 見守りの時刻表示。「今日 14:30」「昨日 14:30」「11/20 14:30」のように日付を付ける。
func dayAndTimeText(_ date: Date, now: Date = Date()) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    switch RelativeDay.of(date, now: now) {
    case .today:     return "\(String(localized: "今日")) \(time)"
    case .yesterday: return "\(String(localized: "昨日")) \(time)"
    case .tomorrow:  return "\(String(localized: "明日")) \(time)"
    case .other:
        let day = date.formatted(.dateTime.month().day())
        return "\(day) \(time)"
    }
}
