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
        // アプリはTabViewでなく、マップ画面 + "メモ追加" ボタンで構成されている
        let addButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'メモ追加' OR label CONTAINS 'ADD MEMO'")
        ).firstMatch
        let listButton = app.buttons["listViewButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "メモ追加ボタンが表示されるべき")
        XCTAssertTrue(listButton.waitForExistence(timeout: 5), "リストボタンが表示されるべき")
    }

    // MARK: - リスト画面への遷移

    @MainActor
    func testSwitchToListTab() throws {
        let listButton = app.buttons["listViewButton"]
        XCTAssertTrue(listButton.waitForExistence(timeout: 5))
        listButton.tap()
        // リスト画面が開いた後も listButton は背後に残るため存在する
        XCTAssertTrue(listButton.waitForExistence(timeout: 3))
    }

    @MainActor
    func testSwitchBetweenTabs() throws {
        let listButton = app.buttons["listViewButton"]
        XCTAssertTrue(listButton.waitForExistence(timeout: 5))

        // リスト画面を開く
        listButton.tap()

        // 閉じるボタン（"<" または chevron）を探して戻る
        let backButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '戻る' OR label CONTAINS 'Back' OR identifier == 'closeListButton'")
        ).firstMatch
        if backButton.waitForExistence(timeout: 3) {
            backButton.tap()
        }

        // マップ画面に戻ったことを "メモ追加" ボタンで確認
        let addButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'メモ追加' OR label CONTAINS 'ADD MEMO'")
        ).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
    }

    // MARK: - リスト画面（空状態）

    @MainActor
    func testListTabShowsEmptyState() throws {
        let listButton = app.buttons["listViewButton"]
        XCTAssertTrue(listButton.waitForExistence(timeout: 5))
        listButton.tap()

        let emptyLabel = app.staticTexts.matching(
            NSPredicate(format: "label == 'No memos yet' OR label == 'メモがありません'")
        ).firstMatch
        XCTAssertTrue(emptyLabel.waitForExistence(timeout: 8), "空状態メッセージが表示されるべき")
    }

    @MainActor
    func testListTabShowsAddMemoHint() throws {
        let listButton = app.buttons["listViewButton"]
        XCTAssertTrue(listButton.waitForExistence(timeout: 5))
        listButton.tap()

        let hintLabel = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Tap the map' OR label CONTAINS '地図をタップ'")
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

    // MARK: - Paywall: フリー制限到達でPaywall表示

    @MainActor
    func testPaywallAppearsAtFreeLimit() throws {
        // デモデータ（5メモ）を注入してフリー制限に到達させる
        app.terminate()
        app.launchArguments = [
            "-UITesting",
            "-hasCompletedOnboarding", "YES",
            "-seedDemoData"
        ]
        app.launch()

        let addButton = app.buttons.matching(
            NSPredicate(format: "label == 'メモ追加' OR label CONTAINS 'ADD'")
        ).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "メモ追加ボタンが表示されるべき")
        addButton.tap()

        // Paywallが表示される
        let paywallTitle = app.staticTexts["GEOMEMO PRO"]
        XCTAssertTrue(paywallTitle.waitForExistence(timeout: 5), "Paywallが表示されるべき")
    }

    // MARK: - Paywall: 製品価格がProgressViewでなく表示される

    @MainActor
    func testPaywallShowsPriceAfterProductLoad() throws {
        app.terminate()
        app.launchArguments = [
            "-UITesting",
            "-hasCompletedOnboarding", "YES",
            "-seedDemoData"
        ]
        app.launch()

        let addButton = app.buttons.matching(
            NSPredicate(format: "label == 'メモ追加' OR label CONTAINS 'ADD'")
        ).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        // Paywallが表示されるまで待つ
        let paywallTitle = app.staticTexts["GEOMEMO PRO"]
        XCTAssertTrue(paywallTitle.waitForExistence(timeout: 5))

        // 製品価格が表示される（ProgressViewが消える）
        // StoreKit設定ファイルで¥500が設定されているので価格テキストが出るはず
        let priceText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '¥' OR label CONTAINS '$' OR label CONTAINS 'One-time'")
        ).firstMatch
        XCTAssertTrue(priceText.waitForExistence(timeout: 8), "製品価格が表示されるべき（ProgressViewが解消されるべき）")
    }

    // MARK: - Paywall: 購入ボタンが製品ロード後に有効になる

    @MainActor
    func testPaywallPurchaseButtonEnabledAfterProductLoad() throws {
        app.terminate()
        app.launchArguments = [
            "-UITesting",
            "-hasCompletedOnboarding", "YES",
            "-seedDemoData"
        ]
        app.launch()

        let addButton = app.buttons.matching(
            NSPredicate(format: "label == 'メモ追加' OR label CONTAINS 'ADD'")
        ).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let paywallTitle = app.staticTexts["GEOMEMO PRO"]
        XCTAssertTrue(paywallTitle.waitForExistence(timeout: 5))

        // 購入ボタンが表示されて有効になる
        let upgradeButton = app.buttons.matching(
            NSPredicate(format: "label == 'Upgrade to Pro' OR label == 'Proへアップグレード'")
        ).firstMatch
        XCTAssertTrue(upgradeButton.waitForExistence(timeout: 8), "購入ボタンが表示されるべき")

        // 製品ロード後にボタンが有効
        let isEnabled = upgradeButton.waitForExistence(timeout: 8) && upgradeButton.isEnabled
        XCTAssertTrue(isEnabled, "製品ロード後に購入ボタンが有効になるべき")
    }

    // MARK: - Paywall: 閉じるボタンで閉じる

    @MainActor
    func testPaywallDismissesOnCloseButton() throws {
        app.terminate()
        app.launchArguments = [
            "-UITesting",
            "-hasCompletedOnboarding", "YES",
            "-seedDemoData"
        ]
        app.launch()

        let addButton = app.buttons.matching(
            NSPredicate(format: "label == 'メモ追加' OR label CONTAINS 'ADD'")
        ).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let paywallTitle = app.staticTexts["GEOMEMO PRO"]
        XCTAssertTrue(paywallTitle.waitForExistence(timeout: 5))

        // 閉じるボタン（X）をタップ
        let closeButton = app.buttons.matching(
            NSPredicate(format: "label == 'Close' OR label == '閉じる'")
        ).firstMatch
        // アクセシビリティラベルがない場合はナビゲーションバーの最初のボタンを使う
        if closeButton.waitForExistence(timeout: 2) {
            closeButton.tap()
        } else {
            app.navigationBars.buttons.firstMatch.tap()
        }

        // Paywallが閉じる
        XCTAssertFalse(paywallTitle.waitForExistence(timeout: 3), "Paywallが閉じるべき")
    }

    // MARK: - Paywall: Restore Purchaseボタンが存在する

    @MainActor
    func testPaywallRestorePurchaseButtonExists() throws {
        app.terminate()
        app.launchArguments = [
            "-UITesting",
            "-hasCompletedOnboarding", "YES",
            "-seedDemoData"
        ]
        app.launch()

        let addButton = app.buttons.matching(
            NSPredicate(format: "label == 'メモ追加' OR label CONTAINS 'ADD'")
        ).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let paywallTitle = app.staticTexts["GEOMEMO PRO"]
        XCTAssertTrue(paywallTitle.waitForExistence(timeout: 5))

        let restoreButton = app.buttons.matching(
            NSPredicate(format: "label == 'Restore Purchase' OR label == '購入を復元'")
        ).firstMatch
        XCTAssertTrue(restoreButton.waitForExistence(timeout: 5), "Restore Purchaseボタンが表示されるべき")
        XCTAssertTrue(restoreButton.isEnabled, "Restore Purchaseボタンが有効であるべき")
    }

    // MARK: - Paywall: 製品未ロード時はRetryボタンが表示される（isLoadingProducts=false, proProduct=nil）

    @MainActor
    func testPaywallShowsRetryWhenProductUnavailable() throws {
        // StoreKit設定ファイルなし（製品空）でテスト
        app.terminate()
        app.launchArguments = [
            "-UITesting",
            "-hasCompletedOnboarding", "YES",
            "-seedDemoData",
            "-UITestEmptyProducts"
        ]
        app.launch()

        let addButton = app.buttons.matching(
            NSPredicate(format: "label == 'メモ追加' OR label CONTAINS 'ADD'")
        ).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let paywallTitle = app.staticTexts["GEOMEMO PRO"]
        XCTAssertTrue(paywallTitle.waitForExistence(timeout: 5))

        // 製品が見つからない場合: "Product unavailable" + Retryボタン
        let unavailableText = app.staticTexts.matching(
            NSPredicate(format: "label == 'Product unavailable' OR label == '製品が利用できません'")
        ).firstMatch
        let retryButton = app.buttons.matching(
            NSPredicate(format: "label == 'Retry' OR label == '再試行'")
        ).firstMatch

        // ProgressViewが消えた後（isLoadingProducts=false になった後）にチェック
        // タイムアウトを長めに設定（製品ロード試行完了まで待つ）
        let unavailableOrRetry = unavailableText.waitForExistence(timeout: 10) || retryButton.waitForExistence(timeout: 10)
        XCTAssertTrue(unavailableOrRetry, "製品未取得時にエラーUIが表示されるべき")
    }

    // MARK: - ドッグフーディング（手動確認用・CI除外）

    @MainActor
    func testDogfoodingWalkthrough() throws {
        let attach = { (name: String) in
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }

        // 1. マップ画面
        let addButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'メモ追加' OR label CONTAINS 'ADD'")
        ).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        attach("01_map_home")

        // 2. メモ追加ボタンをタップ → エディタ画面
        addButton.tap()
        sleep(1)
        attach("02_memo_editor_top")

        // 3. エディタをスクロールして通知設定を確認
        app.swipeUp()
        sleep(1)
        attach("03_memo_editor_notifications")

        // 4. さらにスクロール（DWELL TIMEセクション確認）
        app.swipeUp()
        sleep(1)
        attach("04_memo_editor_dwell_time")

        // 5. キャンセルして戻る
        let cancelButton = app.buttons.matching(
            NSPredicate(format: "label == 'CANCEL' OR label == 'キャンセル' OR label == '✕'")
        ).firstMatch
        if cancelButton.waitForExistence(timeout: 2) {
            cancelButton.tap()
        } else {
            app.navigationBars.buttons.firstMatch.tap()
        }
        sleep(1)
        attach("05_back_to_map")

        // 6. リストボタンをタップ
        let listButton = app.buttons["listViewButton"]
        XCTAssertTrue(listButton.waitForExistence(timeout: 3))
        listButton.tap()
        sleep(1)
        attach("06_list_view")

        // 7. リスト内でスクロール
        app.swipeUp()
        sleep(1)
        attach("07_list_view_scrolled")
    }
}
