# Yinwei public website

Static product introduction and download site for **音围 Yinwei**.

This is not the Flutter app and does not use Flutter Web.

## Public China-reachable URLs

The live site is on **Tencent EdgeOne Makers (China)**:

https://workspace-khz2prs8-qjvhzxns.edgeone.cool/

The Android APK is served through a China-reachable GitHub proxy (**ghfast.top**). JSDMirror rejects this 49.6MB file (403). Direct GitHub is often unreachable on mainland networks.

https://ghfast.top/https://github.com/M2-King/Yinwei-UI-Redesign/raw/refs/heads/cursor/android-a1-capture-consent-9d7c/website/downloads/Yinwei-Android-A1-Preview.apk

Anonymous EdgeOne projects must be **claimed** in the Tencent Cloud China console or they are removed. Claim from the CLI output of `scripts/deploy-edgeone-china.sh`. Do not commit API tokens or claim secrets.

## Preview locally

From this directory:

```bash
python3 -m http.server 4173
```

Open `http://127.0.0.1:4173/`. On localhost the APK link stays a relative file. On the EdgeOne host it switches to the JSDMirror URL.

There is no Vite/React build step.

## Structure

```
website/
  index.html
  css/site.css
  js/site.js
  img/
  downloads/           # MANIFEST.json + Android A1 Preview APK
  scripts/fetch-android-apk.sh
  scripts/deploy-edgeone-china.sh
  scripts/deploy.sh    # optional SSH path if a host alias exists
```

## Downloads

### Android A1 Preview

File: `downloads/Yinwei-Android-A1-Preview.apk`

- Commit `fbe47c9` · workflow `35605274210`
- 49,607,281 bytes
- SHA-256 `d636a88b2bef4141a4394487fda9ecace1ab18338ce1a4aea7467a519709eb67`
- Preview / test build. Not production. Not HRTF Live Transfer.
- Android 10+ for playback capture.

Refresh the local copy from GitHub Actions:

```bash
./scripts/fetch-android-apk.sh
```

### Windows / iOS / macOS

No public packages on this site yet.

## Deploy (China)

```bash
./scripts/deploy-edgeone-china.sh
```

This uploads HTML/CSS/JS/images only to EdgeOne China. It does not upload the APK.

## SSH (optional)

Only if `~/.ssh/config` has a known host alias:

```bash
export YINWEI_SSH_HOST=your-ssh-alias
export YINWEI_REMOTE_ROOT=/actual/document/root
./scripts/deploy.sh
```
