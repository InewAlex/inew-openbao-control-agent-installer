#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/install-health.sh
source "$ROOT_DIR/lib/install-health.sh"
readonly ANSWER_KEYS=(
    INEW_ENVIRONMENT
    INEW_PUBLIC_HOST
    INEW_AGENT_PORT
    INEW_OPENBAO_PORT
    INEW_TLS_CERTIFICATE_PATH
    INEW_TLS_PRIVATE_KEY_PATH
    INEW_OPERATOR_POLICIES
    INEW_OPERATOR_ENTITY_IDS
    INEW_MIN_OPERATOR_TTL_SECONDS
)

fail() {
    printf 'Ошибка: %s\n' "$1" >&2
    if [[ "${MUTATION_STARTED:-0}" -eq 1 ]]; then
        rollback 1
    fi
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "не найдена обязательная команда: $1"
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || fail "запустите установщик через sudo"
}

validate_platform() {
    [[ -f /etc/os-release ]] || fail "не удалось определить Linux-дистрибутив"
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}:${VERSION_ID:-}" in
        ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
        *) fail "поддерживаются Ubuntu 22.04/24.04 и Debian 12/13" ;;
    esac
    [[ "$(uname -m)" == "x86_64" ]] || fail "поддерживается только архитектура x86_64"
}

