'use strict';
'require rpc';
'require view';
'require poll';
'require ui';

const get_status = rpc.declare({
	object: 'luci.vpnswitch',
	method: 'get_status'
});

const switch_vpn = rpc.declare({
	object: 'luci.vpnswitch',
	method: 'switch_vpn',
	params: ['target']
});

const add_vless_profile = rpc.declare({
	object: 'luci.vpnswitch',
	method: 'add_vless_profile',
	params: ['name', 'uri']
});

const switch_vless_profile = rpc.declare({
	object: 'luci.vpnswitch',
	method: 'switch_vless_profile',
	params: ['name']
});

const delete_vless_profile = rpc.declare({
	object: 'luci.vpnswitch',
	method: 'delete_vless_profile',
	params: ['name']
});

const force_ifdown = rpc.declare({
	object: 'luci.vpnswitch',
	method: 'force_ifdown',
	params: ['name']
});

function fmtBytes(n) {
	if (!n) return '—';
	if (n < 1024)       return n + ' B';
	if (n < 1048576)    return (n / 1024).toFixed(2) + ' KiB';
	if (n < 1073741824) return (n / 1048576).toFixed(2) + ' MiB';
	return (n / 1073741824).toFixed(2) + ' GiB';
}

function fmtHandshake(ts) {
	if (!ts) return '—';
	const age = Math.floor(Date.now() / 1000) - ts;
	if (age < 60)    return age + 's ago';
	if (age < 3600)  return Math.floor(age / 60) + 'm ago';
	if (age < 86400) return Math.floor(age / 3600) + 'h ago';
	return Math.floor(age / 86400) + 'd ago';
}

function activeVlessProfile(data) {
	const profiles = data.vless_profiles || [];
	for (let i = 0; i < profiles.length; i++)
		if (profiles[i].is_active)
			return profiles[i];
	return null;
}

