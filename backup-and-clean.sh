#!/bin/bash
#
# backup-and-clean — Copy files to a backup location and delete verified originals.
#
# Copies files matching a pattern from one or more source directories to a backup
# directory, verifies backups by size, and safely moves verified originals to the
# volume's trash. Designed for large media files (e.g., stream recordings).
#
# Configuration is loaded from a .env file (default: ~/.backup-and-clean.env).
# See .env.example for all available options.
#
# Usage:
#   ./backup-and-clean.sh [--config <path>] [--action <action>] [--headless]
#
# Actions: copy, delete, copy+delete, dry-run
#
# Options:
#   --config <path>   Path to config file (default: ~/.backup-and-clean.env)
#   --action <action> Run non-interactively with the given action
#   --headless        Run without GUI dialogs (log to terminal only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$HOME/.backup-and-clean.env}"
HEADLESS=0
ACTION=""

# --- Argument parsing ---

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --action)
            ACTION="$2"
            shift 2
            ;;
        --headless)
            HEADLESS=1
            shift
            ;;
        --help|-h)
            head -20 "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# --- Load config ---

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    echo "Config file not found: $CONFIG_FILE" >&2
    echo "Copy .env.example to $CONFIG_FILE and edit it." >&2
    exit 1
fi

# --- Validate required config ---

SOURCE_DIRS="${SOURCE_DIRS:-}"
BACKUP_DIR="${BACKUP_DIR:-}"
FILE_PATTERN="${FILE_PATTERN:-*.mkv}"
LOG_FILE="${LOG_FILE:-$HOME/Desktop/backup-and-clean.log}"
APP_TITLE="${APP_TITLE:-Backup & Clean}"

if [ -z "$SOURCE_DIRS" ]; then
    echo "SOURCE_DIRS is not set in config." >&2
    exit 1
fi

if [ -z "$BACKUP_DIR" ]; then
    echo "BACKUP_DIR is not set in config." >&2
    exit 1
fi

# --- Core functions ---

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

trap 'log_message "!!! SCRIPT INTERRUPTED (signal received) !!!"; exit 1' INT TERM HUP

show_dialog() {
    local message="$1"
    local icon="${2:-note}"
    if [ "$HEADLESS" -eq 1 ]; then
        echo "$message"
    else
        osascript -e "display dialog \"$message\" buttons {\"OK\"} default button \"OK\" with icon $icon" 2>/dev/null
    fi
}

show_error() {
    local message="$1"
    if [ "$HEADLESS" -eq 1 ]; then
        echo "ERROR: $message" >&2
    else
        osascript -e "display dialog \"$message\" buttons {\"OK\"} default button \"OK\" with icon stop" 2>/dev/null
    fi
}

format_bytes() {
    local bytes="$1"
    if command -v numfmt &>/dev/null; then
        numfmt --to=iec-i --suffix=B "$bytes"
    elif command -v gnumfmt &>/dev/null; then
        gnumfmt --to=iec-i --suffix=B "$bytes"
    else
        echo "$bytes bytes"
    fi
}

format_seconds() {
    local s="$1"
    if [ "$s" -lt 60 ]; then
        echo "${s}s"
    elif [ "$s" -lt 3600 ]; then
        printf '%dm %02ds' $((s/60)) $((s%60))
    else
        printf '%dh %02dm' $((s/3600)) $(((s%3600)/60))
    fi
}

# Polls a destination temp file size while a copy is in progress and logs
# percentage / rate / ETA every PROGRESS_INTERVAL seconds.
# Args: $1 = path to temp file being written, $2 = total source size in bytes,
#       $3 = friendly name for log lines.
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-10}"
poll_copy_progress() {
    local temp_file="$1"
    local source_size="$2"
    local label="$3"
    local start_ts copied now_ts elapsed rate_bps eta_sec pct rate_hr eta_hr
    start_ts=$(date +%s)
    while sleep "$PROGRESS_INTERVAL"; do
        # Stop when temp file disappears (copy finished or aborted).
        [ -f "$temp_file" ] || break
        copied=$(get_file_size "$temp_file")
        now_ts=$(date +%s)
        elapsed=$((now_ts - start_ts))
        if [ "$elapsed" -gt 0 ] && [ "${copied:-0}" -gt 0 ]; then
            rate_bps=$((copied / elapsed))
            if [ "${source_size:-0}" -gt 0 ]; then
                pct=$(( copied * 100 / source_size ))
            else
                pct=0
            fi
            if [ "$rate_bps" -gt 0 ] && [ "${source_size:-0}" -gt "$copied" ]; then
                eta_sec=$(( (source_size - copied) / rate_bps ))
                eta_hr=$(format_seconds "$eta_sec")
            else
                eta_hr="?"
            fi
            rate_hr=$(format_bytes "$rate_bps")
            log_message "    PROGRESS: $label — ${pct}% ($(format_bytes "$copied") / $(format_bytes "$source_size")), ${rate_hr}/s, ETA ${eta_hr}"
        fi
    done
}

