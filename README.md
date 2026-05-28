# vx-dga-l-vaf — Versatile Autoregistration Federated

Daemon que conecta dos niveles de VAS en una jerarquía de federación.

Combina el rol de **VAC** (registro con identidad propia) y **VAL** (consumidor de inventario), publicando el inventario del VAS local como un campo extra en el VAS superior.

## Ecosistema

```
vx-dga-l-vas   → servidor de registro canónico
vx-dga-l-vac   → cliente de autoregistro (cada equipo)
vx-dga-l-val   → consumidor genérico de inventario (hooks)
vx-dga-l-vaf   → federación de servidores VAS (este paquete)
```

VAF asume que `LOCAL_VAS_HOST` tiene un VAS con sus propios clientes VAC registrados,
y que `UPPER_VAS_HOST` es un VAS al que VAF se conecta como cliente.

## ¿Qué hace?

```
VAS local (LOCAL_VAS_HOST)          VAS superior (UPPER_VAS_HOST)
  GET /version  ←── vaf ──→  POST /register
  GET /clients                  extra_imperative.VAF_<KEY>:
  (con FILTER + GLOBAL_KEY)       {"clients": [...inventario local...]}
                               GET /clients/{uuid}  ← verifica extra
```

1. **Se registra** en el VAS superior con su UUID, hostname, IP y MAC.
2. **Monitoriza** el VAS local (`GET /version`). Cuando detecta un cambio:
   - Descarga `GET /clients` del VAS local (filtrando por `FILTER` y `GLOBAL_KEY`).
   - Publica el inventario local como `extra_imperative.VAF_<KEY>` en el VAS superior.
   - Verifica el extra con `GET /clients/{uuid}` en el VAS superior.
3. **Heartbeat** periódico al VAS superior para mantener `last_seen` actualizado.
4. Opcionalmente descarga el inventario del VAS superior (`SYNC_UPPER=true`).

## Caso de uso

Un servidor VAS "de aula" tiene sus propios equipos registrados. VAF permite al VAS de dirección ver el inventario de cada aula como un extra del nodo VAF:

```
VAS dirección  ←── VAF aula3 (KEY=aula3) ──→  VAS aula3
               ←── VAF aula4 (KEY=aula4) ──→  VAS aula4

GET /clients en VAS dirección → clientes = [
  { uuid: "...", hostname: "vaf-aula3", extra_imperative: {
      "VAF_aula3": {"clients": [...equipos del aula 3...]}
  }},
  ...
]
```

## Archivos instalados

| Ruta | Descripción |
|---|---|
| `/usr/bin/vaf` | Daemon principal |
| `/usr/bin/vaf-register` | Registro puntual (equivalente a `vac-register`) |
| `/usr/lib/vaf/vaf-common.sh` | Librería compartida |
| `/etc/vaf/vaf.conf` | Configuración principal |
| `/etc/vaf/vaf.conf.d/` | Overlays de configuración |
| `/etc/vaf/vaf-id` | UUID del nodo (generado en instalación) |
| `/usr/share/vaf/vaf.conf.defaults` | Referencia de valores por defecto |
| `/usr/share/vaf/hooks.d.examples/local-vaf-register` | Hook de ejemplo para VAS local |
| `/var/lib/vaf/local_version` | Última versión del VAS local procesada |
| `/var/lib/vaf/clients.json` | Último inventario local descargado |
| `/var/lib/vaf/identity.json` | Último registro enviado al VAS superior |
| `/var/lib/vaf/upper_version` | Última versión del VAS superior (si `SYNC_UPPER=true`) |
| `/var/lib/vaf/upper_clients.json` | Inventario del VAS superior (si `SYNC_UPPER=true`) |

## Configuración mínima

```ini
# /etc/vaf/vaf.conf
KEY=aula3
LOCAL_VAS_HOST=http://127.0.0.1:8000
UPPER_VAS_HOST=http://10.0.0.1:8000
```

## Variables de configuración

| Variable | Por defecto | Descripción |
|---|---|---|
| `KEY` | _(obligatorio)_ | Clave de agregación. El inventario local se publica como `extra_imperative.VAF_<KEY>`. |
| `LOCAL_VAS_HOST` | `http://127.0.0.1:8000` | VAS local — fuente del inventario. |
| `UPPER_VAS_HOST` | _(obligatorio)_ | VAS superior — destino del registro. |
| `FILTER` | `active` | Filtro del VAS local: `active`, `inactive`, `archived`, `all`. |
| `GLOBAL_KEY` | _(vacío)_ | Clave extra enviada al VAS local como `?extra_key=KEY`. Filtra qué clientes locales incluir. Vacío = todos. |
| `CHECK_SECONDS` | `300` | Intervalo entre comprobaciones de versión y heartbeat. |
| `RETRY_SECONDS` | `60` | Espera ante errores de conexión. |
| `SYNC_UPPER` | `false` | `true`: descarga el inventario del VAS superior en `upper_clients.json` tras cada cambio. |
| `BUMP_LISTEN_PORT` | `0` | Puerto UDP de escucha para notificaciones push del VAS local. `0` = desactivado. Requiere `netcat-openbsd`. |

## Activación del hook en el VAS local

Para que el VAS superior se actualice inmediatamente cuando cambia el inventario local, instala el hook en el mismo servidor que `LOCAL_VAS_HOST`:

```bash
cp /usr/share/vaf/hooks.d.examples/local-vaf-register /etc/vas/hooks.d/
chmod +x /etc/vas/hooks.d/local-vaf-register
```

Cuando el VAS local ejecuta `bump_version()`, el hook llama a `vaf-register` que empuja el nuevo inventario al VAS superior en milisegundos, sin esperar al ciclo de `CHECK_SECONDS`.

## Flujo completo con notificación push

```ini
# /etc/vaf/vaf.conf
KEY=aula3
LOCAL_VAS_HOST=http://127.0.0.1:8000
UPPER_VAS_HOST=http://10.0.0.1:8000
BUMP_LISTEN_PORT=9878
```

```
VAS local bump_version()
  └─ hooks.d/local-vaf-register (fire and forget)
       → vaf-register
         → GET /clients (LOCAL_VAS_HOST)
         → POST /register (UPPER_VAS_HOST) con VAF_aula3
         → GET /clients/{uuid} (UPPER_VAS_HOST) para verificar
```

El daemon `vaf` también puede recibir un bump UDP en `BUMP_LISTEN_PORT` (como VAL-Aware) para interrumpir el sleep e iniciar una comprobación inmediata.

## Consulta del inventario agregado desde el VAS superior

```bash
# Ver todos los nodos VAF registrados
curl -s http://10.0.0.1:8000/clients | jq '.clients[] | select(.extra_imperative | has("VAF_aula3"))'

# Contar equipos del aula 3 desde el VAS superior
curl -s http://10.0.0.1:8000/clients | \
  jq '[.clients[] | select(.extra_imperative.VAF_aula3?) | .extra_imperative.VAF_aula3.clients[]] | length'

# Listar IPs de todos los equipos de todos los nodos VAF
curl -s http://10.0.0.1:8000/clients | \
  jq '[.clients[].extra_imperative | to_entries[] | select(.key | startswith("VAF_")) | .value.clients[].ip]'
```

## Servicio

```bash
systemctl status vaf
systemctl restart vaf
journalctl -u vaf -f
journalctl -u vaf | grep '\[VAF-ERROR\]'
```
