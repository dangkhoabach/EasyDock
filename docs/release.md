# Releasing EasyDock

Everything runs locally on this Mac: no CI secrets. Build and sign here, upload by hand to
admin.dangkhoabach.vn, and Sparkle inside the installed app picks the new version up from
`updates.dangkhoabach.vn/easydock/appcast.xml`.

Builds are signed with an **Apple Development** certificate (a free Personal Team, Team ID
`83829K9Z69`), not Developer ID, and are not notarized. On another Mac the first launch needs
System Settings › Privacy & Security › **Open Anyway**.

## Why the certificate matters

macOS ties three things to the app's signature:

- the **Accessibility** and **Screen Recording** grants (TCC, by designated requirement);
- the Keychain item that holds the **clipboard history key** (by Team ID);
- library validation of the embedded Sparkle framework.

Ad-hoc signing gives every build a new identity, so each update would ask for both permissions
again and lose the clipboard key. A self-signed certificate keeps the permissions but has no
Team ID, so the Keychain asked for the key after every build, and one such prompt froze the app
at launch. An Apple Development certificate has a Team ID, which keeps all three. `release.sh`
refuses to build with anything else and checks the Team ID of the result.

### Renewing the certificate

An Apple Development certificate is valid for one year. Before it expires:

1. Xcode › Settings › Accounts › the Personal Team › Manage Certificates › **+ Apple
   Development**.
2. Put the new certificate's name in `Local.xcconfig` (`CODE_SIGN_IDENTITY`). The Team ID stays
   the same.
3. Release as usual, then install that build here and check that Accessibility and Screen
   Recording still work. The designated requirement names the certificate, so a renewed one may
   make macOS ask again; if it does, say so in that release's notes.

Whether a copy signed with an expired certificate keeps launching is not known yet; check it on
this Mac when the date comes.

## One-time setup

1. **Signing** — `Local.xcconfig` (gitignored) with `CODE_SIGN_IDENTITY = Apple Development: …`
   and `DEVELOPMENT_TEAM = 83829K9Z69`; see `Local.xcconfig.example`.
2. **Sparkle EdDSA key pair** — already generated under the `easydock` Keychain account;
   `SUPublicEDKey` in `EasyDockApp/Info.plist` is its public half. Only if it ever has to be
   regenerated:
   ```bash
   .sparkle-tools/2.10.0/bin/generate_keys --account easydock
   ```
   `--account` is required: without it the tools fall back to the default account and sign
   with another app's key. A new key pair means every installed copy rejects the next update.
3. **`create-dmg`** — `brew install create-dmg`.

`Info.plist` does not set `SUEnableAutomaticChecks`: Sparkle asks on the second launch whether
to check automatically, and Settings › Updates reads and writes that answer. `AppDelegate`
touches `AppUpdater.shared` at launch so the daily check starts, since the controller is lazy.

## Cutting a release

```bash
./scripts/release.sh
```

It prompts for the version (Enter keeps the current one) and writes it into both
`CFBundleShortVersionString` and `CFBundleVersion`, then runs: `swift test` (Core) → app tests
→ Release build (universal arm64 + x86_64, temporary DerivedData) → verify the signature, Hardened
Runtime, Team ID, entitlements and architectures → DMG → Sparkle signature under the `easydock`
account. Output lands in `release-output/<version>/` (gitignored): the `.dmg`, its `.sig` and the
`.app` for `scripts/install-local.sh`.

The version must be `MAJOR.MINOR.PATCH` and not lower than the current one, since Sparkle never
offers a lower one. If anything fails after the version was written, `Info.plist` is restored.
Commit the version change afterwards (`+ Release +`), and tag that commit.

The app tests run a Debug copy of EasyDock as their host. It turns the system's ⌘Tab off and back
on like the real app; the installed copy turns it off again within half a second.

## Build settings worth knowing

- `Local.xcconfig` is the base configuration of both build configurations, so the build fails
  until it exists rather than silently picking an identity.
- `ENABLE_HARDENED_RUNTIME` is `YES` for Release only: Debug builds link the app through a
  generated `<App>.debug.dylib`, and the test host hung under Hardened Runtime.
- `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` for Release: Xcode otherwise injects
  `get-task-allow` into Manual-signed builds.
- Entitlements: `app-sandbox` false and `cs.disable-library-validation` true, nothing else.
  The sandbox would block reading other apps' windows, the Dock and the system's ⌘Tab setting.
  Library validation is lifted so that a build from source signed ad-hoc or self-signed can
  still load Sparkle.
- **Sparkle is pinned to an exact version** (`2.10.0`), and `Package.resolved` is committed.
  Bumping it is a deliberate edit that comes with reading Sparkle's release notes, and with
  updating `SPARKLE_VERSION` and `SPARKLE_SHA256` in `release.sh`.
- **7-Zip** (`Contents/Helpers/7zz`, which extracts archives) is built from the source in
  `ThirdParty/7-Zip` by the **Build 7-Zip** phase and signed by Xcode as it is copied in;
  `release.sh` checks that it has both architectures, the team, Hardened Runtime and no
  entitlements. It reads untrusted files, so before every release read
  <https://www.7-zip.org/history.txt> for security fixes and update it as
  `ThirdParty/7-Zip/README.md` describes.
- `SWIFT_EMIT_LOC_STRINGS = YES`: the compiler emits the exact runtime keys for interpolated
  strings, or catalog entries never match at runtime.

## Uploading a release

Go to **admin.dangkhoabach.vn → Apps**, use "Publish new app" for the first release (slug
`easydock`) or "Republish" afterwards, tick macOS and upload:

| Form field | File |
|---|---|
| Installer file | `EasyDock-<version>.dmg` |
| Sparkle signature (.sig) | `EasyDock-<version>.dmg.sig` (paste its contents) |

Leave the Tauri-format "Updater bundle"/"Signature" fields empty. The admin panel writes
`updates.dangkhoabach.vn/easydock/appcast.xml`, which `SUFeedURL` points at. Compare the SHA-256
the script printed with the uploaded file: the DMG and the signature are two separate fields,
and a mismatch makes every client reject the update with an error that points nowhere near the
cause.

## Tag and GitHub release

Once the DMG is on the admin panel, tag the commit that set the version (never a later commit)
and publish a GitHub release from that tag:

```bash
git tag v<version> <commit>
git push origin v<version>
```

On github.com/dangkhoabach/EasyDock/releases/new pick that tag, title it `EasyDock <version>`
and write the English release notes, then an Install paragraph (**Open Anyway** on first launch,
the two permissions, and **Check for Updates…** for an installed copy) and the DMG's SHA-256.
Attach the same `EasyDock-<version>.dmg` that went to the admin panel, not a rebuild, and check
that the SHA-256 GitHub shows for the asset matches.

## Installing locally

```bash
./scripts/install-local.sh            # newest release-output/<version>
```

Quits the running copy, waits for its ⌘Tab watcher to end, copies the `.app` into
`/Applications` and launches it. The permissions carry over from earlier builds signed with the
same certificate.
