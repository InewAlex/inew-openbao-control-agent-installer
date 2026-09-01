#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly MODE="${1:-full}"

fail() {
    printf 'release_invalid: %s\n' "$1" >&2
    exit 1
}

case "$MODE" in
    full|--source-only) ;;
    *) fail "unsupported verification mode" ;;
esac

if find "$ROOT_DIR" -mindepth 1 -type l -print -quit | grep -q .; then
    fail "symbolic links are forbidden"
fi

mapfile -t actual_files < <(
    cd "$ROOT_DIR"
    find . -type f -printf '%P\n' | LC_ALL=C sort
)

source_files=(
    ".github/workflows/verify.yml"
    ".gitignore"
    "README.md"
    "RELEASE.md"
    "SECURITY.md"
    "config/agent.example.json"
    "install.sh"
    "logrotate/inew-openbao-control-agent"
    "nginx/inew-openbao-control-agent.conf.template"
    "systemd/inew-openbao-control-agent@.service"
    "verify-release.sh"
)

expected_files=("${source_files[@]}")
if [[ "$MODE" == "full" ]]; then
    expected_files+=(
        "release/SHA256SUMS"
        "release/inew-openbao-control-agent"
        "release/manifest.json"
    )
fi
mapfile -t expected_files < <(printf '%s\n' "${expected_files[@]}" | LC_ALL=C sort)

if [[ "${#actual_files[@]}" -ne "${#expected_files[@]}" ]]; then
    fail "unexpected file count"
fi

for index in "${!expected_files[@]}"; do
    if [[ "${actual_files[$index]}" != "${expected_files[$index]}" ]]; then
        fail "unexpected path: ${actual_files[$index]}"
    fi
done

for relative_path in "${actual_files[@]}"; do
    [[ "$relative_path" != /* ]] || fail "absolute path is forbidden"
    [[ "/$relative_path/" != *"/../"* ]] || fail "path traversal is forbidden"
    [[ "$relative_path" != *'\\'* ]] || fail "backslash path is forbidden"
done

for relative_path in "${source_files[@]}"; do
    if grep -IEl \
        -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
        -e '[Ii][Nn][Ee][Ww][-_ ][Ss][Ee][Cc][Rr][Ee][Tt][-_ ][Cc][Aa][Nn][Aa][Rr][Yy]' \
        -e '[Ss][Hh][Aa][Rr][Ee]-[Oo][Nn][Ee]-[A-Za-z0-9-]{8,}' \
        -e '[Hh][Vv][Ss]\.[A-Za-z0-9]{16,}' \
        -e '[A-Z]:\\Users\\Alex' \
        -e '[A-Z]:\\OSPanel' \
        "$ROOT_DIR/$relative_path" >/dev/null; then
        fail "forbidden content: $relative_path"
    fi
done

grep -Fqx 'systemd-analyze verify "$SYSTEMD_UNIT_PATH:$SERVICE_NAME"' \
    "$ROOT_DIR/install.sh" \
    || fail "systemd template must be verified with the selected instance alias"

if [[ "$MODE" == "--source-only" ]]; then
    printf 'source_layout_valid\n'
    exit 0
fi

readonly BINARY_PATH="$ROOT_DIR/release/inew-openbao-control-agent"
readonly MANIFEST_PATH="$ROOT_DIR/release/manifest.json"
readonly CHECKSUM_PATH="$ROOT_DIR/release/SHA256SUMS"

[[ -s "$BINARY_PATH" ]] || fail "Agent binary is missing or empty"
[[ -s "$MANIFEST_PATH" ]] || fail "manifest is missing or empty"
[[ -s "$CHECKSUM_PATH" ]] || fail "checksum file is missing or empty"
binary_size="$(stat -c '%s' "$BINARY_PATH")"
manifest_size="$(stat -c '%s' "$MANIFEST_PATH")"
checksum_size="$(stat -c '%s' "$CHECKSUM_PATH")"
(( binary_size <= 268435456 )) || fail "Agent binary exceeds 256 MiB"
(( manifest_size <= 4096 )) || fail "manifest exceeds 4 KiB"
(( checksum_size <= 256 )) || fail "checksum file exceeds 256 bytes"

checksum_line="$(tr -d '\r' < "$CHECKSUM_PATH")"
[[ "$checksum_line" =~ ^[0-9a-f]{64}[[:space:]][[:space:]]release/inew-openbao-control-agent$ ]] \
    || fail "checksum format is invalid"

(
    cd "$ROOT_DIR"
    sha256sum --check --strict release/SHA256SUMS >/dev/null
) || fail "Agent checksum mismatch"

actual_hash="$(sha256sum "$BINARY_PATH" | awk '{print $1}')"
manifest_hash="$(sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{64\}\)".*/\1/p' "$MANIFEST_PATH")"
[[ "$manifest_hash" == "$actual_hash" ]] || fail "manifest checksum mismatch"
grep -Eq '"schemaVersion"[[:space:]]*:[[:space:]]*1([,[:space:]]|$)' "$MANIFEST_PATH" \
    || fail "manifest schema is invalid"
grep -Eq '"runtimeIdentifier"[[:space:]]*:[[:space:]]*"linux-x64"' "$MANIFEST_PATH" \
    || fail "manifest runtime is invalid"
grep -Eq '"file"[[:space:]]*:[[:space:]]*"release/inew-openbao-control-agent"' "$MANIFEST_PATH" \
    || fail "manifest file is invalid"

printf 'release_valid sha256=%s\n' "$actual_hash"
