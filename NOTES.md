# Developer notes — luci-app-vpnswitch

## Architecture

Modern LuCI apps (OpenWRT 23+) use this stack instead of Lua/CGI:

```
Browser (JS)
  └─ rpc.declare() calls → HTTP /ubus
       └─ rpcd (daemon)
            └─ ucode plugin  /usr/share/rpcd/ucode/vpnswitch.uc
                 ├─ reads UCI  (network, firewall)
                 └─ runs shell commands (ip link, awg show)
```

- **rpcd** loads every `.uc` file in `/usr/share/rpcd/ucode/` at startup.
  A restart is required after adding or changing backend files.
- **ACL** (`/usr/share/rpcd/acl.d/luci-app-vpnswitch.json`) controls which ubus methods
  and UCI configs the logged-in user may access. Without it, all RPC calls return permission errors.
- **Menu** (`/usr/share/luci/menu.d/luci-app-vpnswitch.json`) registers the entry under
  `admin/services/vpnswitch`. The `depends.acl` field makes the item invisible to users who
  don't have the ACL group.
- **Frontend** lives in `/www/luci-static/resources/view/<path>/dashboard.js`.
  LuCI loads it lazily; no restart needed after editing JS.

## What each file does

| File | Role |
|------|------|
| `vpnswitch.uc` | Exposes two ubus methods: `get_status` (read-only) and `switch_vpn` (write). Reads UCI network + firewall, runs `ip link show` and `awg show` for live stats. |
| `dashboard.js` | LuCI view. Calls `get_status` on load, renders one card per AWG interface, polls every 5 s and updates DOM in-place (no full re-render). Switch button calls `switch_vpn` then reloads after 4 s. |
| `luci-app-vpnswitch.json` (menu) | One JSON object: path → title + view path + ACL guard. |
| `luci-app-vpnswitch.json` (ACL) | Grants `read` on ubus methods and UCI configs; `write` on UCI configs. Both read and write are needed because rpcd checks access for every `uci.set` the plugin performs on behalf of the web user. |
| `80_vpnswitch` | uci-defaults script — runs once after package install (or on first boot). Just restarts rpcd so it picks up the new plugin. |

## ucode gotchas

ucode is a minimal scripting language — it is NOT standard ECMAScript.

- **No `for...of`** — use `for (let i = 0; i < length(arr); i++)`.
- **No `?.` optional chaining** — use `obj ? obj.prop : null`.
- **`trim()` is a global** — works as `trim(str)`, not `str.trim()`.
- **Regex character classes are limited** — `\d` and `\w` may not match as expected.
  Use explicit ranges: `[0-9]`, `[A-Za-z]`, `[A-Za-z0-9]`.
- **`popen()` returns a file handle** — call `.read('all')` on it to get the string.
  Wrap in `trim(popen(cmd)?.read?.('all'))` to safely handle command-not-found (returns null).
- **`uci.load()` / `uci.unload()` must be paired** — forgetting `unload()` causes stale reads
  on the second call within the same request.
- **`uci.get_all('network', '@amneziawg_IFACE[0]')`** — UCI anonymous section syntax for
  the first peer of a given interface. Returns `null` if no peer is configured.

After ~4 s the browser reloads and shows the new active interface.

## How status polling works

`poll.add(fn, 5)` registers a function that fires every 5 seconds.  
The function calls `get_status()` (RPC) and for each interface updates six DOM elements by ID:
`up_NAME`, `hs_NAME`, `tr_NAME`, `badge_NAME`, `card_NAME`, `btn_NAME`.  
Full page re-render is avoided to prevent flicker and losing the "Switching…" button state.

## AWG2-specific notes

- Interface proto in UCI: `amneziawg` (not `wireguard`).
- Live stats come from `awg show all dump` — tab-separated, machine-readable, same approach
  as the official `luci.amneziawg` backend. Fields per peer line:
  `[0]=device [1]=pubkey [2]=psk [3]=endpoint [4]=allowed_ips [5]=handshake_unix_ts [6]=rx_bytes [7]=tx_bytes [8]=keepalive`
- Device header line (first line per device) has many more fields and is skipped via a `seen{}` map.
- `awg show` requires the `amneziawg-tools` package (or equivalent).
- A disabled interface (UCI `disabled=1`) does not appear in the dump at all. `is_up=false` for it.
  The endpoint is still shown by falling back to the UCI peer config (`@amneziawg_<iface>[0]`).
