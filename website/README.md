# Yinwei public website

Static product introduction and download site for **音围 Yinwei**.

This is not the Flutter app and does not use Flutter Web.

## Public China-reachable URLs

The live site is on **Tencent EdgeOne Makers (China)**:

https://workspace-jf3znr8o-wyagttnf.edgeone.cool/

The Android APK is **not** uploaded through EdgeOne COS from this environment (50MB uploads stall). It is stored in git and served by **JSDMirror**, a jsDelivr-compatible CDN on EdgeOne, which domestic networks can fetch:

https://cdn.jsdmirror.com/gh/M2-King/Yinwei-UI-Redesign@yinwei-ui-redesign/website/downloads/Yinwei-Android-A1-Preview.apk

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

- Commit `17bdc6b` · workflow `35569621376`
- 49,607,281 bytes
- SHA-256 `697325d506a6f7d4dd7f8d0b5c9437d400204c4da02af80ad54d6fab2a4b18fb`
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
