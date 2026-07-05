"""md_to_wechat_html 列表渲染回归测试。

背景（2026-07-04）：挖矿产出的正文常是「松散列表」（`- ` 条目之间隔空行）。
旧实现遇到空行就 </ul> 关列表、下个条目再开新 <ul>，一个三项列表变成三个
单项 <ul>；且 parts 用 '\n' join，<ul> 内部留下裸换行文本节点。微信公众号
编辑器会把 <ul> 里的游离文本节点规范化成空 <li> —— 草稿里每个条目前后
各多出一个空 bullet（空/条目/空/空/条目/空/空/条目/空）。

约束：一个列表 = 一个 <ul>/<ol>，标签内部不允许出现任何裸文本节点（含换行）。

运行：python3 mining/test_relay_md.py
"""
import re
import sys
import unittest

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from relay_server import md_to_wechat_html


def lists_in(html):
    return re.findall(r'<(ul|ol)\b[^>]*>(.*?)</\1>', html, flags=re.S)


class LooseListTest(unittest.TestCase):
    LOOSE = (
        '操作流程很直白：\n'
        '\n'
        '- 在任何 APP 里点「分享」；\n'
        '\n'
        '- 其他来源的内容，直接点分享就行；\n'
        '\n'
        '- 在弹出的列表里找到 Voice Drop。\n'
    )

    def test_loose_list_is_one_ul(self):
        html = md_to_wechat_html(self.LOOSE)
        lists = lists_in(html)
        self.assertEqual(len(lists), 1, f'松散列表应合并为一个 <ul>，实际 {len(lists)} 个:\n{html}')
        self.assertEqual(lists[0][1].count('<li'), 3)

    def test_no_bare_text_nodes_inside_list(self):
        html = md_to_wechat_html(self.LOOSE)
        for tag, inner in lists_in(html):
            bare = re.sub(r'<li\b[^>]*>.*?</li>', '', inner, flags=re.S)
            self.assertEqual(bare.strip(), '', f'<{tag}> 内有裸文本节点（微信会渲染成空 bullet）: {bare!r}')
            self.assertNotIn('\n', bare, f'<{tag}> 内有换行文本节点: {inner!r}')

    def test_tight_list_unchanged(self):
        html = md_to_wechat_html('- a\n- b\n- c\n')
        lists = lists_in(html)
        self.assertEqual(len(lists), 1)
        self.assertEqual(lists[0][1].count('<li'), 3)
        self.assertNotIn('\n', lists[0][1])

    def test_loose_ordered_list(self):
        html = md_to_wechat_html('1. 一\n\n2. 二\n\n3. 三\n')
        lists = lists_in(html)
        self.assertEqual(len(lists), 1)
        self.assertEqual(lists[0][0], 'ol')
        self.assertEqual(lists[0][1].count('<li'), 3)

    def test_paragraph_after_blank_closes_list(self):
        html = md_to_wechat_html('- a\n\n后面的正文段落。\n')
        lists = lists_in(html)
        self.assertEqual(len(lists), 1)
        self.assertEqual(lists[0][1].count('<li'), 1)
        self.assertIn('<p', html)
        self.assertLess(html.find('</ul>'), html.find('后面的正文段落'))

    def test_heading_closes_list(self):
        html = md_to_wechat_html('- a\n\n## 标题\n')
        self.assertLess(html.find('</ul>'), html.find('<h2'))

    def test_photo_marker_closes_list(self):
        html = md_to_wechat_html('- a\n\n[[photo:photos/x/1-a.jpg]]\n\n- b\n',
                                 photo_url=lambda k: 'https://img/' + k)
        lists = lists_in(html)
        self.assertEqual(len(lists), 2, '照片把列表隔开，前后应是两个列表')
        self.assertLess(html.find('</ul>'), html.find('<img'))

    def test_ul_ol_switch(self):
        html = md_to_wechat_html('- a\n\n1. b\n')
        lists = lists_in(html)
        self.assertEqual([t for t, _ in lists], ['ul', 'ol'])

    def test_inline_md_still_applied(self):
        html = md_to_wechat_html('- **粗体** 和 `代码`\n')
        self.assertIn('<strong>粗体</strong>', html)
        self.assertIn('<code', html)


if __name__ == '__main__':
    unittest.main(verbosity=2)
