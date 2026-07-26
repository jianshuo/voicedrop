每次开始工作前先读 STATE.md，了解现状（稳定架构与契约；逐日改动流水在 CHANGELOG.md）

# 测试规则
本仓（iOS）单测——任何改动前后各跑一遍确认 pass：
```
xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
测试文件在 `VoiceDropTests/`（125 条纯逻辑单测，不打网络；模拟器名不存在时用 `xcrun simctl list devices available` 挑一个）。
若改动涉及服务端 Worker，去 `~/code/jianshuo.dev/agent` 跑 `npm test`（测试在 agent/test/，覆盖 article store、API 路由、tools、loop）。
当作了大型的更改以后：架构/契约变化更新 STATE.md，逐日流水追加到 CHANGELOG.md 顶部，把需要以后的 Agent 注意的内容写进去
因为用xcodegen，当产生新的文件的时候帮我跑一下
