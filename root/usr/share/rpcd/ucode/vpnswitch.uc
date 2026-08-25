#!/usr/bin/env ucode
'use strict';

import { cursor } from 'uci';
import { popen, open, lstat, symlink, readlink, unlink, mkdir, rmdir, glob } from 'fs';

const SINGBOX_IFACE  = 'vless';
const SINGBOX_CONFIG = '/etc/sing-box/config.json';
const PROFILES_DIR   = '/etc/sing-box/profiles';

const HEALTH_LOG          = '/tmp/vpnswitch-health.jsonl';
const HEALTH_MAX_ENTRIES  = 200;   // ~33h at the 10-min cron interval below
const HEALTH_TIMEOUT      = 8;     // seconds, per wget attempt
const HEALTH_TEST_URL     = 'https://1.1.1.1/cdn-cgi/trace';

// Cron (every 10 min) and a manual "Run now" click can overlap — without
// this, two concurrent run_health_check_impl() calls can delete each
// other's in-flight nft exemption rule (one check's traffic gets pulled
// back into the tunnel mid-request) and/or race on append_health_entry()'s
// read-modify-write, silently losing an entry. mkdir() is atomic (fails
// with null if the dir exists) in this ucode build's fs module — open()
// has no exclusive-create mode, so a lockdir is the simplest primitive
// available. HEALTH_LOCK_STALE is well over one check's worst case
// (2 * HEALTH_TIMEOUT, ~16s) so a lock left behind by a killed rpcd/ucode
// process doesn't wedge future checks forever.
const HEALTH_LOCK_DIR     = '/tmp/vpnswitch-health.lock';
const HEALTH_LOCK_STALE   = 60;

// nftables coordinates of the exclusion mechanism sing-box's own auto_route
// installs for route_exclude_address (see NOTES.md "routing loop"). The
// `output` chain here is what redirects locally-generated TCP into tun-sb;
// `prerouting` does the identical thing for LAN-forwarded traffic using the
// same address set — confirmed live 2026-08-25, which is why a router-self
// health check is representative of what a LAN client would see. We reuse
// the same "ip daddr <x> return" pattern, scoped to one IP, to test a dest
// domain directly instead of through the tunnel, without touching sing-box's
// own config or restarting it.
const NFT_TABLE   = 'inet sing-box';
const NFT_CHAIN   = 'output';
const NFT_COMMENT = 'vpnswitch-healthcheck';

function get_awg_interfaces() {
	const uci = cursor();
	const ifaces = [];
	uci.load('network');
	uci.foreach('network', 'interface', function(s) {
		if (s.proto === 'amneziawg')
			push(ifaces, s['.name']);
	});
	uci.unload();
	return ifaces;
}

function get_active_fwd() {
	const uci = cursor();
	let active = null;
	uci.load('firewall');
	uci.foreach('firewall', 'forwarding', function(s) {
		if (s.src === 'lan')
			active = s.dest;
	});
	uci.unload();
	return active;
}

// UCI disabled=1 alone does not reliably tear down an amneziawg interface —
// netifd can leave the wg device up with a live handshake and, worse, a
// route_allowed_ips default route still installed (it replaces the WAN
// default route and is only restored by netifd's own teardown path, which
// `disabled=1` + a bare network restart does not always trigger). Explicit
// `ifdown` forces netifd's real teardown, removing the device and its routes.
function ifdown_iface(name) {
	const p = popen('ifdown ' + name + ' >/dev/null 2>&1');
	if (p) p.close();
}

function singbox_installed() {
	const out = trim(popen('ls /usr/bin/sing-box 2>/dev/null')?.read?.('all'));
	return (length(out) > 0);
}

function singbox_running() {
	const out = trim(popen('pgrep -f /usr/bin/sing-box 2>/dev/null')?.read?.('all'));
	return (length(out) > 0);
}