return view.extend({

	statusBadge: function(text, color) {
		return E('span', {
			'style': [
				'display:inline-block',
				'padding:2px 10px',
				'border-radius:4px',
				'font-weight:bold',
				'font-size:0.9em',
				'background:' + color,
				'color:#fff',
				'margin-left:8px'
			].join(';')
		}, text);
	},

	showAddVlessModal: function(self) {
		const nameInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'style': 'width:100%',
			'placeholder': 'e.g. my-server'
		});
		const uriInput = E('textarea', {
			'class': 'cbi-input-textarea',
			'rows': 4,
			'style': 'width:100%;font-family:monospace',
			'placeholder': 'vless://uuid@host:port?security=reality&type=tcp&...#name'
		});
		const errorBox = E('div', { 'style': 'color:#dc3545;margin-top:8px' });

		const addBtn = E('button', {
			'class': 'cbi-button cbi-button-positive',
			'click': function(ev) {
				const name = nameInput.value.trim();
				const uri  = uriInput.value.trim();
				errorBox.textContent = '';
				if (!name || !uri) {
					errorBox.textContent = 'Name and link are both required';
					return;
				}
				ev.target.disabled = true;
				add_vless_profile(name, uri).then(function(res) {
					if (res && res.error) {
						errorBox.textContent = res.error;
						ev.target.disabled = false;
						return;
					}
					ui.hideModal();
					window.location.reload();
				}).catch(function(err) {
					errorBox.textContent = err.message || String(err);
					ev.target.disabled = false;
				});
			}
		}, 'Add');

		ui.showModal('Add VLESS config', [
			E('p', {}, 'Paste a vless:// link exported from your VPN provider.'),
			E('label', {}, 'Name'),
			nameInput,
			E('label', { 'style': 'display:block;margin-top:8px' }, 'vless:// link'),
			uriInput,
			errorBox,
			E('div', { 'class': 'right', 'style': 'margin-top:12px' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, 'Cancel'),
				' ',
				addBtn
			])
		]);
	},

	renderVlessProfiles: function(profiles, self) {
		const rows = profiles.map(function(p) {
			const nameBits = [ E('strong', {}, p.name) ];
			if (p.is_active)
				nameBits.push(self.statusBadge('ACTIVE', '#28a745'));

			const detail = E('div', {
				'style': 'font-family:monospace;font-size:0.85em;color:#666;margin-top:2px'
			}, p.server + ':' + p.server_port + '  ·  ' + p.security +
			   (p.sni ? ' (' + p.sni + ')' : '') + '  ·  ' + p.network);

			const btns = [];
			if (!p.is_active) {
				btns.push(E('button', {
					'class': 'cbi-button cbi-button-apply',
					'style': 'margin-right:6px',
					'click': function(ev) {
						ev.target.disabled = true;
						ev.target.textContent = '…';
						switch_vless_profile(p.name).then(function(res) {
							if (res && res.error) {
								alert(res.error);
								ev.target.disabled = false;
								ev.target.textContent = 'Activate';
								return;
							}
							setTimeout(function() { window.location.reload(); }, 2000);
						});
					}
				}, 'Activate'));
			}
			btns.push(E('button', {
				'class': 'cbi-button cbi-button-remove',
				'disabled': p.is_active ? true : null,
				'click': function() {
					if (!confirm('Delete profile "' + p.name + '"?'))
						return;
					delete_vless_profile(p.name).then(function(res) {
						if (res && res.error) {
							alert(res.error);
							return;
						}
						window.location.reload();
					});
				}
			}, '✕'));

			return E('div', {
				'style': 'display:flex;align-items:center;justify-content:space-between;' +
				         'padding:8px 12px;border-bottom:1px solid #eee'
			}, [
				E('div', {}, [ E('div', {}, nameBits), detail ]),
				E('div', {}, btns)
			]);
		});

		return E('div', { 'style': 'margin-top:12px' }, [
			E('div', { 'style': 'font-weight:bold;margin-bottom:6px;color:#666' }, 'VLESS profiles'),
			rows.length
				? E('div', { 'style': 'border:1px solid #dee2e6;border-radius:6px' }, rows)
				: E('div', { 'style': 'color:#666;font-style:italic' }, 'No profiles yet'),
			E('button', {
				'class': 'cbi-button cbi-button-add',
				'style': 'margin-top:8px',
				'click': function() { self.showAddVlessModal(self); }
			}, '+ Add VLESS config')
		]);
	},

	renderSingboxCard: function(data, self) {
		const is_active  = data.singbox_active && data.singbox_running;
		const is_running = data.singbox_running;
		const profiles   = data.vless_profiles || [];
		const active_p   = activeVlessProfile(data);

		const statusEl = is_active
			? self.statusBadge('ACTIVE',  '#28a745')
			: is_running
				? self.statusBadge('RUNNING', '#17a2b8')
				: self.statusBadge('STOPPED', '#6c757d');

		const rows = active_p
			? [
				['Profile',    active_p.name, 'prof_name'],
				['Server',     active_p.server + ':' + active_p.server_port, 'prof_server'],
				['Security',   active_p.security + (active_p.sni ? ' (' + active_p.sni + ')' : ''), 'prof_security'],
				['Transport',  active_p.network + (active_p.flow ? ', flow ' + active_p.flow : ''), 'prof_transport'],
				['Service',    is_running ? '✓ running' : '✗ stopped', 'sb_status'],
			]
			: [
				['Profile', 'No VLESS profile configured — add one below', 'prof_name'],
				['Service', is_running ? '✓ running' : '✗ stopped', 'sb_status'],
			];

		const table = E('table', { 'class': 'table', 'style': 'margin-top:8px' },
			rows.map(function(r) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'style': 'width:40%;color:#666' }, r[0]),
					E('td', { 'class': 'td left', 'style': 'font-family:monospace',
					          'id': r[2] || null }, r[1])
				]);
			})
		);

		const btn = E('button', {
			'class': 'cbi-button cbi-button-' + (is_active ? 'save' : 'apply'),
			'style': 'margin-top:12px',
			'disabled': (is_active || !active_p) ? true : null,
			'id': 'btn_vless',
			'click': function() {
				this.disabled    = true;
				this.textContent = 'Switching…';
				switch_vpn('vless').then(function() {
					setTimeout(function() { window.location.reload(); }, 4000);
				}).catch(function() {
					this.disabled    = false;
					this.textContent = 'Switch to VLESS';
				}.bind(this));
			}
		}, is_active ? '✓ Active' : 'Switch to VLESS');

		return E('div', {
			'id': 'card_vless',
			'style': [
				'border:2px solid ' + (is_active ? '#28a745' : '#dee2e6'),
				'border-radius:6px',
				'padding:16px',
				'margin-bottom:16px',
				'background:' + (is_active ? '#f0fff4' : '#fff'),
				'transition:border-color 0.3s,background 0.3s'
			].join(';')
		}, [
			E('div', { 'style': 'display:flex;align-items:center' }, [
				E('h3', { 'style': 'margin:0;font-size:1.1em' }, 'VLESS (sing-box)'),
				E('span', { 'id': 'badge_vless' }, statusEl)
			]),
			table,
			btn,
			self.renderVlessProfiles(profiles, self)
		]);
	},

	updateSingboxCard: function(data, self) {
		const is_active  = data.singbox_active && data.singbox_running;
		const is_running = data.singbox_running;
		const active_p   = activeVlessProfile(data);

		const status_el = document.getElementById('sb_status');
		if (status_el) status_el.textContent = is_running ? '✓ running' : '✗ stopped';

		if (active_p) {
			const nameEl = document.getElementById('prof_name');
			if (nameEl) nameEl.textContent = active_p.name;
			const srvEl = document.getElementById('prof_server');
			if (srvEl) srvEl.textContent = active_p.server + ':' + active_p.server_port;
			const secEl = document.getElementById('prof_security');
			if (secEl) secEl.textContent = active_p.security + (active_p.sni ? ' (' + active_p.sni + ')' : '');
			const trEl = document.getElementById('prof_transport');
			if (trEl) trEl.textContent = active_p.network + (active_p.flow ? ', flow ' + active_p.flow : '');
		}

		const badge_el = document.getElementById('badge_vless');
		if (badge_el) {
			const text  = is_active ? 'ACTIVE' : is_running ? 'RUNNING' : 'STOPPED';
			const color = is_active ? '#28a745' : is_running ? '#17a2b8' : '#6c757d';
			badge_el.replaceChildren(self.statusBadge(text, color));
		}

		const card_el = document.getElementById('card_vless');
		if (card_el) {
			card_el.style.borderColor = is_active ? '#28a745' : '#dee2e6';
			card_el.style.background  = is_active ? '#f0fff4' : '#fff';
		}

		const btn_el = document.getElementById('btn_vless');
		if (btn_el && !btn_el.textContent.includes('Switching')) {
			btn_el.disabled    = is_active || !active_p;
			btn_el.textContent = is_active ? '✓ Active' : 'Switch to VLESS';
			btn_el.className   = 'cbi-button cbi-button-' + (is_active ? 'save' : 'apply');
		}
	},

	renderCard: function(name, info, self) {
		const is_active  = info.is_active_fwd && info.is_up;
		const is_disabled = info.disabled;
		// disabled=1 in UCI but still up at the kernel level: netifd failed to
		// tear it down (leftover wg device, possibly still holding a route —
		// see NOTES.md). This is the state that broke routing before.
		const is_stale = is_disabled && info.is_up;

		const statusEl = is_active
			? self.statusBadge('ACTIVE',  '#28a745')
			: is_stale
				? self.statusBadge('NOT FULLY DOWN', '#dc3545')
				: is_disabled
					? self.statusBadge('DISABLED', '#6c757d')
					: self.statusBadge('STANDBY',  '#ffc107');

		const endpoint = info.endpoint_host
			? (info.endpoint_host + ':' + info.endpoint_port) : '—';

		const rows = [
			['Endpoint',       endpoint,                              null],
			['Interface',      info.is_up ? '✓ up' : '✗ down',       'up_' + name],
			['Last handshake', fmtHandshake(info.handshake_ts),       'hs_' + name],
			['Transfer ↓ / ↑', fmtBytes(info.rx_bytes) + ' / ' + fmtBytes(info.tx_bytes), 'tr_' + name],
		];

		const table = E('table', { 'class': 'table', 'style': 'margin-top:8px' },
			rows.map(function(r) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'style': 'width:40%;color:#666' }, r[0]),
					E('td', { 'class': 'td left', 'style': 'font-family:monospace',
					          'id': r[2] || null }, r[1])
				]);
			})
		);

		// Always render this node (never null/undefined as an E() child —
		// this LuCI build's dom.append() stringifies non-element children,
		// so a bare `null` here would literally render the text "null").
		// Visibility is toggled with display instead.
		const warning = E('div', {
			'id': 'warn_' + name,
			'style': 'margin-top:8px;padding:8px 12px;border-radius:4px;' +
			         'background:#fff3f3;color:#dc3545;font-size:0.9em' +
			         (is_stale ? '' : ';display:none')
		}, '⚠ Disabled in config but still up — it may be holding onto routes it shouldn\'t. Use "Force down" to fix.');

		const btn = E('button', {
			'class': 'cbi-button cbi-button-' + (is_active ? 'save' : 'apply'),
			'style': 'margin-top:12px',
			'disabled': is_active ? true : null,
			'id': 'btn_' + name,
			'click': function() {
				this.disabled    = true;
				this.textContent = 'Switching…';
				switch_vpn(name).then(function() {
					setTimeout(function() { window.location.reload(); }, 4000);
				}).catch(function() {
					this.disabled    = false;
					this.textContent = 'Switch to ' + name;
				}.bind(this));
			}
		}, is_active ? '✓ Active' : 'Switch to ' + name);

		const forceBtn = E('button', {
			'id': 'force_' + name,
			'class': 'cbi-button cbi-button-remove',
			'style': 'margin-top:12px;margin-left:8px;' + (is_stale ? '' : 'display:none'),
			'click': function(ev) {
				ev.target.disabled    = true;
				ev.target.textContent = '…';
				force_ifdown(name).then(function() {
					setTimeout(function() { window.location.reload(); }, 1500);
				});
			}
		}, 'Force down');

		return E('div', {
			'id': 'card_' + name,
			'style': [
				'border:2px solid ' + (is_active ? '#28a745' : is_stale ? '#dc3545' : '#dee2e6'),
				'border-radius:6px',
				'padding:16px',
				'margin-bottom:16px',
				'background:' + (is_active ? '#f0fff4' : is_stale ? '#fff8f8' : '#fff'),
				'transition:border-color 0.3s,background 0.3s'
			].join(';')
		}, [
			E('div', { 'style': 'display:flex;align-items:center' }, [
				E('h3', { 'style': 'margin:0;font-size:1.1em' }, name),
				E('span', { 'id': 'badge_' + name }, statusEl)
			]),
			table,
			warning,
			btn,
			forceBtn
		]);
	},

	updateCard: function(name, info, self) {
		const is_active   = info.is_active_fwd && info.is_up;
		const is_disabled = info.disabled;
		const is_stale    = is_disabled && info.is_up;

		const up_el = document.getElementById('up_' + name);
		if (up_el) up_el.textContent = info.is_up ? '✓ up' : '✗ down';

		const hs_el = document.getElementById('hs_' + name);
		if (hs_el) hs_el.textContent = fmtHandshake(info.handshake_ts);

		const tr_el = document.getElementById('tr_' + name);
		if (tr_el) tr_el.textContent =
			fmtBytes(info.rx_bytes) + ' / ' + fmtBytes(info.tx_bytes);

		const badge_el = document.getElementById('badge_' + name);
		if (badge_el) {
			const text  = is_active ? 'ACTIVE' : is_stale ? 'NOT FULLY DOWN' : is_disabled ? 'DISABLED' : 'STANDBY';
			const color = is_active ? '#28a745' : is_stale ? '#dc3545' : is_disabled ? '#6c757d' : '#ffc107';
			badge_el.replaceChildren(self.statusBadge(text, color));
		}

		const warn_el = document.getElementById('warn_' + name);
		if (warn_el) warn_el.style.display = is_stale ? '' : 'none';

		const force_el = document.getElementById('force_' + name);
		if (force_el && !force_el.textContent.includes('…'))
			force_el.style.display = is_stale ? '' : 'none';

		const card_el = document.getElementById('card_' + name);
		if (card_el) {
			card_el.style.borderColor = is_active ? '#28a745' : is_stale ? '#dc3545' : '#dee2e6';
			card_el.style.background  = is_active ? '#f0fff4' : is_stale ? '#fff8f8' : '#fff';
		}

		const btn_el = document.getElementById('btn_' + name);
		if (btn_el && !btn_el.textContent.includes('Switching')) {
			btn_el.disabled    = is_active;
			btn_el.textContent = is_active ? '✓ Active' : 'Switch to ' + name;
			btn_el.className   = 'cbi-button cbi-button-' + (is_active ? 'save' : 'apply');
		}
	},

	load: function() {
		return get_status();
	},

	render: function(data) {
		const self   = this;
		const ifaces = data.interfaces || {};
		const names  = Object.keys(ifaces);

		poll.add(function() {
			return get_status().then(function(d) {
				const ifaces = d.interfaces || {};
				for (const name of Object.keys(ifaces))
					self.updateCard(name, ifaces[name], self);
				if (d.singbox_installed)
					self.updateSingboxCard(d, self);
			});
		}, 5);

		const cards = names.map(function(name) {
			return self.renderCard(name, ifaces[name], self);
		});
		if (data.singbox_installed)
			cards.push(self.renderSingboxCard(data, self));

		return E('div', {}, [
			E('h2', {}, 'VPN Switch'),
			E('p', { 'style': 'color:#666;margin-bottom:20px' },
				'Manage VPN tunnels. Status updates every 5 seconds.'),
			E('div', {}, cards)
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
