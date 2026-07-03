import SwiftUI

/// 页面无关的配置菜单渲染器：输入一个 `UIMenuConfig`（服务端 ui-config 下发）+
/// 占位符替换闭包，输出原生 contextMenu 内容。组间 `Divider()`（Section 语义）；
/// `type == "submenu"` 且有 children → 递归 `Menu`（2b 二级替换式，系统行为）；
/// 带 `instruction` 的叶子 → `Button`，点选回调收到**已替换完占位符**的成品指令；
/// 未知 type / 缺 instruction 的节点静默跳过（老客户端兼容新配置）。
/// v1 挂在文章详情页的配图/段落上；以后别的页面接同一渲染器。
struct ConfigMenuContent: View {
    let menu: UIMenuConfig
    let fill: (String) -> String
    let onPick: (String) -> Void

    var body: some View {
        ForEach(Array(menu.groups.enumerated()), id: \.offset) { gi, group in
            if gi > 0 { Divider() }
            ForEach(group) { node in
                ConfigMenuNodeView(node: node, fill: fill, onPick: onPick)
            }
        }
    }
}

private struct ConfigMenuNodeView: View {
    let node: UIMenuNode
    let fill: (String) -> String
    let onPick: (String) -> Void

    var body: some View {
        if node.type == "submenu", let children = node.children, !children.isEmpty {
            Menu(node.label) {
                ForEach(children) { child in
                    ConfigMenuNodeView(node: child, fill: fill, onPick: onPick)
                }
            }
        } else if let instruction = node.instruction {
            Button(node.label) { onPick(fill(instruction)) }
        }
    }
}
