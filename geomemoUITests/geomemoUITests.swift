//
//  geomemoUITests.swift
//  geomemoUITests
//
//  Created by 黒滝洋輔 on 2026/03/26.
//

import XCTest

final class geomemoUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // スプラッシュ・権限チェックをバイパスし、オンボーディング済み状態でメイン画面を表示
        app.launchArguments = [
            "-UITesting",
            "-hasCompletedOnboarding", "YES"
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - 起動テスト

    @MainActor
    func testAppLaunchesAndShowsMainScreen() throws {
        // タブバーが表示されることを確認（ラベルは端末ロケールに依存）
        let mapTab = app.buttons.matching(
            NSPredicate(format: "label == 'マップ' OR label == 'Map'")
        ).firstMatch
        let listTab = app.buttons.matching(
            NSPredicate(format: "label == 'リスト' OR label == 'List'")
        ).firstMatch
        XCTAssertTrue(mapTab.waitForExistence(timeout: 5), "マップタブが表示されるべき")
        XCTAssertTrue(listTab.exists, "リストタブが表示されるべき")
    }

    // MARK: - タブ切り替え

    @MainActor
    func testSwitchToListTab() throws {
        let listTab = app.buttons.matching(
            NSPredicate(format: "label == 'リスト' OR label == 'List'")
        ).firstMatch
        XCTAssertTrue(listTab.waitForExistence(timeout: 5))
        listTab.tap()
        XCTAssertTrue(listTab.exists, "リストタブに切り替わるべき")
    }

    @MainActor
    func testSwitchBetweenTabs() throws {
        let mapTab = app.buttons.matching(
            NSPredicate(format: "label == 'マップ' OR label == 'Map'")
        ).firstMatch
        let listTab = app.buttons.matching(
            NSPredicate(format: "label == 'リスト' OR label == 'List'")
        ).firstMatch
        XCTAssertTrue(mapTab.waitForExistence(timeout: 5))

        // マップ → リスト
        listTab.tap()
        XCTAssertTrue(listTab.exists)

        // リスト → マップ
        mapTab.tap()
        XCTAssertTrue(mapTab.exists)
    }

    // MARK: - リスト画面（空状態）

    @MainActor
    func testListTabShowsEmptyState() throws {
        let listTab = app.buttons.matching(
            NSPredicate(format: "label == 'リスト' OR label == 'List'")
        ).firstMatch
        XCTAssertTrue(listTab.waitForExistence(timeout: 5))
        listTab.tap()

        // メモが0件のとき「メモがありません」または「No memos yet」が表示される
        let emptyLabel = app.staticTexts.matching(
            NSPredicate(format: "label == 'メモがありません' OR label == 'No memos yet'")
        ).firstMatch
        XCTAssertTrue(emptyLabel.waitForExistence(timeout: 3), "空状態メッセージが表示されるべき")
    }

    @MainActor
    func testListTabShowsAddMemoHint() throws {
        let listTab = app.buttons.matching(
            NSPredicate(format: "label == 'リスト' OR label == 'List'")
        ).firstMatch
        XCTAssertTrue(listTab.waitForExistence(timeout: 5))
        listTab.tap()

        // ヒントテキストが表示される
        let hintLabel = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'マップタブ' OR label CONTAINS 'Tap the map'")
        ).firstMatch
        XCTAssertTrue(hintLabel.waitForExistence(timeout: 5), "メモ追加ヒントが表示されるべき")
    }

    // MARK: - メモ追加ボタン

    @MainActor
    func testAddMemoButtonExistsOnMapTab() throws {
        let addButton = app.buttons.matching(
            NSPredicate(format: "label == 'メモ追加' OR label == 'ADD MEMO'")
        ).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "メモ追加ボタンが表示されるべき")
    }
}
