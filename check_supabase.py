from pathlib import Path
import requests
import re
import json

config_path = Path('dashboard/js/config.js')
text = config_path.read_text(encoding='utf-8')
match = re.search(r"anonKey: '([^']+)'", text)
if not match:
    print('No anonKey found in config')
    raise SystemExit(1)

key = match.group(1)
url = 'https://vtlfbpxcequpfkivxzgf.supabase.co/rest/v1/v_mrr_monthly?select=month&limit=1'
headers = {
    'apikey': key,
    'Authorization': f'Bearer {key}',
    'Content-Type': 'application/json'
}

r = requests.get(url, headers=headers, timeout=30)
print(f'STATUS: {r.status_code}')
print('HEADERS:', dict(r.headers))
print('BODY:', r.text[:500])