// Parse `awg show all dump` — tab-separated, machine-readable.
// Device header line (first occurrence of a device name) is skipped.
// Peer line fields: [0]=device [1]=pubkey [2]=psk [3]=endpoint
//                   [4]=allowed_ips [5]=handshake_unix_ts [6]=rx_bytes [7]=tx_bytes
function parse_dump() {
	const peers = {};
	const wg_dump = popen('awg show all dump 2>/dev/null');
	if (!wg_dump)
		return peers;

	let seen = {};
	for (let line = wg_dump.read('line'); length(line); line = wg_dump.read('line')) {
		const r = split(rtrim(line, '\n'), '\t');
		const dev = r[0];
		if (!seen[dev]) {
			seen[dev] = true;
			continue;
		}
		const ep  = r[3];
		const col = (ep && ep !== '(none)') ? rindex(ep, ':') : -1;
		peers[dev] = {
			endpoint_host: col >= 0 ? substr(ep, 0, col) : null,
			endpoint_port: col >= 0 ? substr(ep, col + 1) : null,
			handshake_ts:  int(r[5]),
			rx_bytes:      int(r[6]),
			tx_bytes:      int(r[7]),
		};
	}
	return peers;
}

/* ---------- filesystem helpers ---------- */

function read_file(path) {
	const f = open(path, 'r');
	if (!f) return null;
	const data = f.read('all');
	f.close();
	return data;
}

function write_file(path, data) {
	const f = open(path, 'w');
	if (!f) return false;
	f.write(data);
	f.close();
	return true;
}

function read_json_file(path) {
	const raw = read_file(path);
	if (!raw) return null;
	return json(raw);
}

/* ---------- name helpers ---------- */

function is_name_char(c) {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
	       (c >= '0' && c <= '9') || c == '_' || c == '-';
}

function is_valid_name(name) {
	if (!name || length(name) > 40)
		return false;
	for (let i = 0; i < length(name); i++)
		if (!is_name_char(substr(name, i, 1)))
			return false;
	return true;
}

function sanitize_name(s) {
	let out = '';
	for (let i = 0; i < length(s); i++)
		out += is_name_char(substr(s, i, 1)) ? substr(s, i, 1) : '-';
	while (index(out, '--') >= 0)
		out = replace(out, '--', '-');
	while (length(out) && substr(out, 0, 1) == '-')
		out = substr(out, 1);
	while (length(out) && substr(out, length(out) - 1, 1) == '-')
		out = substr(out, 0, length(out) - 1);
	return length(out) ? out : 'profile';
}

function profile_path(name) {
	return PROFILES_DIR + '/' + name + '.json';
}

/* ---------- vless profile storage ----------
 * /etc/sing-box/config.json is a symlink into /etc/sing-box/profiles/<name>.json.
 * Switching the active VLESS server = repointing the symlink + restarting sing-box.
 */

function ensure_profiles_dir() {
	if (!lstat(PROFILES_DIR))
		mkdir(PROFILES_DIR);
}

// One-time migration: if config.json is still a plain file (pre-multi-profile
// setup), move its content into profiles/<name>.json and replace it with a
// symlink. Safe to call on every request — no-ops once migrated.
function migrate_legacy_config() {
	ensure_profiles_dir();

	const st = lstat(SINGBOX_CONFIG);
	if (!st || st.type == 'link')
		return;

	const raw = read_file(SINGBOX_CONFIG);
	const cfg = raw ? json(raw) : null;
	if (!cfg)
		return;

	let name = 'default';
	const outs = cfg.outbounds || [];
	for (let i = 0; i < length(outs); i++) {
		if (outs[i].type == 'vless') {
			if (outs[i].tls && outs[i].tls.server_name)
				name = sanitize_name(outs[i].tls.server_name);
			else if (outs[i].server)
				name = sanitize_name(outs[i].server);
			break;
		}
	}

	let candidate = name;
	let n = 2;
	while (lstat(profile_path(candidate))) {
		candidate = name + '-' + n;
		n++;
	}

	if (!write_file(profile_path(candidate), raw))
		return;

	unlink(SINGBOX_CONFIG);
	symlink(profile_path(candidate), SINGBOX_CONFIG);
}

function active_profile_name() {
	const target = readlink(SINGBOX_CONFIG);
	if (!target)
		return null;
	const slash = rindex(target, '/');
	const base  = slash >= 0 ? substr(target, slash + 1) : target;
	return substr(base, 0, length(base) - 5); // strip ".json"
}