get_file_size() {
    local file="$1"
    if stat -f%z "$file" 2>/dev/null; then
        return
    fi
    # Linux fallback
    stat -c%s "$file" 2>/dev/null || echo 0
}

files_match() {
    local source_file="$1"
    local backup_file="$2"

    [ -f "$backup_file" ] || return 1

    # Check backup file isn't currently being written to
    if lsof "$backup_file" 2>/dev/null | grep -q .; then
        log_message "SKIPPED: $(basename "$source_file") (backup is currently being written to)"
        return 1
    fi

    local s1 s2
    s1=$(get_file_size "$source_file")
    s2=$(get_file_size "$backup_file")
    [ "$s1" = "$s2" ] && [ "$s1" -gt 0 ]
}

copy_with_verification() {
    local source_file="$1"
    local backup_file="$2"
    local backup_subdir backup_basename temp_file source_size cp_pid poll_pid cp_status copy_start copy_end copy_elapsed avg_rate

    backup_subdir=$(dirname "$backup_file")
    backup_basename=$(basename "$backup_file")

    mkdir -p "$backup_subdir" || return 1
    temp_file=$(mktemp "$backup_subdir/.${backup_basename}.tmp.XXXXXX") || return 1

    source_size=$(get_file_size "$source_file")
    copy_start=$(date +%s)

    # Run cp in the background so a sibling poller can report progress.
    cp -p "$source_file" "$temp_file" 2>/dev/null &
    cp_pid=$!

    # Only worth polling for files large enough that user actually waits on them.
    # 50 MiB threshold — smaller files finish in well under one PROGRESS_INTERVAL.
    if [ "${source_size:-0}" -ge 52428800 ]; then
        poll_copy_progress "$temp_file" "$source_size" "$(basename "$source_file")" &
        poll_pid=$!
    fi

    wait "$cp_pid"
    cp_status=$?

    if [ -n "${poll_pid:-}" ]; then
        kill "$poll_pid" 2>/dev/null
        wait "$poll_pid" 2>/dev/null
    fi

    if [ "$cp_status" -ne 0 ]; then
        rm -f "$temp_file"
        return 1
    fi

    copy_end=$(date +%s)
    copy_elapsed=$((copy_end - copy_start))
    if [ "$copy_elapsed" -gt 0 ] && [ "${source_size:-0}" -gt 0 ]; then
        avg_rate=$((source_size / copy_elapsed))
        log_message "    cp done: $(basename "$source_file") in $(format_seconds "$copy_elapsed") avg $(format_bytes "$avg_rate")/s — verifying byte-by-byte..."
    fi

    if ! cmp -s "$source_file" "$temp_file" 2>/dev/null; then
        rm -f "$temp_file"
        return 1
    fi

    if ! mv -f "$temp_file" "$backup_file" 2>/dev/null; then
        rm -f "$temp_file"
        return 1
    fi

    return 0
}

move_to_trash() {
    local file="$1"

    # Try volume-local .Trashes first (instant, no extra space)
    local volume trash_dir
    volume=$(df "$file" 2>/dev/null | tail -1 | awk '{print $NF}')
    trash_dir="${volume}/.Trashes/$(id -u)"
    mkdir -p "$trash_dir" 2>/dev/null
    if mv "$file" "$trash_dir/" 2>/dev/null; then
        return 0
    fi

    # Fallback to user's home trash
    if mv "$file" "$HOME/.Trash/" 2>/dev/null; then
        return 0
    fi

    return 1
}

