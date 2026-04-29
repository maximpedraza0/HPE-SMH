# HPE Management for unRAID

unRAID 6.12+ plugin that installs and runs HPE ProLiant management tooling
on a Slackware host. Provides CLI utilities (ssacli, hponcfg, ssa…) and, on
supported generations, the Systems Management Homepage (SMH) web UI at
`https://<host>:2381`.

HPE ships these tools as RPMs targeting RHEL/CentOS. unRAID is Slackware, so
the plugin bootstraps `rpm` + `rpm2tgz`, downloads the right RPMs from the
HPE Software Delivery Repository, verifies them, converts them to `.tgz`,
and installs them with `installpkg` — no systemd, no foreign init system.
Services are run under a dedicated SysV-style wrapper.

---

## Stacks

The plugin supports three mutually exclusive modes, selected via `STACK` in
the config (or the Settings page):

| `STACK` | Source | What you get | Use when |
|---------|--------|--------------|----------|
| **`modern`** | HPE SDR MCP (CentOS 8) | `ssacli`, `hponcfg`, optionally `amsd` + friends (Tier 2 daemons) | You only need CLI — storage/iLO scripting, monitoring via SNMP |
| **`legacy`** | HPE SDR SPP 2022.03.0 (last that shipped SMH) | Everything in `modern` plus `hpsmh` + templates + `hp-health` + `hp-snmp-agents` + `hp-ams` → the 5-panel web UI on `:2381` | You want the web UI, running Gen8/9/10 hardware |
| **`disabled`** | — | Nothing installed, all services stopped | Plugin stays dormant — useful to diagnose interference |

`modern` and `legacy` can be swapped at runtime: the plugin uninstalls the
previous stack's packages and installs the new one on the next apply.

## Hardware support

SMH (legacy stack) bundles component plugins tied to specific generations.
When `SPP_LEGACY_VER=auto` the plugin picks the last SPP release that still
had matching component packages for the detected server generation:

| Generation | SPP version picked | Notes |
|------------|-------------------|-------|
| Gen8       | 2020.09.0         | Last SPP with full Gen8 Smart Array drivers |
| Gen9       | 2021.10.0         | |
| Gen10      | 2022.03.0         | Newest SPP that still ships SMH |
| Gen10+ / Gen11 | —             | Use `STACK=modern`; no SMH path |

Override with an explicit `YYYY.MM.N` in the config or Settings page if you
need a different SPP release.

## Package catalog

The plugin selects packages based on `STACK` + `EXTRAS` + `INSTALL_AMSD`.
Core roles:

| Package | Role | Stack |
|---------|------|-------|
| `ssacli` | Smart Array CLI | modern, legacy |
| `hponcfg` | iLO configuration from host | modern, legacy |
| `amsd` family (`smad`, `ahslog`, `cpqFca`, …) | Tier 2 monitoring daemons | modern (opt-in) |
| `hpsmh`, `hp-smh-templates` | The SMH web UI itself | legacy |
| `hp-health` | Core health daemon (CMA thresholds, ASR, …) | legacy |
| `hp-snmp-agents` | Bridge daemons exposing HW state to `snmpd` | legacy |
| `hp-ams` | Agentless management service | legacy |
| `ssa` + `hpessad` | Smart Storage Admin UI (browser component) + IPC backend | legacy |

Optional `EXTRAS` (space-separated in config): `ssaducli storcli hponcfg
fibreutils sut sum ilorest hpe-emulex-smartsan-enablement-kit
hpe-qlogic-smartsan-enablement-kit mft hp-ocsbbd hp-tg3sd`. Of those, the
ones with persistent daemons (`sut`, `mft`, `hp-ocsbbd`, `hp-tg3sd`) should
also be listed in `BOOT_EXTRAS` to start on boot.

## Key paths

| Path | What lives there |
|------|------------------|
| `/opt/hp/hpsmh` | SMH web root, CGI scripts, configs (from `hp-smh-templates`) |
| `/opt/hp/hpsmh/webapp-data` | Per-session state written by the hpsmh Apache fork — **must be owned uid 881** (see FAQ) |
| `/opt/compaq` | Legacy `cma*` binaries and snmp agent bridges, kept for SMH plugin discovery |
| `/etc/init.d/` | Vendor init scripts (`hpsmhd`, `hp-health`, `hpessad`, …) — invoked via `rc.hpe-mgmt` |
| `/boot/config/plugins/hpe-mgmt/` | Persistent: config file, downloaded RPM cache, install state stamps |
| `/boot/config/plugins/hpe-mgmt/packages/` | RPM cache. Survives reboots so re-apply is offline-capable after first run |
| `/usr/local/emhttp/plugins/hpe-mgmt/` | Plugin tree at runtime — overwritten on each plg install |

## Trust chain

Downloads are verified at two levels:

1. **Metadata signature**: `repomd.xml` of each HPE SDR repo is signed with
   one of two HPE software-signing keys (shipped in
   `source/keys/hpe-signing.pub` — the 2015 key, used by most repos — and
   `source/keys/hpe-signing-key2.pub` — the 2024 key, used by the SUM repo
   and others HPE rotates onto). The plugin imports both into a sandboxed
   keyring and verifies `repomd.xml.asc` against it before reading any
   package indexes.
