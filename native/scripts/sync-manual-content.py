"""Keep bundled image metadata and the Markdown reference in sync with the guide catalog."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
path = root / 'Sources/TabbyNative/Resources/AIManual/manual.json'
chapters = json.loads(path.read_text())
entries = json.loads((root / 'scripts/manual-illustrations.json').read_text())
for chapter in chapters:
    figures = [dict(image=e['name'], title=e['title'], caption='；'.join(str(i + 1) + '．' + text for i, text in enumerate(e['guides']))) for e in entries if e['chapter'] == chapter['id']]
    if not figures:
        raise ValueError('Missing illustrated instructions: ' + chapter['id'])
    chapter.update(image=figures[0]['image'], imageTitle=figures[0]['title'], caption=figures[0]['caption'], additionalImages=figures[1:])
path.write_text(json.dumps(chapters, ensure_ascii=False, indent=2) + '\n')
version = re.search(r'CFBundleShortVersionString</key><string>([^<]+)', (root / 'scripts/package.sh').read_text()).group(1)
markdown = ['# Axon AI 助手使用手册', f'适用版本：{version}。程序入口：帮助 → AI 助手使用手册；助手及 AI 设置中的书本入口。', f'全部 {len(chapters)} 章均有操作图片，共 {len(entries)} 张实际界面图。图中编号对应具体操作；支持目录、全文搜索、正文大图、逐图放大和示例复制。图片使用示例数据。']
for chapter in chapters:
    markdown.extend(['## ' + chapter['title'], chapter['summary'], '入口：' + chapter['entry'], '流程图：' + ' → '.join(chapter['flow']), '### 看图操作'])
    for index, figure in enumerate([dict(image=chapter['image'], title=chapter['imageTitle'], caption=chapter['caption'])] + chapter['additionalImages']):
        markdown.extend([f'#### 图 {index + 1} · ' + figure['title'], '![' + figure['title'] + '](Sources/TabbyNative/Resources/AIManual/' + figure['image'] + ')', figure['caption']])
    markdown.extend(['### 操作步骤', '\n'.join(str(i + 1) + '. ' + step for i, step in enumerate(chapter['steps'])), '示例：', '```text\n' + chapter['example'] + '\n```', '结果检查：' + chapter['check'], '注意与边界：' + chapter['note']])
(root / 'AI-ASSISTANT-MANUAL.md').write_text('\n\n'.join(markdown) + '\n')
print(f'{len(chapters)} chapters, {len(entries)} illustrated instructions')
