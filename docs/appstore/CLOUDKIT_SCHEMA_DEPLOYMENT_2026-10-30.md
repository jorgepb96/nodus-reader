# CloudKit production schema correction — 30 October 2026

Container: `iCloud.ai.nodus.reader`, team `6RPLS9EA4X`.

The reported server error was `Cannot create new type Book in production schema`. The pre-change Development and Production exports both contained only the built-in Users type. Previous TestFlight approval and local queue tests had not verified server schema availability.

The schema was prepared from the actual CloudSyncService payloads. Apple validated and imported it into Development, then confirmed **Changes Deployed — The schema is deployed to Production.** The deployment created Annotation, Book, Bookmark, Collection, Membership, Preference and Tombstone, plus one record-name index per type. No security roles changed. Application types have no public-database grants; Users was preserved. No library records were created, deleted or copied during schema deployment.

A fresh Production export is versioned at `Config/CloudKitSchema.ckdb`. All seven types and 54 custom field names and types match the app payloads. Book has 30 total fields including six system fields. `tools/cloudkit/check-schema.py` passes for that export and fails against the original Users-only schema and a schema missing Book.title. The check verifies local coverage; it does not replace remote deployment or authenticated end-to-end testing.

Existing clients can retry their queued work against the corrected production schema. No new application build was required. This confirms the missing-schema error is addressed; it does not establish that a particular user's queue has drained or that signed two-device sync has passed.