- Transfer values are returned as raw bytes from the dump. The frontend formats them via `fmtBytes()`.
- Handshake is returned as a Unix timestamp. The frontend formats it via `fmtHandshake()`.
  This means the displayed age updates every poll cycle without re-fetching from the kernel.

## How switch_vpn works

1. Load `network` config.
2. For every AWG interface: set `disabled=1`, except the target → delete `disabled` (absence = enabled).
3. `uci.save()` + `uci.commit('network')` — stages then writes to `/etc/config/network`.
4. Load `firewall` config.
5. Find the `forwarding` section where `src=lan`, set its `dest` to the target zone name.
6. `uci.save()` + `uci.commit('firewall')`.
7. `popen()` restarts firewall and network in background (both fire-and-forget).

`uci.commit()` replaces the previous `command('uci commit ...')` shell call — no subprocess needed.

## sing-box routing loop — root cause and fix

sing-box `auto_route: true` moves the default route from the main routing table into its own
table 2022. sing-box `auto_redirect: true` adds an nftables output chain rule that redirects
all TCP to a transparent proxy port. Together these create a loop: sing-box's own connection
to the VLESS server hits the nftables redirect → goes to transparent proxy → tries to connect
to server again → loop → "no route to internet".

**Why it worked after reboot but not after AWG→VLESS switch:** AWG peer config with
`route_allowed_ips=1` added a `/32` host route for the AWG server IP to the main table. This
host route survived sing-box moving the default. After AWG was stopped and sing-box started,
there was no such host route and the server IP fell through to table 2022 → tun → loop.

**The fix (in sing-box config.json):**
1. `bind_interface: "eth0"` on both outbounds — binds sing-box sockets to WAN via
   `SO_BINDTODEVICE`, bypassing nftables redirect and routing tables entirely.
2. `route_exclude_address: ["SERVER_IP/32", ...]` on tun inbound — removes server IP from
   routing table 2022 (defence in depth).
3. Route rule `ip_cidr: [SERVER_IP/32] → direct` — sing-box application routing also sends
   server traffic through the direct outbound (which also has `bind_interface`).
4. **No `auto_detect_interface`** — conflicts with explicit `bind_interface`, causes
   "missing default interface" error.

