#!/usr/bin/env python3
"""Create VLESS WS TLS inbound using the 3X-UI v3.11.0 authenticated API.

Local loopback only. Fails closed on authentication and unknown API response.
"""
import argparse
import http.cookiejar
import json
import os
import ssl
import sys
import urllib.parse
import urllib.request
import uuid


def api_call(opener, base, path, data=None, form=False):
    url = base.rstrip('/') + '/' + path.lstrip('/')
    payload = None
    headers = {}
    if data is not None:
        if form:
            payload = urllib.parse.urlencode(data).encode()
            headers['Content-Type'] = 'application/x-www-form-urlencoded'
        else:
            payload = json.dumps(data).encode()
            headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(url, data=payload, headers=headers,
                                 method='POST' if data is not None else 'GET')
    with opener.open(req, timeout=15) as res:
        raw = res.read(4_000_000)
        return json.loads(raw.decode())


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--domain', required=True)
    p.add_argument('--port', required=True, type=int)
    p.add_argument('--panel-port', required=True, type=int)
    p.add_argument('--panel-scheme', choices=('http','https'), default='http')
    p.add_argument('--web-path', required=True)
    p.add_argument('--ws-path', required=True)
    p.add_argument('--client-name', required=True)
    p.add_argument('--cert', required=True)
    p.add_argument('--key', required=True)
    args = p.parse_args()
    username = os.environ['XUI_USERNAME']
    password = os.environ['XUI_PASSWORD']
    if not args.ws_path.startswith('/') or '?' in args.ws_path or '#' in args.ws_path:
        sys.exit('Invalid WS path')
    if not (1 <= args.port <= 65535):
        sys.exit('Invalid VPN port')
    basepath = '/' + args.web_path.strip('/') if args.web_path.strip('/') else ''
    ctx = ssl.create_default_context()
    # Only contact the loopback panel while its initial certificate may be self-signed.
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        urllib.request.HTTPSHandler(context=ctx))
    # 3X-UI v3.11.0 requires session-bound CSRF for login and mutations.
    csrf_token = None
    errors = []
    for scheme in (args.panel_scheme,):
        base = f'{scheme}://127.0.0.1:{args.panel_port}{basepath}'
        try:
            token_response = api_call(opener, base, '/csrf-token')
            if token_response.get('success') is not True or not token_response.get('obj'):
                raise RuntimeError('CSRF token endpoint did not return a token')
            csrf_token = token_response['obj']
            # Preserve cookie jar; submit _csrf with the form.
            r = api_call(opener, base, '/login',
                         {'username': username, 'password': password,
                          '_csrf': csrf_token}, form=True)
            if r.get('success') is True:
                break
            errors.append(f'{scheme}: login refused')
        except Exception as exc:
            errors.append(f'{scheme}: {type(exc).__name__}')
    else:
        sys.exit('Panel API login failed: ' + ', '.join(errors))

    current = api_call(opener, base, '/panel/api/inbounds/list')
    if current.get('success') is not True or not isinstance(current.get('obj'), list):
        sys.exit('Could not list inbounds; no changes made')
    for inbound in current['obj']:
        if inbound.get('port') == args.port:
            if inbound.get('remark') == 'VLESS-WS-TLS-Auto':
                if not os.path.isfile('/etc/x-ui/autodeploy-client.vless'):
                    sys.exit('Inbound already exists, but the local client profile is missing. '
                             'Refusing to claim success; inspect the client in 3X-UI.')
                print('Existing inbound found; no duplicate created')
                return
            sys.exit(f'Port {args.port} occupied by another inbound. Aborting.')
    user_id = str(uuid.uuid4())
    payload = {
        'enable': True, 'remark': 'VLESS-WS-TLS-Auto', 'listen': '',
        'port': args.port, 'protocol': 'vless', 'expiryTime': 0, 'total': 0,
        'shareAddrStrategy': 'custom', 'shareAddr': args.domain,
        'settings': {
            'clients': [{'id': user_id, 'email': args.client_name,
                         'enable': True, 'flow': '', 'totalGB': 0,
                         'expiryTime': 0, 'limitIp': 0, 'tgId': 0}],
            'decryption': 'none', 'encryption': 'none', 'fallbacks': []
        },
        'streamSettings': {
            'network': 'ws', 'security': 'tls',
            'wsSettings': {'path': args.ws_path, 'host': args.domain,
                           'headers': {'Host': args.domain}},
            'tlsSettings': {
                'serverName': args.domain, 'alpn': ['http/1.1'],
                'certificates': [{'certificateFile': args.cert, 'keyFile': args.key}]
            }
        },
        'sniffing': {'enabled': False, 'destOverride': ['http', 'tls']}
    }
    # Upstream 3X-UI v3.11.0 model.Inbound expects these three fields
    # as JSON-encoded STRINGS, not nested JSON objects.
    for field in ('settings', 'streamSettings', 'sniffing'):
        payload[field] = json.dumps(payload[field], separators=(',', ':'))
    # Submit the same session's CSRF token to the mutating endpoint.
    # API helper below takes the token via form fallback when JSON cannot carry it.
    request = urllib.request.Request(
        base.rstrip('/') + '/panel/api/inbounds/add',
        data=json.dumps(payload).encode(),
        headers={'Content-Type': 'application/json',
                 'X-CSRF-Token': csrf_token},
        method='POST')
    with opener.open(request, timeout=20) as response:
        result = json.loads(response.read().decode())
    if result.get('success') is not True:
        sys.exit('Inbound creation rejected: ' + str(result.get('msg', 'unknown error')))
    out = '/etc/x-ui/autodeploy-client.json'
    with open(out, 'w', encoding='utf8') as f:
        json.dump({'uuid': user_id, 'domain': args.domain, 'port': args.port,
                   'path': args.ws_path, 'client': args.client_name}, f, indent=2)
    os.chmod(out, 0o600)
    from urllib.parse import quote
    uri = (f'vless://{user_id}@{args.domain}:{args.port}?encryption=none'
           f'&security=tls&sni={quote(args.domain)}&type=ws'
           f'&host={quote(args.domain)}&path={quote(args.ws_path, safe="")}'
           f'#VLESS-WS-TLS-Auto')
    uri_path = '/etc/x-ui/autodeploy-client.vless'
    with open(uri_path, 'w', encoding='utf8') as f:
        f.write(uri + '\n')
    os.chmod(uri_path, 0o600)
    print('Inbound created; private client profile stored in ' + uri_path)


if __name__ == '__main__':
    main()
