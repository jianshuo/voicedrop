# SDUI 可定制首页 · Phase 1：iOS 渲染引擎 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## ⚠️ 交接状态（2026-06-28 — 接手的 agent 先读这里）

**为什么交接**：原会话所在机器只有 Xcode 26.3，**没装 iOS SDK / 模拟器运行时**（装 iOS 平台要 ~7GB），无法编译或跑测试。为避免提交未编译的 Swift 6 代码，Task 2 起的实现没有盲写。**请在装了 iOS SDK + 模拟器运行时的 Mac 上接手。**

**已完成并提交（分支 `design/sdui-homepage`）**
- 设计 spec：`docs/superpowers/specs/2026-06-28-voicedrop-sdui-homepage-design.md`
- 本实现计划（**每个文件的完整源码都在下面对应 Task 里，逐字可用**）
- Task 1 脚手架：`project.yml` 新增 `VoiceDropTests` target + `scheme.testTargets`；新增 `VoiceDropTests/SmokeTests.swift`。**已用 `xcodegen generate` 验证工程能正确生成并含测试 target**；但 `xcodebuild test` 未执行（本机无 SDK）。

**未开始：Task 2–7**（PageModel / PageStore / PageRenderer / HomeLists 抽取 / LibraryView 接线 / 文档）。照计划逐任务 TDD。

**接手前置（本机已做 / 你需要做）**
- xcodegen：本机已 `brew install xcodegen`(2.45.4)；你的机器若没有先装。
- `Secrets.xcconfig`（gitignore，不入库）：先 `cp Secrets.example.xcconfig Secrets.xcconfig` 填真实 `FILES_TOKEN`（记忆 `jianshuo-dev-files-transfer`）再 `xcodegen generate`。本会话用 `REPLACE_ME` 占位仅为生成工程。
- iOS 运行时：`xcodebuild -downloadPlatform iOS` 或 Xcode > Settings > Components 装一个 iOS 模拟器运行时，否则 `xcodebuild test` 没有目标设备。
- 后台隔离：本仓库 `.claude/settings.json`（**gitignore，不会被提交**）这次被设了 `{"worktree":{"bgIsolation":"none"}}`，以便在父目录非 git 仓库的后台会话里直接写文件。你若也是后台 agent 且 cwd 不在本仓库内，可能要同样处理（或用 EnterWorktree）。

**第一步**：`cd ~/code/voicedrop && xcodegen generate && xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 16' test` 确认 SmokeTests 绿，然后从 **Task 2** 起逐任务做。

---

**Goal:** 让 iOS app 能把一份 `users/<sub>/page.json`（服务端驱动 UI 文档）解码、校验、渲染成首页内容区；没有自定义 page.json 时原样显示现有原生首页（零回归）。

**Architecture:** 纯 Foundation 的 `PageNode` 模型 + 健壮解码器（未知节点降级为 `.unknown`，结构损坏返回 nil）；`PageStore` 拉 page.json 并用纯函数 `resolveTree` 决定回退；`PageRenderer` 把节点树递归渲染成 SwiftUI，`embed` 桥接到从 `LibraryView` 抽出的可复用列表子视图。`LibraryView` 变成「固定外壳 + (自定义页 ? PageRenderer : 原生首页)」。

**Tech Stack:** Swift 6（strict concurrency）、SwiftUI、`@Observable`、XcodeGen、XCTest、iOS 18 SDK。

## Global Constraints

- deploymentTarget：iOS **18.0**（project.yml 为准，非 README 写的 26）。
- `SWIFT_VERSION: "6.0"`，strict concurrency；`@MainActor @Observable final class` 是 store 的既有模式。
- 新增 `.swift` / 新 target 后**必须** `xcodegen generate`（工程不入库，由 project.yml 生成）。
- 网络：base = `https://jianshuo.dev/files/api`；token = `AuthStore.shared.bearer`；helper 在 `Networking.swift`（`req.setBearer(_:)`、`resp.isOK`、`resp.httpStatusCode`、`String.urlPathEncoded`）。
- page.json 的相对 key 固定为 `page.json`（下载 `download/page.json`，上传 `upload/page.json`）。
- 颜色/字重/对齐/动作/功能块/图标**全部白名单**，越界回落默认值，绝不抛错。
- 词表（已批准，v1 封闭集）：容器 `vstack|hstack|grid|spacer`；展示 `text|image`；磁贴 `card`(`tap`∈`record|openArticles|openCommunity|openSettings|openNote`)；内嵌 `embed`(`block`∈`recordButton|articleList|communityFeed|notePlaceholder`)。
- 设计单一真理源：`docs/superpowers/specs/2026-06-28-voicedrop-sdui-homepage-design.md`。
- 模拟器可跑纯 Foundation 单测；**真机才有麦克风**（Phase 1 不涉及录音/语音，模拟器足够）。
- **Phase 1 不做语音生成**（PageEditor DO + PageAgentSession 是 Phase 2 单独计划）。本计划产出的引擎用「手动往 R2 放一份 page.json」来端到端验证。

---

### Task 1: 新增 iOS 单元测试 target

**Files:**
- Modify: `project.yml`（新增 `VoiceDropTests` target + 给 `VoiceDrop` 加 scheme.testTargets）
- Create: `VoiceDropTests/SmokeTests.swift`

**Interfaces:**
- Produces: 一个可被 `xcodebuild ... test` 运行的测试 target `VoiceDropTests`，`@testable import VoiceDrop` 可用。后续所有任务的测试都放进 `VoiceDropTests/`。

