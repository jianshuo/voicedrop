# VoiceDrop

**一键录音，停止即自动上传，服务端挖成文章——一个口述捕捉器。** 录下来的音频进入 `jianshuo.dev/files`（R2 收件箱），Worker 转写 + 挖文章后推回 App。

这个 repo 装 **iOS App**（`VoiceDropApp/` + 分享扩展 `VoiceDropShare/`），另有微信发布 relay（`mining/relay_server.py`，跑在 Tokyo VPS）。服务端 Worker 在 `~/code/jianshuo.dev/agent`。

---

## iOS App（本 repo）

### 行为

- 打开 App → 录音库列表（主屏）；点红键 → 全屏录音（出现即开录，计时器 + 停止钮）。
- 点停止 → 录音（m4a/AAC，单声道 64kbps）改成富文件名后立即 PUT 上传，回到列表（列表行显示「正在上传/转写/挖文章」直到成文）。
- 断网/失败 → 录音留在本地待传队列，下次回前台/网络恢复自动重传。**绝不丢录音。**
- 来电等中断 → 当作一次停止收尾，不丢已录部分。
- 成文后：详情页可语音修改（按住说话）、追问、发微信公众号、分享社区/小红书。

### 文件名（自描述）

停止时拼出富文件名再上传，便于在收件箱列表里一眼辨认：

```
VoiceDrop-2026-06-18-143052-0m33s-Thu-Afternoon-Shanghai-Xuhui.m4a
└─前缀──┘ └──时间戳───┘ └时长┘ └星期┘└─时段──┘ └──城市-城区──┘
```

- **全 ASCII**（英文地名，去掉所有非字母字符）——URL / R2 key / curl 全程干净。
- **`VoiceDrop-` 前缀 + `.m4a` 后缀不变**——挖文章 skill 靠这两个认领，中间字段随便加。
- 地点 = CoreLocation 粗定位 + CLGeocoder（en locale）反向地理编码，**best-effort、3s 超时、绝不阻塞录音**；拒绝定位/室内无信号就省略地名。
- 录音先落临时名 `VoiceDrop-<时间戳>.m4a`（崩溃也能补传），停止时算时长+反查地点改成富名。

### ⚠️ 跑起来前唯一一步：填 token

上传鉴权用 `jianshuo.dev/files` 的 `FILES_TOKEN`，不在仓库里（已 gitignore）：

```bash
cp Secrets.example.xcconfig Secrets.xcconfig
# 编辑 Secrets.xcconfig，把 REPLACE_ME 换成真实 FILES_TOKEN
```

**token 现存于 `~/code/.env`（`FILES_TOKEN=`）**，与 R2 / Cloudflare Pages secret 同一个（2026-06-18 轮换为 UUID）。不填的话 App 能录能存，但上传提示「缺少 FILES_TOKEN」并排队。详见记忆 `jianshuo-dev-files-transfer`。

### 开发 / 安装

```bash
xcodegen generate                       # 由 project.yml 生成 VoiceDrop.xcodeproj（已 gitignore）
open VoiceDrop.xcodeproj                 # 数据线连真机直接 Run（最简单）
```

- **必须真机**：模拟器没有麦克风，录出来永远是 -91dB 纯静音（转写为空、挖不出文章）。要测整条链路，用物理 iPhone 录有声内容。
- 模拟器只能验证 UI / 编译：
  ```bash
  xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop \
    -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
  ```
- TestFlight（照搬 `~/code/drop` 的签名，需 App Store Connect API key）：`bundle exec fastlane beta`
- 渐变图标可重生成：`python3 scripts/make_icon.py VoiceDropApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png`

### 代码结构（主干）

