# Agent Dashboard

Agent Dashboard is a native macOS app for the daily cleanup of a developer's machine. It finds every git repository and worktree on the Mac, shows what each project takes on disk and in memory and what is running in it (agent sessions, dev servers, daemons), and shows how much space a deletion would really free. Merged worktrees, build output, package caches and Docker leftovers go in a couple of clicks, without switching between the terminal, Finder and Docker Desktop.

## Release

The app is signed ad hoc (no Developer ID, no notarization) and updates itself through Sparkle. Releases are built locally; nothing here runs in CI.

### Publishing a release

1. Bump the version: `Scripts/bump-version.sh 0.2.0`. It writes `MARKETING_VERSION` and raises `CURRENT_PROJECT_VERSION` by one in `Config/Version.xcconfig`.
2. Commit it: `git commit -am "build: version 0.2.0"`.
3. Tag it: `git tag v0.2.0`. The tag must be `v` plus `MARKETING_VERSION`.
4. Build: `Scripts/release.sh`. It archives the Release app, signs it, packs `dist/Agent-Dashboard-<version>.dmg` and writes `dist/appcast.xml`.
5. Publish: `git push --follow-tags`, then `gh release create v0.2.0 dist/Agent-Dashboard-0.2.0.dmg dist/appcast.xml --title v0.2.0`.

`release.sh` refuses to continue when `SUPublicEDKey` is missing from the app or is still `REPLACE_WITH_PUBLIC_ED_KEY`, and when `GITHUB_REF_NAME` is a tag that differs from `v<MARKETING_VERSION>`.

Optional environment:

- `SPARKLE_PRIVATE_KEY_FILE`: an exported EdDSA private key; without it `generate_appcast` reads the login keychain.
- `SPARKLE_BIN`: the folder with `generate_appcast`; by default the Sparkle package artifact of the archive build, then `~/bin/sparkle/bin`.
- `AD_SIGN_IDENTITY`: a stable self-signed identity to sign with instead of ad hoc.

If `create-dmg` is installed the DMG gets its window layout; otherwise `hdiutil` makes a plain one.

### First install

The app is not notarized, so Gatekeeper blocks the first launch. Drag it to Applications and open it once; macOS refuses. Then open System Settings > Privacy & Security, scroll to the Security section and click "Open Anyway" (it appears only after that first blocked launch), and confirm. Alternatively run `xattr -dr com.apple.quarantine "/Applications/Agent Dashboard.app"` before the first launch. The right-click Open route no longer works since macOS 15. Later updates arrive through Sparkle and are not blocked.

### Keychain after an update

Ad-hoc signatures change with every build, so after an update macOS asks again for access to the Keychain items the app stored (such as host tokens). Choose Always Allow.