2. **Per-RPM checksum**: each RPM's SHA1 in the repo metadata is compared
   to the downloaded file. Mismatches abort install.

Set `VERIFY_GPG=0` only for debugging offline caches; production installs
should leave it at the default `1`.

AlmaLinux's signing key (`source/keys/almalinux-signing.pub`) is also
bundled because `rpm` / `popt` bootstrap pulls from Alma mirrors when the
host lacks them.

## Installation

Install the plugin like any other via Community Applications, or directly:

```
Plugins → Install Plugin →
https://github.com/mpedraza/HPE-SMH/raw/main/hpe-mgmt.plg
```

First install downloads the plugin tree tarball to `/boot/config/plugins/`,
unpacks it under `/usr/local/emhttp/plugins/hpe-mgmt/`, and runs
`scripts/install.sh`. That in turn:

1. Runs the iLO hook to make sure `/dev/hpilo` is present.
2. Bootstraps `rpm` / `rpm2cpio` / `rpm2tgz` if missing (from AlmaLinux).
3. Calls `scripts/fetch-hpe.sh`, which downloads + verifies + converts +
   installs the selected HPE RPMs.
4. Starts the services via `rc.hpe-mgmt start`.

On every subsequent boot, unRAID re-runs `install.sh`, which is idempotent:
already-installed packages are skipped, and only the services come up.

## Configuration

The Settings page (`Settings → hpe-mgmt`) edits
`/boot/config/plugins/hpe-mgmt/hpe-mgmt.cfg`. Relevant keys:

- `STACK` — `modern` | `legacy` | `disabled`
- `EXTRAS`, `BOOT_EXTRAS` — opt-in packages (see catalog)
- `INSTALL_AMSD` — `0` by default; Tier 2 daemons need extra libs not in
  stock unRAID. Flip on only after adding the compat-libs bundle.
- `MCP_DIST`, `MCP_VER` — override repo selection (default `CentOS` / `8`)
- `SPP_LEGACY_VER` — `auto` (generation-aware) or explicit `YYYY.MM.N`
- `VERIFY_GPG` — leave at `1` for production
- `ENABLE_SNMP_REV` — start the `*_rev` variants that bridge to `snmpd`

Changes take effect on the next `rc.hpe-mgmt restart` (or reboot).

### Config drop-ins (snmpd)

unRAID wipes `/etc` on every boot, so hand-edits to `/etc/snmp/snmpd.conf`
do not survive. The plugin keeps an immutable snapshot of the conf it
generated on first install at:

```
/boot/config/plugins/hpe-mgmt/snmpd.conf.base
```

…and on every `rc.hpe-mgmt start` (boot + restart) concatenates any files
placed in:

```
/boot/config/plugins/hpe-mgmt/snmpd.d/*.conf
```

…into `/etc/snmp/snmpd.conf`, then `HUP`s `snmpd` if the result changed.

Use it for site-specific tweaks that should outlive plugin
reinstalls/updates. Example — expose SNMP to a LibreNMS collector on
another host and tag the server:

```
# /boot/config/plugins/hpe-mgmt/snmpd.d/10-librenms.conf
sysLocation    Home rack
sysContact     admin@example.com
view   lnms   included  .1
rocommunity  mycommunity  192.168.27.0/24  -V lnms
rocommunity  mycommunity  172.16.0.0/12    -V lnms
```

Files are concatenated in alphabetical order (same convention as systemd
drop-ins). If you need to regenerate the base (e.g. after a manual
`hpsnmpconfig` run), delete `snmpd.conf.base` and reinstall the plugin.

### Vendor-config overrides

For everything else — vendor configs that the RPM installs into `/etc`
or `/opt/hp` and rewrites on every boot — use the override tree:

```
/boot/config/plugins/hpe-mgmt/overrides/<absolute-path>
```

On every `rc.hpe-mgmt start` the plugin walks `overrides/`, symlinks
each file over its matching system path, and stashes the vendor original
at `<path>.hpe-mgmt-orig` the first time. Edits in USB take effect
immediately — no reboot needed if you `kill -HUP` or restart the
relevant daemon.

Useful targets (Tier B configs the RPMs regenerate at install):

| Path | Package | What it controls |
|---|---|---|
| `/etc/sysconfig/hp-ams` | hp-ams | hp-ams daemon `OPTIONS` |
| `/etc/sysconfig/snmpd` | net-snmp | snmpd command-line `OPTIONS` |
| `/etc/snmp/snmptrapd.conf` | net-snmp | trap receiver |
| `/etc/hp-snmp-agents.conf` | hp-snmp-agents | top-level cma\* tunables |
| `/opt/hp/hp-snmp-agents/cma.conf` | hp-snmp-agents | which sub-agents to enable |
| `/opt/hp/hp-snmp-agents/server/etc/cma{healthd,perfd,…}` | hp-snmp-agents | per-sub-agent env vars |
| `/opt/hp/hpsmh/conf/smhpd.xml` | hpsmh | SMH admin/operator/user groups, anonymous-access, trustmode |
| `/opt/hp/hpsmh/conf/timeout.conf` | hpsmh | SMH session timeouts |
| `/opt/hp/hpsmh/conf/userlists.txt` | hpsmh | local user lists |
| `/opt/hp/hpsmh/conf/extra/httpd-*.conf` | hpsmh | Apache tweaks (cipher list, listen ports) |

