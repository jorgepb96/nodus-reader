import json
import sys
from pathlib import Path
from asc_api import request

ROOT = Path(__file__).resolve().parents[2]
APP = '6826844742'
INTERNAL = '6fca3f0a-fada-4405-a6a0-9357bab03698'
PUBLIC = 'b2c18bee-362c-4fc0-804a-6869fb3ee638'

def state(version="57"):
    result = request('GET', f'/v1/builds?filter[app]={APP}&filter[version]={version}&include=preReleaseVersion,buildBetaDetail,betaAppReviewSubmission&limit=20')
    known = ROOT / f'build/build{version}-known-deliveries.json'
    if known.exists():
        present = {b['id'] for b in result.get('data', [])}
        for bid in json.loads(known.read_text()):
            if bid in present:
                continue
            try:
                extra = request('GET', f'/v1/builds/{bid}?include=preReleaseVersion,buildBetaDetail,betaAppReviewSubmission')
            except RuntimeError as error:
                if str(error).startswith('404 '):
                    continue
                raise
            result.setdefault('data', []).append(extra['data'])
            result.setdefault('included', []).extend(extra.get('included', []))
    included = {(r['type'], r['id']): r['attributes'] for r in result.get('included', [])}
    membership = {}
    for gid in [INTERNAL, PUBLIC]:
        relation = request('GET', f'/v1/betaGroups/{gid}/relationships/builds?limit=200')
        membership[gid] = {ref['id'] for ref in relation.get('data', [])}
        while relation.get('links', {}).get('next'):
            path = relation['links']['next'].removeprefix('https://api.appstoreconnect.apple.com')
            relation = request('GET', path)
            membership[gid].update(ref['id'] for ref in relation.get('data', []))
    rows = []
    for build in result.get('data', []):
        row = {'id': build['id'], **build['attributes']}
        for name in ['preReleaseVersion', 'buildBetaDetail', 'betaAppReviewSubmission']:
            ref = build.get('relationships', {}).get(name, {}).get('data')
            row[name] = included.get((ref['type'], ref['id'])) if ref else None
        row['groups'] = [gid for gid, members in membership.items() if build['id'] in members]
        rows.append(row)
    (ROOT / f'build/TestFlight-{version}-deployment.json').write_text(json.dumps(rows, indent=2))
    return rows

def distribute(platform, version="57"):
    rows = [r for r in state(version) if (r.get('preReleaseVersion') or {}).get('platform') == platform]
    if len(rows) != 1 or rows[0]['processingState'] != 'VALID' or rows[0]['expired']:
        raise RuntimeError('Exactly one valid, non-expired build is required for ' + platform)
    build = rows[0]
    bid = build['id']
    group = request('GET', '/v1/betaGroups/' + INTERNAL)['data']
    if not group['attributes'].get('isInternalGroup'):
        raise RuntimeError('The configured private group is not Internal')
    if not group['attributes'].get('hasAccessToAllBuilds') and INTERNAL not in build['groups']:
        request('POST', f'/v1/betaGroups/{INTERNAL}/relationships/builds', {'data': [{'type': 'builds', 'id': bid}]})
    existing = request('GET', f'/v1/builds/{bid}/betaBuildLocalizations')['data']
    suffix = 'ios' if platform == 'IOS' else 'macos'
    for locale, language in [('en-US', 'en'), ('es-ES', 'es')]:
        text = (ROOT / f'docs/appstore/TestFlight-{version}-{suffix}-{language}.txt').read_text()
        current = next((r for r in existing if r['attributes']['locale'] == locale), None)
        data = {'type': 'betaBuildLocalizations', 'attributes': {'whatsNew': text}}
        if current:
            data['id'] = current['id']
            request('PATCH', '/v1/betaBuildLocalizations/' + current['id'], {'data': data})
        else:
            data['attributes']['locale'] = locale
            data['relationships'] = {'build': {'data': {'type': 'builds', 'id': bid}}}
            request('POST', '/v1/betaBuildLocalizations', {'data': data})
        print(platform, locale, 'What to Test saved', flush=True)
    if platform == 'MAC_OS':
        if PUBLIC in build['groups']:
            request('DELETE', f'/v1/betaGroups/{PUBLIC}/relationships/builds', {'data': [{'type': 'builds', 'id': bid}]})
        print('MAC_OS private Internal distribution only; no external review submission', flush=True)
        return
    detail = request('GET', f'/v1/builds/{bid}/buildBetaDetail')['data']
    if not detail['attributes'].get('autoNotifyEnabled'):
        request('PATCH', '/v1/buildBetaDetails/' + detail['id'], {'data': {'type': 'buildBetaDetails', 'id': detail['id'], 'attributes': {'autoNotifyEnabled': True}}})
    if PUBLIC not in build['groups']:
        request('POST', f'/v1/betaGroups/{PUBLIC}/relationships/builds', {'data': [{'type': 'builds', 'id': bid}]})
    current = next(r for r in state(version) if r['id'] == bid)
    external = (current.get('buildBetaDetail') or {}).get('externalBuildState')
    if external not in ['IN_BETA_TESTING', 'WAITING_FOR_BETA_REVIEW', 'IN_BETA_REVIEW']:
        request('POST', '/v1/betaAppReviewSubmissions', {'data': {'type': 'betaAppReviewSubmissions', 'relationships': {'build': {'data': {'type': 'builds', 'id': bid}}}}})
        print('IOS public beta review submitted', flush=True)
    print('IOS Internal and Public Beta distribution configured', flush=True)

if __name__ == '__main__':
    action = sys.argv[1] if len(sys.argv) > 1 else 'status'
    if action == 'distribute-ios':
        distribute('IOS')
    elif action == 'distribute-mac':
        distribute('MAC_OS')
    elif action != 'status':
        raise ValueError('Unknown action')
    for row in state():
        print(json.dumps({k: row.get(k) for k in ['id', 'version', 'processingState', 'preReleaseVersion', 'buildBetaDetail', 'betaAppReviewSubmission', 'groups']}, ensure_ascii=False))
