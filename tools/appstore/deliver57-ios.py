"""Authorized one-shot iOS beta delivery; never submits production review."""
import hashlib, json, os, shutil, subprocess, sys, time, traceback
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path('/tmp/nodus-reader-ios57-source')
STATUS = ROOT / 'build/build57-ios-status.json'
SIM = 'BB99AB27-1B3D-45AD-A6C3-7B348E1D73AF'
PACKAGES = ROOT / 'build/SourcePackages-release55'
SIM_DD = '/tmp/nodus-reader-build55-sim-release'
ARCHIVE = ROOT / 'build/NodusReader-iOS-0.1.0-57.xcarchive'
EXPORT = ROOT / 'build/export-ios-57'
AUTH = ['-allowProvisioningUpdates', '-authenticationKeyPath', '/Users/jorgepb96/Documents/NODUS SIGNING/AuthKey_687TQG865G.p8', '-authenticationKeyID', '687TQG865G', '-authenticationKeyIssuerID', '36804ede-f0b5-4cd2-a273-c619feb6168f']
sys.path.insert(0, str(Path(__file__).resolve().parent))
from testflight57 import request, state, distribute, INTERNAL, PUBLIC

def record(phase, **details):
    row = dict(phase=phase, at=datetime.now().astimezone().isoformat(), build='57', source=str(SOURCE), **details)
    temp = STATUS.with_suffix('.tmp')
    temp.write_text(json.dumps(row, indent=2) + '\n')
    temp.replace(STATUS)
    print(json.dumps(row), flush=True)

def run(args, log, cwd=SOURCE, timeout=3600):
    with (ROOT / 'build' / log).open('w') as stream:
        subprocess.run(args, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout, check=True)

def snapshot():
    if SOURCE.exists():
        raise RuntimeError('Snapshot already exists; inspect status before resuming to avoid duplicate delivery')
    SOURCE.mkdir()
    for name in ['Config', 'Modules', 'NodusReader', 'NodusReader.xcodeproj', 'NodusReaderTests', 'NodusReaderUITests', 'NodusShareExtension', 'Shared']:
        shutil.copytree(ROOT/name, SOURCE/name, symlinks=True, ignore=shutil.ignore_patterns('.build', '.git', 'xcuserdata', '.DS_Store'))
    shutil.copy2(ROOT/'project.yml', SOURCE/'project.yml')
    files = {}
    for path in SOURCE.rglob('*'):
        if path.is_file() and path.suffix in ['.swift', '.plist', '.entitlements', '.xcstrings', '.pbxproj', '.yml', '.json']:
            files[str(path.relative_to(SOURCE))] = hashlib.sha256(path.read_bytes()).hexdigest()
    (ROOT/'build/build57-ios-source.json').write_text(json.dumps(dict(createdAt=datetime.now().astimezone().isoformat(), files=files), indent=2)+'\n')

def main():
    existing = [r for r in state() if (r.get('preReleaseVersion') or {}).get('platform') == 'IOS']
    if existing:
        raise RuntimeError('Build 57 already exists in Apple; inspect instead of uploading again')
    record('snapshotting current iOS corrections')
    snapshot()
    common = ['xcodebuild', '-project', 'NodusReader.xcodeproj', '-scheme', 'NodusReader', '-clonedSourcePackagesDirPath', str(PACKAGES), '-disableAutomaticPackageResolution', '-jobs', '2']
    record('building iOS unit tests from isolated snapshot')
    run(common + ['-configuration', 'Debug', '-destination', 'platform=iOS Simulator,id='+SIM, '-derivedDataPath', SIM_DD, 'build-for-testing'], 'build57-ios-test-build.log')
    runners = list((Path(SIM_DD)/'Build/Products').glob('NodusReader_iphonesimulator*.xctestrun'))
    runner = max(runners, key=lambda p:p.stat().st_mtime)
    result = ROOT/'build/build57-unit-ios.xcresult'
    record('running iOS unit regressions')
    run(['xcodebuild', 'test-without-building', '-xctestrun', str(runner), '-destination', 'platform=iOS Simulator,id='+SIM, '-only-testing:NodusReaderTests', '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(result), '-collect-test-diagnostics', 'never'], 'build57-unit-ios.log', timeout=1800)
    record('archiving signed iOS Release')
    run(common + ['archive', '-configuration', 'Release', '-destination', 'generic/platform=iOS', '-archivePath', str(ARCHIVE), '-derivedDataPath', '/tmp/nodus-reader-build48-ios-release', *AUTH], 'build57-archive-ios.log')
    record('exporting and checking signature, licenses and Production iCloud')
    run(['xcodebuild', '-exportArchive', '-archivePath', str(ARCHIVE), '-exportPath', str(EXPORT), '-exportOptionsPlist', str(ROOT/'build/ExportOptions-build56-verify.plist'), *AUTH], 'build57-export-ios.log')
    run([sys.executable, str(ROOT/'build/verify-release57.py'), 'ios'], 'build57-verify-ios.log', ROOT)
    record('uploading iOS build 57 once')
    run(['xcrun', 'altool', '--upload-app', '-f', str(EXPORT/'Nodus Reader.ipa'), '--api-key', '687TQG865G', '--api-issuer', '36804ede-f0b5-4cd2-a273-c619feb6168f', '--p8-file-path', '/Users/jorgepb96/Documents/NODUS SIGNING/AuthKey_687TQG865G.p8'], 'build57-upload-ios.log', timeout=3600)
    record('uploaded; waiting for Apple processing')
    deadline = time.monotonic()+7200
    while time.monotonic()<deadline:
        rows = [r for r in state() if (r.get('preReleaseVersion') or {}).get('platform') == 'IOS']
        if rows:
            row=rows[0]
            if row['processingState'] in ['FAILED', 'INVALID']:
                raise RuntimeError('Apple rejected processing: '+json.dumps(row))
            if row['processingState']=='VALID':
                record('assigning Internal and Public Beta and submitting beta review if needed', buildId=row['id'])
                distribute('IOS')
                current=next(r for r in state() if r['id']==row['id'])
                assert set(current['groups'])=={INTERNAL,PUBLIC}
                notes=request('GET', f"/v1/builds/{row['id']}/betaBuildLocalizations")['data']
                for locale,lang in [('en-US','en'),('es-ES','es')]:
                    actual=next(n['attributes']['whatsNew'] for n in notes if n['attributes']['locale']==locale).strip()
                    assert actual==(ROOT/f'docs/appstore/TestFlight-57-ios-{lang}.txt').read_text().strip()
                receipt=dict(current, sourceManifest='build/build57-ios-source.json', unitResults='build/build57-unit-ios.xcresult', verification=json.loads((ROOT/'build/Build57-ios-verification.json').read_text()), physicalValidation='Explicitly deferred by user', productionReviewSubmitted=False)
                (ROOT/'docs/appstore/BUILD57_IOS_DELIVERY.json').write_text(json.dumps(receipt,indent=2)+'\n')
                record('COMPLETE', buildId=row['id'], groups=current['groups'], beta=current['buildBetaDetail'], physicalValidation='Deferred; beta only')
                return
        time.sleep(30)
    raise TimeoutError('Upload completed, Apple processing still pending; do not upload again')

if __name__=='__main__':
    try:
        main()
    except BaseException as error:
        record('FAILED', error=str(error), uploadRetryAllowed=False)
        traceback.print_exc()
        raise
