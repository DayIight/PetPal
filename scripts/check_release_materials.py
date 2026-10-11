#!/usr/bin/env python3
"""本地发布材料校验；--submission 额外检查尚待提供的真实发布配置。"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import sys

root = Path(__file__).resolve().parents[1]
pack = root / 'docs/release/zh-Hans'
parser = argparse.ArgumentParser()
parser.add_argument('--submission', action='store_true')
args = parser.parse_args()
errors = []
metadata = json.loads((pack / 'metadata.json').read_text())
for key, limit in [('name', 30), ('subtitle', 30), ('promotionalText', 170), ('description', 4000), ('whatsNew', 4000)]:
    value = metadata[key]
    if not value or len(value) > limit:
        errors.append(f'{key}: {len(value)} 字符，允许 1..{limit}')
    print(f'{key}: {len(value)}/{limit} 字符')
keywords = metadata['keywords'].encode('utf-8')
print(f'keywords: {len(keywords)}/100 UTF-8 字节')
if len(keywords) > 100 or not keywords:
    errors.append('keywords 超限或为空')
manifest_path = pack / 'screenshots/manifest.json'
if not manifest_path.exists():
    errors.append('缺截图清单')
else:
    manifest = json.loads(manifest_path.read_text())
    for device, expected in [('iphone', (1320, 2868)), ('ipad', (2064, 2752))]:
        shots = [s for s in manifest['screenshots'] if s['device'] == device]
        if len(shots) != 5:
            errors.append(f'{device} 应有 5 张截图')
        for shot in shots:
            path = pack / 'screenshots' / shot['file']
            if not path.exists():
                errors.append(f'缺截图 {path}'); continue
            data = path.read_bytes()
            size = struct.unpack('>II', data[16:24]) if data.startswith(b'\x89PNG\r\n\x1a\n') else (0, 0)
            if size != expected or list(size) != shot['pixels']:
                errors.append(f'{path.name} 尺寸错误 {size}')
            if hashlib.sha256(data).hexdigest() != shot['sha256']:
                errors.append(f'{path.name} 内容与清单不一致')
        print(f'{device}: {len(shots)} 张截图')
for name in ['审核说明.md', '真机与TestFlight验收.md', 'README.md']:
    if not (pack / name).exists(): errors.append(f'缺 {name}')
for name in ['report-standard.pdf', 'report-long.pdf', 'report-empty.pdf']:
    path = root / 'output/pdf' / name
    if not path.exists() or not path.read_bytes().startswith(b'%PDF-'):
        errors.append(f'缺有效 PDF 样例 {name}')
if args.submission:
    info = plistlib.loads((root / 'PetPal/Supporting/Info.plist').read_bytes())
    for key in ['PetPalOperatorName', 'PetPalPrivacyPolicyURL', 'PetPalSupportURL']:
        if not info.get(key): errors.append(f'待提供 {key}')
    project = (root / 'project.yml').read_text()
    if 'DEVELOPMENT_TEAM: ""' in project: errors.append('待配置真实 DEVELOPMENT_TEAM')
    if 'com.petpal.prototype' in project: errors.append('待确认正式 Bundle ID（当前 prototype）')
    app_groups = plistlib.loads((root / 'PetPal/Supporting/PetPal.entitlements').read_bytes()).get('com.apple.security.application-groups', [])
    widget_groups = plistlib.loads((root / 'PetPalWidget/PetPalWidget.entitlements').read_bytes()).get('com.apple.security.application-groups', [])
    if not app_groups or app_groups != widget_groups:
        errors.append('App 与 Widget 的 App Group 配置缺失或不一致')
    if 'group.com.petpal.prototype' in app_groups:
        errors.append('待确认正式 App Group（当前 prototype）')
    acceptance = json.loads((pack / 'acceptance.json').read_text())
    for kind in ['physicalDevice', 'minimumOS', 'testFlight']:
        result = acceptance[kind]
        if result['status'] != 'passed' or any(not result[field] for field in ['device', 'system', 'build', 'evidence']):
            errors.append(f'{kind} 验收待完成并附证据')
if errors:
    print('\n未通过项：\n' + '\n'.join('- ' + e for e in errors))
    sys.exit(1)
print('本地材料检查通过。尚未执行外部分发验收。')