function summarize_vless(cfg, name, active) {
	const outs = cfg.outbounds || [];
	let out = null;
	for (let i = 0; i < length(outs); i++) {
		if (outs[i].type == 'vless') {
			out = outs[i];
			break;
		}
	}
	if (!out)
		return null;

	const tls      = out.tls || {};
	const reality  = tls.reality || {};
	const transport = out.transport || {};

	return {
		name:        name,
		server:      out.server,
		server_port: out.server_port,
		flow:        out.flow || null,
		security:    reality.enabled ? 'reality' : (tls.enabled ? 'tls' : 'none'),
		sni:         tls.server_name || null,
		fingerprint: (tls.utls && tls.utls.fingerprint) || null,
		network:     transport.type || 'tcp',
		is_active:   active,
	};
}

function get_vless_profiles() {
	ensure_profiles_dir();
	migrate_legacy_config();

	const active = active_profile_name();
	const files  = glob(PROFILES_DIR + '/*.json') || [];
	const list   = [];

	for (let i = 0; i < length(files); i++) {
		const path  = files[i];
		const slash = rindex(path, '/');
		const base  = substr(path, slash + 1);
		const name  = substr(base, 0, length(base) - 5);
		const cfg   = read_json_file(path);
		if (!cfg)
			continue;
		const summary = summarize_vless(cfg, name, name == active);
		if (summary)
			push(list, summary);
	}

	sort(list, function(a, b) {
		return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
	});

	return list;
}

/* ---------- vless:// URI parsing ---------- */

function urldecode(s) {
	let out = '';
	let i = 0;
	const n = length(s);
	while (i < n) {
		const c = substr(s, i, 1);
		if (c == '%' && i + 2 < n) {
			out += chr(int(substr(s, i + 1, 2), 16));
			i += 3;
		} else if (c == '+') {
			out += ' ';
			i += 1;
		} else {
			out += c;
			i += 1;
		}
	}
	return out;
}

function parse_qs(qs) {
	const params = {};
	if (!qs)
		return params;
	const pairs = split(qs, '&');
	for (let i = 0; i < length(pairs); i++) {
		if (!length(pairs[i]))
			continue;
		const eq = index(pairs[i], '=');
		const k  = urldecode(eq >= 0 ? substr(pairs[i], 0, eq) : pairs[i]);
		const v  = eq >= 0 ? urldecode(substr(pairs[i], eq + 1)) : '';
		if (length(k))
			params[k] = v;
	}
	return params;
}

// vless://<uuid>@<host>:<port>?<query>#<remark>
function parse_vless_uri(uri) {
	uri = trim(uri || '');
	if (substr(uri, 0, 8) != 'vless://')
		return null;

	let rest = substr(uri, 8);

	const hashIdx = index(rest, '#');
	if (hashIdx >= 0)
		rest = substr(rest, 0, hashIdx);

	let query = '';
	const qIdx = index(rest, '?');
	if (qIdx >= 0) {
		query = substr(rest, qIdx + 1);
		rest  = substr(rest, 0, qIdx);
	}

	const atIdx = index(rest, '@');
	if (atIdx < 0)
		return null;
	const uuid     = substr(rest, 0, atIdx);
	const hostport = substr(rest, atIdx + 1);

	const colonIdx = rindex(hostport, ':');
	if (colonIdx < 0)
		return null;
	const host = substr(hostport, 0, colonIdx);
	const port = int(substr(hostport, colonIdx + 1));

	if (!length(uuid) || !length(host) || !port)
		return null;

	return { uuid: uuid, host: host, port: port, params: parse_qs(query) };
}

function get_wan_device() {
	const uci = cursor();
	uci.load('network');
	const dev = uci.get('network', 'wan', 'device');
	uci.unload();
	return dev || 'eth1';
}

