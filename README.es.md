<div align="center">
  <img src="assets/logo.svg" alt="VAF logo" width="100"/>
  <h1>VAF — Versatile Autoregistration Federated</h1>
</div>

[![en](https://img.shields.io/badge/lang-en-blue.svg)](README.md)
[![es](https://img.shields.io/badge/lang-es-green.svg)](README.es.md)

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Debian package](https://img.shields.io/badge/package-versatile--autoreg--vaf-brightgreen)](https://github.com/GabrielNavi/vaf/releases)
[![Bash](https://img.shields.io/badge/shell-bash-89e051.svg)](https://www.gnu.org/software/bash/)
[![Platform: Linux](https://img.shields.io/badge/platform-Linux-lightgrey.svg)]()

Daemon de federación para redes Linux gestionadas centralmente. Conecta dos niveles de VAS actuando simultáneamente como cliente VAC (se registra en un VAS superior) y consumidor VAL (monitoriza el inventario de un VAS local), publicando el inventario local como `extra_imperative.VAF_<KEY>` en el VAS superior. Soporta jerarquías de profundidad arbitraria y registro simultáneo en múltiples VAS superiores mediante sub-instancias.

---

## Tabla de contenidos

- [Ecosistema](#ecosistema)
- [Instalación rápida](#instalación-rápida)
- [Archivos instalados](#archivos-instalados)
- [Configuración](#configuración)
- [Ciclo de operación](#ciclo-de-operación)
- [Sistema de extras](#sistema-de-extras)
- [Notificación push (VAF-Aware)](#notificación-push-vaf-aware)
- [Paralelización](#paralelización)
- [Servicio](#servicio)
- [Wiki](#wiki)
- [Licencia](#licencia)

---

## Ecosistema

```
VAS (superior) ◄── POST /register, /heartbeat ── VAF ──► GET /version, /clients ── VAS (local)
                      extra_imperative:                        │
                        VAF_<KEY>: {clients: [...]}        Clientes VAC, otros nodos VAF...
```

| Paquete | Repositorio | Descripción |
|---------|-------------|-------------|
| `versatile-autoreg-vas` | [vas](https://github.com/GabrielNavi/vas) | Servidor de inventario |
| `versatile-autoreg-vac` | [vac](https://github.com/GabrielNavi/vac) | Cliente de autoregistro |
| `versatile-autoreg-val` | [val](https://github.com/GabrielNavi/val) | Consumidor genérico con hooks |
| `versatile-autoreg-vaf` | [vaf](https://github.com/GabrielNavi/vaf) ← *este* | Federación de servidores |

**Despliegue típico** — jerarquía de tres niveles:

```
VAS centro ◄── VAF aula3  ──► VAS aula3  ◄── VAC equipo01
                                          ◄── VAC equipo02
           ◄── VAF aula4  ──► VAS aula4  ◄── VAC ...
```

---

## Instalación rápida

```bash
# Instalar
sudo dpkg -i versatile-autoreg-vaf_*.deb
sudo apt-get -f install

# Configurar — mínimo necesario
sudo nano /etc/vaf/vaf.conf
# KEY=aula3
# UPPER_VAS_HOST=10.0.0.1

# Arrancar
sudo systemctl enable --now vaf

# Verificar
journalctl -u vaf -f
```

> **Dependencias:** `bash`, `curl`, `jq`, `uuid-runtime`, `iproute2` · `netcat-openbsd` (recomendado, para VAF-Aware)  
> `LOCAL_VAS_HOST` se auto-detecta desde `/etc/vas/vas.conf` — VAS debe estar instalado en el mismo equipo.  
> Ver [Instalación](https://github.com/GabrielNavi/vaf/wiki/ES_Instalacion) en la wiki para instrucciones completas.

---

## Archivos instalados

| Ruta | Descripción |
|------|-------------|
| `/usr/bin/vaf` | Daemon principal de federación |
| `/usr/bin/vaf-register` | Registro puntual (para hooks del VAS local) |
| `/usr/bin/vaf-sub` | Bucle VAF completo para sub-instancias |
| `/usr/bin/vaf-sub-manager` | Supervisor de sub-instancias con fail counter |
| `/usr/bin/vaf-sub-instance` | CLI para crear, listar y eliminar sub-instancias |
| `/usr/lib/vaf/vaf-common.sh` | Librería compartida: config, identidad, extras, registro, federación |
| `/etc/vaf/vaf.conf` | Configuración principal |
| `/etc/vaf/vaf.conf.d/` | Overlays de configuración en orden lexical |
| `/etc/vaf/extras_imperative.d/` | Scripts hook cíclicos para extras imperativos |
| `/etc/vaf/extras_informative.d/` | Scripts hook cíclicos para extras informativos |
| `/etc/vaf/hooks_local.d/` | Scripts disparados cuando cambia el inventario del VAS local |
| `/usr/share/vaf/vaf.conf.defaults` | Referencia exhaustiva de variables (solo lectura) |
| `/usr/share/vaf/hooks.d/local-vaf-register` | Hook auto-instalado en VAS en la instalación |
| `/lib/systemd/system/vaf.service` | Unidad systemd |
| `/lib/systemd/system/vaf-sub.service` | Unidad del gestor de sub-instancias |

**Estado en tiempo de ejecución:**

| Ruta | Descripción |
|------|-------------|
| `/etc/vaf/vaf-id` | UUID persistente del nodo (generado una vez, modo 600) |
| `/var/lib/vaf/identity.json` | Datos propios tal como los confirmó el VAS superior |
| `/var/lib/vaf/local_version` | Última versión del VAS local procesada |
| `/var/lib/vaf/clients.json` | Último inventario local descargado |
| `/var/lib/vaf/upper_version` | Última versión del VAS superior (`SYNC_UPPER=true`) |
| `/var/lib/vaf/upper_clients.json` | Inventario del VAS superior (`SYNC_UPPER=true`) |

---

## Configuración

```ini
# /etc/vaf/vaf.conf  (referencia completa en /usr/share/vaf/vaf.conf.defaults)

KEY=aula3                # clave de agregación — publicada como VAF_aula3 en VAS superior
# LOCAL_VAS_HOST=http://127.0.0.1:8000   # auto-detectado desde /etc/vas/vas.conf
UPPER_VAS_HOST=10.0.0.1  # sin scheme; se añade :8000 automáticamente
FILTER=active            # active | inactive | archived | all
CHECK_SECONDS=300        # polling VAS local + actualización VAS superior
# HEARTBEAT_SECONDS=60   # heartbeat de liveness; vacío = igual a CHECK_SECONDS
SYNC_UPPER=false         # descargar inventario VAS superior a upper_clients.json
BUMP_LISTEN_PORT=0       # puerto UDP push (0 = desactivado; requiere netcat-openbsd)
LOG_LEVEL=normal         # no | normal | debug
PARALLEL_MODE=both       # both | only_parallel | only_main
```

`UPPER_VAS_HOST` acepta `10.0.0.1`, `10.0.0.1:9000` o `vas.ejemplo.org`. El scheme se extrae automáticamente con `[WARN]`.

Guía completa: [Configuración](https://github.com/GabrielNavi/vaf/wiki/ES_Configuracion)

---

## Ciclo de operación

VAF ejecuta dos temporizadores independientes de forma simultánea:

```
Cada CHECK_SECONDS  (o con bump UDP):
  collect_extras_imperative()
  GET /version (VAS local)
  Nueva versión → GET /clients → build_vaf_extra()
                  → [opcional: VAT --direction upstream] normalizar extras
                  → POST /register (VAS superior) con VAF_<KEY>_clients
                  → materialize_keys() → [opcional: VAT --direction downstream]
                  → dispatch_hooks_local()

Cada HEARTBEAT_SECONDS:
  selfcheck vs identity.json
  Con cambios  → POST /register (VAS superior) [completo, COALESCE extras]
  Sin cambios  → POST /heartbeat (VAS superior) [~50B, solo last_seen]
```

El bloque CHECK actúa como VAL (detecta cambios en el inventario local y los publica). El bloque HB actúa como VAC (mantiene el nodo activo en el VAS superior). Un registro exitoso en cualquier bloque resetea el temporizador del otro.

VAT (Transformador de Autoregistro Versátil) puede normalizar el inventario antes de enviarlo upstream y filtrar la réplica de la BD antes de almacenarla localmente. Véase la [documentación VAT](https://github.com/GabrielNavi/vat) para la configuración.

Más información: [Flujo de operación](https://github.com/GabrielNavi/vaf/wiki/ES_Federacion)

---

## Sistema de extras

Además del campo `VAF_<KEY>_clients` generado automáticamente, VAF soporta el mismo sistema de extras que VAC. Las claves extra se incluyen junto al payload de federación en el registro del VAS superior.

```bash
# Hook cíclico: la clave es el basename sin extensión
#!/bin/bash
# /etc/vaf/extras_imperative.d/carga.sh
load=$(awk '{print $1}' /proc/loadavg)
echo "{\"load1\": \"${load}\"}"
```

Ejemplo de entrada en el VAS superior:
```json
{
  "hostname": "vaf-aula3",
  "extra_imperative": {
    "VAF_aula3":  {"clients": [...]},
    "carga":      {"load1": "0.42"},
    "actualizaciones": {"pending": 3}
  }
}
```

Más información: [Extras](https://github.com/GabrielNavi/vaf/wiki/ES_Extras)

---

## Notificación push (VAF-Aware)

Con `BUMP_LISTEN_PORT` activo, VAF reacciona a cambios del inventario local en milisegundos sin esperar al siguiente ciclo de `CHECK_SECONDS`. El hook `local-vaf-register` (auto-instalado por el postinst en `hooks.d/` del VAS) dispara un registro puntual en cada `bump_version()`:

```
VAS local bump_version()
  └─ hooks.d/local-vaf-register
       → vaf-register → GET /clients → POST /register (VAS superior)
                                         ↑ milisegundos
```

Sin VAF-Aware, el daemon detecta el mismo cambio en el siguiente ciclo CHECK (hasta `CHECK_SECONDS`).

Más información: [VAF-Aware](https://github.com/GabrielNavi/vaf/wiki/ES_VAF-Aware)

---

## Paralelización

Un nodo VAF puede registrarse en múltiples VAS superiores con UUIDs y estado independientes por sub-instancia:

```bash
vaf-sub-instance --create mirror --upper 10.0.1.5 --key aula3-mirror
vaf-sub-instance --list
# NOMBRE    UPPER_VAS_HOST  CLAVE            ENABLED  ESTADO
# mirror    10.0.1.5:8000   aula3-mirror     sí       activa
systemctl restart vaf   # con PARALLEL_MODE=both
```

El UUID de cada sub-instancia se deriva como UUIDv5 (sha1, namespace=vaf-id-base, name=nombre-instancia), garantizando identidad estable entre reinicios.

`PARALLEL_MODE`: `both` · `only_parallel` · `only_main`. El supervisor deja de reiniciar una instancia tras 5 fallos duros consecutivos.

Más información: [Sub-instancias](https://github.com/GabrielNavi/vaf/wiki/ES_Sub-instancias)

---

## Servicio

```bash
sudo systemctl status vaf
sudo systemctl restart vaf
journalctl -u vaf -f
journalctl -u vaf | grep '\[VAF-ERROR\]'
journalctl -u vaf | grep '\[SYNC\]'
journalctl -u vaf | grep '\[STARTUP\]'
journalctl -u vaf | grep '\[PARALLEL\]'
```

---

## Wiki

[Instalación](https://github.com/GabrielNavi/vaf/wiki/ES_Instalacion) · [Configuración](https://github.com/GabrielNavi/vaf/wiki/ES_Configuracion) · [Flujo de operación](https://github.com/GabrielNavi/vaf/wiki/ES_Flujo) · [Federación](https://github.com/GabrielNavi/vaf/wiki/ES_Federacion) · [VAF-Aware](https://github.com/GabrielNavi/vaf/wiki/ES_VAF-Aware) · [Sub-instancias](https://github.com/GabrielNavi/vaf/wiki/ES_Sub-instancias) · [Logging](https://github.com/GabrielNavi/vaf/wiki/ES_Logging)

---

## Licencia

[Apache License 2.0](LICENSE)