Example — restrict the SMH web UI to a single admin group:

```
mkdir -p /boot/config/plugins/hpe-mgmt/overrides/opt/hp/hpsmh/conf
cp /opt/hp/hpsmh/conf/smhpd.xml \
   /boot/config/plugins/hpe-mgmt/overrides/opt/hp/hpsmh/conf/smhpd.xml
# edit the copy
/etc/rc.d/rc.hpe-mgmt restart
```

To roll back an override: remove the file from `overrides/`, rename the
`.hpe-mgmt-orig` backup back into place, and restart.

`overrides/` and `snmpd.d/` are complementary. Use `snmpd.d/` for
**adding** lines to `/etc/snmp/snmpd.conf` (concat semantics); use
`overrides/` to **replace** any other vendor config wholesale.

Two known limits of the override system:

1. **Executable scripts/binaries cannot live in `overrides/`.** The
   unRAID flash is mounted VFAT with `fmask=0177`, so anything under
   `/boot/` always reads back as non-executable. A script symlinked
   from there will never run. If you need to swap an executable
   (init.d unit, helper binary, log filter…), do it from `install.sh`
   in the plugin tree — that path lives on tmpfs with normal POSIX
   perms.
2. **Files regenerated by a vendor binary at every restart cannot be
   overridden via symlink.** `smhpd.conf`, in particular, is rewritten
   from a baked-in template inside `smhstart` whenever the daemon
   starts; a symlink there gets clobbered through. Tools that work on
   the *generated* output (e.g. wrapping `rotatelogs` to filter the
   `ErrorLog` stream) are the way around it.

## Service management

Everything runs under `/etc/rc.d/rc.hpe-mgmt`:

```
rc.hpe-mgmt start     # start everything STACK + BOOT_EXTRAS enables
rc.hpe-mgmt stop      # stop in reverse order (hpsmhd first on legacy)
rc.hpe-mgmt restart
rc.hpe-mgmt status    # per-daemon state
```

Each daemon is either a `bin` (tracked by pidfile) or an `init` (delegated
to the vendor SysV script). Startup order matters on the legacy stack:
SMH enumerates component plugins at boot, so all `cma*` / `hpessad` / `ssa`
backends must be up before `hpsmhd` starts — the service table enforces
this by placing `hpsmhd` last.

## FAQ

**Why uid 881?**
hpsmh's Apache fork runs under `uid 881` on RHEL/CentOS. The bundled
`webapp-data/` directory (session storage) is created owned by that uid
inside the RPM, and the daemon refuses to write if it sees a different
owner. `install.sh` creates `user 881` (name `hpsmh`) locally and
chown-fixes the tree after every install.

**Why not systemd?**
unRAID has no systemd. The plugin reads each vendor unit file, extracts
the `ExecStart` binary + arguments + `EnvironmentFile`, and reimplements
the lifecycle in `rc.hpe-mgmt`. Vendor init scripts that already support
SysV (`start/stop/status`) are delegated to as-is (`kind=init`).

**Why copy-no-symlink for `hpssa.xml`?**
The SMH plugin loader reads its component XML list by scanning a physical
directory. Symlinks don't appear in the enumeration under some builds, so
install.sh copies `hpssa.xml` into `/opt/hp/hpsmh/webapp/compaq/hpssa/` as
a real file rather than symlinking from the package install path.

**Where do logs go?**
`rc.hpe-mgmt` redirects `bin` daemons to `/var/log/hpe-mgmt/<name>.log`.
Vendor init scripts write to their own locations (hpsmhd:
`/var/log/hpsmh/`; hp-health: `/var/log/cma/`). SMH's HTTPS access log is
under `/var/log/hpsmh/access_log`.

## Uninstall

```
Plugins → Installed Plugins → hpe-mgmt → Remove
```

Calls `scripts/remove.sh`, which stops services, uninstalls the HPE packages
with `removepkg`, and leaves the config + RPM cache under
`/boot/config/plugins/hpe-mgmt/` so reinstall is fast. Delete that folder
manually if you want a fully clean slate.

## Contributing

After cloning, install the repo's git hooks once:

```
scripts/install-hooks.sh
```

This symlinks `scripts/hooks/pre-push` into `.git/hooks/`, which validates
`hpe-mgmt.plg` as XML before each push. unRAID's plugin manager rejects a
malformed `.plg` and quarantines it under `/boot/config/plugins-error/`, so
the hook catches the most common foot-gun (raw `<angle-bracket>` text in
the `CHANGES` block) before it reaches main.

## Support

- Issues: https://github.com/mpedraza/HPE-SMH/issues
- Tested on: ML110 Gen9, DL360 Gen10 under unRAID 6.12 / 7.x