function build_vless_outbound(parsed) {
	const p         = parsed.params;
	const security  = p.security || 'none';
	const isReality = (security == 'reality');
	const isTls     = (security == 'tls' || isReality);
	const netType   = p.type || 'tcp';

	const out = {
		type:           'vless',
		tag:            'vless-out',
		server:         parsed.host,
		server_port:    parsed.port,
		uuid:           parsed.uuid,
		bind_interface: get_wan_device(),
	};

	if (length(p.flow))
		out.flow = p.flow;
	if (length(p.packetEncoding))
		out.packet_encoding = p.packetEncoding;

	if (isTls) {
		const tls = {
			enabled:     true,
			server_name: length(p.sni) ? p.sni : parsed.host,
		};
		if (length(p.alpn))
			tls.alpn = split(p.alpn, ',');
		if (length(p.fp))
			tls.utls = { enabled: true, fingerprint: p.fp };
		if (isReality) {
			tls.reality = {
				enabled:    true,
				public_key: p.pbk || '',
				short_id:   p.sid || '',
			};
		}
		out.tls = tls;
	}

	if (netType == 'grpc') {
		out.transport = { type: 'grpc', service_name: p.serviceName || '' };
	} else if (netType == 'ws') {
		const t = { type: 'ws', path: length(p.path) ? p.path : '/' };
		if (length(p.host))
			t.headers = { Host: p.host };
		out.transport = t;
	} else if (netType == 'http') {
		out.transport = {
			type: 'http',
			path: length(p.path) ? p.path : '/',
			host: length(p.host) ? [ p.host ] : [],
		};
	}

	return out;
}

// Fixed template (log/inbound/route/dns) shared by every profile — only the
// outbound (server, keys, transport) differs between VLESS configs. See
// NOTES.md "sing-box routing loop" for why bind_interface + the direct
// exclusion rule for the server IP are both required.
function build_singbox_config(vlessOut) {
	return {
		log: { level: 'warn', output: '/tmp/sing-box.log', timestamp: true },
		inbounds: [
			{
				type:           'tun',
				tag:            'tun-in',
				interface_name: 'tun-sb',
				address:        [ '172.19.0.1/30' ],
				mtu:            1400,
				stack:          'mixed',
				auto_route:     true,
				auto_redirect:  true,
				strict_route:   false,
				sniff:          true,
				route_exclude_address: [
					vlessOut.server + '/32',
					'192.168.0.0/16',
					'10.0.0.0/8',
					'172.16.0.0/12',
				],
			},
		],
		outbounds: [
			vlessOut,
			{ type: 'direct', tag: 'direct', bind_interface: vlessOut.bind_interface },
		],
		route: {
			rules: [
				{ protocol: 'dns', action: 'hijack-dns' },
				{ ip_cidr: [ vlessOut.server + '/32' ], outbound: 'direct' },
			],
			final: 'vless-out',
		},
		dns: {
			servers: [
				{ tag: 'remote', address: 'tls://8.8.8.8', detour: 'vless-out' },
			],
			final: 'remote',
		},
	};
}

/* ---------- LAN health checks ----------
 * Two active probes, run from the router itself (see the NFT_* comment above
 * for why that's representative of a LAN client):
 *   - check_internet(): does a real HTTPS request complete through whatever
 *     tunnel is currently active — the thing that actually broke on 2026-08-24
 *     while every "is the process alive" signal stayed green.
 *   - check_dest(): for an active VLESS+Reality profile only, tests the
 *     Reality camouflage `dest` domain directly, bypassing the tunnel via a
 *     temporary nft exemption. This is what would have caught the
 *     koba-auto.com failure (see hosts.txt) as "dest is down" instead of a
 *     multi-hour manual packet-capture investigation.
 * Results are appended to a small capped JSON-lines ring buffer in /tmp
 * (tmpfs — deliberately not persisted to flash) so the health page has
 * recent history even between page loads. A cron job (see
 * root/etc/uci-defaults/81_vpnswitch_health) calls run_health_check every
 * 10 minutes; the frontend's "Run now" button calls the same ubus method.
 */

function is_valid_hostname(s) {
	if (!s || !length(s) || length(s) > 253)
		return false;
	for (let i = 0; i < length(s); i++) {
		const c = substr(s, i, 1);
		const ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		           (c >= '0' && c <= '9') || c == '.' || c == '-';
		if (!ok)
			return false;
	}
	return true;
}

