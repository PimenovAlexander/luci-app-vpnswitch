'use strict';
'require rpc';
'require view';
'require poll';
'require ui';

const get_health_history = rpc.declare({
	object: 'luci.vpnswitch',
	method: 'get_health_history'
});

const run_health_check = rpc.declare({
	object: 'luci.vpnswitch',
	method: 'run_health_check'
});

const POLL_SECONDS    = 15;
const HISTORY_SHOWN   = 50; // backend keeps more (see max_entries); the page only lists the most recent

function statusBadge(text, color) {
	return E('span', {
		'style': [
			'display:inline-block',
			'padding:2px 10px',
			'border-radius:4px',
			'font-weight:bold',
			'font-size:0.9em',
			'background:' + color,
			'color:#fff'
		].join(';')
	}, text);
}

function fmtAgo(ts) {
	if (!ts) return '—';
	const age = Math.floor(Date.now() / 1000) - ts;
	if (age < 5)     return 'just now';
	if (age < 60)    return age + 's ago';
	if (age < 3600)  return Math.floor(age / 60) + 'm ago';
	if (age < 86400) return Math.floor(age / 3600) + 'h ago';
	return Math.floor(age / 86400) + 'd ago';
}

function pad2(n) {
	return (n < 10 ? '0' : '') + n;
}

function fmtClock(ts) {
	if (!ts) return '—';
	const d = new Date(ts * 1000);
	return pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
}

function targetLabel(entry) {
	if (entry.target === 'vless')
		return 'VLESS' + (entry.dest && entry.dest.profile ? ' (' + entry.dest.profile + ')' : '');
	return entry.target || '—';
}

// Small inline dot + label used in the history table cells.
function resultDot(ok, title) {
	const color = ok === true ? '#28a745' : ok === false ? '#dc3545' : '#adb5bd';
	return E('span', {
		'title': title || '',
		'style': 'display:inline-block;width:10px;height:10px;border-radius:50%;' +
		         'background:' + color + ';margin-right:4px;vertical-align:middle'
	});
}

