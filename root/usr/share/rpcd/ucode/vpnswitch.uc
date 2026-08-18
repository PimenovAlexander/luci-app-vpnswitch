#!/usr/bin/env ucode
'use strict';

import { cursor } from 'uci';
import { popen, open, lstat, symlink, readlink, unlink, mkdir, glob } from 'fs';

const SINGBOX_IFACE  = 'vless';
const SINGBOX_CONFIG = '/etc/sing-box/config.json';
const PROFILES_DIR   = '/etc/sing-box/profiles';

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
				// Switching to VLESS: mark all AWG disabled in UCI, then start sing-box.
				// sing-box config handles routing loop prevention via bind_interface+
				// route_exclude_address — no kernel route manipulation needed here.
				uci.load('network');
				for (let i = 0; i < length(ifaces); i++)
					uci.set('network', ifaces[i], 'disabled', '1');
				uci.save();
				uci.commit('network');
				uci.unload();

				const fw = popen('/etc/init.d/firewall restart >/dev/null 2>&1 &');
				if (fw) fw.close();
				const sb = popen('/etc/init.d/sing-box start >/dev/null 2>&1 &');
				if (sb) sb.close();
			} else {
				// Switching to AWG: stop sing-box, enable target, disable others
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

				const fw  = popen('/etc/init.d/firewall restart >/dev/null 2>&1 &');
				const net = popen('/etc/init.d/network restart >/dev/null 2>&1 &');
				if (fw)  fw.close();
				if (net) net.close();
			}

			return { success: true, switched_to: target };
		}
	},
};

return { 'luci.vpnswitch': methods };