function looks_like_ipv4(s) {
	if (!s)
		return false;
	const parts = split(s, '.');
	if (length(parts) != 4)
		return false;
	for (let i = 0; i < 4; i++) {
		const p = parts[i];
		if (!length(p) || length(p) > 3)
			return false;
		for (let j = 0; j < length(p); j++) {
			const c = substr(p, j, 1);
			if (c < '0' || c > '9')
				return false;
		}
	}
	return true;
}

// nslookup's own answer lines look like "Address: 1.2.3.4" (no port); the
// resolver line at the top is "Address: 127.0.0.1:53" — the colon is what
// tells them apart.
function resolve_ipv4(domain) {
	if (!is_valid_hostname(domain))
		return null;
	const p = popen('nslookup ' + domain + ' 2>/dev/null');
	const out = p ? p.read('all') : null;
	if (p) p.close();
	if (!out)
		return null;

	const lines = split(out, '\n');
	for (let i = 0; i < length(lines); i++) {
		const l = trim(lines[i]);
		if (substr(l, 0, 8) != 'Address:')
			continue;
		const addr = trim(substr(l, 8));
		if (index(addr, ':') < 0 && looks_like_ipv4(addr))
			return addr;
	}
	return null;
}

function nft_table_ready() {
	const p = popen('nft list table ' + NFT_TABLE + ' 2>/dev/null');
	const out = p ? p.read('all') : null;
	if (p) p.close();
	return length(trim(out || '')) > 0;
}

// Returns the handle of our tagged exemption rule, or null if none is
// present. Shared by nft_exempt_cleanup() (delete it) and nft_exempt_add()
// (confirm the insert actually landed instead of trusting popen()'s exit
// silently — nft's own stderr is discarded, so a failed insert would
// otherwise look identical to a successful one).
function nft_exempt_handle() {
	const p = popen('nft -a list chain ' + NFT_TABLE + ' ' + NFT_CHAIN + ' 2>/dev/null');
	const out = p ? p.read('all') : null;
	if (p) p.close();
	if (!out)
		return null;

	const lines = split(out, '\n');
	for (let i = 0; i < length(lines); i++) {
		if (index(lines[i], NFT_COMMENT) < 0)
			continue;
		const hIdx = index(lines[i], '# handle ');
		if (hIdx < 0)
			continue;
		return trim(substr(lines[i], hIdx + length('# handle ')));
	}
	return null;
}

function nft_exempt_cleanup() {
	const handle = nft_exempt_handle();
	if (!handle)
		return;
	const d = popen('nft delete rule ' + NFT_TABLE + ' ' + NFT_CHAIN + ' handle ' + handle + ' 2>/dev/null');
	if (d) d.close();
}

// Returns false if the exemption couldn't be installed — either the
// sing-box nftables table isn't present (e.g. AWG is active, or sing-box
// just isn't running) or the insert itself didn't take (verified by
// re-reading the chain, not assumed from popen() succeeding). Callers must
// treat a check made without a successful exemption as inconclusive, not
// as a real "dest is reachable" result — without the bypass, the request
// would just get redirected into the tunnel like any other traffic and no
// longer tests dest independently of it.
function nft_exempt_add(ip) {
	if (!looks_like_ipv4(ip) || !nft_table_ready())
		return false;
	nft_exempt_cleanup();
	const p = popen('nft insert rule ' + NFT_TABLE + ' ' + NFT_CHAIN +
	                 ' ip daddr ' + ip + ' return comment "' + NFT_COMMENT + '" 2>/dev/null');
	if (p) p.close();
	return nft_exempt_handle() != null;
}

function wget_probe(url) {
	const t0 = time();
	const p = popen('wget -T ' + HEALTH_TIMEOUT + ' --no-check-certificate -O /dev/null ' + url + ' 2>&1');
	const out = p ? p.read('all') : '';
	if (p) p.close();
	return { out: out || '', elapsed_s: time() - t0 };
}

