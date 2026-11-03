# Pronunciation CloudKit deployment — 3 November 2026

Container: `iCloud.ai.nodus.reader`, team `6RPLS9EA4X`.

Added only `Book.pronunciationsJSON STRING` in Development, reviewed the Production diff (one insertion, zero indexes or security-role changes) and deployed it. Apple confirmed “Changes Deployed — The schema is deployed to Production.” A fresh Production export was downloaded and copied to `Config/CloudKitSchema.ckdb`. The contract check passes: seven application record types, 55 payload fields, no PUBLIC permissions on application types. Book now has 31 fields including six system fields. Users and all other fields were preserved.

Proof: `build/Pronunciation-CloudKit-Deployed.png`; schema export: `Config/CloudKitSchema.ckdb`. The schema operation did not create, delete or copy library records.

Signed Development validation completed between a Mac peer and the physical iPhone of Jorge. Session `E2A0BAAE-80BA-437A-862A-25078CB2D8B0`: initial pronunciation Mac → iPhone; edit iPhone → Mac; dictionary deletion Mac → iPhone; acknowledgment and temporary-zone cleanup. The iPhone test `livePronunciationCloudKitRoundTrip()` passed in 4.672 seconds. Result bundle: `build/DerivedData-device-pronunciation/Logs/Test/Test-NodusReader-2026.11.03_00-30-58-+0100.xcresult`.

The test used synthetic data in a session-specific zone and an isolated SwiftData fixture, exercising the app’s payload builder, remote apply and library mutations. Personal books, annotations, reading positions and iCloud Drive files were not involved. Production metadata availability is verified by the schema export; authenticated transport was tested in Development.
