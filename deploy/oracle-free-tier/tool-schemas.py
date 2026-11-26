#!/usr/bin/env python3
"""Print the input schema of every tool the local omnivox-mcp server registers.

The probe reads the same inventory, but a required field and its shape are only
visible here: calling a tool with a wrong argument name proves nothing about the
tool, it proves the probe guessed. Run it on the box as root:

    sudo python3 tool-schemas.py            # every tool
    sudo python3 tool-schemas.py get-overview get-calendar

Nothing is called: the inventory is a GET, so it cannot touch the account.
"""
import json
import os
import sys
import urllib.request

BASE = os.environ.get('OMNIVOX_URL', 'http://127.0.0.1:3000')
KEY_FILE = os.environ.get('OMNIVOX_KEY_FILE', '/opt/omnivox-mcp/data/accessKey.txt')

want = set(sys.argv[1:])
with open(KEY_FILE) as handle:
    key = handle.read().strip()

req = urllib.request.Request(f'{BASE}/tools', headers={'x-mcp-auth': key})
with urllib.request.urlopen(req, timeout=60) as res:
    tools = json.load(res)['tools']

for tool in tools:
    name = tool['name']
    if want and name not in want:
        continue
    schema = tool.get('inputSchema') or {}
    props = schema.get('properties') or {}
    required = schema.get('required') or []
    print(f'\n{name}')
    print(f'  description: {" ".join((tool.get("description") or "").split())[:240]}')
    if not props:
        print('  (no input)')
    for prop, spec in props.items():
        kind = spec.get('type') or spec.get('anyOf') or spec.get('enum') or ''
        if isinstance(kind, list):
            kind = '/'.join(str(k.get('type', k)) if isinstance(k, dict) else str(k) for k in kind)
        if isinstance(kind, list):
            kind = 'enum ' + ','.join(str(k) for k in kind)
        mark = 'required' if prop in required else 'optional'
        extra = ''
        if 'default' in spec:
            extra = f' default={spec["default"]!r}'
        if spec.get('description'):
            extra += '  # ' + ' '.join(spec['description'].split())[:140]
        print(f'  - {prop}: {kind} ({mark}){extra}')