**Why `auto_detect_interface: true` alone is not enough (even though it's in the docs):**
On OpenWRT with fwmark-based routing rules, the interface detection picks up the wrong
interface or fails. The explicit `bind_interface` is required.

**Why NOT to add `network.vless` UCI interface:** If netifd manages tun-sb, it removes the
WAN default route from the main table when it brings up the vless interface — leaving no
path for sing-box to reach its server before it sets up its own rules.

## VLESS multi-profile storage

- `/etc/sing-box/config.json` is a symlink into `/etc/sing-box/profiles/<name>.json`.
  Each profile file is a *complete* sing-box config (log/inbounds/outbounds/route/dns),
  not just an outbound fragment — keeps `switch_vless_profile` a single `unlink`+`symlink`
  with no JSON merging.
- `migrate_legacy_config()` runs at the top of `get_vless_profiles()` (called from
  `get_status` and `add_vless_profile`), so it's idempotent and needs no separate
  install step. It only acts when `config.json` is a plain file (`lstat().type != 'link'`);
  once migrated it's a no-op forever after.
- Profile name → filename mapping is `profiles/<name>.json`; `active_profile_name()`
  derives the active name by `readlink()` + stripping the directory and `.json` suffix.
- `add_vless_profile` only auto-activates the new profile (creates the symlink) if
  `config.json` doesn't exist yet at all — i.e. only for the very first profile on a
  fresh sing-box install. Otherwise adding never disturbs the currently active profile.

## ucode gotchas (part 2 — discovered while building VLESS profile support)

- **`typeof` is an operator, not a function.** `typeof(x)` parses as calling the
  result of `typeof x` — always throws "left-hand side is not a function". Write
  `(typeof x)` or `typeof x` directly.
- **A `.uc` file's top-level `return { ... }` only works when the file is the rpcd
  entry point (or run directly via `ucode file.uc`).** It does NOT work as a target
  of ucode's own `import`/`include()` — `import` demands `export` statements, and
  `include()` silently discards a bare top-level `return`. There is no script-level
  way to unit-test a rpcd `.uc` module's internals via `import`/`include`; the
  practical workaround used during development was a `getenv('SOME_FLAG')`-gated
  self-test block inserted just above the final `return`, printing results directly
  — then deleted before deploying.
- **`fs` module functions must be destructured by name** (`import { open, symlink,
  glob, lstat, readlink, unlink, mkdir } from 'fs'`) — `import * as fs from 'fs'`
  does not expose them as `fs.open()` etc. in this ucode build.
- **No `readfile`/`writefile` convenience functions** — use `open(path, 'r'|'w')`
  then `.read('all')` / `.write(data)` then `.close()`.
- **`lstat(path)` returns `null` for a missing path**, otherwise an object with a
  `type` field: `'file'`, `'directory'`, or `'link'` (symlinks are *not* followed,
  unlike `stat()`).
- **`json(str)`** (global function) parses a JSON string; **`sprintf('%J', value)`**
  serializes a value back to JSON (with spacing — fine for sing-box, not
  byte-for-byte identical to hand-written configs).
- **No `urldecode()` builtin** — needed one for parsing `vless://` query strings;
  implemented manually with `substr()` + `int(hex, 16)` + `chr()` (see `urldecode()`
  in `vpnswitch.uc`). `int(str, base)` takes an explicit base — `int("1A", 16)` → `26`.
- **`replace(subject, needle, repl)` is a single left-to-right pass, not recursive** —
  collapsing runs of a character (e.g. `--` → `-`) needs a `while (index(...) >= 0)` loop.

## LAN health checks (added 2026-08-25)

Two active probes exposed as `run_health_check` (call both, append to history)
and `get_health_history` (read the ring buffer). See README.md's "LAN health
page" section for what they check and why; this section is the *how*.

- **Cron calls ubus, not a second script.** A `.uc` file's helpers can't be
  shared via `import`/`include()` with the rpcd entry point (see the ucode
  gotchas above), so rather than duplicating `get_active_fwd()`,
  `get_vless_profiles()` etc. into a standalone cron script, the cron job is
  just `ubus call luci.vpnswitch run_health_check "{}"` — it reuses the
  already-running rpcd plugin instead of needing its own file at all. Local
  `ubus call` invocations (as root, via cron) aren't subject to the rpcd ACL
  — that only gates browser-originated `/ubus` HTTP calls.
- **The dest bypass mutates live nftables state, briefly.** sing-box's own
  `route_exclude_address` (server IP + private ranges) is implemented by
  itself as `ip daddr { ... } return` rules in `table inet sing-box`, chain
  `output` (locally-generated traffic) and `prerouting` (LAN-forwarded — same
  address set, confirmed identical live 2026-08-25, which is *why* an
  on-router check is representative of a LAN client's experience without any
  namespace/veth trickery). `check_dest()` inserts one more `ip daddr <resolved
  dest ip> return` rule into the `output` chain (tagged with a comment so it
  can be found and removed), runs the request, then deletes it — never
  touches sing-box's own config or restarts it. If the table doesn't exist
  (AWG active, or sing-box not running) the insert is skipped and the result
  is marked `bypassed: false` — callers must treat that as inconclusive, not
  as a real pass/fail, since an unbypassed request would just get redirected
  into the tunnel like anything else and test the VPS's reachability to dest
  instead of the router's.
- **No TLS-version pinning available.** `wget` on this firmware is
  `uclient-fetch`, whose `--ciphers` flag sets the cipher list, not the TLS
  version — there is no way to force TLS 1.3-only from the router the way
  `openssl s_client -tls1_3` does from a dev machine. A dest that has quietly
  fallen back to TLS 1.2 (see the `samokishevauto.bg` entry in
  `../vpn/hosts.txt`) would still show `dest.ok: true` here. The health page
  says so in its own copy; a real fix would need `openssl`/`ldopenssl`
  installed via opkg, or the check delegated to a machine that has it.
- **History format.** JSON-lines (one `sprintf('%J', entry)` object per line)
  in `/tmp/vpnswitch-health.jsonl`, capped at `HEALTH_MAX_ENTRIES` (200) by a
  read-all/slice/rewrite on every append — deliberately not append-mode I/O,
  since the file is tiny (≲50KB) and this sidesteps needing to confirm ucode's
  `fs.open(path, 'a')` support. Lives on tmpfs on purpose: recent health is
  useful, and avoiding writes to the ~65MB overlay flash on a 10-minute cadence
  matters more than surviving a reboot.

## Known limitations

- Firewall zone name must equal the UCI interface name (or device name for vless zone).
  If they differ, `switch_vpn` will update the forwarding dest but the zone won't match.
- If two `lan → *` forwarding rules exist, `get_active_fwd` returns the last one.
- Only the first peer (`@amneziawg_<iface>[0]`) is shown per interface.