function check_internet() {
	const t0 = time();
	const p = popen('wget -T ' + HEALTH_TIMEOUT + ' --no-check-certificate -O- ' + HEALTH_TEST_URL + ' 2>&1');
	const out = p ? p.read('all') : '';
	if (p) p.close();
	const elapsed = time() - t0;

	const ok = (index(out, 'ip=') >= 0);
	let exit_ip = null, colo = null, loc = null;

	if (ok) {
		const lines = split(out, '\n');
		for (let i = 0; i < length(lines); i++) {
			const l = trim(lines[i]);
			if (substr(l, 0, 3) == 'ip=')        exit_ip = substr(l, 3);
			else if (substr(l, 0, 5) == 'colo=') colo    = substr(l, 5);
			else if (substr(l, 0, 4) == 'loc=')  loc     = substr(l, 4);
		}
	}

	return { ok: ok, elapsed_s: elapsed, exit_ip: exit_ip, colo: colo, loc: loc };
}

// Only meaningful for an active reality profile. `bypassed: false` means the
// nft exemption couldn't be installed (table missing) — the request, if any
// was even made, went through the tunnel like everything else and this
// result says nothing about dest's own health. The frontend must show that
// distinctly from a real ok/fail.
function check_dest(sni) {
	const ip = resolve_ipv4(sni);
	if (!ip)
		return { ok: false, sni: sni, ip: null, bypassed: false, elapsed_s: 0, error: 'dns_failed' };

	const bypassed = nft_exempt_add(ip);
	const probe = wget_probe('https://' + sni + '/');
	if (bypassed)
		nft_exempt_cleanup();

	return {
		ok:         bypassed && (index(probe.out, 'Download completed') >= 0),
		sni:        sni,
		ip:         ip,
		bypassed:   bypassed,
		elapsed_s:  probe.elapsed_s,
	};
}

// mkdir() is atomic in this ucode build's fs module (null if the dir
// already exists) — see HEALTH_LOCK_DIR comment above for why this exists.
function acquire_health_lock() {
	const st = lstat(HEALTH_LOCK_DIR);
	if (st && (time() - st.mtime) > HEALTH_LOCK_STALE)
		rmdir(HEALTH_LOCK_DIR);
	return mkdir(HEALTH_LOCK_DIR) === true;
}

function release_health_lock() {
	rmdir(HEALTH_LOCK_DIR);
}

function active_vless_profile() {
	const profiles = get_vless_profiles();
	for (let i = 0; i < length(profiles); i++)
		if (profiles[i].is_active)
			return profiles[i];
	return null;
}

function read_health_history() {
	const raw = read_file(HEALTH_LOG);
	if (!raw)
		return [];
	const lines = filter(split(trim(raw), '\n'), function(l) { return length(l) > 0; });
	const out = [];
	for (let i = 0; i < length(lines); i++) {
		const e = json(lines[i]);
		if (e)
			push(out, e);
	}
	return out;
}

function append_health_entry(entry) {
	let lines = filter(split(trim(read_file(HEALTH_LOG) || ''), '\n'), function(l) { return length(l) > 0; });
	push(lines, sprintf('%J', entry));
	if (length(lines) > HEALTH_MAX_ENTRIES)
		lines = slice(lines, -HEALTH_MAX_ENTRIES);
	write_file(HEALTH_LOG, join('\n', lines) + '\n');
}

// Serialized via acquire_health_lock()/release_health_lock() — cron (every
// 10 min) and a manual "Run now" click can otherwise land close enough
// together to race on the nft exemption and/or the history file (see
// HEALTH_LOCK_DIR comment). If another check is already in flight, this
// just returns the most recent recorded entry instead of running a second,
// overlapping one.
function run_health_check_impl() {
	if (!acquire_health_lock()) {
		const hist = read_health_history();
		return length(hist) ? hist[length(hist) - 1] : null;
	}

	const active_fwd = get_active_fwd();
	const entry = { ts: time(), target: active_fwd };

	entry.internet = check_internet();
	entry.dest = null;

	if (active_fwd === SINGBOX_IFACE && singbox_installed() && singbox_running()) {
		const active_p = active_vless_profile();
		if (active_p && active_p.security == 'reality' && length(active_p.sni)) {
			entry.dest = check_dest(active_p.sni);
			entry.dest.profile = active_p.name;
		}
	}

	append_health_entry(entry);
	release_health_lock();
	return entry;
}

