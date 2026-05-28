# vaf-common.sh — Funciones compartidas de VAF.
#
# Uso: source /usr/lib/vaf/vaf-common.sh
#
# El script que carga esta librería debe definir LOG_TAG antes del source:
#   LOG_TAG="[VAF]"           → bucle principal
#   LOG_TAG="[VAF-REGISTER]"  → registro puntual

# ---------------------------------------------------------------------------
# Rutas (sobreescribibles antes del source para sub-instancias futuras)
# ---------------------------------------------------------------------------
CONF_FILE="${CONF_FILE:-/etc/vaf/vaf.conf}"
CONF_DIR="${CONF_DIR:-/etc/vaf/vaf.conf.d}"
ID_FILE="${ID_FILE:-/etc/vaf/vaf-id}"
STATE_DIR="${STATE_DIR:-/var/lib/vaf}"

VERSION_FILE="${STATE_DIR}/local_version"
CLIENTS_FILE="${STATE_DIR}/clients.json"
TMP_CLIENTS="${STATE_DIR}/clients.json.tmp"
UPPER_VERSION_FILE="${STATE_DIR}/upper_version"
UPPER_CLIENTS_FILE="${STATE_DIR}/upper_clients.json"
TMP_UPPER_CLIENTS="${STATE_DIR}/upper_clients.json.tmp"
IDENTITY_FILE="${STATE_DIR}/identity.json"
TMP_IDENTITY="${STATE_DIR}/identity.json.tmp"

# ---------------------------------------------------------------------------
# Valores por defecto de configuración
# ---------------------------------------------------------------------------
KEY=""
LOCAL_VAS_HOST="http://127.0.0.1:8000"
UPPER_VAS_HOST=""
FILTER="active"
GLOBAL_KEY=""
CHECK_SECONDS=300
HEARTBEAT_SECONDS=""   # vacío = igual a CHECK_SECONDS (resuelto tras load_all_conf)
RETRY_SECONDS=60
SYNC_UPPER=false
BUMP_LISTEN_PORT=0
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
            KEY)              KEY="$val";              (( ++loaded )) ;;
            LOCAL_VAS_HOST)   LOCAL_VAS_HOST="$val";   (( ++loaded )) ;;
            UPPER_VAS_HOST)   UPPER_VAS_HOST="$val";   (( ++loaded )) ;;
            FILTER)           FILTER="$val";           (( ++loaded )) ;;
            GLOBAL_KEY)       GLOBAL_KEY="$val";       (( ++loaded )) ;;
            CHECK_SECONDS)    CHECK_SECONDS="$val";    (( ++loaded )) ;;
            HEARTBEAT_SECONDS) HEARTBEAT_SECONDS="$val"; (( ++loaded )) ;;
            RETRY_SECONDS)    RETRY_SECONDS="$val";    (( ++loaded )) ;;
            SYNC_UPPER)       SYNC_UPPER="$val";       (( ++loaded )) ;;
            BUMP_LISTEN_PORT) BUMP_LISTEN_PORT="$val"; (( ++loaded )) ;;
            LOG_LEVEL)        LOG_LEVEL="$val";        (( ++loaded )) ;;
            LOG_FILE)         LOG_FILE="$val";         (( ++loaded )) ;;
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
}

# ---------------------------------------------------------------------------
# Datos de red (idéntico a VAC)
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
        }' > "$TMP_IDENTITY" 2>/dev/null \
    && mv "$TMP_IDENTITY" "$IDENTITY_FILE" \
    || { log "[IDENTITY] Error escribiendo $IDENTITY_FILE"; rm -f "$TMP_IDENTITY"; return 1; }
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

