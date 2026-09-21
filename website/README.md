# Yinwei public website

Static product introduction and download site for **音围 Yinwei**.

This is not the Flutter app and does not use Flutter Web.

## Public China-reachable URLs

The live site is on **Tencent EdgeOne Makers (China)**:

https://workspace-khz2prs8-qjvhzxns.edgeone.cool/

The Android APK is served through a China-reachable GitHub proxy (**ghfast.top**). JSDMirror rejects this ~51MB file (403). Direct GitHub is often unreachable on mainland networks.

https://ghfast.top/https://github.com/M2-King/Yinwei-UI-Redesign/raw/refs/heads/cursor/android-a2-dsp-bridge-9d7c/website/downloads/Yinwei-Android-A2-Preview.apk

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
  downloads/           # MANIFEST.json + Android A2 Preview APK
  scripts/fetch-android-apk.sh
  scripts/deploy-edgeone-china.sh
  scripts/deploy.sh    # optional SSH path if a host alias exists
```

## Downloads

### Android A2 Preview

File: `downloads/Yinwei-Android-A2-Preview.apk`

- Commit `dfb1cb6` · workflow `35612161963`
- 51,360,447 bytes
- SHA-256 `aaad5aae826e2001e0c62292bbd0d1abe27fc77c5b9800d75a07a6d8a52ab465`
- Preview / test build. Capture → JNI → spatial_core HRTF DSP.
- Wet frames are measured and discarded. No wet output yet. Not A3.
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