# --- Preflight checks ---

if [ ! -d "$BACKUP_DIR" ]; then
    show_error "Backup directory not found: $BACKUP_DIR"
    log_message "ERROR: Backup directory not found: $BACKUP_DIR"
    exit 1
fi

# Parse SOURCE_DIRS (colon-separated) into array
IFS=':' read -ra source_dir_list <<< "$SOURCE_DIRS"
active_sources=()
source_display=""

for dir in "${source_dir_list[@]}"; do
    if [ -d "$dir" ]; then
        active_sources+=("$dir")
        if [ -n "$source_display" ]; then
            source_display="$source_display, $dir"
        else
            source_display="$dir"
        fi
    fi
done

if [ ${#active_sources[@]} -eq 0 ]; then
    show_error "No source directories found."
    log_message "ERROR: No source directories found"
    exit 1
fi

# --- Action selection ---

if [ -z "$ACTION" ]; then
    if [ "$HEADLESS" -eq 1 ]; then
        echo "No --action specified in headless mode." >&2
        echo "Use: copy, delete, copy+delete, or dry-run" >&2
        exit 1
    fi

    ACTION=$(osascript -e '
tell application "System Events" to set frontmost of process "Terminal" to true
choose from list {"Copy Only", "Copy + Delete", "Delete Backed Up", "Delete Dry Run"} with prompt "'"$APP_TITLE"'

Sources: '"$source_display"'
Backup: '"$BACKUP_DIR"'
Pattern: '"$FILE_PATTERN"'

What would you like to do?" default items {"Copy + Delete"} with title "'"$APP_TITLE"'"' 2>&1)

    if [ -z "$ACTION" ] || [ "$ACTION" = "false" ]; then
        exit 0
    fi
fi

# Normalize action names
should_copy=0
should_delete=0
dry_run=0

case "$ACTION" in
    "Copy Only"|copy)
        should_copy=1
        ;;
    "Copy + Delete"|copy+delete)
        should_copy=1
        should_delete=1
        ;;
    "Delete Backed Up"|delete)
        should_delete=1
        ;;
    "Delete Dry Run"|dry-run)
        should_delete=1
        dry_run=1
        ;;
    *)
        echo "Unknown action: $ACTION" >&2
        exit 1
        ;;
esac

log_message "=== Starting $APP_TITLE (action: $ACTION, pattern: $FILE_PATTERN) ==="

# --- Copy phase ---

if [ "$should_copy" -eq 1 ]; then
    log_message "--- Copy Phase ---"
    copied_count=0
    updated_count=0
    copy_skipped=0
    copy_failed=0

    for src_dir in "${active_sources[@]}"; do
        log_message "Copying from: $src_dir"
        while IFS= read -r -d '' source_file; do
            relative_path="${source_file#"$src_dir"/}"
            backup_file="$BACKUP_DIR/$relative_path"
            backup_existed=0

            if [ -f "$backup_file" ]; then
                backup_existed=1
            fi

            if files_match "$source_file" "$backup_file"; then
                log_message "COPY SKIPPED (already verified): $relative_path"
                ((copy_skipped++)) || true
                continue
            fi

            file_size=$(get_file_size "$source_file")
            log_message "COPYING: $relative_path ($(format_bytes "$file_size"))..."
            if copy_with_verification "$source_file" "$backup_file"; then
                if [ "$backup_existed" -eq 1 ]; then
                    log_message "UPDATED + VERIFIED: $relative_path"
                    ((updated_count++)) || true
                else
                    log_message "COPIED + VERIFIED: $relative_path"
                    ((copied_count++)) || true
                fi
            else
                log_message "COPY FAILED: $relative_path"
                ((copy_failed++)) || true
            fi
        done < <(find "$src_dir" -type f -name "$FILE_PATTERN" -print0)
    done

    log_message "Copy complete: $copied_count copied, $updated_count updated, $copy_skipped already verified, $copy_failed failed"

    if [ "$should_delete" -eq 0 ]; then
        show_dialog "Copy complete!\n\nCopied: $copied_count\nUpdated: $updated_count\nAlready verified: $copy_skipped\nFailed: $copy_failed\n\nSee $LOG_FILE for details."
        exit 0
    fi

    if [ $copy_failed -gt 0 ]; then
        if [ "$HEADLESS" -eq 0 ]; then
            osascript -e 'display dialog "Copy phase complete but '"$copy_failed"' files failed.\n\nCopied: '"$copied_count"'\nUpdated: '"$updated_count"'\nAlready verified: '"$copy_skipped"'\nFailed: '"$copy_failed"'\n\nDelete will only remove files with verified backups.\n\nContinue?" buttons {"Cancel", "Continue to Delete"} default button "Cancel" with icon caution' 2>/dev/null
            if [[ $? -ne 0 ]]; then
                exit 0
            fi
        else
            log_message "WARNING: $copy_failed files failed to copy. Continuing to delete phase (only verified files)."
        fi
    else
        if [ "$HEADLESS" -eq 0 ]; then
            osascript -e 'display dialog "Copy phase complete!\n\nCopied: '"$copied_count"'\nUpdated: '"$updated_count"'\nAlready verified: '"$copy_skipped"'\n\nProceed to delete verified files?" buttons {"Cancel", "Continue to Delete"} default button "Continue to Delete" with icon note' 2>/dev/null
            if [[ $? -ne 0 ]]; then
                exit 0
            fi
        fi
    fi