- [ ] **Step 1: 在 project.yml 末尾新增测试 target**

在 `targets:` 下、`VoiceDropShare:` 之后追加：

```yaml
  VoiceDropTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: "18.0"
    sources:
      - path: VoiceDropTests
    dependencies:
      - target: VoiceDrop
    settings:
      base:
        SWIFT_VERSION: "6.0"
        GENERATE_INFOPLIST_FILE: "YES"
        PRODUCT_BUNDLE_IDENTIFIER: com.wangjianshuo.VoiceDropTests
        TARGETED_DEVICE_FAMILY: "1"
```

- [ ] **Step 2: 给 VoiceDrop 应用 target 挂上 scheme 的测试 target**

在 `VoiceDrop:` target 块内（与 `sources:` 同级）加：

```yaml
    scheme:
      testTargets:
        - VoiceDropTests
```

- [ ] **Step 3: 写一个冒烟测试**

`VoiceDropTests/SmokeTests.swift`：
```swift
import XCTest
@testable import VoiceDrop

final class SmokeTests: XCTestCase {
    func testTrue() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 4: 重新生成工程**

Run: `cd ~/code/voicedrop && xcodegen generate`
Expected: 成功，输出包含 `VoiceDropTests`。

- [ ] **Step 5: 跑测试，确认 target 通了**

Run: `cd ~/code/voicedrop && xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 16' test`
Expected: 编译成功，`SmokeTests.testTrue` PASS。
（若 `@testable import VoiceDrop` 报找不到模块：确认 xcodegen 已为该 unit-test target 自动写入 `TEST_HOST`/`BUNDLE_LOADER`；若没有，在上面 settings.base 里补 `TEST_HOST: "$(BUILT_PRODUCTS_DIR)/VoiceDrop.app/VoiceDrop"` 与 `BUNDLE_LOADER: "$(TEST_HOST)"` 后重跑 Step 4-5。）

- [ ] **Step 6: 提交**

```bash
cd ~/code/voicedrop
git add project.yml VoiceDropTests/SmokeTests.swift
git commit -m "test: 新增 iOS 单元测试 target VoiceDropTests"
```

---

### Task 2: PageNode 模型 + 健壮解码器

**Files:**
- Create: `VoiceDropApp/PageModel.swift`
- Test: `VoiceDropTests/PageModelTests.swift`

**Interfaces:**
- Produces:
  - `enum PageAlign: String { leading, center, trailing }`，`static func from(_ : Any?) -> PageAlign`（默认 `.leading`）
  - `enum PageWeight: String { regular, medium, semibold, bold }`，`from` 默认 `.regular`
  - `enum PageAction: String { record, openArticles, openCommunity, openSettings, openNote }`，`static func from(_ : Any?) -> PageAction?`（未知→nil）
  - `enum PageBlock: String { recordButton, articleList, communityFeed, notePlaceholder }`，`from` 未知→nil
  - `enum PageColorToken: String { ink, secondary, faint, accent, recordRed, greenDone, amberPending }`，`from` 默认 `.ink`
  - `enum PageIcons { static let allowed: Set<String>; static func sanitize(_ : Any?) -> String? }`
  - `indirect enum PageNode: Equatable { … case unknown }`，`static func parse(_ : Any?) -> PageNode`
  - `struct PageDocument: Equatable { var schema: Int; var version: Int; var root: PageNode; static func decode(_ : Data) -> PageDocument? }`

- [ ] **Step 1: 写失败测试**

