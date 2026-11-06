"""Launch the authorized one-shot delivery independently of Codex's session."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
from datetime import datetime

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--build', type=int, required=True)
args = parser.parse_args()
number = str(args.build)
label = 'ai.nodus.reader.beta' + number
runroot = root / 'build' / ('beta' + number)
runroot.mkdir(parents=True, exist_ok=True)
statusfile = root / f'docs/appstore/BUILD{number}_AUTOMATION_STATUS.json'
if statusfile.exists() and json.loads(statusfile.read_text()).get('phase') != 'QUEUED':
    raise SystemExit('Delivery already started: inspect its status instead of launching a duplicate.')
launchfile = Path.home() / 'Library/LaunchAgents' / (label + '.plist')
launchfile.parent.mkdir(parents=True, exist_ok=True)
config = {
    'Label': label,
    'ProgramArguments': ['/usr/bin/caffeinate', '-i', sys.executable, '-u',
                         str(root / 'tools/appstore/deliver-beta.py'), '--build', number, '--pr', '76'],
    'WorkingDirectory': str(root),
    'EnvironmentVariables': {'PATH': os.environ.get('PATH', '/usr/bin:/bin:/usr/sbin:/sbin'),
                             'PYTHONUNBUFFERED': '1'},
    'RunAtLoad': True,
    'KeepAlive': False,
    'ProcessType': 'Background',
    'StandardOutPath': str(runroot / 'worker.log'),
    'StandardErrorPath': str(runroot / 'worker.log'),
}
launchfile.write_bytes(plistlib.dumps(config))
subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(launchfile)], check=True)
print(json.dumps({'label': label, 'launchAgent': str(launchfile), 'log': str(runroot / 'worker.log'),
                  'status': str(statusfile), 'startedAt': datetime.now().astimezone().isoformat()}))