# POST /register en UPPER_VAS con identidad + extra_imperative.VAF_<KEY>.
register_client() {
    local host="$1" ip="$2" mac="$3" extra_imp="${4:-}" extra_inf="${5:-}"
    local payload response

    if [[ -z "$ip" ]]; then
        log "[REGISTER] IP vacía — sin red activa. Abortando registro."
        return 1
    fi
    [[ -z "$mac" ]] && log "[REGISTER] MAC vacía (interfaz virtual). Registrando sin MAC."

    local imp_desc
    if   [[ -z "$extra_imp" ]];     then imp_desc="(null/COALESCE)"
    elif [[ "$extra_imp" == "{}" ]]; then imp_desc="(borrado explícito)"
    else imp_desc="VAF_${KEY} JSON"; fi
    log_debug "[REGISTER] hostname=$host ip=$ip imp=$imp_desc"

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

    log "[REGISTER] POST ${UPPER_VAS_HOST%/}/register ..."
    response="$(curl -fsS --max-time 10 --connect-timeout 5 \
        -X POST "${UPPER_VAS_HOST%/}/register" \
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

# POST /heartbeat — solo actualiza last_seen en UPPER_VAS.
# Devuelve 1 si falla o si VAS responde 404 (nodo no registrado → re-registrar).
heartbeat_client() {
    local response
    log_debug "[HEARTBEAT] POST ${UPPER_VAS_HOST%/}/heartbeat ..."
    response="$(curl -fsS --max-time 10 --connect-timeout 5 \
        -X POST "${UPPER_VAS_HOST%/}/heartbeat" \
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

# GET /clients/{uuid} en UPPER_VAS — comprueba que el nodo está registrado
# y actualiza identity.json con los datos confirmados por el VAS superior
# (incluido el VAF_<KEY> que efectivamente almacenó).
# Devuelve 1 si no se puede contactar o si el nodo no existe (404).
refresh_upper_identity() {
    local response
    response="$(curl -fsS --max-time 10 --connect-timeout 5 \
        "${UPPER_VAS_HOST%/}/clients/${CLIENT_ID}" 2>/dev/null)" || response=""

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
# Consulta de versiones
# ---------------------------------------------------------------------------
get_local_version() {
    curl -fsS --max-time 10 --connect-timeout 5 \
        "${LOCAL_VAS_HOST%/}/version" 2>/dev/null \
        | jq -r '.version' 2>/dev/null || echo ""
}

get_upper_version() {
    curl -fsS --max-time 10 --connect-timeout 5 \
        "${UPPER_VAS_HOST%/}/version" 2>/dev/null \
        | jq -r '.version' 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# Inventario local → extra VAF_<KEY>
# ---------------------------------------------------------------------------

# GET /clients desde el VAS local con FILTER (status) y GLOBAL_KEY (extra_key),
# igual que VAL. Guarda en clients.json de forma atómica.
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
        return 0
    else
        log "[FETCH-ERROR] No se pudo descargar inventario de $LOCAL_VAS_HOST."
        rm -f "$TMP_CLIENTS"
        return 1
    fi
}

# Construye el JSON de extra_imperative para enviar al VAS superior:
#   { "VAF_<KEY>": {"clients": [...]} }
# El objeto clients.json descargado del VAS local se encapsula íntegro.
build_vaf_extra() {
    [[ -z "$KEY" ]] && { echo "{}"; return 0; }
    if [[ ! -f "$CLIENTS_FILE" ]]; then
        jq -n --arg k "VAF_${KEY}" '{($k): {"clients": []}}' 2>/dev/null || echo "{}"
        return 0
    fi
    jq -c --arg k "VAF_${KEY}" '{($k): .}' "$CLIENTS_FILE" 2>/dev/null || echo "{}"
}

# ---------------------------------------------------------------------------
# Inventario del VAS superior (SYNC_UPPER)
# ---------------------------------------------------------------------------
download_upper_clients() {
    log "[UPPER] GET ${UPPER_VAS_HOST%/}/clients"
    if curl -fsS --max-time 15 --connect-timeout 5 \
        "${UPPER_VAS_HOST%/}/clients" -o "$TMP_UPPER_CLIENTS" 2>/dev/null; then
        local count
        count="$(jq '.clients | length' "$TMP_UPPER_CLIENTS" 2>/dev/null || echo '?')"
        mv "$TMP_UPPER_CLIENTS" "$UPPER_CLIENTS_FILE"
        log "[UPPER] Inventario superior: $count nodo(s)"
        return 0
    else
        log "[UPPER-ERROR] No se pudo descargar inventario de $UPPER_VAS_HOST."
        rm -f "$TMP_UPPER_CLIENTS"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Selfcheck de identidad propia (hostname/IP/MAC vs identity.json)
# ---------------------------------------------------------------------------
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