`VoiceDropTests/PageModelTests.swift`：
```swift
import XCTest
@testable import VoiceDrop

final class PageModelTests: XCTestCase {
    private func doc(_ json: String) -> PageDocument? {
        PageDocument.decode(Data(json.utf8))
    }

    func testDecodesValidTree() {
        let d = doc("""
        { "schema":1, "version":3, "root": {
            "type":"vstack", "spacing":16, "padding":20, "align":"leading", "children":[
              { "type":"text", "value":"早安", "size":28, "weight":"bold", "color":"ink" },
              { "type":"grid", "columns":2, "children":[
                 { "type":"card", "title":"写文章", "icon":"doc.text", "tint":"accent", "tap":"openArticles" }
              ]},
              { "type":"embed", "block":"recordButton" }
            ] } }
        """)
        XCTAssertEqual(d?.version, 3)
        guard case let .vstack(spacing, padding, align, children)? = d?.root else { return XCTFail("root not vstack") }
        XCTAssertEqual(spacing, 16); XCTAssertEqual(padding, 20); XCTAssertEqual(align, .leading)
        XCTAssertEqual(children.count, 3)
        guard case .text(let v, let sz, let w, let c, _) = children[0] else { return XCTFail() }
        XCTAssertEqual(v, "早安"); XCTAssertEqual(sz, 28); XCTAssertEqual(w, .bold); XCTAssertEqual(c, .ink)
        guard case .grid(let cols, _, let gkids) = children[1] else { return XCTFail() }
        XCTAssertEqual(cols, 2)
        guard case .card(_, _, let icon, let tint, let tap) = gkids[0] else { return XCTFail() }
        XCTAssertEqual(icon, "doc.text"); XCTAssertEqual(tint, .accent); XCTAssertEqual(tap, .openArticles)
        guard case .embed(.recordButton) = children[2] else { return XCTFail() }
    }

    func testUnknownTypeBecomesUnknownNode() {
        let d = doc(#"{ "root": { "type":"vstack", "children":[ {"type":"blink"} ] } }"#)
        guard case let .vstack(_, _, _, kids)? = d?.root else { return XCTFail() }
        XCTAssertEqual(kids.first, .unknown)
    }

    func testBadTokensFallBackNotThrow() {
        let d = doc(#"{ "root": { "type":"text", "value":"x", "weight":"ultra", "color":"neon", "align":"justify" } }"#)
        guard case .text(_, _, let w, let c, let a)? = d?.root else { return XCTFail() }
        XCTAssertEqual(w, .regular); XCTAssertEqual(c, .ink); XCTAssertEqual(a, .leading)
    }

    func testMissingFieldsGetDefaults() {
        let d = doc(#"{ "root": { "type":"vstack" } }"#)
        guard case let .vstack(spacing, padding, _, kids)? = d?.root else { return XCTFail() }
        XCTAssertEqual(spacing, 12); XCTAssertEqual(padding, 0); XCTAssertTrue(kids.isEmpty)
    }

    func testGridColumnsClampedTo1Through4() {
        let hi = doc(#"{ "root": { "type":"grid", "columns":99 } }"#)
        let lo = doc(#"{ "root": { "type":"grid", "columns":0 } }"#)
        if case .grid(let c, _, _)? = hi?.root { XCTAssertEqual(c, 4) } else { XCTFail() }
        if case .grid(let c, _, _)? = lo?.root { XCTAssertEqual(c, 1) } else { XCTFail() }
    }

    func testDisallowedIconDropped() {
        let d = doc(#"{ "root": { "type":"card", "title":"t", "icon":"nuke.fill", "tap":"record" } }"#)
        guard case .card(_, _, let icon, _, _)? = d?.root else { return XCTFail() }
        XCTAssertNil(icon)
    }

    func testCardWithoutValidTapIsUnknown() {
        let d = doc(#"{ "root": { "type":"card", "title":"t", "tap":"launchMissiles" } }"#)
        XCTAssertEqual(d?.root, .unknown)
    }

    func testEmbedWithoutValidBlockIsUnknown() {
        let d = doc(#"{ "root": { "type":"embed", "block":"weather" } }"#)
        XCTAssertEqual(d?.root, .unknown)
    }

    func testStructurallyBrokenReturnsNil() {
        XCTAssertNil(doc("not json"))
        XCTAssertNil(doc(#"{ "noroot": true }"#))
    }

    func testUnknownRootTreatedAsBroken() {
        XCTAssertNil(doc(#"{ "root": { "type":"???" } }"#))
    }
}
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd ~/code/voicedrop && xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 16' test`
Expected: 编译失败（`PageDocument` / `PageNode` 未定义）。

- [ ] **Step 3: 写实现**

`VoiceDropApp/PageModel.swift`：
```swift
import Foundation

// MARK: - 白名单枚举（越界回落默认值，绝不抛错）

enum PageAlign: String, Equatable {
    case leading, center, trailing
    static func from(_ s: Any?) -> PageAlign { (s as? String).flatMap(PageAlign.init(rawValue:)) ?? .leading }
}

enum PageWeight: String, Equatable {
    case regular, medium, semibold, bold
    static func from(_ s: Any?) -> PageWeight { (s as? String).flatMap(PageWeight.init(rawValue:)) ?? .regular }
}

enum PageAction: String, Equatable {
    case record, openArticles, openCommunity, openSettings, openNote
    static func from(_ s: Any?) -> PageAction? { (s as? String).flatMap(PageAction.init(rawValue:)) }
}

enum PageBlock: String, Equatable {
    case recordButton, articleList, communityFeed, notePlaceholder
    static func from(_ s: Any?) -> PageBlock? { (s as? String).flatMap(PageBlock.init(rawValue:)) }
}

enum PageColorToken: String, Equatable {
    case ink, secondary, faint, accent, recordRed, greenDone, amberPending
    static func from(_ s: Any?) -> PageColorToken { (s as? String).flatMap(PageColorToken.init(rawValue:)) ?? .ink }
}

enum PageIcons {
    /// SF Symbol 白名单。新增图标只能往这里加。
    static let allowed: Set<String> = [
        "doc.text", "person.2", "mic", "mic.circle", "brain", "lightbulb",
        "square.grid.2x2", "star", "bookmark", "waveform", "house", "gearshape",
        "pencil", "tray", "bubble.left.and.bubble.right"
    ]
    static func sanitize(_ s: Any?) -> String? {
        guard let n = s as? String, allowed.contains(n) else { return nil }
        return n
    }
}

// MARK: - 节点

indirect enum PageNode: Equatable {
    case vstack(spacing: Double, padding: Double, align: PageAlign, children: [PageNode])
    case hstack(spacing: Double, padding: Double, align: PageAlign, children: [PageNode])
    case grid(columns: Int, spacing: Double, children: [PageNode])
    case spacer(size: Double?)
    case text(value: String, size: Double, weight: PageWeight, color: PageColorToken, align: PageAlign)
    case image(source: String, aspect: Double?, corner: Double)
    case card(title: String, subtitle: String?, icon: String?, tint: PageColorToken, tap: PageAction)
    case embed(block: PageBlock)
    case unknown

    /// 把任意 JSON 值递归解析成节点。无法识别 → `.unknown`（永不抛错）。
    static func parse(_ any: Any?) -> PageNode {
        guard let dict = any as? [String: Any], let type = dict["type"] as? String else { return .unknown }
        func num(_ k: String, _ d: Double) -> Double { (dict[k] as? NSNumber)?.doubleValue ?? d }
        func optNum(_ k: String) -> Double? { (dict[k] as? NSNumber)?.doubleValue }
        func kids() -> [PageNode] { (dict["children"] as? [Any])?.map(PageNode.parse) ?? [] }

        switch type {
        case "vstack":
            return .vstack(spacing: num("spacing", 12), padding: num("padding", 0),
                           align: .from(dict["align"]), children: kids())
        case "hstack":
            return .hstack(spacing: num("spacing", 12), padding: num("padding", 0),
                           align: .from(dict["align"]), children: kids())
        case "grid":
            let cols = max(1, min(4, (dict["columns"] as? NSNumber)?.intValue ?? 2))
            return .grid(columns: cols, spacing: num("spacing", 12), children: kids())
        case "spacer":
            return .spacer(size: optNum("size"))
        case "text":
            return .text(value: (dict["value"] as? String) ?? "", size: num("size", 17),
                         weight: .from(dict["weight"]), color: .from(dict["color"]),
                         align: .from(dict["align"]))
        case "image":
            guard let src = dict["source"] as? String, !src.isEmpty else { return .unknown }
            return .image(source: src, aspect: optNum("aspect"), corner: num("corner", 8))
        case "card":
            guard let tap = PageAction.from(dict["tap"]) else { return .unknown }
            return .card(title: (dict["title"] as? String) ?? "",
                         subtitle: dict["subtitle"] as? String,
                         icon: PageIcons.sanitize(dict["icon"]),
                         tint: .from(dict["tint"]), tap: tap)
        case "embed":
            guard let block = PageBlock.from(dict["block"]) else { return .unknown }
            return .embed(block: block)
        default:
            return .unknown
        }
    }
}

// MARK: - 文档

struct PageDocument: Equatable {
    var schema: Int
    var version: Int
    var root: PageNode

    /// 解码 + 校验。结构性损坏（非对象 / 无 root / root 不可渲染）→ nil，交给调用方回退。
    static func decode(_ data: Data) -> PageDocument? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rootAny = obj["root"] else { return nil }
        let root = PageNode.parse(rootAny)
        if case .unknown = root { return nil }
        return PageDocument(schema: (obj["schema"] as? NSNumber)?.intValue ?? 1,
                            version: (obj["version"] as? NSNumber)?.intValue ?? 1,
                            root: root)
    }
}
```

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd ~/code/voicedrop && xcodegen generate && xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 16' test`
Expected: `PageModelTests` 全 PASS。

