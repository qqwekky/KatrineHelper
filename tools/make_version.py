"""Пересчитывает version.json по moonloader/MVDHelper.lua: версия, размер и SHA-256.
Запуск: python tools/make_version.py (из корня репозитория). Его же вызывает GitHub Actions."""
import hashlib
import json
import pathlib
import re

root = pathlib.Path(__file__).resolve().parent.parent
script = root / 'moonloader' / 'MVDHelper.lua'
data = script.read_bytes()
m = re.search(rb"local VERSION = '([0-9.]+)'", data)
if not m:
    raise SystemExit('В MVDHelper.lua не найдена строка local VERSION')
info = {
    'version': m.group(1).decode(),
    'size': len(data),
    'sha256': hashlib.sha256(data).hexdigest(),
    'file': 'moonloader/MVDHelper.lua',
}
target = root / 'version.json'
old = target.read_text(encoding='utf-8') if target.exists() else ''
new = json.dumps(info, ensure_ascii=False, indent=1) + '\n'
if old != new:
    target.write_text(new, encoding='utf-8')
    print('version.json обновлён:', info['version'], info['sha256'][:12])
else:
    print('version.json уже актуален')
