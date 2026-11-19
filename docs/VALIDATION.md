# Validation — 18 November 2026

The following describes observed results, not a promise of compatibility with every port or macOS release.

| Check | Observed result |
| --- | --- |
| Native Mac anonymous validation and synthetic Settings signature | Passed on Intel, macOS 26.6 |
| Mac helper builds | Intel and Apple Silicon slices compiled and verified |
| Device helper builds | ARM64 compiled and ad-hoc signatures verified |
| New client against existing device modules | Both USB channels connected; native phone AuthKit check passed while the previous Mac provider was stopped |
| Existing Settings iCloud sign-in | Previously accepted by Apple on the development setup; the current test did not request another password entry |
| Catalog token after device reboot | Native cache and consumer both read a valid token |
| New packaged catalog command | Passed on the device: native cache preserved, HTTP 200 for Telegram Messenger |
| Fresh catalog token requested by packaged Mac provider | Passed; native anonymous token received with valid server expiry, without saving or printing its value |
| Fresh installation of newly named device hooks | Not yet tested end to end; experimental |
| Execution on Apple Silicon hardware | Not yet tested |
| App Store account login and downloads | Not provided by this release |
| iCloud Passwords/Keychain synchronization | Unresolved |

The phone retained the same boot image and graphical configuration during these client tests. No account was deleted, and the previous owner-local provider was restored after the isolated test. Logs used for development contain no published credentials or request bodies and are not shipped in this repository.

The project includes local tests for framing, channel identity, bounded inputs, replay rejection, leases, private state, mapping ownership and catalog metadata. Test results must be rerun when these components change.

The release check completed **16 tests in 8.143 seconds, all passing**.

## USB image preparation — 19 November 2026

The complete updated repository suite passed: **21 tests in 16.236 seconds**. The image test rebuilds and re-reads an actual APFS fixture, preserving permissions, symlinks and files, and checks a 280004-byte VTBL extent table and the empty-md0 layout. Stock/malformed and AVB-signed input is rejected.

The CLI also rebuilt a private copy of the actual gpu167 image. The candidate was decoded and its APFS contents checked; the XNU kernel, md0, external-volume table and fallback Android bytes were preserved. It was **not flashed or boot-tested**. No device image is included in this repository or ZIP.

All four host helpers, including usb_host, were compiled with arm64 and x86_64 slices, verified with lipo and codesign. The two device USB helpers were compiled for iOS ARM64 and their signatures verified. Physical testing on an Apple Silicon Mac remains pending.