- [ ] **Step 5: 提交**

```bash
cd ~/code/voicedrop
git add VoiceDropApp/PageModel.swift VoiceDropTests/PageModelTests.swift
git commit -m "feat: page.json 节点模型 + 健壮解码器（未知降级、坏 JSON 返回 nil）"
```

---

### Task 3: PageStore 回退决策 + 拉取

**Files:**
- Create: `VoiceDropApp/PageStore.swift`
- Test: `VoiceDropTests/PageStoreTests.swift`

**Interfaces:**
- Consumes: `PageDocument.decode(_:)`、`PageNode`（Task 2）；`Networking.swift` 的 `setBearer`/`isOK`/`httpStatusCode`；`AuthStore.shared.bearer`。
- Produces:
  - `static func PageStore.resolveTree(status: Int, data: Data, lastGood: PageNode?) -> (tree: PageNode?, lastGood: PageNode?)`（纯函数，`tree==nil` 表示「渲染原生默认首页」）
  - `@MainActor @Observable final class PageStore { var tree: PageNode?; var loading: Bool; func load() async }`

- [ ] **Step 1: 写失败测试**

`VoiceDropTests/PageStoreTests.swift`：
```swift
import XCTest
@testable import VoiceDrop

final class PageStoreTests: XCTestCase {
    private let good = Data(#"{ "root": { "type":"vstack", "children":[ {"type":"embed","block":"articleList"} ] } }"#.utf8)
    private var goodRoot: PageNode { PageDocument.decode(good)!.root }

    func test404MeansNativeHome() {
        let r = PageStore.resolveTree(status: 404, data: Data(), lastGood: goodRoot)
        XCTAssertNil(r.tree)   // nil → 原生首页（即使之前有 lastGood，404=被重置）
    }

    func testValidIsAdoptedAndRemembered() {
        let r = PageStore.resolveTree(status: 200, data: good, lastGood: nil)
        XCTAssertEqual(r.tree, goodRoot)
        XCTAssertEqual(r.lastGood, goodRoot)
    }

    func testBrokenJsonKeepsLastGood() {
        let r = PageStore.resolveTree(status: 200, data: Data("garbage".utf8), lastGood: goodRoot)
        XCTAssertEqual(r.tree, goodRoot)
    }

    func testTransientErrorKeepsLastGood() {
        let r = PageStore.resolveTree(status: 500, data: Data(), lastGood: goodRoot)
        XCTAssertEqual(r.tree, goodRoot)
    }

    func testBrokenJsonWithNoLastGoodFallsToNative() {
        let r = PageStore.resolveTree(status: 200, data: Data("garbage".utf8), lastGood: nil)
        XCTAssertNil(r.tree)
    }
}
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd ~/code/voicedrop && xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 16' test`
Expected: 编译失败（`PageStore` 未定义）。

- [ ] **Step 3: 写实现**

