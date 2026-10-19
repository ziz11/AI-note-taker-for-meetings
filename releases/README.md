# Release records

This directory contains small historical build reports and checksums only. **Do not commit application bundles, ZIP archives, DMGs or other build artifacts.**

Build locally with `./scripts/build-standalone-local.sh`. Output belongs in ignored `build/`. If distributing a build, attach it as a GitHub Release asset or use separate artifact storage; do not add the binary to the source tree or Git LFS.

On 2026-10-20, seven tracked archives (150,429,647 bytes) and the obsolete standalone tags that retained them were removed from Git. The original local archives and repository history were backed up outside Git. The individual reports retain their original source hashes and checksums as historical evidence, not active download links.

The delivery branches are `develop` and `main`. Their application code remains unchanged by artifact cleanup.
