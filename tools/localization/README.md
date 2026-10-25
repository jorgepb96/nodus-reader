# Localization

English is the base language; Spanish is the one translation. A device whose
preferred language is Spanish shows Spanish; every other language shows English.

- `es1.py`, `es2.py` — the English → Spanish table, keyed by the exact catalog key
  (`%@`, `%lld`; use positional `%1$@` when Spanish reorders arguments).
- `gencat.py` — rebuilds `NodusReader/Resources/Localizable.xcstrings` from the keys
  the compiler extracts (`SWIFT_EMIT_LOC_STRINGS`) plus the keys the DesignSystem
  package looks up at runtime, and reports keys with no Spanish or mismatched
  placeholders.

After adding UI text, build for iOS and macOS, then run:

```bash
python3 tools/localization/gencat.py NodusReader/Resources/Localizable.xcstrings \
  build/DerivedData-ios/Build/Intermediates.noindex build/DerivedData-mac/Build/Intermediates.noindex
```

Add any reported key to `es2.py` and run it again until it reports 0 missing.