`VoiceDropApp/PageStore.swift`：
```swift
import Foundation
import Observation

/// 拉取并持有用户的自定义首页树。`tree == nil` 表示没有自定义页 —— 渲染层回退到
/// 现有原生首页（零回归）。解码/回退的决策抽成纯函数 `resolveTree` 以便单测。
@MainActor
@Observable
final class PageStore {
    var tree: PageNode?       // nil → 原生默认首页
    var loading = false

    private let base = URL(string: "https://jianshuo.dev/files/api")!
    private var token: String { AuthStore.shared.bearer }
    private var lastGood: PageNode?

    /// 纯决策：给定 HTTP 状态 + 响应体 + 上一份好的树，决定新的 (tree, lastGood)。
    static func resolveTree(status: Int, data: Data, lastGood: PageNode?) -> (tree: PageNode?, lastGood: PageNode?) {
        if status == 404 { return (nil, lastGood) }                                  // 无自定义页 / 被重置 → 原生
        guard (200..<300).contains(status) else { return (lastGood, lastGood) }      // 瞬时错误 → 保上一份
        if let doc = PageDocument.decode(data) { return (doc.root, doc.root) }        // 正常 → 采用
        return (lastGood, lastGood)                                                   // 坏 JSON → 保上一份（无则 nil→原生）
    }

    func load() async {
        guard !token.isEmpty else { tree = nil; return }
        loading = true; defer { loading = false }
        guard let url = URL(string: "\(base.absoluteString)/download/page.json") else { return }
        var req = URLRequest(url: url)
        req.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let r = Self.resolveTree(status: resp.httpStatusCode, data: data, lastGood: lastGood)
            tree = r.tree; lastGood = r.lastGood
        } catch {
            let r = Self.resolveTree(status: 0, data: Data(), lastGood: lastGood)     // 网络异常按瞬时错误
            tree = r.tree; lastGood = r.lastGood
        }
    }
}
```

- [ ] **Step 4: 跑测试，确认通过**

Run: `cd ~/code/voicedrop && xcodegen generate && xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 16' test`
Expected: `PageStoreTests` 全 PASS。

- [ ] **Step 5: 提交**

```bash
cd ~/code/voicedrop
git add VoiceDropApp/PageStore.swift VoiceDropTests/PageStoreTests.swift
git commit -m "feat: PageStore 拉取 page.json + 纯函数回退决策（404→原生 / 坏→上一份）"
```

---

### Task 4: 抽出可复用列表子视图（embed 的桥）

**Files:**
- Modify: `VoiceDropApp/LibraryView.swift`
- Create: `VoiceDropApp/HomeLists.swift`

**Interfaces:**
- Consumes: 现有 `LibraryStore`、`Uploader`、`CommunityStore`、`Recording`、`CommunityPost`、`Theme`。
- Produces（供 Task 6 与 embed 复用）：
  - `struct RecordingsList: View`，init：`(store: LibraryStore, uploader: Uploader, onSelect: (Recording)->Void, onDelete: (Recording)->Void, onReprocess: (Recording)->Void)`
  - `struct CommunityFeedList: View`，init：`(store: CommunityStore, onSelect: (CommunityPost)->Void, onUnshare: (CommunityPost)->Void)`
- 行为不变：这两个 view 的 body 就是把 `LibraryView` 现有 `recordingsContent`/`communityContent` 的 `List{…}` 主体**原样搬出**，把对 `tab`/`selectedRec`/`confirmDelete` 等的直接引用换成 init 传入的闭包/参数。`rows` 计算属性随 `RecordingsList` 一起搬（它只依赖 store+uploader）。卡片绘制方法 `rowCard`/`statusBadge`/`badge`/`communityCard`/`message`/`communityDate` 一并移过去（保持 `private`）。

- [ ] **Step 1: 新建 HomeLists.swift，搬入两个列表视图**

`VoiceDropApp/HomeLists.swift`（把 `LibraryView` 里的对应私有方法整体迁移；下面是结构骨架，方法体逐字搬运、仅把状态引用改成参数/闭包）：
```swift
import SwiftUI

/// 「我的录音」列表主体——从 LibraryView 抽出，供原生首页与 page.json 的
/// `embed: articleList` 复用。选中/删除/重生成都通过闭包上交给外壳处理。
struct RecordingsList: View {
    let store: LibraryStore
    let uploader: Uploader
    let onSelect: (Recording) -> Void
    let onDelete: (Recording) -> Void
    let onReprocess: (Recording) -> Void

    // ← 从 LibraryView 搬来：`rows` 计算属性（仅依赖 store + uploader）
    private var rows: [Recording] { /* 原 LibraryView.rows 逐字 */ fatalError("move verbatim") }

    var body: some View {
        // ← 从 LibraryView.recordingsContent 搬来；List 行里
        //   Button{ selectedRec = rec } → Button{ onSelect(rec) }
        //   confirmDelete = rec → onDelete(rec)
        //   长按 badge confirmReprocess = rec → onReprocess(rec)
        EmptyView() // placeholder for the moved body
    }

    // ← 搬来：rowCard / statusBadge / badge / message（保持 private）
}

/// 「VD社区」列表主体——供原生首页与 `embed: communityFeed` 复用。
struct CommunityFeedList: View {
    let store: CommunityStore
    let onSelect: (CommunityPost) -> Void
    let onUnshare: (CommunityPost) -> Void

    var body: some View {
        // ← 从 LibraryView.communityContent 搬来；selectedPost = post → onSelect(post)
        //   confirmUnshare = post → onUnshare(post)
        EmptyView() // placeholder for the moved body
    }

    // ← 搬来：communityCard / communityDate / message（message 可与上面共用一份，见 Step 2）
}
```
> 注意：`message(_:_:)` 在两处都用到——抽成一个文件内顶层 `func homeMessage(_ title: String, _ subtitle: String) -> some View` 供两个 view 复用，避免重复。

- [ ] **Step 2: 在 LibraryView 里改用新子视图**

