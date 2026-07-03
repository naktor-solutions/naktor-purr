# Releasing Barktor

## TL;DR

```bash
# from a clean main checkout
vim Resources/Info.plist   # bump CFBundleShortVersionString + CFBundleVersion
vim CHANGELOG.md           # add a "## [X.Y.Z] - YYYY-MM-DD" section
git commit -am "Release X.Y.Z"
git push
scripts/release.sh --dry-run   # build + package only, no tag
scripts/release.sh             # tag + GitHub release with DMG + sha256
```

`scripts/release.sh` does the rest: builds, signs, packages the drag-install
DMG, writes the SHA-256 sidecar the in-app updater requires, and publishes a
GitHub release whose notes are your CHANGELOG section.

## Prerequisites

- `gh auth login` with push access to `naktor-solutions/barktor`.
- **The signing identity "Purr Local Dev" in your login keychain.** This is
  the important one:

  macOS ties the app's permissions (Accessibility, Input Monitoring,
  Microphone) to the bundle ID **plus the signing certificate**. Every
  release must be signed with the *same* certificate or every user re-grants
  all permissions after updating. Do not create a new certificate; ask a
  teammate who has released before to export theirs:

  1. They open **Keychain Access**, find the "Purr Local Dev" certificate
     (with its private key) under *My Certificates*, right-click →
     *Export…* as a password-protected `.p12`, and hand it over securely
     (never commit it).
  2. You double-click the `.p12` to import it, then trust it for code
     signing and let `codesign` use it without prompting:

     ```bash
     security add-trusted-cert -p codeSign \
       <(security find-certificate -c "Purr Local Dev" -p)
     # re-import with codesign access if signing prompts for a password:
     # security import barktor.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
     ```
  3. Verify: `security find-identity -p codesigning -v` lists
     "Purr Local Dev".

  (The identity keeps the legacy "Purr" name on purpose - renaming it would
  mean a new certificate, which is exactly what we're avoiding.)

## After building

Mount `dist/Barktor.dmg` once and eyeball the install window: custom
background with the drag arrow, Barktor.app on the left, Applications on the
right. The window layout ships as a pre-baked `Resources/dmg-DS_Store`;
if it ever renders as a plain white window, that file needs regenerating.

## Swapping in new artwork (icon / logo)

Replace these files, then commit and release as usual:

| File | Used for |
| --- | --- |
| `Resources/AppIcon.icns` | App icon, About window, DMG volume icon |
| `Resources/barktor_menubar_glyph.pdf` | Menu-bar status item (template image: monochrome, alpha-only, ~18 pt) |
| `Resources/dmg-launch-window.png` | DMG install-window background (640×400ish, includes the drag arrow) |

(The README header uses the Naktor wordmark, `Resources/naktor-logo*.svg`.)

Add a CHANGELOG line for the new icon under the release's section.
`make app` / `release.sh` copy these into the bundle automatically; icons are
cached aggressively by macOS, so if Finder shows the old icon after an
install, that's cosmetic staleness, not a build problem.

## Notes

- First install on a new Mac: right-click → Open (builds are not notarized).
- Updates after that are one click from **About Barktor**; the updater
  refuses any DMG whose SHA-256 sidecar is missing or wrong.
- The notarized path (`make dmg`) needs an Apple Developer ID and is not
  what we currently use.
