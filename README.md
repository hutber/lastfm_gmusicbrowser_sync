# Last.fm gmusicbrowser Playcount Sync

A gmusicbrowser plugin that pulls track play counts from a Last.fm account and updates local gmusicbrowser `playcount` values.

The plugin is installed as `LASTFMPLAYCOUNTSYNC` and appears in gmusicbrowser Settings under:

`Settings -> Plugins -> Last.fm playcount sync`

## Features

- Pulls Last.fm `user.getTopTracks` play counts.
- Matches local tracks by normalized artist and title.
- Updates gmusicbrowser play counts through `Songs::Set`.
- Optional username/password validation when API secret is configured.
- `Test API` button to verify API key, username, and optional password/API secret.
- Automatic backup before sync, enabled by default.
- Manual `Backup now` and `Restore latest backup` buttons.
- `Only increase local play counts` option to avoid lowering existing local counts.

## Requirements

- gmusicbrowser with Perl/Gtk3 support.
- Perl modules available in a standard Perl install:
  - `JSON::PP`
  - `Digest::MD5`
  - `POSIX`
- A Last.fm API key. An API secret is optional unless you want to validate the password.

## Get a Last.fm API Key

Open:

`https://www.last.fm/api/accounts`

Create an API account if needed.

For Last.fm's application form:

- **Application name:** `gmusicbrowser Last.fm Playcount Sync`
- **Application description:** `Syncs Last.fm track play counts into gmusicbrowser local play counts.`
- **Callback URL:** leave blank
- **Application homepage:** leave blank, or use this project URL if you publish it

Last.fm's callback URL is only needed for web-based authentication. This plugin is a desktop plugin, so it does not need a callback URL.

## Install

Clone or copy this folder somewhere local. From this repository:

```bash
mkdir -p ~/.config/gmusicbrowser/plugins
ln -sf /home/hutber/www/npm/lastfm_gmusicbrowser_sync/lastfm_playcount_sync.pm ~/.config/gmusicbrowser/plugins/lastfm_playcount_sync.pm
```

Restart gmusicbrowser after installing or updating the plugin:

```bash
gmusicbrowser -quit
gmusicbrowser &
```

If `gmusicbrowser -quit` does not close it, quit from the tray/menu and then start it again.

## Configure

Open:

`Settings -> Plugins -> Last.fm playcount sync`

Fill in:

- **username:** your Last.fm username
- **password:** optional; only used for validation when API secret is also filled in
- **API key:** required
- **API secret:** optional; required only for password validation

Recommended defaults:

- Keep **Only increase local play counts** enabled.
- Keep **Backup play counts before sync** enabled.
- Leave **maximum pages, 0 for all** at `0` unless you want to limit the import.

## Test

Click **Test API** before syncing.

The test checks:

- API key and username by calling Last.fm `user.getTopTracks` with `limit=1`.
- Password and API secret by calling Last.fm `auth.getMobileSession`, only when both password and API secret are filled in.

Results appear in the plugin log area.

## Sync

Click **Force sync**.

The plugin will:

1. Backup current gmusicbrowser play counts if backup is enabled.
2. Fetch Last.fm top tracks page by page.
3. Match Last.fm tracks to local gmusicbrowser tracks by artist/title.
4. Update local play counts.
5. Log a summary with fetched, updated, skipped, and unmatched counts.

## Backups

Backups are written to:

`~/.config/gmusicbrowser/lastfm_playcount_sync_backups/`

Backup files are JSON and named like:

`playcounts-YYYYMMDD-HHMMSS.json`

Each backup stores:

- title
- artist
- album
- full filename
- normalized artist/title key
- playcount

Use **Restore latest backup** to restore the newest backup. Restore matches by full filename first, then falls back to a unique artist/title match.

## Updating

If the installed plugin is a symlink, edit this repository's `lastfm_playcount_sync.pm` and restart gmusicbrowser.

Verify the symlink:

```bash
ls -l ~/.config/gmusicbrowser/plugins/lastfm_playcount_sync.pm
readlink -f ~/.config/gmusicbrowser/plugins/lastfm_playcount_sync.pm
```

Verify gmusicbrowser can discover the plugin:

```bash
gmusicbrowser -listplugin | grep LASTFMPLAYCOUNTSYNC
```

Expected output:

```text
LASTFMPLAYCOUNTSYNC : Last.fm playcount sync
```

## Notes

- Last.fm play counts are per Last.fm account and are fetched from `user.getTopTracks`.
- The plugin does not need a Last.fm callback URL.
- The password is not required for playcount syncing. It is only used to validate credentials when API secret is present.
- Because the plugin uses gmusicbrowser's normal song update API, gmusicbrowser should save changed play counts using its normal save behavior.