`LibraryView.recordingsContent` 改为：
```swift
@ViewBuilder private var recordingsContent: some View {
    RecordingsList(store: store, uploader: uploader,
                   onSelect: { selectedRec = $0 },
                   onDelete: { confirmDelete = $0 },
                   onReprocess: { confirmReprocess = $0 })
}
```
`LibraryView.communityContent` 改为：
```swift
@ViewBuilder private var communityContent: some View {
    CommunityFeedList(store: community,
                      onSelect: { selectedPost = $0 },
                      onUnshare: { confirmUnshare = $0 })
}
```
删除 `LibraryView` 中已搬走的 `rows`、`rowCard`、`statusBadge`、`badge`、`communityCard`、`communityDate`、`message`（避免重复定义）。`recordButton`、`topBar`、`tabHeader`、导航/alert 等留在 `LibraryView`。

- [ ] **Step 3: 重新生成并编译**

Run: `cd ~/code/voicedrop && xcodegen generate && xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 4: 手动验证首页零变化**

模拟器跑起来：我的录音 / VD社区 两个 tab、录音键、滑动删除、长按 badge 重生成——**与改动前完全一致**（这一步是纯重构）。

- [ ] **Step 5: 提交**

```bash
cd ~/code/voicedrop
git add VoiceDropApp/HomeLists.swift VoiceDropApp/LibraryView.swift
git commit -m "refactor: 抽出 RecordingsList / CommunityFeedList 供 SDUI embed 复用（行为不变）"
```

---

### Task 5: PageRenderer 渲染引擎

**Files:**
- Create: `VoiceDropApp/PageRenderer.swift`
- Test: `VoiceDropTests/PageRenderMappingTests.swift`

**Interfaces:**
- Consumes: `PageNode`/`PageColorToken`/`PageWeight`/`PageAlign`/`PageAction`/`PageBlock`（Task 2）、`Theme`、`RecordingsList`/`CommunityFeedList`（Task 4）。
- Produces:
  - `struct PageContext { let articleList: AnyView; let communityFeed: AnyView; let recordButton: AnyView; let notePlaceholder: AnyView; let loadPhoto: (String) async -> Data?; let onTap: (PageAction) -> Void }`
  - `struct PageRenderer: View { let node: PageNode; let ctx: PageContext }`
  - 纯映射（可单测）：`PageColorToken.color: Color`、`PageWeight.swiftUI: Font.Weight`、`PageAlign.horizontal/frameAlignment/textAlignment`

- [ ] **Step 1: 写失败测试（只测纯映射，View 树靠编译+手动验）**

`VoiceDropTests/PageRenderMappingTests.swift`：
```swift
import XCTest
import SwiftUI
@testable import VoiceDrop

final class PageRenderMappingTests: XCTestCase {
    func testColorTokensMapToTheme() {
        XCTAssertEqual(PageColorToken.accent.color, Theme.accent)
        XCTAssertEqual(PageColorToken.recordRed.color, Theme.recordRed)
        XCTAssertEqual(PageColorToken.ink.color, Theme.ink)
    }
    func testWeightMapping() {
        XCTAssertEqual(PageWeight.bold.swiftUI, .bold)
        XCTAssertEqual(PageWeight.regular.swiftUI, .regular)
    }
    func testAlignMapping() {
        XCTAssertEqual(PageAlign.trailing.horizontal, .trailing)
        XCTAssertEqual(PageAlign.center.textAlignment, .center)
    }
}
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `cd ~/code/voicedrop && xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 16' test`
Expected: 编译失败（映射未定义）。

- [ ] **Step 3: 写实现**

