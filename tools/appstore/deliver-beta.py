"""One-shot detached beta delivery for iOS (Internal/Public) and Mac (Internal).

An immutable Git snapshot is built/tested. Uploads are never automatically
retried; the Apple state is checked before upload to prevent duplicates.
No production App Store review is submitted and no credentials are recorded.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time
import traceback
from datetime import datetime

import testflight57 as beta

ROOT = Path(__file__).resolve().parents[2]
KEY = Path('/Users/jorgepb96/Documents/NODUS SIGNING/AuthKey_687TQG865G.p8')
AUTH = ['-allowProvisioningUpdates', '-authenticationKeyPath', str(KEY),
        '-authenticationKeyID', '687TQG865G', '-authenticationKeyIssuerID', '36804ede-f0b5-4cd2-a273-c619feb6168f']
SIM = 'BB99AB27-1B3D-45AD-A6C3-7B348E1D73AF'
PACKAGES = ROOT / 'build/SourcePackages-release55'


def now():
    return datetime.now().astimezone().isoformat()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', required=True, type=int)
    parser.add_argument('--pr', default='76')
    args = parser.parse_args()
    number = str(args.build)
    runroot = ROOT / 'build' / ('beta' + number)
    runroot.mkdir(parents=True, exist_ok=True)
    statusfile = ROOT / f'docs/appstore/BUILD{number}_AUTOMATION_STATUS.json'
    snapshot = Path('/tmp') / f'nodus-reader-beta{number}-source'
    branch = subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip()
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if statusfile.exists():
        previous = json.loads(statusfile.read_text())
        if previous.get('phase') != 'QUEUED':
            print('Existing run: refusing a duplicate delivery. Inspect ' + str(statusfile), flush=True)
            return
    status = dict(build=number, sourceCommit=commit, sourceBranch=branch, startedAt=now(),
                  phase='STARTING', platforms={}, productionReviewSubmitted=False,
                  physicalValidation='Explicitly deferred by user')

    def record(phase, platform=None, **details):
        status['phase'] = phase
        status['updatedAt'] = now()
        if platform:
            status['platforms'].setdefault(platform, {}).update(phase=phase, **details)
        else:
            status.update(details)
        temporary = statusfile.with_suffix('.tmp')
        temporary.write_text(json.dumps(status, indent=2) + '\n')
        temporary.replace(statusfile)
        print(json.dumps(dict(phase=phase, platform=platform, at=now(), **details)), flush=True)

    def run(command, log, cwd=snapshot, timeout=7200):
        with (runroot / log).open('w') as output:
            subprocess.run(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT,
                           timeout=timeout, check=True, stdin=subprocess.DEVNULL)

    def publish():
        paths = [str(statusfile.relative_to(ROOT))]
        paths += [str(p.relative_to(ROOT)) for p in (ROOT / 'docs/appstore').glob(f'BUILD{number}_*_DELIVERY.json')]
        current = subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip()
        if current != branch or subprocess.run(['git', 'diff', '--cached', '--quiet'], cwd=ROOT).returncode:
            print('Outcome saved locally; unrelated Git state prevents automatic commit.', flush=True)
            return
        subprocess.run(['git', 'add', '--', *paths], cwd=ROOT, check=True)
        if subprocess.run(['git', 'diff', '--cached', '--quiet'], cwd=ROOT).returncode:
            subprocess.run(['git', 'commit', '-m', f'Record build {number} automated beta delivery results'], cwd=ROOT, check=True)
            subprocess.run(['git', 'push', 'origin', 'HEAD:' + branch], cwd=ROOT, check=True)
        body = runroot / 'pr-body.md'
        body.write_text(f'''Fix reader navigation, Mac window controls and playback/voice selection.

The reader suspends automatic following during manual navigation and search. Mac word clicks and drag selection have separate handling. The native header, sidebar and selected-text contrast follow the app theme. The transport bar opens the narrated book at its exact cursor, provides the full player panel and shares the styled persistent voice filters. Immersive Audio stays with the narrated book while another reader is browsed.

Validation and beta delivery for build {number}: **{status['phase']}**.

- Source: `{commit}` (isolated snapshot).
- iOS: Internal and Public Beta; external availability depends on Apple beta review.
- macOS: private Internal group only.
- Automated platform details, unit results and receipts: `docs/appstore/BUILD{number}_AUTOMATION_STATUS.json`.
- Physical iPhone/iPad playback and final user visual checks remain pending. No production review submitted.
''')
        subprocess.run(['gh', 'pr', 'edit', args.pr, '--body-file', str(body)], cwd=ROOT, check=True)

    try:
        record('SNAPSHOTTING')
        if snapshot.exists():
            raise RuntimeError('Snapshot exists; refusing to overwrite an earlier delivery')
        snapshot.mkdir()
        archive = subprocess.check_output(['git', 'archive', commit], cwd=ROOT)
        subprocess.run(['tar', '-xf', '-', '-C', str(snapshot)], input=archive, check=True)
        # Generated from the checksum-verified official SDK; intentionally not
        # tracked in Git. Everything else comes from the exact committed tree.
        binary = Path('Modules/LinnetTTS/CLinnetTTS.xcframework')
        shutil.copytree(ROOT / binary, snapshot / binary, symlinks=True)
        (snapshot / 'build').mkdir(exist_ok=True)
        manifest = {}
        for path in (snapshot / binary).rglob('*'):
            if path.is_file():
                manifest[str(path.relative_to(snapshot))] = hashlib.sha256(path.read_bytes()).hexdigest()
        (runroot / 'source.json').write_text(json.dumps(dict(commit=commit, generatedSDK=manifest), indent=2) + '\n')
        beta.ROOT = snapshot
        queued = {}
        for platform, scheme, destination, dd, export_name in [
            ('IOS', 'NodusReader', 'generic/platform=iOS', '/tmp/nodus-reader-build48-ios-release', 'ios'),
            ('MAC_OS', 'NodusReader-macOS', 'generic/platform=macOS', '/tmp/nodus-reader-build48-mac-release', 'macOS')]:
            try:
                if any((b.get('preReleaseVersion') or {}).get('platform') == platform for b in beta.state(number)):
                    raise RuntimeError('Build already exists in Apple; no new upload will be attempted')
                common = ['xcodebuild', '-project', 'NodusReader.xcodeproj', '-scheme', scheme,
                          '-clonedSourcePackagesDirPath', str(PACKAGES), '-disableAutomaticPackageResolution',
                          '-jobs', '2']
                if platform == 'IOS':
                    booted = subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'booted'], text=True)
                    if SIM not in booted:
                        subprocess.run(['xcrun', 'simctl', 'boot', SIM], check=True)
                    subprocess.run(['xcrun', 'simctl', 'bootstatus', SIM, '-b'], check=True, timeout=300)
                    test_destination = 'platform=iOS Simulator,id=' + SIM
                    test_dd = '/tmp/nodus-reader-build55-sim-release'
                else:
                    test_destination = 'platform=macOS,arch=arm64'
                    test_dd = dd
                record('UNIT_TESTS', platform)
                run(common + ['-configuration', 'Debug', '-destination', test_destination,
                              '-derivedDataPath', test_dd, 'test', '-only-testing:NodusReaderTests',
                              '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
                              '-resultBundlePath', str(runroot / (platform + '-tests.xcresult')),
                              'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES'], platform + '-tests.log', timeout=3600)
                test_text = (runroot / (platform + '-tests.log')).read_text(errors='replace')
                matches = re.findall(r'Test run with (\d+) tests in (\d+) suites passed', test_text)
                if not matches or int(matches[-1][0]) == 0:
                    raise RuntimeError('No passing Swift Testing unit suite was recorded')
                record('ARCHIVING', platform, unitTestsPassed=int(matches[-1][0]))
                archive_path = ROOT / f'build/NodusReader-{export_name}-0.1.0-{number}.xcarchive'
                export = ROOT / f'build/export-{export_name}-{number}'
                run(common + ['archive', '-configuration', 'Release', '-destination', destination,
                              '-derivedDataPath', dd, '-archivePath', str(archive_path),
                              'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES', *AUTH], platform + '-archive.log')
                options = plistlib.loads((ROOT / ('Config/ExportOptions-AppStore.plist' if platform == 'IOS' else 'Config/ExportOptions-macOS.plist')).read_bytes())
                options['destination'] = 'export'
                options_path = runroot / (platform + '-export.plist')
                options_path.write_bytes(plistlib.dumps(options))
                record('EXPORTING_AND_VERIFYING', platform)
                run(['xcodebuild', '-exportArchive', '-archivePath', str(archive_path), '-exportPath', str(export),
                     '-exportOptionsPlist', str(options_path), *AUTH], platform + '-export.log')
                verify_platform = 'ios' if platform == 'IOS' else 'mac'
                run([sys.executable, str(ROOT / 'tools/appstore/verify-release57.py'), verify_platform, number],
                    platform + '-verify.log', cwd=ROOT)
                # Recheck immediately before the irreversible upload. Write an
                # upload marker first; a crash must never cause a blind retry.
                if any((b.get('preReleaseVersion') or {}).get('platform') == platform for b in beta.state(number)):
                    raise RuntimeError('Build appeared in Apple before upload; refusing a duplicate')
                marker = runroot / (platform + '-upload-attempt.json')
                if marker.exists():
                    raise RuntimeError('An upload was already attempted; inspect Apple instead of retrying')
                marker.write_text(json.dumps(dict(at=now(), commit=commit)))
                record('UPLOADING', platform)
                package = export / ('Nodus Reader.ipa' if platform == 'IOS' else 'Nodus Reader.pkg')
                run(['xcrun', 'altool', '--upload-app', '-f', str(package), '--api-key', '687TQG865G',
                     '--api-issuer', '36804ede-f0b5-4cd2-a273-c619feb6168f', '--p8-file-path', str(KEY)],
                    platform + '-upload.log', timeout=3600)
                queued[platform] = time.monotonic() + 7200
                record('APPLE_PROCESSING', platform)
            except Exception as error:
                record('FAILED', platform, error=str(error), uploadRetryAllowed=False)
                traceback.print_exc()
                # The other platform still gets its independent delivery.
        while queued:
            try:
                rows = beta.state(number)
            except Exception:
                if all(time.monotonic() > deadline for deadline in queued.values()):
                    raise
                time.sleep(30)
                continue
            for platform, deadline in list(queued.items()):
                try:
                    build = next((r for r in rows if (r.get('preReleaseVersion') or {}).get('platform') == platform), None)
                    if build and build['processingState'] in ['FAILED', 'INVALID']:
                        raise RuntimeError('Apple processing state: ' + build['processingState'])
                    if not build or build['processingState'] != 'VALID':
                        if time.monotonic() > deadline:
                            raise TimeoutError('Apple processing pending; upload must not be retried')
                        continue
                    record('ASSIGNING_TESTFLIGHT_GROUPS', platform, buildId=build['id'])
                    beta.distribute(platform, number)
                    current = next(r for r in beta.state(number) if r['id'] == build['id'])
                    internal = beta.request('GET', '/v1/betaGroups/' + beta.INTERNAL)['data']['attributes']
                    assert internal['isInternalGroup']
                    assert beta.INTERNAL in current['groups'] or internal.get('hasAccessToAllBuilds')
                    assert (beta.PUBLIC in current['groups']) == (platform == 'IOS')
                    receipt = dict(current, sourceCommit=commit, physicalValidation='Deferred by user', productionReviewSubmitted=False)
                    path = ROOT / f'docs/appstore/BUILD{number}_{platform}_DELIVERY.json'
                    path.write_text(json.dumps(receipt, indent=2) + '\n')
                    record('DISTRIBUTED', platform, buildId=build['id'], groups=current['groups'], beta=current['buildBetaDetail'])
                    del queued[platform]
                except Exception as error:
                    record('FAILED', platform, error=str(error), uploadRetryAllowed=False)
                    traceback.print_exc()
                    del queued[platform]
            if queued:
                time.sleep(30)
        complete = all(status['platforms'].get(p, {}).get('phase') == 'DISTRIBUTED' for p in ['IOS', 'MAC_OS'])
        record('COMPLETE' if complete else 'COMPLETED_WITH_ERRORS')
    except BaseException as error:
        record('FAILED', error=str(error), uploadRetryAllowed=False)
        traceback.print_exc()
    finally:
        try:
            publish()
        except Exception:
            traceback.print_exc()


if __name__ == '__main__':
    main()
