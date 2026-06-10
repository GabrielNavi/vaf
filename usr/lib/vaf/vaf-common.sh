# shellcheck shell=bash
# shellcheck disable=SC2034  # Librería: variables definidas aquí son usadas por los scripts que la sourcean
# vaf-common.sh — Funciones compartidas de VAF.
#
# Uso: source /usr/lib/vaf/vaf-common.sh
#
# El script que carga esta librería debe definir LOG_TAG antes del source:
#   LOG_TAG="[VAF]"           → bucle principal
#   LOG_TAG="[VAF-REGISTER]"  → registro puntual

# ---------------------------------------------------------------------------
# Rutas (sobreescribibles antes del source para sub-instancias)
# ---------------------------------------------------------------------------
CONF_FILE="${CONF_FILE:-/etc/vaf/vaf.conf}"
CONF_DIR="${CONF_DIR:-/etc/vaf/vaf.conf.d}"
ID_FILE="${ID_FILE:-/etc/vaf/vaf-id}"
STATE_DIR="${STATE_DIR:-/var/lib/vaf}"

VERSION_FILE="${STATE_DIR}/version"
CLIENTS_FILE="${STATE_DIR}/clients.json"
TMP_CLIENTS="${STATE_DIR}/clients.json.tmp"
UPPER_VERSION_FILE="${STATE_DIR}/upper_version"
UPPER_CLIENTS_FILE="${STATE_DIR}/upper_clients.json"
TMP_UPPER_CLIENTS="${STATE_DIR}/upper_clients.json.tmp"
IDENTITY_FILE="${STATE_DIR}/identity.json"
EXTRAS_IMP_FILE="${STATE_DIR}/extras_imperative.json"
EXTRAS_INF_FILE="${STATE_DIR}/extras_informative.json"

# ---------------------------------------------------------------------------
# Valores por defecto de configuración
# ---------------------------------------------------------------------------
KEY=""
UPPER_VAS_HOST=""
UPPER_VAS_SCHEME="http"
FILTER="active"
GLOBAL_KEY=""
LOCAL_KEY_LIST=""
CHECK_SECONDS=300
HEARTBEAT_SECONDS=""
RETRY_SECONDS=60
SYNC_UPPER=false
EXTRAS_ENABLED=true
EXTRAS_TTL=86400
EXTRAS_IMPERATIVE_HOOKS_DIR="${EXTRAS_IMPERATIVE_HOOKS_DIR:-/etc/vaf/extras_imperative.d}"
EXTRAS_INFORMATIVE_HOOKS_DIR="${EXTRAS_INFORMATIVE_HOOKS_DIR:-/etc/vaf/extras_informative.d}"
HOOKS_LOCAL_DIR="${HOOKS_LOCAL_DIR:-/etc/vaf/hooks_local.d}"
DISPATCH_STDIN=true
HOOK_TIMEOUT_SECONDS=30
PARALLEL_MODE="both"
USE_VAT=false
VAT_PRESET=""
LOG_LEVEL="${LOG_LEVEL:-normal}"
LOG_FILE="${LOG_FILE:-}"
LOG_TAG="${LOG_TAG:-[VAF]}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_log_write() {
    echo "$*"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

log() {
    [[ "$LOG_LEVEL" == "no" ]] && return 0
    _log_write "$LOG_TAG $*"
}

log_debug() {
    [[ "$LOG_LEVEL" != "debug" ]] && return 0
    _log_write "$LOG_TAG [DEBUG] $*"
}