| 文件 | 作用 |
|---|---|
| `VoiceDropApp/VoiceDropApp.swift` | `@main` 入口 → `RootView` → `LibraryView`（列表即主屏） |
| `VoiceDropApp/RootView.swift` + `AppRouter.swift` | 根视图 + 深链/Universal Link 路由（地址表在 AppRouter 注释里） |
| `VoiceDropApp/LibraryView.swift` | 主屏：录音列表、红键入口、深链应用、库级语音命令入口 |
| `VoiceDropApp/RecordSession.swift` | 全屏录音页（出现即开录）；停止后交 `RecordingPromoter` 改富名 |
| `VoiceDropApp/AudioRecorder.swift` / `EngineRecorder.swift` / `RecordingBackend.swift` | 双录音引擎（经典 AVAudioRecorder / AVAudioEngine+实时采访），统一 `RecordingBackend` 协议 |
| `VoiceDropApp/RecordingName.swift` | 纯 Foundation 的富文件名构造（时间戳/时长/星期/时段），可单测；双 target 共享 |
| `VoiceDropApp/Uploader.swift` | PUT 上传到 files API；Documents 目录即待传队列；前台/网络恢复重传 |
| `VoiceDropApp/Library.swift` | `Recording`/`ArticleDoc`/`MinedArticle` 模型 + `LibraryStore`（列表/文章 SWR 缓存，最大的非 View 文件） |
| `VoiceDropApp/RecordingDetailView.swift` | 文章详情/编辑页（语音修改、追问、发布、分享；最大的 View） |
| `VoiceDropApp/AgentSocket.swift` | 可重连 WebSocket 基座（25s 心跳/1.5s 重连/防双开），三个 session 共用 |
| `VoiceDropApp/AgentSession.swift` | `ArticleAgentSession`：文章级语音编辑指令队列 + 服务端快照对账 |
| `VoiceDropApp/LibraryCommandSession.swift` / `StatusSession.swift` | 库级语音命令 / 挖矿状态与配对推送（同一基座） |
| `VoiceDropApp/Networking.swift` | 所有 host/URL 的单一真源 + authed 请求收口；双 target 共享 |
| `VoiceDropShare/` | 分享扩展（音频/照片/文风语料入口，`ShareAPI.swift` 是它的网络层） |
| `VoiceDropTests/` | 纯逻辑单测（PromptLogic / ArticleBody / RecordingName / AppRouter / PromptDragEngine） |
| `mining/relay_server.py` | 微信发布 relay（Tokyo VPS 常驻） |
| `project.yml` | XcodeGen 工程定义（bundle `com.wangjianshuo.VoiceDrop`，team `97XBW2A43H`，iOS 26 / Swift 6） |
| `Secrets.xcconfig` | `FILES_TOKEN`（gitignore，本地）；`Secrets.example.xcconfig` 是占位模板 |
| `docs/superpowers/specs/` | 设计文档（单一事实源） |

---

## 技术文档

- [文章版本控制与撤销/重做](docs/article-versioning.md) — head 指针模型、schema-3 格式、API 路由

---

## 给未来 agent 的指北

- **改 App 行为** → 这个 repo。设计的单一事实源是 `docs/superpowers/specs/2026-06-18-voicedrop-design.md`，先读它。
- **改文件中转站本身**（鉴权 / 路由 / R2） → `~/code/jianshuo.dev`，函数在 `functions/files/api/[[path]].js`，Pages 项目名 `jianshuo-dev`。
- **token 在哪** → `~/code/.env` 的 `FILES_TOKEN`，与 Cloudflare Pages secret 同值；轮换见记忆 `jianshuo-dev-files-transfer`。
- **后台/隔离**：本 repo 是 git 仓库，后台 agent 改代码前先 `EnterWorktree`。
- **已知坑**：模拟器无麦克风 → 录音恒为 -91dB 静音；`CLGeocoder` 在 iOS 26 标记 deprecated（仍可用，将来可迁 `MKReverseGeocodingRequest`）。
- **相关**：`~/code/drop` / `~/code/DuduCam`（同款 XcodeGen+fastlane iOS 工程，可参照签名/发布）。

仓库：https://github.com/jianshuo/voicedrop
