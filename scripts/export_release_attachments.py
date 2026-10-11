#!/usr/bin/env python3
"""从 xcresulttool export attachments 产物拷贝命名 PDF/截图并生成可校验清单。"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('attachments', type=Path)
args = parser.parse_args()
for group in json.loads((args.attachments / 'manifest.json').read_text()):
    for attachment in group['attachments']:
        name = attachment['suggestedHumanReadableName'].split('_')[0]
        source = args.attachments / attachment['exportedFileName']
        if name.startswith('report-') and source.suffix == '.pdf':
            target = root / 'output/pdf' / (name + '.pdf')
        elif name.startswith('store-') and source.suffix == '.png':
            device = attachment['deviceName']
            if device == 'iPhone 18 Pro Max': family = 'iphone'
            elif device == 'iPad Pro 13-inch (M5)': family = 'ipad'
            else: continue  # 中尺寸回归截图不替代商店的大屏原生图。
            target = root / 'docs/release/zh-Hans/screenshots' / family / (name.removeprefix('store-') + '.png')
        else: continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        print(target.relative_to(root))
pack = root / 'docs/release/zh-Hans/screenshots'
shots = []
for path in sorted(pack.glob('*/*.png')):
    data = path.read_bytes()
    shots.append({'device': path.parent.name, 'file': str(path.relative_to(pack)), 'pixels': list(struct.unpack('>II', data[16:24])), 'sha256': hashlib.sha256(data).hexdigest()})
pack.mkdir(parents=True, exist_ok=True)
(pack / 'manifest.json').write_text(json.dumps({'generated': '2026-10-11', 'source': 'ReleaseFlowUITests/test_storeScreenshots, Debug in-memory synthetic fixtures, native unedited screenshots', 'screenshots': shots}, ensure_ascii=False, indent=2) + '\n')
