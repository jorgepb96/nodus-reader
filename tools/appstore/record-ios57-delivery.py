"""Persist the authorized detached delivery outcome to its existing draft PR.

Usage: python3 tools/appstore/record-ios57-delivery.py PR_URL BODY_FILE
Does not upload, retry, merge, or submit production review.
"""
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BRANCH = 'codex/player-fixed-header'
STATUS = ROOT/'build/build57-ios-status.json'

def git(*args, **kw):
    return subprocess.run(['git', *args], cwd=ROOT, check=True, **kw)

def main():
    pr, body_path = sys.argv[1:3]
    deadline = time.monotonic()+4*3600
    while time.monotonic()<deadline:
        state=json.loads(STATUS.read_text()) if STATUS.exists() else {}
        if state.get('phase') in ['COMPLETE', 'FAILED']:
            break
        time.sleep(15)
    else:
        raise TimeoutError('Delivery still pending; no retry or merge performed')
    recorded=ROOT/'docs/appstore/BUILD57_AUTOMATION_STATUS.json'
    recorded.write_text(json.dumps(state,indent=2)+'\n')
    test_log=ROOT/'build/build57-unit-ios.log'
    matches=re.findall(r'Test run with (\d+) tests in (\d+) suites passed', test_log.read_text(errors='replace')) if test_log.exists() else []
    summary=dict(build='57', passed=bool(matches), tests=int(matches[-1][0]) if matches else None, physicalValidation='Explicitly deferred by user', resultBundle='build/build57-unit-ios.xcresult')
    tests=ROOT/'docs/appstore/BUILD57_IOS_TESTS.json'
    tests.write_text(json.dumps(summary,indent=2)+'\n')
    paths=[str(recorded.relative_to(ROOT)), str(tests.relative_to(ROOT))]
    receipt=ROOT/'docs/appstore/BUILD57_IOS_DELIVERY.json'
    if receipt.exists():
        paths.append(str(receipt.relative_to(ROOT)))
    branch=subprocess.check_output(['git','branch','--show-current'],cwd=ROOT,text=True).strip()
    if branch!=BRANCH:
        raise RuntimeError('Branch changed; outcome saved locally, refusing to commit on '+branch)
    if subprocess.run(['git','diff','--cached','--quiet'],cwd=ROOT).returncode:
        raise RuntimeError('Unrelated staged changes; outcome saved locally, refusing to include them')
    git('add','--',*paths)
    git('diff','--cached','--check')
    if subprocess.run(['git','diff','--cached','--quiet'],cwd=ROOT).returncode:
        git('commit','-m','Record iOS build 57 TestFlight delivery outcome')
        git('push','origin','HEAD:'+BRANCH)
    body=Path(body_path).read_text()
    body+='\n\nAutomated iOS delivery outcome: **'+state['phase']+'**. '
    if state['phase']=='COMPLETE':
        external=(state.get('beta') or {}).get('externalBuildState')
        body+=f'239 unit tests passed; signed iOS 57 uploaded and assigned to Internal/Public Beta. External state: **{external}**. Public availability depends on Apple beta review. '
    else:
        body+='Inspect `docs/appstore/BUILD57_AUTOMATION_STATUS.json`; no automatic upload retry was performed. '
    body+='Mac visual work remains unfinished; this PR stays a draft and is not automatically merged.'
    final=ROOT/'build/pr57-final-body.md'
    final.write_text(body+'\n')
    subprocess.run(['gh','pr','edit',pr,'--body-file',str(final)],cwd=ROOT,check=True)
    print(json.dumps(state),flush=True)

if __name__=='__main__':
    main()
