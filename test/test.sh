#!/bin/bash
#
# Tests for backup-and-clean.sh
# Run: ./test/test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT="$REPO_DIR/backup-and-clean.sh"

PASS=0
FAIL=0
TEST_DIR=""

# --- Helpers ---

setup() {
    TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/source" "$TEST_DIR/backup" "$TEST_DIR/trash"
    cat > "$TEST_DIR/test.env" << EOF
SOURCE_DIRS="$TEST_DIR/source"
BACKUP_DIR="$TEST_DIR/backup"
FILE_PATTERN="*.mkv"
LOG_FILE="$TEST_DIR/test.log"
APP_TITLE="Test"
EOF
}

teardown() {
    [ -n "$TEST_DIR" ] && rm -rf "$TEST_DIR"
}

create_file() {
    local path="$1"
    local size="${2:-1024}"
    mkdir -p "$(dirname "$path")"
    dd if=/dev/urandom of="$path" bs=1 count="$size" 2>/dev/null
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        ((PASS++)) || true
    else
        echo "  FAIL: $desc (expected '$expected', got '$actual')"
        ((FAIL++)) || true
    fi
}

assert_file_exists() {
    local desc="$1" path="$2"
    if [ -f "$path" ]; then
        echo "  PASS: $desc"
        ((PASS++)) || true
    else
        echo "  FAIL: $desc (file not found: $path)"
        ((FAIL++)) || true
    fi
}

assert_file_missing() {
    local desc="$1" path="$2"
    if [ ! -f "$path" ]; then
        echo "  PASS: $desc"
        ((PASS++)) || true
    else
        echo "  FAIL: $desc (file should not exist: $path)"
        ((FAIL++)) || true
    fi
}

run_script() {
    bash "$SCRIPT" --config "$TEST_DIR/test.env" --headless "$@" 2>&1
}

# --- Tests ---

test_copy_new_files() {
    echo "TEST: Copy new files to backup"
    setup

    create_file "$TEST_DIR/source/video1.mkv" 2048
    create_file "$TEST_DIR/source/video2.mkv" 4096

    run_script --action copy >/dev/null

    assert_file_exists "video1 copied to backup" "$TEST_DIR/backup/video1.mkv"
    assert_file_exists "video2 copied to backup" "$TEST_DIR/backup/video2.mkv"

    local s1 s2
    s1=$(stat -f%z "$TEST_DIR/source/video1.mkv" 2>/dev/null || stat -c%s "$TEST_DIR/source/video1.mkv")
    s2=$(stat -f%z "$TEST_DIR/backup/video1.mkv" 2>/dev/null || stat -c%s "$TEST_DIR/backup/video1.mkv")
    assert_eq "video1 backup same size as source" "$s1" "$s2"

    teardown
}

test_copy_skips_existing() {
    echo "TEST: Copy skips already-backed-up files"
    setup

    create_file "$TEST_DIR/source/video1.mkv" 2048
    cp -p "$TEST_DIR/source/video1.mkv" "$TEST_DIR/backup/video1.mkv"

    output=$(run_script --action copy)
    assert_eq "reports skipped" "0" "$(echo "$output" | grep -c "COPIED + VERIFIED" || true)"

    teardown
}

test_dry_run_deletes_nothing() {
    echo "TEST: Dry run doesn't delete anything"
    setup

    create_file "$TEST_DIR/source/video1.mkv" 2048
    cp -p "$TEST_DIR/source/video1.mkv" "$TEST_DIR/backup/video1.mkv"

    run_script --action dry-run >/dev/null

    assert_file_exists "source file still exists after dry run" "$TEST_DIR/source/video1.mkv"

    teardown
}

test_delete_only_verified() {
    echo "TEST: Delete only removes verified files"
    setup

    create_file "$TEST_DIR/source/video1.mkv" 2048
    create_file "$TEST_DIR/source/video2.mkv" 4096
    # Only back up video1
    cp -p "$TEST_DIR/source/video1.mkv" "$TEST_DIR/backup/video1.mkv"

    run_script --action delete >/dev/null

    assert_file_missing "verified file deleted from source" "$TEST_DIR/source/video1.mkv"
    assert_file_exists "unverified file kept in source" "$TEST_DIR/source/video2.mkv"

    teardown
}

test_delete_skips_size_mismatch() {
    echo "TEST: Delete skips files where backup size doesn't match"
    setup

    create_file "$TEST_DIR/source/video1.mkv" 2048
    # Create a backup with different size (simulates incomplete copy)
    create_file "$TEST_DIR/backup/video1.mkv" 1024

    run_script --action delete >/dev/null

    assert_file_exists "source kept when backup size mismatches" "$TEST_DIR/source/video1.mkv"

    teardown
}