return view.extend({

	renderInternetCard: function(entry) {
		const net = entry ? entry.internet : null;
		const ok  = net ? net.ok : null;

		const statusEl = ok === true
			? statusBadge('OK', '#28a745')
			: ok === false
				? statusBadge('FAIL', '#dc3545')
				: statusBadge('NO DATA', '#6c757d');

		const rows = net ? [
			['Target',     entry ? targetLabel(entry) : '—'],
			['Checked',    entry ? (fmtClock(entry.ts) + '  (' + fmtAgo(entry.ts) + ')') : '—'],
			['Latency',    net.elapsed_s != null ? net.elapsed_s + 's' : '—'],
			['Exit IP',    net.exit_ip || '—'],
			['Exit region',[net.loc, net.colo].filter(Boolean).join(' / ') || '—'],
		] : [['Status', 'No checks recorded yet — click "Run now"']];

		const table = E('table', { 'class': 'table', 'style': 'margin-top:8px' },
			rows.map(r => E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'style': 'width:40%;color:#666' }, r[0]),
				E('td', { 'class': 'td left', 'style': 'font-family:monospace' }, r[1])
			]))
		);

		return E('div', {
			'style': [
				'border:2px solid ' + (ok === true ? '#28a745' : ok === false ? '#dc3545' : '#dee2e6'),
				'border-radius:6px', 'padding:16px', 'margin-bottom:16px',
				'background:' + (ok === true ? '#f0fff4' : ok === false ? '#fff8f8' : '#fff')
			].join(';')
		}, [
			E('div', { 'style': 'display:flex;align-items:center;gap:8px' }, [
				E('h3', { 'style': 'margin:0;font-size:1.1em' }, 'Internet via active tunnel'),
				statusEl
			]),
			E('p', { 'style': 'color:#666;margin:6px 0 0;font-size:0.9em' },
				'Real HTTPS request through whatever is currently active — VLESS or AWG. ' +
				'This is what actually broke on 2026-08-24 while sing-box itself stayed "running".'),
			table
		]);
	},

	renderDestCard: function(entry) {
		const dest = entry ? entry.dest : undefined;

		if (dest === null || dest === undefined) {
			return E('div', {
				'style': 'border:2px solid #dee2e6;border-radius:6px;padding:16px;margin-bottom:16px;background:#fff'
			}, [
				E('h3', { 'style': 'margin:0;font-size:1.1em;color:#888' }, 'Reality dest health'),
				E('p', { 'style': 'color:#666;margin:8px 0 0' },
					'Not applicable right now — AWG is active, or the active VLESS profile has no Reality dest to check.')
			]);
		}

		const inconclusive = dest.bypassed === false;
		const ok = inconclusive ? null : dest.ok;

		const statusEl = inconclusive
			? statusBadge('INCONCLUSIVE', '#ffc107')
			: ok ? statusBadge('OK', '#28a745') : statusBadge('FAIL', '#dc3545');

		const rows = [
			['Domain (SNI)', dest.sni || '—'],
			['Resolved IP',  dest.ip || (dest.error === 'dns_failed' ? 'DNS resolution failed' : '—')],
			['Latency',      dest.elapsed_s != null ? dest.elapsed_s + 's' : '—'],
		];

		return E('div', {
			'style': [
				'border:2px solid ' + (inconclusive ? '#ffc107' : ok ? '#28a745' : '#dc3545'),
				'border-radius:6px', 'padding:16px', 'margin-bottom:16px',
				'background:' + (inconclusive ? '#fffdf5' : ok ? '#f0fff4' : '#fff8f8')
			].join(';')
		}, [
			E('div', { 'style': 'display:flex;align-items:center;gap:8px' }, [
				E('h3', { 'style': 'margin:0;font-size:1.1em' }, 'Reality dest health'),
				statusEl
			]),
			E('p', { 'style': 'color:#666;margin:6px 0 0;font-size:0.9em' },
				'Tests the VLESS profile\'s camouflage domain directly, bypassing the tunnel — this is ' +
				'the check that would have caught the koba-auto.com failure as "dest is down" instead ' +
				'of hours of packet capture. TLS1.2-fallback is not distinguished from TLS1.3 here — ' +
				'see hosts.txt for that caveat.' +
				(inconclusive ? ' Currently inconclusive: could not bypass the tunnel for this test (sing-box nftables table not found).' : '')),
			E('table', { 'class': 'table', 'style': 'margin-top:8px' },
				rows.map(r => E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'style': 'width:40%;color:#666' }, r[0]),
					E('td', { 'class': 'td left', 'style': 'font-family:monospace' }, r[1])
				]))
			)
		]);
	},

	renderHistory: function(entries) {
		const shown = entries.slice(-HISTORY_SHOWN).reverse();

		if (!shown.length) {
			return E('div', { 'style': 'color:#666;font-style:italic;padding:8px 0' }, 'No history yet.');
		}

		const rows = shown.map(function(e) {
			const net  = e.internet || {};
			const dest = e.dest;
			const destCell = dest === null || dest === undefined
				? E('span', { 'style': 'color:#adb5bd' }, '—')
				: E('span', {}, [
					resultDot(dest.bypassed === false ? null : dest.ok,
					          dest.bypassed === false ? 'inconclusive' : (dest.ok ? 'ok' : 'fail')),
					dest.elapsed_s != null ? dest.elapsed_s + 's' : ''
				]);

			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'style': 'font-family:monospace;white-space:nowrap' }, fmtClock(e.ts)),
				E('td', { 'class': 'td left' }, targetLabel(e)),
				E('td', { 'class': 'td left' }, [
					resultDot(net.ok, net.ok ? 'ok' : 'fail'),
					net.elapsed_s != null ? net.elapsed_s + 's' : '—'
				]),
				E('td', { 'class': 'td left' }, destCell)
			]);
		});

		return E('div', { 'style': 'max-height:420px;overflow-y:auto;border:1px solid #dee2e6;border-radius:6px' }, [
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, 'Time'),
					E('th', { 'class': 'th' }, 'Target'),
					E('th', { 'class': 'th' }, 'Internet'),
					E('th', { 'class': 'th' }, 'Dest')
				])
			].concat(rows))
		]);
	},

	buildDynamicChildren: function(data) {
		const entries = (data && data.entries) || [];
		const latest  = entries.length ? entries[entries.length - 1] : null;

		return [
			this.renderInternetCard(latest),
			this.renderDestCard(latest),
			E('div', { 'style': 'margin-top:20px' }, [
				E('div', { 'style': 'display:flex;align-items:center;justify-content:space-between' }, [
					E('h3', { 'style': 'margin:0;font-size:1.05em;color:#666' }, 'History'),
					E('span', { 'style': 'color:#888;font-size:0.85em' },
						entries.length + ' of ' + ((data && data.max_entries) || '?') + ' kept')
				]),
				this.renderHistory(entries)
			])
		];
	},

	renderAll: function(data) {
		const container = document.getElementById('health-dynamic');
		if (!container)
			return;
		container.replaceChildren.apply(container, this.buildDynamicChildren(data));
	},

	load: function() {
		return get_health_history();
	},

	render: function(data) {
		const self = this;

		const runBtn = E('button', {
			'class': 'cbi-button cbi-button-apply',
			'click': function(ev) {
				ev.target.disabled = true;
				ev.target.textContent = 'Checking…';
				run_health_check().then(function() {
					return get_health_history();
				}).then(function(fresh) {
					self.renderAll(fresh);
				}).catch(function(err) {
					alert('Health check failed: ' + (err.message || String(err)));
				}).finally(function() {
					ev.target.disabled = false;
					ev.target.textContent = 'Run check now';
				});
			}
		}, 'Run check now');

		poll.add(function() {
			return get_health_history().then(function(fresh) {
				self.renderAll(fresh);
			});
		}, POLL_SECONDS);

		return E('div', {}, [
			E('h2', {}, 'VPN Switch — LAN Health'),
			E('p', { 'style': 'color:#666;margin-bottom:12px' },
				'Active probes run from the router itself every 10 minutes (cron), plus on demand. ' +
				'History is kept in RAM (/tmp) and is cleared on reboot.'),
			runBtn,
			E('div', { 'id': 'health-dynamic', 'style': 'margin-top:16px' },
				self.buildDynamicChildren(data))
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
