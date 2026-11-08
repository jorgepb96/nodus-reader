"""Replace one App Store screenshot set with new captures, in order.

Usage: python3 tools/appstore/upload-screenshots.py VERSION_ID LOCALE DISPLAY_TYPE FILE...

VERSION_ID is the App Store version (not a build), LOCALE e.g. en-US, DISPLAY_TYPE
e.g. APP_IPHONE_67 or APP_IPAD_PRO_3GEN_129. The files are uploaded in the order
given, the previous screenshots of that set are deleted only after every new one
is COMPLETE, and the set is left in the given order. Nothing is submitted.
"""
import hashlib, json, sys, time, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from asc_api import request


def put(operation, data):
    chunk = data[operation['offset']:operation['offset'] + operation['length']]
    headers = {h['name']: h['value'] for h in operation.get('requestHeaders', [])}
    req = urllib.request.Request(operation['url'], data=chunk, headers=headers, method=operation['method'])
    with urllib.request.urlopen(req, timeout=120) as response:
        response.read()


def screenshot_set(version_id, locale, display):
    locs = request('GET', f'/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations')['data']
    loc = next(l for l in locs if l['attributes']['locale'] == locale)
    sets = request('GET', f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")['data']
    found = next((s for s in sets if s['attributes']['screenshotDisplayType'] == display), None)
    if found:
        return found['id']
    created = request('POST', '/v1/appScreenshotSets', {'data': {
        'type': 'appScreenshotSets', 'attributes': {'screenshotDisplayType': display},
        'relationships': {'appStoreVersionLocalization': {'data': {'type': 'appStoreVersionLocalizations', 'id': loc['id']}}}}})
    return created['data']['id']


def upload(set_id, path):
    data = path.read_bytes()
    reserved = request('POST', '/v1/appScreenshots', {'data': {
        'type': 'appScreenshots', 'attributes': {'fileName': path.name, 'fileSize': len(data)},
        'relationships': {'appScreenshotSet': {'data': {'type': 'appScreenshotSets', 'id': set_id}}}}})['data']
    for operation in reserved['attributes']['uploadOperations']:
        put(operation, data)
    request('PATCH', f"/v1/appScreenshots/{reserved['id']}", {'data': {
        'type': 'appScreenshots', 'id': reserved['id'],
        'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest()}}})
    return reserved['id']


def wait_complete(set_id, ids):
    # Apple can take several minutes per image.
    for _ in range(300):
        states = {s['id']: (s['attributes'].get('assetDeliveryState') or {}).get('state')
                  for s in request('GET', f'/v1/appScreenshotSets/{set_id}/appScreenshots')['data']}
        if all(states.get(i) == 'COMPLETE' for i in ids):
            return
        if any(states.get(i) == 'FAILED' for i in ids):
            raise SystemExit(f'Apple rejected an upload: {states}')
        time.sleep(5)
    raise SystemExit('Screenshots did not finish processing')


def main():
    version_id, locale, display, *files = sys.argv[1:]
    paths = [Path(f) for f in files]
    assert paths and all(p.is_file() for p in paths), 'missing files'
    assert len(paths) <= 10, 'App Store sets hold at most 10 screenshots'
    set_id = screenshot_set(version_id, locale, display)
    current = request('GET', f'/v1/appScreenshotSets/{set_id}/appScreenshots')['data']
    # Resumable: a file already uploaded under the same name is kept, not sent again.
    uploaded = {s['attributes']['fileName']: s['id'] for s in current
                if (s['attributes'].get('assetDeliveryState') or {}).get('state') != 'FAILED'}
    wanted = {p.name for p in paths}
    old = [s['id'] for s in current if s['attributes']['fileName'] not in wanted]
    # A set holds at most 10, uploads included: swap one at a time so it never empties.
    new = []
    for path in paths:
        if path.name in uploaded:
            new.append(uploaded[path.name])
            continue
        if len(old) + len(new) >= 10:
            request('DELETE', f'/v1/appScreenshots/{old.pop(0)}')
        new.append(upload(set_id, path))
    for screenshot_id in old:
        request('DELETE', f'/v1/appScreenshots/{screenshot_id}')
    wait_complete(set_id, new)
    request('PATCH', f'/v1/appScreenshotSets/{set_id}/relationships/appScreenshots',
            {'data': [{'type': 'appScreenshots', 'id': i} for i in new]})
    final = request('GET', f'/v1/appScreenshotSets/{set_id}/appScreenshots')['data']
    print(json.dumps({'locale': locale, 'display': display, 'set': set_id,
                      'files': [str(p) for p in paths],
                      'ids': [s['id'] for s in final],
                      'states': [(s['attributes'].get('assetDeliveryState') or {}).get('state') for s in final]}))


if __name__ == '__main__':
    main()