`VoiceDropApp/PageRenderer.swift`：
```swift
import SwiftUI

// MARK: - 纯映射（白名单 token → SwiftUI 值）

extension PageColorToken {
    var color: Color {
        switch self {
        case .ink: Theme.ink
        case .secondary: Theme.secondary
        case .faint: Theme.faint
        case .accent: Theme.accent
        case .recordRed: Theme.recordRed
        case .greenDone: Theme.greenDone
        case .amberPending: Theme.amberPending
        }
    }
}
extension PageWeight {
    var swiftUI: Font.Weight {
        switch self { case .regular: .regular; case .medium: .medium; case .semibold: .semibold; case .bold: .bold }
    }
}
extension PageAlign {
    var horizontal: HorizontalAlignment { switch self { case .leading: .leading; case .center: .center; case .trailing: .trailing } }
    var frameAlignment: Alignment { switch self { case .leading: .leading; case .center: .center; case .trailing: .trailing } }
    var textAlignment: TextAlignment { switch self { case .leading: .leading; case .center: .center; case .trailing: .trailing } }
}

// MARK: - 渲染上下文（embed 桥 + 动作回调）

struct PageContext {
    let articleList: AnyView
    let communityFeed: AnyView
    let recordButton: AnyView
    let notePlaceholder: AnyView
    let loadPhoto: (String) async -> Data?
    let onTap: (PageAction) -> Void
}

// MARK: - 递归渲染器

struct PageRenderer: View {
    let node: PageNode
    let ctx: PageContext
    var body: some View { Self.render(node, ctx) }

    @MainActor static func render(_ n: PageNode, _ ctx: PageContext) -> AnyView {
        switch n {
        case let .vstack(spacing, padding, align, children):
            return AnyView(VStack(alignment: align.horizontal, spacing: spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, c in render(c, ctx) }
            }.padding(padding).frame(maxWidth: .infinity, alignment: align.frameAlignment))

        case let .hstack(spacing, padding, align, children):
            return AnyView(HStack(spacing: spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, c in render(c, ctx) }
            }.padding(padding).frame(maxWidth: .infinity, alignment: align.frameAlignment))

        case let .grid(columns, spacing, children):
            let cols = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns)
            return AnyView(LazyVGrid(columns: cols, spacing: spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, c in render(c, ctx) }
            })

        case let .spacer(size):
            return AnyView(size.map { Spacer().frame(height: $0) } ?? Spacer())

        case let .text(value, size, weight, color, align):
            return AnyView(Text(value)
                .font(.system(size: size, weight: weight.swiftUI))
                .foregroundStyle(color.color)
                .multilineTextAlignment(align.textAlignment)
                .frame(maxWidth: .infinity, alignment: align.frameAlignment))

        case let .image(source, aspect, corner):
            return AnyView(PageImage(source: source, aspect: aspect, corner: corner, loadPhoto: ctx.loadPhoto))

        case let .card(title, subtitle, icon, tint, tap):
            return AnyView(Button { ctx.onTap(tap) } label: {
                HStack(spacing: 13) {
                    if let icon {
                        RoundedRectangle(cornerRadius: Theme.R.card).fill(tint.color.opacity(0.12))
                            .frame(width: 42, height: 42)
                            .overlay(Image(systemName: icon).font(.system(size: 17)).foregroundStyle(tint.color))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                        if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.chevron)
                }
                .padding(.vertical, 14).padding(.horizontal, 15)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.borderChrome, lineWidth: 1))
                .cardChromeShadow()
            }.buttonStyle(.plain))

        case let .embed(block):
            switch block {
            case .articleList: return ctx.articleList
            case .communityFeed: return ctx.communityFeed
            case .recordButton: return ctx.recordButton
            case .notePlaceholder: return ctx.notePlaceholder
            }

        case .unknown:
            return AnyView(EmptyView())
        }
    }
}

/// `image` 节点：`asset:<name>` 用 bundle 图，`photo:<relKey>` 通过 ctx.loadPhoto 异步拉。
private struct PageImage: View {
    let source: String
    let aspect: Double?
    let corner: Double
    let loadPhoto: (String) async -> Data?
    @State private var data: Data?

    var body: some View {
        Group {
            if source.hasPrefix("asset:") {
                Image(String(source.dropFirst("asset:".count))).resizable().scaledToFill()
            } else if let data, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Rectangle().fill(Theme.tileNeutral)
            }
        }
        .aspectRatio(aspect ?? 1, contentMode: .fill)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .task {
            guard source.hasPrefix("photo:"), data == nil else { return }
            data = await loadPhoto(String(source.dropFirst("photo:".count)))
        }
    }
}
```

- [ ] **Step 4: 跑测试 + 编译**

Run: `cd ~/code/voicedrop && xcodegen generate && xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 16' test`
Expected: 映射测试 PASS、整体编译成功。

- [ ] **Step 5: 提交**

```bash
cd ~/code/voicedrop
git add VoiceDropApp/PageRenderer.swift VoiceDropTests/PageRenderMappingTests.swift
git commit -m "feat: PageRenderer 递归渲染 page.json 节点树（embed 桥 + token 映射）"
```

---

### Task 6: 把 PageRenderer 接进 LibraryView 外壳

**Files:**
- Modify: `VoiceDropApp/LibraryView.swift`

**Interfaces:**
- Consumes: `PageStore`（Task 3）、`PageRenderer`/`PageContext`（Task 5）、`RecordingsList`/`CommunityFeedList`（Task 4）。
- 行为：`pageStore.tree == nil` → 原样渲染现有原生首页（tabHeader + recordingsContent/communityContent）；`tree != nil` → 渲染 `PageRenderer(tree, ctx)`（外壳 topBar 始终在）。`embed` 的 articleList/communityFeed 复用同一批闭包（onSelect/onDelete 走既有 `selectedRec`/`confirmDelete` 状态与导航）。recordButton embed = 复用现有 `recordButton`。

- [ ] **Step 1: 在 LibraryView 加入 PageStore 与渲染分支**

加状态：
```swift
@State private var pageStore = PageStore()
```
`mainContent` 的内容区改为按 tree 分支（topBar 始终在最上）：
```swift
private var mainContent: some View {
    VStack(spacing: 0) {
        topBar
        if let tree = pageStore.tree {
            ScrollView { PageRenderer(node: tree, ctx: pageContext) }
        } else {
            tabHeader
            if tab == .recordings { recordingsContent } else { communityContent }
        }
    }
    .background(Theme.appBG.ignoresSafeArea())
    .overlay(alignment: .bottom) { if pageStore.tree == nil && tab == .recordings { recordButton } else { EmptyView() } }
    // …（导航 destinations / fullScreenCover / alerts 原样保留）
}
```
在 `.task{…}` 里追加 `await pageStore.load()`；`scenePhase == .active` 分支里也追加 `Task { await pageStore.load() }`。

- [ ] **Step 2: 构造 PageContext**

