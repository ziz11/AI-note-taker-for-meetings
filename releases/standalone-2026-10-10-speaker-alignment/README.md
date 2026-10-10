# Recordly standalone — transcript speaker alignment

[Download Recordly](Recordly-5268b03-local.zip). Installed and launched at `/Applications/Recordly.app` on 2026-10-10. Xcode is unnecessary at runtime; speech models are provisioned separately.

## Changes

Whole ASR phrases now aggregate a voice's fragmented turns and split timed text when the speaker changes. Short same-voice pauses no longer introduce unnecessary Remote fragments. A short boundary turn can reuse the ID established on the exact same audio in adjacent window padding. Ambiguous and unsupported speech remains explicitly unresolved; voice similarity thresholds are unchanged.

See [alignment analysis](../../docs/speaker-transcript-alignment.md) and [original-recording verification](../../docs/recording-7C943EA0-verification.md).

## Integrity

- Compiled source: `5268b03c1f59bb198a6cea649aa92a6febaa3289`.
- Release tag: `standalone-2026-10-10-speaker-alignment`.
- FluidAudio: 0.17.7, revision `503b4bd1bbf7220882de39fe8ae6716aae4132da`.
- ZIP: **23,975,751 bytes**, SHA-256 `48b97bf8779b137d3531c848549e67a11ab17ed20e626d677687a6624e725488`.
- App: **53,586,609 logical bytes**. Executable SHA-256 `00df5f4662ce07aa120f35eb1bb52d822ec11daa5a45ed46e32d5e071c547630`.
- Universal arm64/x86_64; native inference verified on M3 Pro. App version 0.1.0, build 1; minimum macOS 15.
- Built, extracted and installed bundles passed `codesign --verify --deep --strict` with the persistent `Recordly Local Development` certificate. This remains local distribution rather than a notarized Developer ID release.
- Full suite: **368 tests, 0 failures, 3 optional skips**. Native copy acceptance: **1 test, 0 failures**. Final original-recording/repeat/name-copy acceptance: **1 test, 0 failures**; independent artifact audit passed.
- Original recording: all 48 AAC hashes, every cached token/time and all established voice IDs preserved. All 143 full transcript segments and all identities/aliases identical on repeat. Assigned name preserved in 23 segments on a separate copy, including JSON/TXT/SRT.
- Final session-voice coverage: **4,193 / 4,444 remote tokens (94.35%)**. Four original problem windows still lack a reliable session assignment. This is partial continuity, not annotated human-speaker accuracy.

Verify the archive from this folder with `shasum -a 256 -c SHA256SUMS`.

The [previous FluidAudio/session-speaker release](../standalone-2026-10-10-fluid-speakers/README.md) remains unchanged for rollback. The prior installed app was saved locally at `/private/tmp/Recordly-before-speaker-alignment-2026-10-10.app`. Private recordings and voice vectors are absent from the release. Opening the installed app preserved transcript JSON/TXT/SRT, speaker identities and session metadata byte-for-byte.