# ---------------------------------------------------------------------------
# Carga de configuración
# ---------------------------------------------------------------------------
load_conf() {
    local file="$1"
    [ -f "$file" ] || return 0
    local loaded=0
    while IFS='=' read -r key val; do
        key="$(echo "$key" | xargs 2>/dev/null || true)"
        val="$(echo "$val" | xargs 2>/dev/null | sed 's/^"//; s/"$//' || true)"
        [ -z "$key" ] && continue
        case "$key" in
            KEY)                          KEY="$val";                          (( ++loaded )) ;;
            UPPER_VAS_HOST)               UPPER_VAS_HOST="$val";               (( ++loaded )) ;;
            UPPER_VAS_SCHEME)             UPPER_VAS_SCHEME="$val";             (( ++loaded )) ;;
            FILTER)                       FILTER="$val";                       (( ++loaded )) ;;
            GLOBAL_KEY)                   GLOBAL_KEY="$val";                   (( ++loaded )) ;;
            LOCAL_KEY_LIST)               LOCAL_KEY_LIST="$val";               (( ++loaded )) ;;
            CHECK_SECONDS)                CHECK_SECONDS="$val";                (( ++loaded )) ;;
            HEARTBEAT_SECONDS)            HEARTBEAT_SECONDS="$val";            (( ++loaded )) ;;
            RETRY_SECONDS)                RETRY_SECONDS="$val";                (( ++loaded )) ;;
            SYNC_UPPER)                   SYNC_UPPER="$val";                   (( ++loaded )) ;;
            EXTRAS_ENABLED)               EXTRAS_ENABLED="$val";               (( ++loaded )) ;;
            EXTRAS_TTL)                   EXTRAS_TTL="$val";                   (( ++loaded )) ;;
            EXTRAS_IMPERATIVE_HOOKS_DIR)  EXTRAS_IMPERATIVE_HOOKS_DIR="$val";  (( ++loaded )) ;;
            EXTRAS_INFORMATIVE_HOOKS_DIR) EXTRAS_INFORMATIVE_HOOKS_DIR="$val"; (( ++loaded )) ;;
            HOOKS_LOCAL_DIR)              HOOKS_LOCAL_DIR="$val";              (( ++loaded )) ;;
            DISPATCH_STDIN)               DISPATCH_STDIN="$val";               (( ++loaded )) ;;
            HOOK_TIMEOUT_SECONDS)         HOOK_TIMEOUT_SECONDS="$val";         (( ++loaded )) ;;
            PARALLEL_MODE)                PARALLEL_MODE="$val";                (( ++loaded )) ;;
            USE_VAT)                      USE_VAT="$val";                      (( ++loaded )) ;;
            VAT_PRESET)                   VAT_PRESET="$val";                   (( ++loaded )) ;;
            LOG_LEVEL)                    LOG_LEVEL="$val";                    (( ++loaded )) ;;
            LOG_FILE)                     LOG_FILE="$val";                     (( ++loaded )) ;;
        esac
    done < <(grep -v '^\s*#' "$file" | grep '=' || true)
    log_debug "Config cargada desde $file: $loaded clave(s)"
}

