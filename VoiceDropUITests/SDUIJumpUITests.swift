import XCTest

/// SDUI 自定义页的跳转语义端到端验证：点卡片 → 露出原生 tab + 「我的首页」
/// 返回胶囊 → 点胶囊回到自定义页。页面树用 -sduiFixedPage 注入，不依赖云端。
final class SDUIJumpUITests: XCTestCase {
    private let fourBlocks = """
    {"schema":1,"version":1,"root":{"type":"vstack","spacing":18,"padding":20,"children":[
      {"type":"text","value":"你好，建硕","size":30,"weight":"bold","color":"ink"},
      {"type":"grid","columns":2,"spacing":14,"children":[
        {"type":"card","title":"写文章","icon":"doc.text","tint":"accent","tap":"openArticles"},
        {"type":"card","title":"看社区","icon":"person.2","tint":"recordRed","tap":"openCommunity"},
        {"type":"card","title":"思考","icon":"brain","tint":"amberPending","tap":"openNote"},
        {"type":"card","title":"设置","icon":"gearshape","tint":"secondary","tap":"openSettings"}]}]}}
    """

    @MainActor
    func testCardJumpsToNativeTabAndHomeChipReturns() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-sduiFixedPage", fourBlocks]
        app.launch()

        // 自定义页渲染出来了
        let card = app.staticTexts["写文章"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "自定义页没渲染出四大块")

        // 点「写文章」→ 临时收起自定义页，露出原生「我的录音」tab + 返回胶囊
        card.tap()
        let homeChip = app.staticTexts["我的首页"]
        XCTAssertTrue(homeChip.waitForExistence(timeout: 5), "点卡片后没露出原生 tab 的返回胶囊")
        XCTAssertTrue(app.buttons["我的录音"].exists, "原生 tab 头没出现")

        // 点「我的首页」→ 回到自定义页
        homeChip.tap()
        XCTAssertTrue(app.staticTexts["你好，建硕"].waitForExistence(timeout: 5), "点返回胶囊后没回到自定义页")
        XCTAssertFalse(homeChip.exists, "回到自定义页后返回胶囊应消失")
    }
}
