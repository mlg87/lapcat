# lapcat

LapCat is a macOS menu-bar meeting notetaker: it records your mic and the meeting app's
audio as two channels (no bot), transcribes on-device, and enhances your notes with an LLM.
See [docs/product-requirements/lapcat-mvp-prd.md](docs/product-requirements/lapcat-mvp-prd.md).

## Development

Requirements: macOS 14.2+, Swift 6.2 (Command Line Tools are enough; Xcode is optional).
The project is a single SwiftPM package — there is no `.xcodeproj`.

```bash
scripts/make-dev-cert.sh     # once: self-signed "LapCat Dev" identity in its own keychain
scripts/fetch-sidecars.sh    # once: llama-server binaries for the local LLM (vendor/)
scripts/dev.sh               # build build/LapCat.app (debug), sign it, run it in the foreground
scripts/test.sh              # run the test suites (use this, not bare `swift test`)
scripts/bundle-app.sh release  # Universal 2 (arm64 + x86_64) app bundle
swift run lapcat-dev --help  # developer CLI (probes and benchmarks)
```

The app only runs from its signed bundle: macOS privacy grants (microphone, system audio,
accessibility) are keyed to the bundle's signature, and the stable "LapCat Dev" identity keeps
them across rebuilds. Set `LAPCAT_CODESIGN_IDENTITY` to sign with a different identity.

`scripts/test.sh` exists because the Command Line Tools keep `Testing.framework` off the default
search path: a bare `swift test` builds fine but silently runs zero tests.