load_all_conf() {
    load_conf "$CONF_FILE"
    if [[ -d "$CONF_DIR" ]]; then
        for cfg in "$CONF_DIR"/*.conf; do
            [[ -f "$cfg" ]] || continue
            load_conf "$cfg"
        done
    fi
    _normalize_upper_vas_host
    _resolve_local_vas_host
    : "${HEARTBEAT_SECONDS:=$CHECK_SECONDS}"
    [[ -z "$KEY" ]] && KEY="$(hostname -s 2>/dev/null || hostname)"
}

# ---------------------------------------------------------------------------
# Resolución de hosts
# ---------------------------------------------------------------------------

# UPPER_VAS_HOST puede llegar como URL completa (compat.) o como host:port.
# Normaliza a host:port + UPPER_VAS_SCHEME separados, igual que VAL/VAC.
_normalize_upper_vas_host() {
    if [[ "$UPPER_VAS_HOST" =~ ^(https?)://(.+) ]]; then
        local extracted="${BASH_REMATCH[1]}"
        UPPER_VAS_HOST="${BASH_REMATCH[2]}"
        [[ "$extracted" != "$UPPER_VAS_SCHEME" ]] && \
            log "[WARN] UPPER_VAS_HOST contenía scheme '$extracted'; extraído a UPPER_VAS_SCHEME."
        UPPER_VAS_SCHEME="$extracted"
    fi
    UPPER_VAS_HOST="${UPPER_VAS_HOST%/}"
    if [[ -n "$UPPER_VAS_HOST" && ! "$UPPER_VAS_HOST" =~ :[0-9]+$ ]]; then
        UPPER_VAS_HOST="${UPPER_VAS_HOST}:8000"
        log_debug "[CONFIG] Puerto implícito añadido: UPPER_VAS_HOST=$UPPER_VAS_HOST"
    fi
}

# LOCAL_VAS_HOST se auto-detecta desde /etc/vas/vas.conf (VAS siempre es local).
# Nunca necesita configuración manual; se puede sobreescribir con LOCAL_VAS_PORT=.
LOCAL_VAS_HOST=""
LOCAL_VAS_PORT=""

_resolve_local_vas_host() {
    if [[ -n "$LOCAL_VAS_HOST" ]]; then
        return 0
    fi
    local port="${LOCAL_VAS_PORT:-}"
    if [[ -z "$port" ]]; then
        port=8000
        local cfg
        for cfg in /etc/vas/vas.conf /etc/vas/vas.conf.d/*.conf; do
            [[ -f "$cfg" ]] || continue
            local p
            p="$(grep -E '^PORT=[0-9]+$' "$cfg" 2>/dev/null | tail -1 | cut -d= -f2 | xargs 2>/dev/null || true)"
            [[ -n "$p" ]] && port="$p"
        done
    fi
    LOCAL_VAS_HOST="http://127.0.0.1:${port}"
    log_debug "[CONFIG] LOCAL_VAS_HOST detectado: $LOCAL_VAS_HOST"
}

# ---------------------------------------------------------------------------
# Datos de red
# ---------------------------------------------------------------------------
get_hostname() { hostname -f 2>/dev/null || hostname; }

get_ip() {
    ip route get 1.1.1.1 2>/dev/null \
        | awk '/src/ { for (i=1;i<=NF;i++) if ($i=="src") { print $(i+1); exit } }' \
        || true
}

get_mac() {
    ip link show 2>/dev/null \
        | awk '/^[0-9]+: (eth|ens|enp|wlan|wlp)/ { iface=1; next }
               iface && /link\/ether/ { print $2; exit }
               /^[0-9]+:/ { iface=0 }' \
        || true
}

# ---------------------------------------------------------------------------
# Identity local (espejo del registro en UPPER_VAS)
# ---------------------------------------------------------------------------
save_identity() {
    local host="$1" ip="$2" mac="$3" extra_imp="${4:-}" extra_inf="${5:-}"
    local tmp="${IDENTITY_FILE}.tmp.$$"
    jq -n \
        --arg     hostname  "$host"              \
        --arg     ip        "$ip"                \
        --arg     mac       "$mac"               \
        --argjson extra_imp "${extra_imp:-null}" \
        --argjson extra_inf "${extra_inf:-null}" \
        '{
            hostname:          $hostname,
            ip:                $ip,
            mac:               $mac,
            extra_imperative:  $extra_imp,
            extra_informative: $extra_inf
        }' > "$tmp" 2>/dev/null \
    && mv "$tmp" "$IDENTITY_FILE" \
    || { log "[IDENTITY] Error escribiendo $IDENTITY_FILE"; rm -f "$tmp"; return 1; }
    log_debug "[IDENTITY] Guardado: $IDENTITY_FILE"
}

load_identity() {
    if [[ ! -f "$IDENTITY_FILE" ]]; then
        log_debug "[IDENTITY] $IDENTITY_FILE no encontrado."
        return 1
    fi
    IDENTITY_HOST="$(jq -r '.hostname          // empty' "$IDENTITY_FILE" 2>/dev/null)"
    IDENTITY_IP="$(  jq -r '.ip                // empty' "$IDENTITY_FILE" 2>/dev/null)"
    IDENTITY_MAC="$( jq -r '.mac               // empty' "$IDENTITY_FILE" 2>/dev/null)"
    IDENTITY_IMP="$( jq -c '.extra_imperative  // empty' "$IDENTITY_FILE" 2>/dev/null)"
    IDENTITY_INF="$( jq -c '.extra_informative // empty' "$IDENTITY_FILE" 2>/dev/null)"
    if [[ -z "$IDENTITY_HOST" && -z "$IDENTITY_IP" ]]; then
        log "[IDENTITY] $IDENTITY_FILE inválido o vacío."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Registro y heartbeat con UPPER_VAS
# ---------------------------------------------------------------------------
register_client() {
    local host="$1" ip="$2" mac="$3" extra_imp="${4:-}" extra_inf="${5:-}"
    local payload response

    if [[ -z "$ip" ]]; then
        log "[REGISTER] IP vacía — sin red activa. Abortando registro."
        return 1
    fi
    [[ -z "$mac" ]] && log "[REGISTER] MAC vacía (interfaz virtual). Registrando sin MAC."

    payload="$(jq -n \
        --arg     id        "$CLIENT_ID"           \
        --arg     hostname  "$host"                \
        --arg     ip        "$ip"                  \
        --arg     mac       "$mac"                 \
        --argjson extra_imp "${extra_imp:-null}"   \
        --argjson extra_inf "${extra_inf:-null}"   \
        '{
            id:                $id,
            hostname:          $hostname,
            ip:                $ip,
            mac:               $mac,
            extra_imperative:  $extra_imp,
            extra_informative: $extra_inf
        }')"

    log "[REGISTER] POST ${UPPER_VAS_SCHEME}://${UPPER_VAS_HOST}/register ..."
    response="$(curl -fsS --max-time 10 --connect-timeout 5 \
        -X POST "${UPPER_VAS_SCHEME}://${UPPER_VAS_HOST}/register" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)" || response=""

    if [[ -n "$response" ]]; then
        log_debug "[REGISTER] Respuesta: $response"
        echo "$response"
        return 0
    else
        log "[REGISTER] Sin respuesta de UPPER_VAS (timeout o error de red)."
        return 1
    fi
}

heartbeat_client() {
    local response
    log_debug "[HEARTBEAT] POST ${UPPER_VAS_SCHEME}://${UPPER_VAS_HOST}/heartbeat ..."
    response="$(curl -fsS --max-time 10 --connect-timeout 5 \
        -X POST "${UPPER_VAS_SCHEME}://${UPPER_VAS_HOST}/heartbeat" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"$CLIENT_ID\"}" 2>/dev/null)" || response=""
    if [[ -n "$response" ]]; then
        log_debug "[HEARTBEAT] OK: $response"
        return 0
    else
        log "[HEARTBEAT] Sin respuesta (timeout, error de red o nodo no registrado)."
        return 1
    fi
}

refresh_upper_identity() {
    local response
    response="$(curl -fsS --max-time 10 --connect-timeout 5 \
        "${UPPER_VAS_SCHEME}://${UPPER_VAS_HOST}/clients/${CLIENT_ID}" 2>/dev/null)" || response=""

    if [[ -z "$response" ]]; then
        log "[IDENTITY] No se pudo obtener datos propios de UPPER_VAS. Identity no actualizado."
        return 1
    fi

    local vas_host vas_ip vas_mac vas_imp vas_inf
    vas_host="$(echo "$response" | jq -r '.hostname          // empty' 2>/dev/null || echo "")"
    vas_ip="$(  echo "$response" | jq -r '.ip                // empty' 2>/dev/null || echo "")"
    vas_mac="$( echo "$response" | jq -r '.mac               // empty' 2>/dev/null || echo "")"
    vas_imp="$( echo "$response" | jq -c '.extra_imperative  // empty' 2>/dev/null || echo "")"
    vas_inf="$( echo "$response" | jq -c '.extra_informative // empty' 2>/dev/null || echo "")"

    save_identity "$vas_host" "$vas_ip" "$vas_mac" "$vas_imp" "$vas_inf"
    log_debug "[IDENTITY] Actualizado desde UPPER_VAS: host=$vas_host ip=$vas_ip"
}

# ---------------------------------------------------------------------------
# Versiones
# ---------------------------------------------------------------------------
get_local_version() {
    curl -fsS --max-time 10 --connect-timeout 5 \
        "${LOCAL_VAS_HOST%/}/version" 2>/dev/null \
        | jq -r '.version' 2>/dev/null || echo ""
}

get_upper_version() {
    curl -fsS --max-time 10 --connect-timeout 5 \
        "${UPPER_VAS_SCHEME}://${UPPER_VAS_HOST}/version" 2>/dev/null \
        | jq -r '.version' 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# Inventario local → clientes
# ---------------------------------------------------------------------------
fetch_local_clients() {
    local url="${LOCAL_VAS_HOST%/}/clients"
    local params=""
    [[ "$FILTER" != "active" ]] && params="status=${FILTER}"
    [[ -n "$GLOBAL_KEY" ]] && params="${params:+${params}&}extra_key=${GLOBAL_KEY}"
    [[ -n "$params" ]] && url="${url}?${params}"
    log "[FETCH] GET $url"
    if curl -fsS --max-time 15 --connect-timeout 5 \
        "$url" -o "$TMP_CLIENTS" 2>/dev/null; then
        local count
        count="$(jq '.clients | length' "$TMP_CLIENTS" 2>/dev/null || echo '?')"
        mv "$TMP_CLIENTS" "$CLIENTS_FILE"
        log "[FETCH] Inventario local: $count equipo(s)"

        if [[ "$USE_VAT" == "true" && -n "$VAT_PRESET" ]]; then
            if command -v vat-operate &>/dev/null; then
                local vat_out
                vat_out="$(vat-operate --source-component VAF --direction upstream \
                    --preset "$VAT_PRESET" < "$CLIENTS_FILE" 2>/dev/null)" \
                && echo "$vat_out" > "${CLIENTS_FILE}.tmp" \
                && mv "${CLIENTS_FILE}.tmp" "$CLIENTS_FILE" \
                && log "[VAT] clients.json saneado (upstream) con preset '$VAT_PRESET'" \
                || log "[VAT-WARN] vat-operate falló. clients.json sin sanear."
            else
                log "[VAT-WARN] USE_VAT=true pero vat-operate no encontrado."
            fi
        fi
        return 0
    else
        log "[FETCH-ERROR] No se pudo descargar inventario de $LOCAL_VAS_HOST."
        rm -f "$TMP_CLIENTS"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Materialización de vistas por clave (LOCAL_KEY_LIST) — como VAL
# ---------------------------------------------------------------------------
materialize_keys() {
    [[ -z "$LOCAL_KEY_LIST" ]] && return 0
    [[ ! -f "$CLIENTS_FILE" ]] && return 0

    local key
    for key in $LOCAL_KEY_LIST; do
        local out="${STATE_DIR}/${key}_clients.json"
        local tmp="${out}.tmp"
        if jq --arg key "$key" \
            '{clients: [.clients[]? | select(
                (.extra_imperative  and (.extra_imperative  | has($key))) or
                (.extra_informative and (.extra_informative | has($key)))
            )]}' \
            "$CLIENTS_FILE" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$out"
            local count
            count="$(jq '.clients | length' "$out" 2>/dev/null || echo '?')"
            log "[MATERIALIZE] ${key}_clients.json → $count equipo(s)"
        else
            log "[VAF-ERROR] Error materializando ${key}_clients.json"
            rm -f "$tmp"
        fi
    done
}

# ---------------------------------------------------------------------------
# Distribución a hooks_local (rol VAL: consume el inventario local)
# ---------------------------------------------------------------------------
dispatch_hooks_local() {
    local version="$1"

    if [[ ! -d "$HOOKS_LOCAL_DIR" ]]; then
        log_debug "[HOOKS-LOCAL] Directorio no encontrado: $HOOKS_LOCAL_DIR"
        return 0
    fi

    local hook_count=0 hook_errors=0
    local stdin_src="$CLIENTS_FILE"
    [[ "$DISPATCH_STDIN" != "true" ]] && stdin_src="/dev/null"

    local timeout_cmd=()
    [[ "$HOOK_TIMEOUT_SECONDS" != "0" ]] && timeout_cmd=(timeout "$HOOK_TIMEOUT_SECONDS")

    for hook in "$HOOKS_LOCAL_DIR"/*; do
        [[ -f "$hook" && -x "$hook" ]] || continue
        (( ++hook_count ))
        log "[HOOKS-LOCAL] Ejecutando: $(basename "$hook")"
        local hook_exit=0
        VAF_VERSION="$version" \
        VAF_FILTER="$FILTER" \
        VAF_GLOBAL_KEY="$GLOBAL_KEY" \
        VAF_KEY="$KEY" \
        VAF_STATE_DIR="$STATE_DIR" \
        "${timeout_cmd[@]}" "$hook" < "$stdin_src" || hook_exit=$?
        if [[ $hook_exit -eq 0 ]]; then
            log_debug "[HOOKS-LOCAL] OK: $(basename "$hook")"
        elif [[ $hook_exit -eq 124 ]]; then
            log "[VAF-ERROR] Hook $(basename "$hook") superó el timeout de ${HOOK_TIMEOUT_SECONDS}s."
            (( ++hook_errors ))
        else
            log "[VAF-ERROR] Hook $(basename "$hook") terminó con error ($hook_exit). Continuando."
            (( ++hook_errors ))
        fi
    done

    if [[ $hook_count -eq 0 ]]; then
        log_debug "[HOOKS-LOCAL] Sin hooks ejecutables en $HOOKS_LOCAL_DIR"
    else
        log "[HOOKS-LOCAL] $hook_count hook(s) ejecutado(s), $hook_errors error(es)"
    fi
}

# ---------------------------------------------------------------------------
# Extras (rol VAC: enriquece el registro en UPPER_VAS)
# ---------------------------------------------------------------------------

# upsert_extra_key FILE KEY DATA_JSON
#   Inserta o actualiza KEY con timestamp UTC y DATA_JSON. Escritura atómica.
upsert_extra_key() {
    local file="$1" key="$2" data="$3"
    local ts tmp current raw lock
    ts="$(date -u +%Y%m%d%H%M%S)"
    tmp="${file}.tmp"
    lock="${file}.lock"
    (
        flock -x 9
        current="{}"
        if [[ -f "$file" ]]; then
            raw="$(cat "$file")"
            if jq empty <<< "$raw" 2>/dev/null; then
                current="$raw"
            else
                log "[WARN] [EXTRAS] $(basename "$file") corrupto — reiniciando vacío."
            fi
        fi
        jq -c --arg key "$key" --arg ts "$ts" --argjson data "$data" \
            '.[$key] = {"timestamp": $ts, "data": $data} | to_entries | sort_by(.key) | from_entries' \
            <<< "$current" > "$tmp" \
        && mv "$tmp" "$file" \
        || { rm -f "$tmp"; return 1; }
    ) 9>"$lock"
}

# expire_extras FILE
#   Elimina claves cuyo timestamp supera EXTRAS_TTL segundos.
expire_extras() {
    local file="$1"
    [[ ! -f "$file" ]] && return 0
    [[ "${EXTRAS_TTL:-0}" -eq 0 ]] && return 0

    local now key ts ts_epoch age
    now="$(date +%s)"
    local expired=()

    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        ts="$(jq -r --arg k "$key" '.[$k].timestamp // empty' "$file" 2>/dev/null)"
        [[ -z "$ts" || ! "$ts" =~ ^[0-9]{14}$ ]] && continue
        ts_epoch="$(date -d "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:8:2}:${ts:10:2}:${ts:12:2}" +%s 2>/dev/null)" || continue
        age=$(( now - ts_epoch ))
        if [[ "$age" -gt "$EXTRAS_TTL" ]]; then
            log "[WARN] [EXTRAS] Clave '$key' expirada (${age}s > TTL ${EXTRAS_TTL}s) — eliminada."
            expired+=("$key")
        fi
    done < <(jq -r 'keys[]' "$file" 2>/dev/null)

    [[ "${#expired[@]}" -eq 0 ]] && return 0

    local tmp="${file}.tmp" lock="${file}.lock"
    local keys_json
    keys_json="$(printf '%s\n' "${expired[@]}" | jq -R . | jq -sc .)"
    (
        flock -x 9
        jq -c --argjson keys "$keys_json" \
            'del(.[$keys[]]) | to_entries | sort_by(.key) | from_entries' \
            "$file" > "$tmp" \
        && mv "$tmp" "$file" \
        || { rm -f "$tmp"; return 1; }
    ) 9>"$lock"
}

# build_extras_merge FILE
#   Devuelve JSON plano { key: data } para enviar a VAS (sin timestamps).
#   Sin fichero  → "" (null → COALESCE en VAS)
#   0 claves     → "{}" (borrado explícito)
#   Con claves   → { key: data, ... }
build_extras_merge() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo ""
        return 0
    fi
    local count
    if ! count="$(jq 'keys | length' "$file" 2>/dev/null)"; then
        echo ""
        return 0
    fi
    if [[ "$count" -eq 0 ]]; then
        echo "{}"
        return 0
    fi
    jq -c 'to_entries | map({key: .key, value: .value.data}) | from_entries' "$file" 2>/dev/null || echo ""
}

# _run_extras_hooks DIR FILE LABEL
#   Ejecuta los hooks de un directorio y almacena resultados en FILE con TTL.
_run_extras_hooks() {
    local dir="$1" file="$2" label="$3"
    [[ "$EXTRAS_ENABLED" != "true" ]] && return 0
    if [[ ! -d "$dir" ]]; then
        log_debug "[$label] Directorio de hooks no encontrado: $dir"
        return 0
    fi
    local hook key output normalized
    for hook in "$dir"/*; do
        [[ -f "$hook" && -x "$hook" ]] || continue
        key="$(basename "$hook")"
        key="${key%.*}"
        if output="$(timeout 10 "$hook" 2>/dev/null)"; then
            if [[ -z "$output" ]]; then
                log_debug "[$label] Hook '$(basename "$hook")': sin salida — clave '$key' no actualizada."
                continue
            fi
            if normalized="$(echo "$output" | jq -c '.' 2>/dev/null)"; then
                upsert_extra_key "$file" "$key" "$normalized" \
                    && log_debug "[$label] Clave '$key' actualizada." \
                    || log "[WARN] [EXTRAS] Error escribiendo clave '$key'."
            else
                log "[WARN] [EXTRAS] Hook '$(basename "$hook")' salida no es JSON válido."
            fi
        else
            log "[WARN] [EXTRAS] Hook '$(basename "$hook")' falló — clave '$key' no actualizada."
        fi
    done
}

# collect_extras_imperative
#   Ejecuta hooks imperativos, expira TTL y asigna EXTRA_IMP_BASE.
#   EXTRA_IMP_BASE no incluye VAF_KEY_clients (eso lo añade build_vaf_extra).
collect_extras_imperative() {
    if [[ "$EXTRAS_ENABLED" != "true" ]]; then
        EXTRA_IMP_BASE="{}"
        return
    fi
    _run_extras_hooks "$EXTRAS_IMPERATIVE_HOOKS_DIR" "$EXTRAS_IMP_FILE" "IMP"
    expire_extras "$EXTRAS_IMP_FILE"
    EXTRA_IMP_BASE="$(build_extras_merge "$EXTRAS_IMP_FILE")"
}

# collect_extras_informative
#   Ejecuta hooks informativos, expira TTL y asigna EXTRA_INF.
collect_extras_informative() {
    if [[ "$EXTRAS_ENABLED" != "true" ]]; then
        EXTRA_INF="{}"
        return
    fi
    _run_extras_hooks "$EXTRAS_INFORMATIVE_HOOKS_DIR" "$EXTRAS_INF_FILE" "INF"
    expire_extras "$EXTRAS_INF_FILE"
    EXTRA_INF="$(build_extras_merge "$EXTRAS_INF_FILE")"
}

# ---------------------------------------------------------------------------
# Construcción del extra_imperative completo para UPPER_VAS
# ---------------------------------------------------------------------------
# build_vaf_extra EXTRA_IMP_BASE
#   Construye el extra_imperative completo:
#     { VAF_<KEY>_clients: <clients.json>, ...EXTRA_IMP_BASE }
#   VAF_KEY_clients siempre está presente. Los extras del usuario se añaden encima.
build_vaf_extra() {
    local base="${1:-}"
    local clients_json="{}"
    [[ -f "$CLIENTS_FILE" ]] && clients_json="$(cat "$CLIENTS_FILE" 2>/dev/null || echo '{}')"

    local vaf_key="VAF_${KEY}_clients"

    if [[ -z "$base" || "$base" == "{}" ]]; then
        jq -c --arg k "$vaf_key" '{($k): .}' <<< "$clients_json" 2>/dev/null || echo "{}"
    else
        jq -c --arg k "$vaf_key" --argjson clients "$clients_json" \
            '. + {($k): $clients}' <<< "$base" 2>/dev/null || echo "{}"
    fi
}

# ---------------------------------------------------------------------------
# Inventario del VAS superior (SYNC_UPPER)
# ---------------------------------------------------------------------------
download_upper_clients() {
    log "[UPPER] GET ${UPPER_VAS_SCHEME}://${UPPER_VAS_HOST}/clients"
    if curl -fsS --max-time 15 --connect-timeout 5 \
        "${UPPER_VAS_SCHEME}://${UPPER_VAS_HOST}/clients" -o "$TMP_UPPER_CLIENTS" 2>/dev/null; then
        local count
        count="$(jq '.clients | length' "$TMP_UPPER_CLIENTS" 2>/dev/null || echo '?')"
        if [[ "$USE_VAT" == "true" && -n "$VAT_PRESET" ]] && command -v vat-operate &>/dev/null; then
            local vat_out
            vat_out="$(vat-operate --source-component VAF --direction downstream \
                --preset "$VAT_PRESET" < "$TMP_UPPER_CLIENTS" 2>/dev/null)" \
            && echo "$vat_out" > "$TMP_UPPER_CLIENTS" \
            && log "[VAT] upper_clients.json saneado (downstream) con preset '$VAT_PRESET'" \
            || log "[VAT-WARN] vat-operate falló. upper_clients.json sin sanear."
        fi
        mv "$TMP_UPPER_CLIENTS" "$UPPER_CLIENTS_FILE"
        log "[UPPER] Inventario superior: $count nodo(s)"
        return 0
    else
        log "[UPPER-ERROR] No se pudo descargar inventario de UPPER_VAS."
        rm -f "$TMP_UPPER_CLIENTS"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Escritura atómica de ficheros de versión
# ---------------------------------------------------------------------------
write_version() {
    local ver="$1" tmp="${VERSION_FILE}.tmp"
    echo "$ver" > "$tmp" && mv "$tmp" "$VERSION_FILE" \
        || { rm -f "$tmp"; log "[WARN] No se pudo escribir VERSION_FILE."; }
}

write_upper_version() {
    local ver="$1" tmp="${UPPER_VERSION_FILE}.tmp"
    echo "$ver" > "$tmp" && mv "$tmp" "$UPPER_VERSION_FILE" \
        || { rm -f "$tmp"; log "[WARN] No se pudo escribir UPPER_VERSION_FILE."; }
}

# ---------------------------------------------------------------------------
# Selfcheck de identidad (hostname/IP/MAC + extra_imperative)
# ---------------------------------------------------------------------------
# selfcheck_local: compara host/ip/mac contra identity.json.
# Devuelve 0 si coincide, 1 si hay discordancia o no existe identity.json.
selfcheck_local() {
    if ! load_identity; then
        log "[SELFCHECK] Sin identity.json — forzando registro."
        return 1
    fi
    local mismatch=0
    [[ "$LOC_HOST" != "$IDENTITY_HOST" ]] && { log "[SELFCHECK] hostname: '$IDENTITY_HOST' → '$LOC_HOST'"; mismatch=1; }
    [[ "$LOC_IP"   != "$IDENTITY_IP"   ]] && { log "[SELFCHECK] IP: '$IDENTITY_IP' → '$LOC_IP'";           mismatch=1; }
    [[ "$LOC_MAC"  != "$IDENTITY_MAC"  ]] && { log "[SELFCHECK] MAC: '$IDENTITY_MAC' → '$LOC_MAC'";        mismatch=1; }
    [[ "$mismatch" -eq 0 ]] && log_debug "[SELFCHECK] Identidad sin cambios."
    return "$mismatch"
}

# selfcheck_imp NEW_IMP: añade comparación de extra_imperative al selfcheck.
# Devuelve 1 (re-registrar) si hay discordancia en host/ip/mac/imp.
selfcheck_imp() {
    local new_imp="$1"
    if ! selfcheck_local; then
        return 1
    fi
    if [[ -n "$new_imp" && "$new_imp" != "$IDENTITY_IMP" ]]; then
        log "[SELFCHECK] extra_imperative cambió."
        return 1
    fi
    return 0
}
