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

Federation daemon for centrally managed Linux networks. Bridges two VAS levels by acting simultaneously as a VAC client (registers with an upper VAS) and a VAL consumer (monitors a local VAS inventory), publishing the local inventory as `extra_imperative.VAF_<KEY>` in the upper VAS. Supports arbitrary hierarchy depth and simultaneous registration in multiple upper VAS servers via sub-instances.

> 📖 [Versión en español](README.es.md)

---

## Table of Contents

- [Ecosystem](#ecosystem)
- [Quick Start](#quick-start)
- [Installed Files](#installed-files)
- [Configuration](#configuration)
- [Operation Cycle](#operation-cycle)
- [Extras System](#extras-system)
- [Push Notifications (VAF-Aware)](#push-notifications-vaf-aware)
- [Parallelization](#parallelization)
- [Service Management](#service-management)
- [Wiki](#wiki)
- [License](#license)

---

## Ecosystem

```
VAS (upper) ◄── POST /register, /heartbeat ── VAF ──► GET /version, /clients ── VAS (local)
                   extra_imperative:                        │
                     VAF_<KEY>: {clients: [...]}        VAC clients, other VAF nodes...
```

| Package | Repository | Description |
|---------|------------|-------------|
| `versatile-autoreg-vas` | [vas](https://github.com/GabrielNavi/vas) | Inventory server |
| `versatile-autoreg-vac` | [vac](https://github.com/GabrielNavi/vac) | Autoregistration client |
| `versatile-autoreg-val` | [val](https://github.com/GabrielNavi/val) | Generic consumer with hooks |
| `versatile-autoreg-vaf` | [vaf](https://github.com/GabrielNavi/vaf) ← *this* | Server federation (beta) |
| `versatile-autoreg-vat` | [vat](https://github.com/GabrielNavi/vat) | Inventory Transformer (experimental) |

**Typical deployment** — three-level hierarchy:

```
VAS centre ◄── VAF school-A  ──► VAS school-A  ◄── VAC workstation01
                                                ◄── VAC workstation02
           ◄── VAF school-B  ──► VAS school-B  ◄── VAC ...
```

---

## Quick Start

```bash
# Install
sudo dpkg -i versatile-autoreg-vaf_*.deb
sudo apt-get -f install

# Configure — minimum required
sudo nano /etc/vaf/vaf.conf
# KEY=school-a
# UPPER_VAS_HOST=10.0.0.1

# Start
sudo systemctl enable --now vaf

# Verify
journalctl -u vaf -f
```

> **Dependencies:** `bash`, `curl`, `jq`, `uuid-runtime`, `iproute2` · `netcat-openbsd` (recommended, for VAF-Aware)  
> `LOCAL_VAS_HOST` defaults to `http://127.0.0.1:8000` — VAS must be installed on the same host.  
> See [Installation](https://github.com/GabrielNavi/vaf/wiki/EN_Install) in the wiki for full instructions.

---

## Installed Files

| Path | Description |
|------|-------------|
| `/usr/bin/vaf` | Main federation daemon |
| `/usr/bin/vaf-register` | One-shot registration (for VAS local hooks) |
| `/usr/bin/vaf-sub` | Full VAF loop for sub-instances |
| `/usr/bin/vaf-sub-manager` | Sub-instance supervisor with fail counter |
| `/usr/bin/vaf-sub-instance` | CLI to create, list and delete sub-instances |
| `/usr/lib/vaf/vaf-common.sh` | Shared library: config, identity, extras, registration, federation |
| `/etc/vaf/vaf.conf` | Main configuration file |
| `/etc/vaf/vaf.conf.d/` | Config overlays in lexical order |
| `/etc/vaf/extras_imperative.d/` | Cyclic hook scripts for imperative extras |
| `/etc/vaf/extras_informative.d/` | Cyclic hook scripts for informative extras |
| `/etc/vaf/hooks_local.d/` | Scripts triggered when local VAS inventory changes |
| `/usr/share/vaf/vaf.conf.defaults` | Exhaustive variable reference (read-only) |
| `/usr/share/vaf/hooks.d/local-vaf-register` | Hook auto-installed in VAS on package install |
| `/lib/systemd/system/vaf.service` | systemd unit |
| `/lib/systemd/system/vaf-sub.service` | Sub-instance manager unit |

**Runtime state:**

| Path | Description |
|------|-------------|
| `/etc/vaf/vaf-id` | Persistent node UUID (generated once, mode 600) |
| `/var/lib/vaf/identity.json` | Own data as confirmed by upper VAS |
| `/var/lib/vaf/local_version` | Last local VAS version processed |
| `/var/lib/vaf/clients.json` | Last downloaded local inventory |
| `/var/lib/vaf/upper_version` | Last upper VAS version (`SYNC_UPPER=true`) |
| `/var/lib/vaf/upper_clients.json` | Upper VAS inventory (`SYNC_UPPER=true`) |

---

## Configuration

```ini
# /etc/vaf/vaf.conf  (full reference at /usr/share/vaf/vaf.conf.defaults)

KEY=school-a             # aggregation key — published as VAF_school-a in upper VAS
# LOCAL_VAS_HOST=http://127.0.0.1:8000   # auto-detected from /etc/vas/vas.conf
UPPER_VAS_HOST=10.0.0.1  # no scheme; :8000 added automatically
FILTER=active            # active | inactive | archived | all
CHECK_SECONDS=300        # local VAS polling + upper VAS update interval
# HEARTBEAT_SECONDS=60   # liveness heartbeat; empty = same as CHECK_SECONDS
SYNC_UPPER=false         # download upper VAS inventory to upper_clients.json
BUMP_LISTEN_PORT=0       # UDP push port (0 = disabled; requires netcat-openbsd)
LOG_LEVEL=normal         # no | normal | debug
PARALLEL_MODE=both       # both | only_parallel | only_main
```

`UPPER_VAS_HOST` accepts `10.0.0.1`, `10.0.0.1:9000` or `vas.example.org`. The scheme is extracted automatically with `[WARN]`.

Full guide: [Configuration](https://github.com/GabrielNavi/vaf/wiki/EN_Config)

---

## Operation Cycle

VAF runs two independent timers simultaneously:

```
Every CHECK_SECONDS  (or on UDP bump):
  collect_extras_imperative()
  GET /version (local VAS)
  Changed → GET /clients → build_vaf_extra()
            → [optional: VAT --direction upstream] normalize extras
            → POST /register (upper VAS) with VAF_<KEY>_clients
            → materialize_keys() → [optional: VAT --direction downstream]
            → dispatch_hooks_local()

Every HEARTBEAT_SECONDS:
  selfcheck vs identity.json
  Changed → POST /register (upper VAS) [full, COALESCE extras]
  No change → POST /heartbeat (upper VAS) [~50B, last_seen only]
```

The CHECK block acts as VAL (watches local VAS inventory changes and publishes upstream). The HB block acts as VAC (keeps the node alive in the upper VAS). A successful registration in either block resets the other timer.

VAT (Versatile Autoregistration Transformer) can normalize the inventory before sending upstream and filter the database replica before storing locally. See [VAT documentation](https://github.com/GabrielNavi/vat) for configuration.

More details: [Operation Flow](https://github.com/GabrielNavi/vaf/wiki/EN_Federation)

---

## Extras System

In addition to the auto-generated `VAF_<KEY>_clients` field, VAF supports the same extras system as VAC. Extra keys are included alongside the federation payload in the upper VAS registration.

```bash
# Cyclic hook: key = basename without extension
#!/bin/bash
# /etc/vaf/extras_imperative.d/load.sh
load=$(awk '{print $1}' /proc/loadavg)
echo "{\"load1\": \"${load}\"}"
```

Example inventory entry in upper VAS:
```json
{
  "hostname": "vaf-school-a",
  "extra_imperative": {
    "VAF_school-a": {"clients": [...]},
    "load":         {"load1": "0.42"},
    "updates":      {"pending": 3}
  }
}
```

More details: [Extras](https://github.com/GabrielNavi/vaf/wiki/EN_Extras)

---

## Push Notifications (VAF-Aware)

With `BUMP_LISTEN_PORT` set, VAF reacts to inventory changes in milliseconds instead of waiting up to `CHECK_SECONDS`. The `local-vaf-register` hook (auto-installed by postinst in VAS `hooks.d/`) triggers a one-shot registration on every `bump_version()`:

```
VAS local bump_version()
  └─ hooks.d/local-vaf-register
       → vaf-register → GET /clients → POST /register (upper VAS)
                                         ↑ milliseconds
```

Without VAF-Aware, the daemon detects the same change in the next CHECK cycle (up to `CHECK_SECONDS`).

More details: [VAF-Aware](https://github.com/GabrielNavi/vaf/wiki/EN_VAF-Aware)

---

## Parallelization

A single VAF node can register in multiple upper VAS servers with independent UUIDs and state per sub-instance:

```bash
vaf-sub-instance --create school-b-mirror --upper 10.0.1.5 --key school-a-mirror
vaf-sub-instance --list
# NAME             UPPER_VAS_HOST  KEY                    ENABLED  STATUS
# school-b-mirror  10.0.1.5:8000   school-a-mirror        yes      active
systemctl restart vaf   # with PARALLEL_MODE=both
```

Sub-instance UUID is derived as UUIDv5 (sha1, namespace=base-vaf-id, name=instance-name), ensuring stable identity across restarts.

`PARALLEL_MODE`: `both` (main + instances) · `only_parallel` (`exec vaf-sub-manager`) · `only_main`. The supervisor stops restarting an instance after 5 consecutive hard failures.

More details: [Sub-instances](https://github.com/GabrielNavi/vaf/wiki/EN_Sub-instances)

---

## Service Management

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

[Installation](https://github.com/GabrielNavi/vaf/wiki/EN_Install) · [Configuration](https://github.com/GabrielNavi/vaf/wiki/EN_Config) · [Operation](https://github.com/GabrielNavi/vaf/wiki/EN_Operation) · [Federation](https://github.com/GabrielNavi/vaf/wiki/EN_Federation) · [VAF-Aware](https://github.com/GabrielNavi/vaf/wiki/EN_VAF-Aware) · [Sub-instances](https://github.com/GabrielNavi/vaf/wiki/EN_Sub-instances) · [Logging](https://github.com/GabrielNavi/vaf/wiki/EN_Logging)

---

## License

[Apache License 2.0](LICENSE)