test_delete_skips_empty_backup() {
    echo "TEST: Delete skips files where backup is 0 bytes"
    setup

    create_file "$TEST_DIR/source/video1.mkv" 2048
    # Create an empty backup file
    touch "$TEST_DIR/backup/video1.mkv"

    run_script --action delete >/dev/null

    assert_file_exists "source kept when backup is empty" "$TEST_DIR/source/video1.mkv"

    teardown
}

test_file_pattern() {
    echo "TEST: Only processes files matching pattern"
    setup

    create_file "$TEST_DIR/source/video1.mkv" 2048
    create_file "$TEST_DIR/source/notes.txt" 512

    run_script --action copy >/dev/null

    assert_file_exists "mkv copied" "$TEST_DIR/backup/video1.mkv"
    assert_file_missing "txt not copied" "$TEST_DIR/backup/notes.txt"

    teardown
}

test_multiple_sources() {
    echo "TEST: Multiple source directories"
    setup

    mkdir -p "$TEST_DIR/source2"
    create_file "$TEST_DIR/source/video1.mkv" 2048
    create_file "$TEST_DIR/source2/video2.mkv" 4096

    cat > "$TEST_DIR/test.env" << EOF
SOURCE_DIRS="$TEST_DIR/source:$TEST_DIR/source2"
BACKUP_DIR="$TEST_DIR/backup"
FILE_PATTERN="*.mkv"
LOG_FILE="$TEST_DIR/test.log"
APP_TITLE="Test"
EOF

    run_script --action copy >/dev/null

    assert_file_exists "video1 from source1 copied" "$TEST_DIR/backup/video1.mkv"
    assert_file_exists "video2 from source2 copied" "$TEST_DIR/backup/video2.mkv"

    teardown
}

test_missing_config() {
    echo "TEST: Exits with error when config missing"
    setup

    output=$(bash "$SCRIPT" --config "$TEST_DIR/nonexistent.env" --headless --action copy 2>&1 || true)
    assert_eq "reports missing config" "1" "$(echo "$output" | grep -c "Config file not found" || true)"

    teardown
}

test_missing_backup_dir() {
    echo "TEST: Exits with error when backup dir missing"
    setup

    cat > "$TEST_DIR/test.env" << EOF
SOURCE_DIRS="$TEST_DIR/source"
BACKUP_DIR="$TEST_DIR/nonexistent"
FILE_PATTERN="*.mkv"
LOG_FILE="$TEST_DIR/test.log"
APP_TITLE="Test"
EOF

    output=$(run_script --action copy 2>&1 || true)
    count=$(echo "$output" | grep -c "Backup directory not found" || true)
    if [ "$count" -ge 1 ]; then
        echo "  PASS: reports missing backup dir"
        ((PASS++)) || true
    else
        echo "  FAIL: reports missing backup dir (expected >= 1 match, got $count)"
        ((FAIL++)) || true
    fi

    teardown
}

test_log_file_created() {
    echo "TEST: Log file is created with entries"
    setup

    create_file "$TEST_DIR/source/video1.mkv" 2048

    run_script --action copy >/dev/null

    assert_file_exists "log file created" "$TEST_DIR/test.log"

    local lines
    lines=$(wc -l < "$TEST_DIR/test.log" | tr -d ' ')
    if [ "$lines" -gt 0 ]; then
        echo "  PASS: log file has $lines entries"
        ((PASS++)) || true
    else
        echo "  FAIL: log file is empty"
        ((FAIL++)) || true
    fi

    teardown
}

test_copy_then_delete() {
    echo "TEST: Copy + Delete works end to end"
    setup

    create_file "$TEST_DIR/source/video1.mkv" 2048
    create_file "$TEST_DIR/source/video2.mkv" 4096

    run_script --action copy+delete >/dev/null

    assert_file_exists "video1 in backup" "$TEST_DIR/backup/video1.mkv"
    assert_file_exists "video2 in backup" "$TEST_DIR/backup/video2.mkv"
    assert_file_missing "video1 removed from source" "$TEST_DIR/source/video1.mkv"
    assert_file_missing "video2 removed from source" "$TEST_DIR/source/video2.mkv"

    teardown
}

# --- Run all tests ---

echo "=== backup-and-clean tests ==="
echo ""

test_copy_new_files
test_copy_skips_existing
test_dry_run_deletes_nothing
test_delete_only_verified
test_delete_skips_size_mismatch
test_delete_skips_empty_backup
test_file_pattern
test_multiple_sources
test_missing_config
test_missing_backup_dir
test_log_file_created
test_copy_then_delete

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
