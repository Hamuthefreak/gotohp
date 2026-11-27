"""Reads the tool list a live server actually serves, from outside every other script.

    KEY=$(sudo cat /opt/omnivox-mcp/data/accessKey.txt) python3 toolscheck-live.py [port]

Prints every name, fails if one of the tools this deployment adds is missing, and
then proves the check can fail by asking a port that must be closed. The key is
read from the environment and never printed.
"""

import json
import os
import sys
import urllib.error
import urllib.request

EXTRA = (
    'get-college-document-link',
    'get-mio-message-link',
    'get-campus-events',
    'get-upcoming-schedule',
)


def tools(port, key):
    req = urllib.request.Request(
        f'http://127.0.0.1:{port}/tools', headers={'x-mcp-auth': key}
    )
    with urllib.request.urlopen(req, timeout=20) as res:
        return json.load(res)


def main() -> int:
    key = os.environ.get('KEY', '')
    if not key:
        print('toolscheck-live: no KEY in the environment', file=sys.stderr)
        return 2
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
    try:
        served = sorted(t['name'] for t in tools(port, key)['tools'])
    except urllib.error.HTTPError as err:
        print(f'::error::/tools refused the key on port {port} ({err.code})')
        return 1
    except OSError as err:
        print(f'::error::nothing answers on port {port} ({err})')
        return 1
    print(f'/tools answers {len(served)} tools')
    for name in served:
        print(f'  {name}')
    missing = [name for name in EXTRA if name not in served]
    if missing:
        print(f'::error::the live server does not serve {missing}')
        return 1
    try:
        tools(1, key)
    except OSError:
        print('the same check fails on a closed port, so it can fail')
    except urllib.error.HTTPError as err:
        print(f'the same check fails when the key is refused ({err.code})')
    else:
        print('::error::the tool-list check read a port that must be closed')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
