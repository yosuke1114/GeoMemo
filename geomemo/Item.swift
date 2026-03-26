//
//  Item.swift
//  geomemo
//
//  Created by 黒滝洋輔 on 2026/03/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
