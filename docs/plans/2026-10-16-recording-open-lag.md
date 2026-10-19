# Fast recording detail text implementation plan

**Goal:** Eliminate multi-second UI stalls when switching recordings with long transcripts.

**Approved design:** Replace the single selectable SwiftUI Text in the notes panel with a read-only NSTextView. Keep the existing outer scroll view, padding, colors, text selection across paragraphs and Copy action. Do not change recording data or inference.

**Evidence:** On recording 439, reading the 176 KB transcript takes under 1 ms; a standalone reproduction of the current SwiftUI layout takes 3.16 s each time. Native full-text layout takes 0.059 s. Lazy per-line views take 0.016 s but change cross-line selection behavior, so the user approved the native component.

**Architecture:** The macOS representable belongs alongside RecordingDetailView. Its text container follows the proposed width and reports the full document height to the existing scroll view. Only changed text is assigned, and native layout is cached by TextKit. No nested scroll view or editable text.

**Tech stack:** Swift, SwiftUI NSViewRepresentable, AppKit NSTextView, XCTest.

1. Add a synthetic long-transcript detail-view regression test in RecordingsPhaseOneTests.swift; measure initial layout and replacement with another long recording, require each under 1.5 s. Run on the original UI and confirm the performance failure.
2. Replace only the notes text rendering with the native representable; preserve full selection/copy, sizing on width changes, accessibility, fallback colors and non-editability. Add focused text-update, width and selection tests.
3. Rerun focused tests, then the full suite; compare the actual recording's text in the isolated display harness. Review the diff.
4. Make a local commit on codex/fix-recording-open-lag. Build and verify a signed standalone app, retain the previous installation and install the updated app without stopping the running app or capture. Report test evidence, branch, commit and restart requirement.

**Validation command:** xcodebuild test -project Recordly.xcodeproj -scheme Recordly -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/recordly-open-lag-build -clonedSourcePackagesDirPath /Users/nacnac/Library/Developer/Xcode/DerivedData/Recordly-dcnqgmaydqjvmobdaeiplxlqynfn/SourcePackages -disableAutomaticPackageResolution -skipPackageUpdates ONLY_ACTIVE_ARCH=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Recordly Local Development' DEVELOPMENT_TEAM=''
