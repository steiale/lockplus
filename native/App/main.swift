// The process entry (DESIGN §10.4): `--resume-protection` runs headless before any app object exists; otherwise
// the SwiftUI app starts. No closure literals here (D73-11): the logic lives in AppEntry.
AppEntry.run()