fi

# --- Delete phase ---

log_message "--- Delete Phase ---"
deleted_count=0
missing_backup_count=0
verification_failed_count=0
delete_failed_count=0
total_space_freed=0

for src_dir in "${active_sources[@]}"; do
    log_message "Processing: $src_dir"
    file_count=$(find "$src_dir" -type f -name "$FILE_PATTERN" 2>/dev/null | wc -l | tr -d ' ')
    log_message "Found $file_count files matching '$FILE_PATTERN' in $src_dir"

    while IFS= read -r -d '' source_file; do
        relative_path="${source_file#"$src_dir"/}"
        backup_file="$BACKUP_DIR/$relative_path"

        if [ ! -f "$backup_file" ]; then
            log_message "SKIPPED: $relative_path (no backup found)"
            ((missing_backup_count++)) || true
            continue
        fi

        if ! files_match "$source_file" "$backup_file"; then
            log_message "SKIPPED: $relative_path (backup exists but size mismatch)"
            ((verification_failed_count++)) || true
            continue
        fi

        file_size=$(get_file_size "$source_file")

        if [ "$dry_run" -eq 1 ]; then
            log_message "DRY RUN - WOULD DELETE: $relative_path ($(format_bytes "$file_size"))"
            ((deleted_count++)) || true
            ((total_space_freed += file_size)) || true
        elif move_to_trash "$source_file"; then
            log_message "MOVED TO TRASH: $relative_path ($(format_bytes "$file_size"))"
            ((deleted_count++)) || true
            ((total_space_freed += file_size)) || true
        else
            log_message "FAILED TO DELETE: $relative_path (file may be in use)"
            ((delete_failed_count++)) || true
        fi
    done < <(find "$src_dir" -type f -name "$FILE_PATTERN" -print0)
done

space_freed_hr=$(format_bytes "$total_space_freed")

log_message "=== Process Complete ==="

if [ "$dry_run" -eq 1 ]; then
    log_message "DRY RUN - Would delete: $deleted_count files"
    log_message "Skipped (no backup): $missing_backup_count"
    log_message "Skipped (size mismatch): $verification_failed_count"
    log_message "Space that would be freed: $space_freed_hr"

    show_dialog "DRY RUN Complete (nothing was deleted)\n\nWould delete: $deleted_count files\nSkipped (no backup): $missing_backup_count\nSkipped (size mismatch): $verification_failed_count\nSpace that would be freed: $space_freed_hr\n\nSee $LOG_FILE for details."
else
    log_message "Deleted: $deleted_count"
    log_message "Skipped (no backup): $missing_backup_count"
    log_message "Skipped (size mismatch): $verification_failed_count"
    log_message "Failed (in use): $delete_failed_count"
    log_message "Space freed: $space_freed_hr"

    show_dialog "Complete!\n\nDeleted: $deleted_count\nSkipped (no backup): $missing_backup_count\nSkipped (size mismatch): $verification_failed_count\nFailed (in use): $delete_failed_count\nSpace freed: $space_freed_hr\n\nSee $LOG_FILE for details."
fi

exit 0
