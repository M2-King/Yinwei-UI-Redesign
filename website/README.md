# Yinwei public website

Static product introduction and download site for **音围 Yinwei**.

This is not the Flutter app and does not use Flutter Web.

## Preview locally

From this directory:

```bash
python3 -m http.server 4173
```

Open `http://127.0.0.1:4173/`.

There is no build step. Deploy the `website/` directory as static files.

## Structure

```
website/
  index.html
  css/site.css
  js/site.js
  img/                 # mark, favicon, real workstation screenshots
  downloads/           # MANIFEST.json + APK at deploy time (APK is not in git)
  scripts/fetch-android-apk.sh
  scripts/deploy.sh
```

## Downloads

Binaries stay off git. Metadata is in `downloads/MANIFEST.json`.

### Android A1 Preview

```bash
./scripts/fetch-android-apk.sh
```

This pulls GitHub Actions artifact `yinwei-android-live-transfer-a1` from run `35569621376` and writes:

`downloads/Yinwei-Android-A1-Preview.apk`

Expected SHA-256:

`697325d506a6f7d4dd7f8d0b5c9437d400204c4da02af80ad54d6fab2a4b18fb`

Commit `17bdc6b`. Preview / test build. Not production. Not HRTF Live Transfer.

### Windows / iOS / macOS

No public packages are published on this site yet.

- Windows: workstation exists; no installer in this repository.
- iOS: unsigned CI IPA is a developer artifact, not a public install.
- macOS: in development.

To add a future real package: put the file in `downloads/`, update `MANIFEST.json` and the matching card in `index.html`. Do not invent URLs.

## Deployment target

This environment had **no** `~/.ssh/config` and no deploy host alias. Do not guess a server.

After you have a working SSH host alias and document root:

```bash
export YINWEI_SSH_HOST=your-ssh-alias
export YINWEI_REMOTE_ROOT=/actual/document/root
./scripts/deploy.sh
```

The script:

1. Fetches the Android APK if missing
2. Inspects the remote web server
3. Creates a timestamped backup of the remote root
4. rsyncs this directory (excluding `.git` and scripts)

It does not store keys, passwords, or tokens.

## Rollback

The backup path is printed by `deploy.sh`, typically:

`/var/www/<site>-backup-YYYYMMDD-HHMMSS`

Restore with rsync from that backup onto the document root, then reload nginx/Caddy.

## MIME types

APK, ZIP, EXE, and IPA should download as binaries. If the server does not already map them, add:

```
application/vnd.android.package-archive  apk;
application/octet-stream                 ipa exe zip;
```

Do not disable HTTPS or security headers to make downloads work.