const methods = {

	get_status: {
		call: function() {
			const ifaces     = get_awg_interfaces();
			const active_fwd = get_active_fwd();
			const peers      = parse_dump();
			const sb_installed = singbox_installed();
			const sb_running   = sb_installed ? singbox_running() : false;
			const result       = {
				interfaces:         {},
				active_forwarding:  active_fwd,
				singbox_installed:  sb_installed,
				singbox_running:    sb_running,
				singbox_active:     (active_fwd === SINGBOX_IFACE),
				vless_profiles:     sb_installed ? get_vless_profiles() : [],
			};

			const uci = cursor();
			uci.load('network');

			for (let i = 0; i < length(ifaces); i++) {
				const iface    = ifaces[i];
				const disabled = uci.get('network', iface, 'disabled');
				const peer_cfg = uci.get_all('network', `@amneziawg_${iface}[0]`);
				const peer     = peers[iface];

				result.interfaces[iface] = {
					disabled:      (disabled === '1'),
					is_up:         (peer !== null),
					is_active_fwd: (iface === active_fwd),
					endpoint_host: peer ? peer.endpoint_host : (peer_cfg ? peer_cfg.endpoint_host : null),
					endpoint_port: peer ? peer.endpoint_port : (peer_cfg ? peer_cfg.endpoint_port : null),
					handshake_ts:  peer ? peer.handshake_ts  : 0,
					rx_bytes:      peer ? peer.rx_bytes      : 0,
					tx_bytes:      peer ? peer.tx_bytes      : 0,
				};
			}

			uci.unload();
			return result;
		}
	},

	// Parses a vless:// link and stores it as a new profile file. Does not
	// touch routing/firewall — use switch_vless_profile to make it active.
	add_vless_profile: {
		args: { name: 'name', uri: 'uri' },
		call: function(req) {
			const name = req.args ? trim(req.args.name || '') : '';
			const uri  = req.args ? req.args.uri : null;

			if (!is_valid_name(name))
				return { error: 'Name must be 1-40 characters: letters, digits, - or _' };
			if (!uri)
				return { error: 'vless:// link is required' };
			if (!singbox_installed())
				return { error: 'sing-box is not installed' };

			ensure_profiles_dir();
			migrate_legacy_config();

			if (lstat(profile_path(name)))
				return { error: 'A profile named "' + name + '" already exists' };

			const parsed = parse_vless_uri(uri);
			if (!parsed)
				return { error: 'Could not parse vless:// link' };

			const outbound = build_vless_outbound(parsed);
			const cfg       = build_singbox_config(outbound);

			if (!write_file(profile_path(name), sprintf('%J', cfg)))
				return { error: 'Failed to write profile file' };

			// First profile ever configured becomes active automatically.
			if (!lstat(SINGBOX_CONFIG))
				symlink(profile_path(name), SINGBOX_CONFIG);

			return { success: true, name: name };
		}
	},

	// Repoints the config.json symlink at a stored profile and restarts
	// sing-box if it's currently running so the change takes effect.
	switch_vless_profile: {
		args: { name: 'name' },
		call: function(req) {
			const name = req.args ? req.args.name : null;
			if (!name || !lstat(profile_path(name)))
				return { error: 'Unknown profile: ' + name };

			if (lstat(SINGBOX_CONFIG))
				unlink(SINGBOX_CONFIG);
			symlink(profile_path(name), SINGBOX_CONFIG);

			if (singbox_running()) {
				const sb = popen('/etc/init.d/sing-box restart >/dev/null 2>&1 &');
				if (sb) sb.close();
			}

			return { success: true, active: name };
		}
	},

	delete_vless_profile: {
		args: { name: 'name' },
		call: function(req) {
			const name = req.args ? req.args.name : null;
			if (!name || !lstat(profile_path(name)))
				return { error: 'Unknown profile: ' + name };
			if (name == active_profile_name())
				return { error: 'Cannot delete the active profile — switch to another one first' };

			unlink(profile_path(name));
			return { success: true };
		}
	},

	switch_vpn: {
		args: { target: 'target' },
		call: function(req) {
			const target = req.args ? req.args.target : null;
			if (!target)
				return { error: 'No target specified' };

			const ifaces = get_awg_interfaces();
			const is_singbox = (target === SINGBOX_IFACE);

			if (is_singbox && !singbox_installed())
				return { error: 'sing-box is not installed' };

			if (!is_singbox && index(ifaces, target) === -1)
				return { error: 'Unknown interface: ' + target };

			const uci = cursor();

			// Update firewall forwarding
			uci.load('firewall');
			uci.foreach('firewall', 'forwarding', function(s) {
				if (s.src === 'lan')
					uci.set('firewall', s['.name'], 'dest', target);
			});
			uci.save();
			uci.commit('firewall');
			uci.unload();

			if (is_singbox) {
				// Switching to VLESS: mark all AWG disabled in UCI, then force
				// every one of them down at the network layer (see ifdown_iface
				// — UCI disabled=1 alone can leave a wg device up with a live
				// default route, breaking routing for everything, not just
				// VLESS), then start sing-box. sing-box's own config handles
				// routing loop prevention via bind_interface+route_exclude_address.
				uci.load('network');
				for (let i = 0; i < length(ifaces); i++)
					uci.set('network', ifaces[i], 'disabled', '1');
				uci.save();
				uci.commit('network');
				uci.unload();

				for (let i = 0; i < length(ifaces); i++)
					ifdown_iface(ifaces[i]);

				// An AWG peer with route_allowed_ips=1 replaces WAN's default
				// route while it's up (that's how it forces all traffic
				// through the tunnel) and nothing puts it back when the
				// interface goes down — ifdown alone can leave the router
				// with NO default route via the WAN device at all, which
				// breaks sing-box's bind_interface dial to its own VLESS
				// server. Re-asserting wan forces its default route back.
				const wanup = popen('ifup wan >/dev/null 2>&1');
				if (wanup) wanup.close();

				const fw = popen('/etc/init.d/firewall restart >/dev/null 2>&1 &');
				if (fw) fw.close();
				const sb = popen('/etc/init.d/sing-box start >/dev/null 2>&1 &');
				if (sb) sb.close();
			} else {
				// Switching to AWG: stop sing-box, enable target, force every
				// other AWG interface down (not just flag it disabled).
				const sb = popen('/etc/init.d/sing-box stop >/dev/null 2>&1');
				if (sb) sb.close();

				uci.load('network');
				for (let i = 0; i < length(ifaces); i++) {
					const iface = ifaces[i];
					if (iface === target)
						uci.delete('network', iface, 'disabled');
					else
						uci.set('network', iface, 'disabled', '1');
				}
				uci.save();
				uci.commit('network');
				uci.unload();

				for (let i = 0; i < length(ifaces); i++)
					if (ifaces[i] !== target)
						ifdown_iface(ifaces[i]);

				const fw  = popen('/etc/init.d/firewall restart >/dev/null 2>&1 &');
				const net = popen('/etc/init.d/network restart >/dev/null 2>&1 &');
				if (fw)  fw.close();
				if (net) net.close();
			}

			return { success: true, switched_to: target };
		}
	},

	// Manual remediation: force a specific AWG interface down at the network
	// layer, for when the UI shows it as "not fully down" (disabled in UCI
	// but still up/handshaking at the kernel level).
	force_ifdown: {
		args: { name: 'name' },
		call: function(req) {
			const name = req.args ? req.args.name : null;
			const ifaces = get_awg_interfaces();
			if (!name || index(ifaces, name) === -1)
				return { error: 'Unknown interface: ' + name };

			ifdown_iface(name);

			// If this interface had replaced WAN's default route (route_allowed_ips=1
			// on a 0.0.0.0/0 peer), ifdown alone won't bring it back — see the
			// matching comment in switch_vpn.
			const wanup = popen('ifup wan >/dev/null 2>&1');
			if (wanup) wanup.close();

			return { success: true };
		}
	},

	// Runs both active probes synchronously (up to ~2*HEALTH_TIMEOUT seconds)
	// and appends the result to the history ring buffer. Called both by the
	// "Run now" button and by cron every 10 minutes.
	run_health_check: {
		call: function() {
			return run_health_check_impl();
		}
	},

	get_health_history: {
		call: function() {
			return { entries: read_health_history(), max_entries: HEALTH_MAX_ENTRIES };
		}
	},
};

return { 'luci.vpnswitch': methods };
