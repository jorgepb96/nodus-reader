"""Build NodusReader/Resources/Localizable.xcstrings from extracted keys + Spanish table.
usage: gencat.py OUT.xcstrings DERIVED_DIR [DERIVED_DIR...]"""
import json, glob, sys, re, os
sys.path.insert(0, os.path.dirname(__file__))
from es1 import ES as A
from es2 import ES as B
ES = {**A, **B}
out, dirs = sys.argv[1], sys.argv[2:]
keys = set()
for d in dirs:
    for f in glob.glob(d + '/**/*.stringsdata', recursive=True):
        try: data = json.load(open(f))
        except Exception: continue
        for table, items in data.get('tables', {}).items():
            if table == 'Localizable':
                keys.update(i['key'] for i in items)
keyfile = os.path.join(os.path.dirname(__file__), '..', 'export_keys.txt')
if os.path.exists(keyfile):
    keys.update(k for k in open(keyfile).read().split('\n') if k and not k.startswith('CF') and k not in ('NSHumanReadableCopyright', 'Markdown Document'))
stale = {"%lld %@", "%lld %@ for “%@”", "%lld %@ not downloaded on this %@.", "%lld voices%@"}
keys -= stale
# Keys looked up at runtime from the DesignSystem package (bundle .main).
keys.update(["Progress", "%@, by %@", "Nodus Reader", "Light", "Dark", "OLED Black", "Sepia",
             "High Contrast", "System", "Collection",
             "Voices", "Models", "Original PDF", "Intelligent Reading"])
spec = re.compile(r'%(?:\d+\$)?(lld|ld|d|@|lf|f|%)')
def specs(s): return sorted(m.group(1) for m in spec.finditer(s))
missing, bad, strings = [], [], {}
for k in sorted(keys):
    entry = {}
    if k in ES:
        v = ES[k]
        if specs(k) != specs(v): bad.append((k, v))
        entry = {"localizations": {"es": {"stringUnit": {"state": "translated", "value": v}}}}
    elif re.search('[A-Za-z]{2}', k):
        missing.append(k)
    strings[k] = entry
json.dump({"sourceLanguage": "en", "strings": strings, "version": "1.0"},
          open(out, 'w'), ensure_ascii=False, indent=2, sort_keys=True)
print(f"{len(keys)} keys, {len(missing)} without Spanish, {len(bad)} placeholder mismatches")
for k in missing: print("MISSING:", k)
for k, v in bad: print("BAD:", k, "=>", v)
