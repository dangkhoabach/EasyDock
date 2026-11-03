# Security policy

## Reporting a vulnerability

Please report security issues privately, not in a public issue:

- **GitHub:** Security tab → **Report a vulnerability** on this repository, or
- **Contact form** on [dangkhoabach.vn](https://dangkhoabach.vn), asking for a private channel.

Include the app version (Settings), your macOS version and the steps to reproduce. You will get
a reply within a week. Please give a fix the chance to ship before you disclose the issue
publicly.

## Supported versions

Only the latest release gets security fixes. It reaches you through **Check for Updates…**, or
download it from [apps.dangkhoabach.vn/easydock](https://apps.dangkhoabach.vn/easydock).

## Scope

EasyDock holds the Accessibility and Screen Recording permissions and keeps a clipboard history,
so these are in scope:

- **Clipboard history:** reading stored items without the key in the Keychain, recording an
  item a password manager marked as concealed, or recording from an app on the exclusion list.
- **Permissions:** another app using EasyDock to act through its Accessibility or Screen
  Recording permission.
- **Window thumbnails:** a thumbnail written to disk or sent anywhere.
- **Updates:** installing an update that is not signed with the release key.

Out of scope:

- A Mac that is already compromised, or someone using it while it is unlocked.
