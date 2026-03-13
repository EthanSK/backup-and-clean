# backup-and-clean

Copy files to a backup location and safely delete verified originals.

Designed for large media files (e.g., stream recordings) where you want to:
1. Copy files from one or more source directories to a backup drive
2. Verify the backup matches the original (size check + lsof guard)
3. Move verified originals to trash (on the same volume, so it's instant)

## Features

- **Multiple source directories** — back up from several locations at once
- **Configurable file pattern** — defaults to `*.mkv`, works with any glob
- **Safe delete** — only deletes files with a verified same-size, non-empty backup
- **lsof guard** — won't delete if the backup file is still being written to
- **Moves to trash** — uses the volume's `.Trashes` folder (instant, recoverable)
- **Dry run** — see what would be deleted without touching anything
- **Headless mode** — run from cron or scripts without GUI dialogs
- **macOS app** — optional `.app` bundle for double-click launching from Finder
- **Detailed logging** — every action is logged with timestamps

## Quick start

```bash
# Clone
git clone https://github.com/EthanSK/backup-and-clean.git
cd backup-and-clean

# Create your config
cp .env.example ~/.backup-and-clean.env
# Edit ~/.backup-and-clean.env with your paths

# Make executable
chmod +x backup-and-clean.sh

# Run interactively (shows a dialog on macOS)
./backup-and-clean.sh

# Or run headless
./backup-and-clean.sh --headless --action dry-run
./backup-and-clean.sh --headless --action copy
./backup-and-clean.sh --headless --action delete
./backup-and-clean.sh --headless --action copy+delete
```

## Configuration

Create `~/.backup-and-clean.env` (or pass `--config <path>`):

```bash
# Colon-separated list of directories to back up from
SOURCE_DIRS="/path/to/source1:/path/to/source2"

# Where backups are stored
BACKUP_DIR="/path/to/backup"

# Glob pattern for files to process (default: *.mkv)
FILE_PATTERN="*.mkv"

# Log file path
LOG_FILE="$HOME/Desktop/backup-and-clean.log"

# Title shown in macOS dialogs
APP_TITLE="Backup & Clean"
```

## macOS app

To create a `.app` you can double-click from Finder:

```bash
chmod +x macos-app/create-app.sh
./macos-app/create-app.sh
```

This creates `~/Desktop/Backup and Clean.app`. The app opens Terminal and runs the script there (needed for access to external volumes).

## Actions

| Action | Copies? | Deletes? | Description |
|--------|---------|----------|-------------|
| `copy` / Copy Only | Yes | No | Copy unverified files to backup |
| `delete` / Delete Backed Up | No | Yes | Delete files that have a verified backup |
| `copy+delete` / Copy + Delete | Yes | Yes | Copy first, then delete verified |
| `dry-run` / Delete Dry Run | No | No | Show what would be deleted |

## Safety

- Files are only deleted if a backup exists with **matching size** and is **non-empty**
- Files currently being written to (detected via `lsof`) are skipped
- Deleted files go to the volume's **trash** (recoverable via Finder)
- Copy uses a **temp file + byte-for-byte verify + atomic rename** to prevent corruption
- Every action is **logged** with timestamps
- The script **traps interrupts** and logs if killed

## Tests

```bash
chmod +x test/test.sh
./test/test.sh
```

## License

MIT
