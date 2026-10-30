#!/usr/bin/env python3
"""Check a CloudKit schema export against record fields sent by the app.

Usage: python3 tools/cloudkit/check-schema.py [production-export.ckdb]
This checks the schema contract, not whether it has been deployed remotely.
Apple's import validation checks CloudKit syntax and compatible field types.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
path = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'Config/CloudKitSchema.ckdb'
schema = path.read_text()
source = (ROOT / 'NodusReader/Core/Sync/CloudSyncService.swift').read_text()
types = dict(re.findall(r'RECORD TYPE (\w+)\s*\((.*?)\);', schema, re.S))
errors = []
record_count = 0
field_count = 0
for constructor in re.finditer(r'CKRecord\(recordType: "(\w+)"', source):
    name = constructor[1]
    following = source[constructor.end():]
    # Each constructor is in a dedicated case or function. Do not include
    # assignments from a later case/function in this record's field contract.
    boundary = re.search(r'\n(?:        case |    (?:private )?func )', following)
    body = following[:boundary.start()] if boundary else following
    fields = set(re.findall(r'(?:record|tombstone)\["(\w+)"\]\s*=', body))
    if not fields:
        errors.append(f'{name}: no assignments found; update the checker for the new construction pattern')
        continue
    if name not in types:
        errors.append(f'{name}: record type missing')
        continue
    declarations = set(re.findall(r'^\s*(\w+)\s+(?:STRING|INT64|DOUBLE|TIMESTAMP|REFERENCE|BYTES|ASSET|LOCATION|NUMBER|LIST)', types[name], re.M))
    missing = fields - declarations
    if missing:
        errors.append(f'{name}: missing fields {", ".join(sorted(missing))}')
    # Nodus uses the private database. A schema export must not silently grant
    # public access to books, notes, positions or preferences.
    if re.search(r'\bGRANT\b', types[name]):
        errors.append(f'{name}: unexpected PUBLIC database permissions')
    record_count += 1
    field_count += len(fields)
if record_count == 0:
    errors.append('No record contracts checked')
if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)
print(f'{record_count} record types, {field_count} payload fields present; no PUBLIC permissions on app types.')
print('Remote production deployment must be verified separately with a fresh production export.')
