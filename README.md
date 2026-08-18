# luci-app-vpnswitch

LuCI page for switching between VPN tunnels on OpenWRT.  
Supports **AmneziaWG 2.0** tunnels and **VLESS+Reality via sing-box**.  
Shows live status (up/down, last handshake, transfer stats) and switches the active tunnel with one click.

## Features

- One card per AWG2 interface — endpoint, handshake age, transfer stats, Switch button
- Optional VLESS (sing-box) card — appears automatically if `sing-box` is installed
- **Multiple VLESS configs**: stored as separate profiles under `/etc/sing-box/profiles/`,
  switched by repointing the `/etc/sing-box/config.json` symlink — add, activate, or
  delete profiles without touching the ones you're not using
- **Add a VLESS config from a `vless://` link** directly in the UI — paste the link
  exported by your VPN provider, no shell access needed
- The VLESS card shows the *actual* active profile's server, port, security (reality/tls),
  SNI and transport — read live from the profile file, not hardcoded
- Live updates every 5 seconds without page reload
- Switching to AWG: stops sing-box, enables the target interface, restarts network
- Switching to VLESS: disables all AWG interfaces, starts sing-box (using whichever
  VLESS profile is currently active)
- Safe on routers without sing-box — VLESS card simply doesn't appear

## Requirements

- OpenWRT 24.10.5 or later
- At least one `amneziawg` interface configured in `/etc/config/network`
- LuCI installed (`luci-base`)
- One `lan → <vpn-zone>` forwarding rule in firewall

**Optional (for VLESS card):**
- `sing-box` installed (`opkg install sing-box`)
- `/etc/sing-box/config.json` configured
- A firewall zone named `vless` with `masq=1` and a `network=vless` interface pointing to `tun-sb`

## File layout

```
luci-app-vpnswitch/
├── htdocs/luci-static/resources/view/vpnswitch/
│   └── dashboard.js                        # LuCI frontend (JavaScript)
└── root/
    ├── etc/uci-defaults/
    │   └── 80_vpnswitch                    # Post-install: restarts rpcd
    └── usr/share/
        ├── luci/menu.d/
        │   └── luci-app-vpnswitch.json     # Registers Services → VPN Switch
        ├── rpcd/acl.d/
        │   └── luci-app-vpnswitch.json     # ACL: grants network/firewall read+write
        └── rpcd/ucode/
            └── vpnswitch.uc               # RPC backend (ucode)
```

## Installation

```sh
ROUTER=root@192.168.10.1
BASE=/path/to/luci-app-vpnswitch

ssh $ROUTER "mkdir -p /usr/share/rpcd/ucode /usr/share/rpcd/acl.d \
  /usr/share/luci/menu.d /www/luci-static/resources/view/vpnswitch"

ssh $ROUTER "cat > /usr/share/rpcd/ucode/vpnswitch.uc" \
    < $BASE/root/usr/share/rpcd/ucode/vpnswitch.uc

ssh $ROUTER "cat > /usr/share/rpcd/acl.d/luci-app-vpnswitch.json" \
    < $BASE/root/usr/share/rpcd/acl.d/luci-app-vpnswitch.json

ssh $ROUTER "cat > /usr/share/luci/menu.d/luci-app-vpnswitch.json" \
    < $BASE/root/usr/share/luci/menu.d/luci-app-vpnswitch.json

ssh $ROUTER "cat > /www/luci-static/resources/view/vpnswitch/dashboard.js" \
    < $BASE/htdocs/luci-static/resources/view/vpnswitch/dashboard.js

ssh $ROUTER "/etc/init.d/rpcd restart"
```

Open LuCI → **Services → VPN Switch**.  
If the menu item is missing, do a hard refresh (Ctrl+F5).

## Firewall setup (AWG)

Each AWG interface needs its own firewall zone. There must be exactly one `lan → <zone>` forwarding rule — the app reads and updates it.

```
config zone
    option name 'keyubu'
    list network 'keyubu'
    option input 'REJECT'
    option output 'ACCEPT'
    option forward 'REJECT'
    option masq '1'

config forwarding
    option src 'lan'
    option dest 'keyubu'
```

## VLESS profiles (multiple configs)

`/etc/sing-box/config.json` is a symlink into `/etc/sing-box/profiles/<name>.json` —
each profile is a complete, self-contained sing-box config (same shape as the
original single-file setup, just with its own server/keys/transport). Activating a
profile means repointing the symlink and restarting sing-box if it's already running.

- On first use after upgrading, an existing plain `config.json` is migrated
  automatically into `profiles/<name>.json` (name derived from the TLS SNI) and
  replaced with a symlink — no manual step required, and the running sing-box
  process is not restarted by the migration itself.
- Adding a profile via the UI ("+ Add VLESS config") parses a `vless://` link and
  writes a new profile file with the same fixed inbound/route/dns template as
  every other profile (see `build_singbox_config` in `vpnswitch.uc`), substituting
  only the outbound (server, uuid, tls/reality, transport). `bind_interface` is read
  from `network.wan.device` at add-time, not hardcoded.
- The routing-loop-prevention rule (`ip_cidr: [server/32] -> direct`, see NOTES.md)
  is generated per-profile automatically, pointed at that profile's own server IP.
- Supported `vless://` query params: `security` (`reality`/`tls`/`none`), `type`
  (`tcp`/`grpc`/`ws`/`http`), `sni`, `fp`, `pbk`, `sid`, `flow`, `alpn`, `serviceName`
  (grpc), `path`/`host` (ws/http). Unknown params are ignored.
- A profile can't be deleted while it's the active one — switch away first.

## Firewall setup (VLESS / sing-box)

See `../vless.txt` for the full sing-box setup. The key UCI pieces:

```sh
# Firewall zone — no UCI network interface needed; fw4 uses device='tun-sb' directly
uci add firewall zone
uci set firewall.@zone[-1].name='vless'
uci set firewall.@zone[-1].device='tun-sb'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci set firewall.@zone[-1].masq='1'
uci commit firewall
```

The forwarding `lan → vless` is set automatically when you click "Switch to VLESS".

## Switching behaviour

| Action | What happens |
|--------|-------------|
| Switch to AWG tunnel | sing-box stopped → target AWG enabled, others disabled → network+firewall restarted |
| Switch to VLESS | all AWG disabled → firewall restarted → sing-box started |
| sing-box not installed | VLESS card hidden, switching to `vless` returns error |

After switching, the page reloads automatically after ~4 seconds.

## Removal

```sh
ROUTER=root@192.168.10.1

ssh $ROUTER "
  rm /usr/share/rpcd/ucode/vpnswitch.uc
  rm /usr/share/rpcd/acl.d/luci-app-vpnswitch.json
  rm /usr/share/luci/menu.d/luci-app-vpnswitch.json
  rm -rf /www/luci-static/resources/view/vpnswitch
  /etc/init.d/rpcd restart
"
```

## Updating a single file

```sh
# Frontend JS — no restart needed
ssh root@192.168.10.1 "cat > /www/luci-static/resources/view/vpnswitch/dashboard.js" \
    < htdocs/luci-static/resources/view/vpnswitch/dashboard.js

# Backend ucode — requires rpcd restart
ssh root@192.168.10.1 "cat > /usr/share/rpcd/ucode/vpnswitch.uc" \
    < root/usr/share/rpcd/ucode/vpnswitch.uc
ssh root@192.168.10.1 "/etc/init.d/rpcd restart"
```
