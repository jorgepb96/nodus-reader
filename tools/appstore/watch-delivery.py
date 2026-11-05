"""Keep a local delivery awake, refresh its PR description, and record failures.

Usage: python3 tools/appstore/watch-delivery.py PID STATUS_JSON LOG PR BODY_FILE
This observes an already authorized worker; it never retries uploads or merges.
"""
import json, os, subprocess, sys, time
from pathlib import Path

pid = int(sys.argv[1])
status, log, pr, body = Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], Path(sys.argv[5])
awake = subprocess.Popen(['caffeinate', '-i', '-w', str(pid)])
try:
    while True:
        try:
            os.kill(pid, 0)
            state = subprocess.check_output(['ps', '-p', str(pid), '-o', 'stat='], text=True).strip()
            if state.startswith('Z'):
                break
        except (ProcessLookupError, subprocess.CalledProcessError):
            break
        time.sleep(10)
    result = json.loads(status.read_text()) if status.exists() else {}
    if result.get('phase') == 'COMPLETE':
        if body.exists():
            subprocess.run(['gh', 'pr', 'edit', pr, '--body-file', str(body)], check=True)
        print(json.dumps(result), flush=True)
    else:
        result['phase'] = 'FAILED — inspect the delivery log; no automatic retry'
        result['errorTail'] = log.read_text(errors='replace')[-5000:] if log.exists() else 'Log missing'
        status.write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result), flush=True)
finally:
    awake.terminate()
