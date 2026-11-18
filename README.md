# LiveScribe

Lightweight live transcriber for iPhone (Korean + English).

- **System audio** – captures the sound of every app through an iOS broadcast extension and transcribes it in the background.
- **Microphone** – transcribes speech around you, keeps running with the screen locked.
- Every session is saved; open it to edit, copy or share the text.

## Build the IPA (no Xcode)

1. Create a GitHub repository and add `.github/workflows/build.yml` (it's the only file you need; the full source is embedded in it).
2. Commit. The **Build LiveScribe IPA** workflow runs on GitHub's macOS machines (~5 min).
3. Open the repo's **Releases** page and download `LiveScribe.ipa`, then install it with AltStore / SideStore.

If the repo also contains this source tree (`project.yml` at the root), the workflow builds from those files instead, so you can edit them.

## Notes

- AltStore uses 2 App IDs for this app (the app + its broadcast extension).
- Recognition uses Apple's Speech framework, on-device when available. One language at a time; switch it live.
- Apps that block screen capture (Netflix, Apple TV, some music apps) come through silent.