read_answer_file() {
    local answer_path="$1"
    [[ "$answer_path" == /* ]] || fail "путь к файлу ответов должен быть абсолютным"
    [[ -f "$answer_path" && ! -L "$answer_path" ]] || fail "файл ответов должен быть обычным файлом"
    [[ "$(stat -c '%u' "$answer_path")" == "0" ]] || fail "владельцем файла ответов должен быть root"
    [[ "$(stat -c '%a' "$answer_path")" == "600" ]] || fail "права файла ответов должны быть 0600"

    declare -A seen=()
    local raw key value allowed
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        raw="${raw%$'\r'}"
        [[ -z "$raw" || "$raw" == \#* ]] && continue
        [[ "$raw" =~ ^([A-Z0-9_]+)=([^[:space:]]+)$ ]] || fail "некорректная строка файла ответов"
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        allowed=0
        for candidate in "${ANSWER_KEYS[@]}"; do
            [[ "$candidate" == "$key" ]] && allowed=1
        done
        [[ "$allowed" -eq 1 ]] || fail "неподдерживаемое поле файла ответов: $key"
        [[ -z "${seen[$key]+x}" ]] || fail "поле файла ответов повторяется: $key"
        seen[$key]=1
        printf -v "$key" '%s' "$value"
    done < "$answer_path"
}

prompt_value() {
    local variable_name="$1"
    local prompt="$2"
    local default_value="${3:-}"
    local current_value="${!variable_name:-}"
    local entered
    [[ -z "$current_value" ]] || return 0
    if [[ -n "$default_value" ]]; then
        printf '%s [%s]: ' "$prompt" "$default_value"
    else
        printf '%s: ' "$prompt"
    fi
    IFS= read -r entered || fail "ввод прерван"
    printf -v "$variable_name" '%s' "${entered:-$default_value}"
}

validate_port() {
    [[ "$2" =~ ^[0-9]{1,5}$ ]] || fail "$1 должен быть числом"
    (( 10#$2 >= 1 && 10#$2 <= 65535 )) || fail "$1 должен быть в диапазоне 1..65535"
}

validate_absolute_file_path() {
    local label="$1"
    local path="$2"
    [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ && "/$path/" != *"/../"* ]] \
        || fail "$label: разрешён только абсолютный путь без пробелов и '..'"
    local resolved_path
    resolved_path="$(readlink -f -- "$path")" || fail "$label не удалось разрешить"
    [[ "$resolved_path" == /* && -f "$resolved_path" && ! -L "$resolved_path" ]] \
        || fail "$label должен разрешаться в обычный файл"
}

validate_csv_identifiers() {
    local label="$1"
    local value="$2"
    local item
    IFS=',' read -r -a items <<< "$value"
    [[ "${#items[@]}" -gt 0 ]] || fail "$label не может быть пустым"
    for item in "${items[@]}"; do
        [[ "$item" =~ ^[A-Za-z0-9._:/-]{1,128}$ ]] || fail "$label содержит недопустимое значение"
    done
}

assert_managed_directory() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -d "$path" && ! -L "$path" ]] || fail "управляемый каталог имеет небезопасный тип: $path"
    fi
}

json_array_from_csv() {
    local value="$1"
    local first=1
    local item
    IFS=',' read -r -a items <<< "$value"
    printf '['
    for item in "${items[@]}"; do
        [[ "$first" -eq 1 ]] || printf ', '
        printf '"%s"' "$item"
        first=0
    done
    printf ']'
}

render_template() {
    local source_path="$1"
    local destination_path="$2"
    sed \
        -e "s|{{PUBLIC_HOST}}|$INEW_PUBLIC_HOST|g" \
        -e "s|{{TLS_CERTIFICATE_PATH}}|$INEW_TLS_CERTIFICATE_PATH|g" \
        -e "s|{{TLS_PRIVATE_KEY_PATH}}|$INEW_TLS_PRIVATE_KEY_PATH|g" \
        -e "s|{{DEVICE_CA_CERTIFICATE_PATH}}|$DEVICE_CA_CERTIFICATE_PATH|g" \
        -e "s|{{AGENT_PORT}}|$INEW_AGENT_PORT|g" \
        "$source_path" > "$destination_path"
}

backup_file() {
    local source_path="$1"
    local backup_name="$2"
    if [[ -e "$source_path" || -L "$source_path" ]]; then
        [[ -f "$source_path" && ! -L "$source_path" ]] || fail "небезопасный существующий путь: $source_path"
        cp -a -- "$source_path" "$BACKUP_ROOT/$backup_name"
    else
        : > "$BACKUP_ROOT/$backup_name.absent"
    fi
}

restore_file() {
    local destination_path="$1"
    local backup_name="$2"
    if [[ -f "$BACKUP_ROOT/$backup_name" ]]; then
        install -D --mode="$(stat -c '%a' "$BACKUP_ROOT/$backup_name")" \
            "$BACKUP_ROOT/$backup_name" "$destination_path"
        chown --reference="$BACKUP_ROOT/$backup_name" "$destination_path"
    elif [[ -f "$BACKUP_ROOT/$backup_name.absent" ]]; then
        rm -f -- "$destination_path"
    fi
}

rollback() {
    local exit_code="${1:-1}"
    trap - ERR INT TERM
    set +e
    if [[ "${MUTATION_STARTED:-0}" -eq 1 ]]; then
        printf 'Установка не завершена. Выполняется откат файлов...\n' >&2
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1
        restore_file "$CONFIGURATION_PATH" agent.json
        restore_file "$DEVICE_CA_CERTIFICATE_PATH" device-ca.crt
        restore_file "$DEVICE_CA_PRIVATE_KEY_PATH" device-ca.key
        restore_file "$DEVICE_STATE_PATH" device-state.json
        restore_file "$NGINX_CONFIGURATION_PATH" nginx.conf
        restore_file "$SYSTEMD_UNIT_PATH" systemd.service
        restore_file "$LOGROTATE_PATH" logrotate
        restore_file "$RELEASE_BINARY_PATH" agent-binary
        rm -f -- "$CURRENT_LINK"
        if [[ -f "$BACKUP_ROOT/current-link-target" ]]; then
            ln -s -- "$(<"$BACKUP_ROOT/current-link-target")" "$CURRENT_LINK"
        fi
        rmdir -- "$RELEASE_DIRECTORY" >/dev/null 2>&1
        systemctl daemon-reload >/dev/null 2>&1
        nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
        [[ "${WAS_ENABLED:-0}" -eq 1 ]] && systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
        [[ "${WAS_ACTIVE:-0}" -eq 1 ]] && systemctl start "$SERVICE_NAME" >/dev/null 2>&1
    fi
    exit "$exit_code"
}

ANSWER_FILE=''
case "$#" in
    0) ;;
    2)
        [[ "$1" == "--answers" ]] || fail "использование: sudo ./install.sh [--answers /root/agent-install.env]"
        ANSWER_FILE="$2"
        ;;
    *) fail "использование: sudo ./install.sh [--answers /root/agent-install.env]" ;;
esac

require_root
for required_command in awk cp curl find getent grep id install nginx openssl readlink runuser sed sha256sum sleep stat systemctl systemd-analyze uname useradd; do
    require_command "$required_command"
done
validate_platform
"$ROOT_DIR/verify-release.sh" full

[[ -z "$ANSWER_FILE" ]] || read_answer_file "$ANSWER_FILE"
prompt_value INEW_ENVIRONMENT "Среда (dev или prod)"
[[ "${INEW_ENVIRONMENT:-}" == "dev" || "${INEW_ENVIRONMENT:-}" == "prod" ]] \
    || fail "среда должна быть dev или prod"

if [[ "$INEW_ENVIRONMENT" == "dev" ]]; then
    DEFAULT_AGENT_PORT=9120
    DEFAULT_OPENBAO_PORT=8200
else
    DEFAULT_AGENT_PORT=9130
    DEFAULT_OPENBAO_PORT=8300
fi

prompt_value INEW_PUBLIC_HOST "Публичное DNS-имя Control Agent"
prompt_value INEW_AGENT_PORT "Локальный порт Control Agent" "$DEFAULT_AGENT_PORT"
prompt_value INEW_OPENBAO_PORT "Локальный порт OpenBao" "$DEFAULT_OPENBAO_PORT"
prompt_value INEW_TLS_CERTIFICATE_PATH "Путь к TLS-сертификату сайта"
prompt_value INEW_TLS_PRIVATE_KEY_PATH "Путь к закрытому TLS-ключу сайта"
prompt_value INEW_OPERATOR_POLICIES "Разрешённые policy OpenBao через запятую"
prompt_value INEW_OPERATOR_ENTITY_IDS "Разрешённые entity ID операторов через запятую"
prompt_value INEW_MIN_OPERATOR_TTL_SECONDS "Минимальный TTL токена оператора, секунд" "300"

[[ "$INEW_PUBLIC_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ \
    && "$INEW_PUBLIC_HOST" == *.* \
    && "$INEW_PUBLIC_HOST" != *..* ]] || fail "DNS-имя имеет недопустимый формат"
validate_port "порт Control Agent" "$INEW_AGENT_PORT"
validate_port "порт OpenBao" "$INEW_OPENBAO_PORT"
[[ "$INEW_AGENT_PORT" != "$INEW_OPENBAO_PORT" ]] || fail "порты Agent и OpenBao должны различаться"
validate_absolute_file_path "TLS-сертификат" "$INEW_TLS_CERTIFICATE_PATH"
validate_absolute_file_path "TLS-ключ" "$INEW_TLS_PRIVATE_KEY_PATH"
openssl x509 -in "$INEW_TLS_CERTIFICATE_PATH" -noout >/dev/null 2>&1 || fail "TLS-сертификат не читается OpenSSL"
openssl pkey -in "$INEW_TLS_PRIVATE_KEY_PATH" -noout >/dev/null 2>&1 || fail "TLS-ключ не читается OpenSSL"
validate_csv_identifiers "policy OpenBao" "$INEW_OPERATOR_POLICIES"
validate_csv_identifiers "entity ID оператора" "$INEW_OPERATOR_ENTITY_IDS"
[[ "$INEW_MIN_OPERATOR_TTL_SECONDS" =~ ^[0-9]{1,6}$ ]] || fail "TTL должен быть числом"
(( 10#$INEW_MIN_OPERATOR_TTL_SECONDS >= 60 && 10#$INEW_MIN_OPERATOR_TTL_SECONDS <= 86400 )) \
    || fail "TTL должен быть в диапазоне 60..86400 секунд"

VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9._-]*\)".*/\1/p' "$ROOT_DIR/release/manifest.json")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([._-][A-Za-z0-9.-]+)?$ ]] || fail "версия Agent в manifest некорректна"

readonly SERVICE_USER="inew-openbao-agent-$INEW_ENVIRONMENT"
readonly SERVICE_NAME="inew-openbao-control-agent@$INEW_ENVIRONMENT.service"
readonly CONFIGURATION_DIRECTORY="/etc/inew-openbao-control-agent/$INEW_ENVIRONMENT"
readonly CONFIGURATION_PATH="$CONFIGURATION_DIRECTORY/agent.json"
readonly DEVICE_CA_CERTIFICATE_PATH="$CONFIGURATION_DIRECTORY/device-ca.crt"
readonly DEVICE_CA_PRIVATE_KEY_PATH="$CONFIGURATION_DIRECTORY/device-ca.key"
readonly STATE_DIRECTORY="/var/lib/inew-openbao-control-agent/$INEW_ENVIRONMENT"
readonly AUDIT_DIRECTORY="/var/log/inew-openbao-control-agent/$INEW_ENVIRONMENT"
readonly AGENT_BACKUP_DIRECTORY="/var/backups/inew-openbao-control-agent/$INEW_ENVIRONMENT"
readonly DEVICE_STATE_PATH="$STATE_DIRECTORY/device-state.json"
readonly RELEASE_DIRECTORY="/opt/inew-openbao-control-agent/releases/$VERSION"
readonly RELEASE_BINARY_PATH="$RELEASE_DIRECTORY/inew-openbao-control-agent"
readonly CURRENT_LINK="/opt/inew-openbao-control-agent/current-$INEW_ENVIRONMENT"
readonly SYSTEMD_UNIT_PATH="/etc/systemd/system/inew-openbao-control-agent@.service"
readonly NGINX_CONFIGURATION_PATH="/etc/nginx/conf.d/inew-openbao-control-agent-$INEW_ENVIRONMENT.conf"
readonly LOGROTATE_PATH="/etc/logrotate.d/inew-openbao-control-agent"
readonly BACKUP_ROOT="/var/backups/inew-openbao-control-agent/install-$(date -u +%Y%m%dT%H%M%SZ)-$INEW_ENVIRONMENT"

[[ ! -e "$CURRENT_LINK" || -L "$CURRENT_LINK" ]] || fail "путь current занят не символической ссылкой"
for managed_directory in \
    /etc/inew-openbao-control-agent \
    "$CONFIGURATION_DIRECTORY" \
    /var/lib/inew-openbao-control-agent \
    "$STATE_DIRECTORY" \
    /var/log/inew-openbao-control-agent \
    "$AUDIT_DIRECTORY" \
    /var/backups/inew-openbao-control-agent \
    "$AGENT_BACKUP_DIRECTORY" \
    /opt/inew-openbao-control-agent \
    /opt/inew-openbao-control-agent/releases \
    "$RELEASE_DIRECTORY" \
    /etc/nginx/conf.d \
    /etc/systemd/system \
    /etc/logrotate.d; do
    assert_managed_directory "$managed_directory"
done

install -d -m 0700 "$BACKUP_ROOT"
backup_file "$CONFIGURATION_PATH" agent.json
backup_file "$DEVICE_CA_CERTIFICATE_PATH" device-ca.crt
backup_file "$DEVICE_CA_PRIVATE_KEY_PATH" device-ca.key
backup_file "$DEVICE_STATE_PATH" device-state.json
backup_file "$NGINX_CONFIGURATION_PATH" nginx.conf
backup_file "$SYSTEMD_UNIT_PATH" systemd.service
backup_file "$LOGROTATE_PATH" logrotate
backup_file "$RELEASE_BINARY_PATH" agent-binary
if [[ -L "$CURRENT_LINK" ]]; then
    readlink -- "$CURRENT_LINK" > "$BACKUP_ROOT/current-link-target"
fi

WAS_ENABLED=0
WAS_ACTIVE=0
systemctl is-enabled --quiet "$SERVICE_NAME" >/dev/null 2>&1 && WAS_ENABLED=1
systemctl is-active --quiet "$SERVICE_NAME" >/dev/null 2>&1 && WAS_ACTIVE=1
MUTATION_STARTED=1
trap 'rollback $?' ERR
trap 'rollback 130' INT TERM

systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
if ! getent passwd "$SERVICE_USER" >/dev/null; then
    useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
fi

install -d -o root -g "$SERVICE_USER" -m 0750 "$CONFIGURATION_DIRECTORY"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0700 \
    "$STATE_DIRECTORY" "$AUDIT_DIRECTORY" "$AGENT_BACKUP_DIRECTORY"
install -d -o root -g root -m 0755 "$RELEASE_DIRECTORY" "$(dirname "$CURRENT_LINK")"

if [[ ! -e "$DEVICE_CA_CERTIFICATE_PATH" && ! -e "$DEVICE_CA_PRIVATE_KEY_PATH" ]]; then
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -subj "/CN=INew OpenBao Control Agent $INEW_ENVIRONMENT Device CA" \
        -keyout "$DEVICE_CA_PRIVATE_KEY_PATH" \
        -out "$DEVICE_CA_CERTIFICATE_PATH" >/dev/null 2>&1
elif [[ ! -f "$DEVICE_CA_CERTIFICATE_PATH" || ! -f "$DEVICE_CA_PRIVATE_KEY_PATH" \
    || -L "$DEVICE_CA_CERTIFICATE_PATH" || -L "$DEVICE_CA_PRIVATE_KEY_PATH" ]]; then
    fail "device CA существует частично или использует небезопасный тип файла"
fi
chown "$SERVICE_USER:$SERVICE_USER" "$DEVICE_CA_CERTIFICATE_PATH" "$DEVICE_CA_PRIVATE_KEY_PATH"
chmod 0600 "$DEVICE_CA_CERTIFICATE_PATH" "$DEVICE_CA_PRIVATE_KEY_PATH"

POLICIES_JSON="$(json_array_from_csv "$INEW_OPERATOR_POLICIES")"
ENTITIES_JSON="$(json_array_from_csv "$INEW_OPERATOR_ENTITY_IDS")"
CONFIGURATION_TEMP="$(mktemp "$CONFIGURATION_DIRECTORY/agent.json.tmp.XXXXXX")"
cat > "$CONFIGURATION_TEMP" <<JSON
{
  "schemaVersion": 1,
  "environmentId": "$INEW_ENVIRONMENT",
  "listenUri": "http://127.0.0.1:$INEW_AGENT_PORT/",
  "openBaoBaseUri": "http://127.0.0.1:$INEW_OPENBAO_PORT/",
  "stateDirectory": "$STATE_DIRECTORY",
  "auditDirectory": "$AUDIT_DIRECTORY",
  "backupDirectory": "$AGENT_BACKUP_DIRECTORY",
  "deviceCaCertificatePath": "$DEVICE_CA_CERTIFICATE_PATH",
  "deviceCaPrivateKeyPath": "$DEVICE_CA_PRIVATE_KEY_PATH",
  "allowedOperatorPolicies": $POLICIES_JSON,
  "allowedOperatorEntityIds": $ENTITIES_JSON,
  "minimumOperatorTtlSeconds": $INEW_MIN_OPERATOR_TTL_SECONDS,
  "allowOrphanOperatorTokens": false
}
JSON
chown "$SERVICE_USER:$SERVICE_USER" "$CONFIGURATION_TEMP"
chmod 0600 "$CONFIGURATION_TEMP"
mv -f -- "$CONFIGURATION_TEMP" "$CONFIGURATION_PATH"

install -o root -g root -m 0755 "$ROOT_DIR/release/inew-openbao-control-agent" "$RELEASE_BINARY_PATH"
CURRENT_LINK_TEMP="$(dirname "$CURRENT_LINK")/.current-$INEW_ENVIRONMENT-$$"
ln -s -- "releases/$VERSION" "$CURRENT_LINK_TEMP"
mv -Tf -- "$CURRENT_LINK_TEMP" "$CURRENT_LINK"

install -o root -g root -m 0644 \
    "$ROOT_DIR/systemd/inew-openbao-control-agent@.service" "$SYSTEMD_UNIT_PATH"
install -o root -g root -m 0644 \
    "$ROOT_DIR/logrotate/inew-openbao-control-agent" "$LOGROTATE_PATH"
NGINX_TEMP="$(mktemp "/etc/nginx/conf.d/.inew-openbao-control-agent-$INEW_ENVIRONMENT.XXXXXX")"
render_template "$ROOT_DIR/nginx/inew-openbao-control-agent.conf.template" "$NGINX_TEMP"
chmod 0644 "$NGINX_TEMP"
chown root:root "$NGINX_TEMP"
mv -f -- "$NGINX_TEMP" "$NGINX_CONFIGURATION_PATH"

runuser -u "$SERVICE_USER" -- "$RELEASE_BINARY_PATH" \
    --config "$CONFIGURATION_PATH" --validate-config | grep -qx 'configuration_valid' \
    || fail "Agent отклонил сформированную конфигурацию"
systemd-analyze verify "$SYSTEMD_UNIT_PATH:$SERVICE_NAME"
nginx -t

PAIRING_CODE=''
if [[ ! -f "$DEVICE_STATE_PATH" ]]; then
    PAIRING_CODE="$(runuser -u "$SERVICE_USER" -- "$RELEASE_BINARY_PATH" \
        --config "$CONFIGURATION_PATH" --create-pairing)"
    [[ "$PAIRING_CODE" =~ ^[A-Za-z0-9_-]{43}$ ]] || fail "Agent вернул некорректный код привязки"
fi

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
systemctl is-active --quiet "$SERVICE_NAME" || fail "служба Agent не запустилась"
systemctl is-active --quiet nginx || systemctl start nginx
systemctl reload nginx
AGENT_HEALTH_URI="http://127.0.0.1:$INEW_AGENT_PORT/api/v1/health"
wait_for_agent_health "$AGENT_HEALTH_URI" 30 1 \
    || fail "Agent не стал готов за 30 секунд. Выполните: journalctl -u $SERVICE_NAME -n 50 --no-pager"

MUTATION_STARTED=0
trap - ERR INT TERM

printf '\nControl Agent %s установлен для среды %s.\n' "$VERSION" "$INEW_ENVIRONMENT"
printf 'Публичный адрес: https://%s/\n' "$INEW_PUBLIC_HOST"
printf 'Резервная копия предыдущих файлов: %s\n' "$BACKUP_ROOT"
if [[ -n "$PAIRING_CODE" ]]; then
    printf '\nОдноразовый код привязки: %s\n' "$PAIRING_CODE"
    printf 'Введите его в OpenBao Manager для среды %s. Код не сохраняется установщиком.\n' "$INEW_ENVIRONMENT"
else
    printf '\nСуществующее состояние устройств сохранено; новый код привязки не создавался.\n'
    printf 'При необходимости используйте раздел привязки в руководстве RELEASE.md.\n'
fi
unset PAIRING_CODE