在 `LibraryView` 内加：
```swift
private var pageContext: PageContext {
    PageContext(
        articleList: AnyView(RecordingsList(store: store, uploader: uploader,
            onSelect: { selectedRec = $0 }, onDelete: { confirmDelete = $0 }, onReprocess: { confirmReprocess = $0 })),
        communityFeed: AnyView(CommunityFeedList(store: community,
            onSelect: { selectedPost = $0 }, onUnshare: { confirmUnshare = $0 })),
        recordButton: AnyView(recordButton),
        notePlaceholder: AnyView(NotePlaceholder()),
        loadPhoto: { await store.photoData(fullKey: $0) },
        onTap: { handlePageAction($0) }
    )
}

private func handlePageAction(_ action: PageAction) {
    switch action {
    case .record: showRecord = true
    case .openArticles: tab = .recordings
    case .openCommunity: tab = .community; Task { await community.load() }
    case .openSettings: showSettings = true
    case .openNote: break   // 占位：Phase 1 无动作
    }
}
```
加占位视图（同文件或 HomeLists.swift）：
```swift
struct NotePlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain").font(.system(size: 28)).foregroundStyle(Theme.faint)
            Text("思考 · 即将推出").font(.system(size: 15)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.borderChrome, lineWidth: 1))
        .padding(.horizontal, 16)
    }
}
```

- [ ] **Step 3: 重新生成并编译**

Run: `cd ~/code/voicedrop && xcodegen generate && xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 4: 端到端手动验证（无 Phase 2 也能测）**

1. 不放 page.json：首页 = 原生两栏（零回归）。
2. 用 curl 往自己的 R2 放一份自定义 page.json（token 在 `~/code/.env` 的 `FILES_TOKEN`；anon 用户用 app 设置里的 access token）：
   ```bash
   curl -X PUT "https://jianshuo.dev/files/api/upload/page.json" \
     -H "Authorization: Bearer <你的 token>" -H "Content-Type: application/json" \
     --data '{"schema":1,"version":1,"root":{"type":"vstack","spacing":16,"padding":20,"children":[
       {"type":"text","value":"早安，建硕","size":28,"weight":"bold","color":"ink"},
       {"type":"grid","columns":2,"spacing":12,"children":[
         {"type":"card","title":"写文章","icon":"doc.text","tint":"accent","tap":"openArticles"},
         {"type":"card","title":"看社区","icon":"person.2","tint":"accent","tap":"openCommunity"},
         {"type":"card","title":"思考","icon":"brain","tint":"secondary","tap":"openNote"}],
       },
       {"type":"embed","block":"articleList"}]}}'
   ```
   重进 app：首页变成自定义布局；点「写文章」切到录音 tab、点「看社区」切社区、文章列表内嵌可点进详情。
3. 放一份坏 JSON：首页回退（上一份好的或原生），**不白屏**。
4. 删除 page.json（DELETE `file/page.json`）：回原生首页。

- [ ] **Step 5: 提交**

```bash
cd ~/code/voicedrop
git add VoiceDropApp/LibraryView.swift VoiceDropApp/HomeLists.swift
git commit -m "feat: LibraryView 外壳接入 PageRenderer（有自定义页则渲染，否则原生首页）"
```

---

### Task 7: 文档与契约更新

**Files:**
- Modify: `STATE.md`
- Modify: `docs/superpowers/specs/2026-06-28-voicedrop-sdui-homepage-design.md`

- [ ] **Step 1: STATE.md 增补 R2 契约一条**

在「R2 layout & marker conventions」列表加：
```
- `users/<sub>/page.json` — 用户自定义首页(SDUI 文档) `{schema,version,root:<node>}`。缺失/损坏 → app 渲染原生默认首页(零回归)。词表见 spec 2026-06-28-voicedrop-sdui-homepage-design.md。Phase 1 = iOS 渲染引擎；Phase 2 = 语音生成(PageEditor DO)。
```
并在「iOS app」段注明 `LibraryView` 现在是「固定外壳 + (自定义页?PageRenderer:原生首页)」，新增 `PageModel/PageStore/PageRenderer/HomeLists`。

- [ ] **Step 2: spec 增补一条「Phase 1 落地说明」**

在 spec 末尾加：默认首页采用「tree==nil → 原生首页」而非内置默认 page.json 树（等价结果、更低风险、词表不需要 `tabs`）。

- [ ] **Step 3: 提交**

```bash
cd ~/code/voicedrop
git add STATE.md docs/superpowers/specs/2026-06-28-voicedrop-sdui-homepage-design.md
git commit -m "docs: 记录 page.json R2 契约 + Phase 1 默认首页采用原生回退"
```

---

## Self-Review（对照 spec）

- **组件模型=混合**：Task 2 词表含容器+展示+card+embed ✓
- **安全壳=取代+固定外壳**：Task 6 topBar 始终在、内容区分支 ✓
- **v1 只包现有功能 + 思考占位**：embed 四种、`NotePlaceholder` ✓
- **校验/回退永不崩**：Task 2 `.unknown`/nil + Task 3 `resolveTree` + Task 6 验证 ✓
- **测试**：解码器(Task2)、回退(Task3)、token 映射(Task5)单测；View 树编译+手动 ✓
- **类型一致性**：`PageNode`/`PageContext`/`resolveTree`/各枚举签名跨任务一致 ✓
- **未覆盖（有意，属 Phase 2）**：语音生成 PageEditor DO、PageAgentSession、「编辑首页」入口、服务端 schema 校验、`llmlogs`。
- **占位说明**：Task 4 的 view body 写「逐字搬运」而非贴 150 行——这是对既有代码的机械迁移，不是 TBD。

---

## Phase 2 预告（另立计划）

`agent/src/` 新增 `PageEditor` DO（照抄 `ArticleEditor`）+ 服务端 schema 校验 + 词表系统提示；客户端 `PageAgentSession.swift`（照抄 `ArticleAgentSession`）+ 齿轮菜单「编辑首页」hold-to-talk；`agent/test/` 加校验测试。建在 Phase 1 引擎之上。
