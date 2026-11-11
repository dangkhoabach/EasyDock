# 7-Zip

EasyDock extracts archives with `7zz`, the command line version of [7-Zip](https://www.7-zip.org/)
by Igor Pavlov. It is built from this source when the app builds and runs as a separate program in
`EasyDock.app/Contents/Helpers/7zz`, inside a sandbox that lets it read only the archive and write
only to the folder it extracts to.

| | |
|---|---|
| Version | 26.06 (2026-11-06) |
| File | `7z2606-src.tar.xz`, unmodified |
| SHA-256 | `a4e374c8f864f51df48c2cfd0e1413ec3b2ea030deae852d6a655402ebb61ac4` |
| From | <https://www.7-zip.org/download.html>, <https://github.com/ip7z/7zip/releases/tag/26.06> |
| License | GNU LGPL 2.1 ([copying.txt](copying.txt)), BSD 3-clause and 2-clause for some files, unRAR license restriction for the RAR decoder: [License.txt](License.txt), [unRarLicense.txt](unRarLicense.txt) |

The RAR decoder was developed using the source of unRAR. That code may not be used to develop a
RAR (WinRAR) compatible archiver; EasyDock only extracts.

## How it is built

`scripts/build-7zip.sh`, run by the app target's **Build 7-Zip** phase: it checks the SHA-256,
unpacks the source into a temporary folder and builds `CPP/7zip/Bundles/Alone2` with 7-Zip's own macOS
makefiles for each architecture of the build, then joins them with `lipo`. Xcode signs the result
when it copies it into the app.

## Updating

Before each EasyDock release, read <https://www.7-zip.org/history.txt> for security fixes. To
move to a new version:

1. Download `7zXXXX-src.tar.xz` from the GitHub release and check its SHA-256.
2. Replace the file here and update this table, `License.txt`, `unRarLicense.txt` and
   `copying.txt` (from the source's `DOC/`).
3. Update the file name and `SOURCE_SHA256` in `scripts/build-7zip.sh`, and the input path of
   the **Build 7-Zip** phase in the Xcode project.
4. Build, run the tests, and update the 7-Zip entry in `EasyDockApp/Resources/ThirdPartyNotices.txt`.
