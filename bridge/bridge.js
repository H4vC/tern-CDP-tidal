// TIDAL bridge: drives the TIDAL desktop app (or tidal-hifi on Linux) over the Chrome DevTools
// protocol. Runs on the app's own Electron binary in Node mode (ELECTRON_RUN_AS_NODE=1), so it
// needs nothing installed:
//
//   <app executable> bridge.js <data-dir> <app executable>
//
// The app must be started with --remote-debugging-port; `launch` and `relaunch` do that. Talks to
// the plugin through files in the data directory; see the protocol in src/link.luau.
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const childProcess = require('child_process');

const [data, appExe] = process.argv.slice(2);
if (!data || !appExe) process.exit(2);

const INBOX = path.join(data, 'inbox');
const PAGE_SCRIPT = fs.readFileSync(path.join(__dirname, 'tidal-page.js'), 'utf8');
const HIFI = /tidal-hifi/i.test(appExe);
const PROFILE =
	process.platform === 'win32'
		? path.join(process.env.APPDATA || '', 'TIDAL')
		: process.platform === 'darwin'
			? path.join(os.homedir(), 'Library', 'Application Support', 'TIDAL')
			: path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), HIFI ? 'tidal-hifi' : 'TIDAL');
const PORT_FILE = path.join(PROFILE, 'DevToolsActivePort');

const COMMAND_MAX_AGE_S = 10;
const ORPHAN_AFTER_S = 30;
const HEARTBEAT_MS = 1000;
const RECONNECT_MS = 1000;
const PROCESS_CHECK_MS = 3000;

const started = Date.now();
const nowS = () => Math.floor(Date.now() / 1000);

function log(message) {
	const file = path.join(data, 'bridge.log');
	try {
		if (fs.statSync(file).size > 64 * 1024) fs.writeFileSync(file, '');
	} catch {}
	try {
		fs.appendFileSync(file, new Date().toISOString() + ' ' + message + '\n');
	} catch {}
}

// One bridge per data directory, however many Tern windows start one: the pid file is created
// exclusively, so of bridges racing to start exactly one wins. A file left by a bridge that died
// is taken over.
function lock() {
	const file = path.join(data, 'bridge.pid');
	for (let attempt = 0; attempt < 2; attempt++) {
		try {
			fs.writeFileSync(file, String(process.pid), { flag: 'wx' });
			process.on('exit', () => {
				try {
					if (Number(fs.readFileSync(file, 'utf8')) === process.pid) fs.unlinkSync(file);
				} catch {}
			});
			return true;
		} catch (error) {
			if (error.code !== 'EEXIST') throw error;
		}
		let owner = 0;
		try {
			owner = Number(fs.readFileSync(file, 'utf8'));
		} catch {}
		if (owner && owner !== process.pid) {
			try {
				process.kill(owner, 0); // throws when it's gone
				return false;
			} catch (error) {
				if (error.code === 'EPERM') return false; // alive, someone else's
			}
		}
		// Stale or unreadable (another bridge mid-write would have won `wx` already): take it over.
		try {
			fs.unlinkSync(file);
		} catch {}
	}
	return false;
}

// ---- The app's processes -------------------------------------------------------------------

function appPids() {
	const name = path.basename(appExe);
	try {
		if (process.platform === 'win32') {
			const out = childProcess.execFileSync('tasklist', ['/FO', 'CSV', '/NH', '/FI', 'IMAGENAME eq ' + name], {
				windowsHide: true,
				encoding: 'utf8',
			});
			return [...out.matchAll(/^"[^"]*","(\d+)"/gm)].map((m) => Number(m[1])).filter((pid) => pid !== process.pid);
		}
		const out = childProcess.execFileSync('pgrep', ['-f', appExe], { encoding: 'utf8' });
		return out.split('\n').map(Number).filter((pid) => pid && pid !== process.pid);
	} catch {
		return [];
	}
}

let appRunning = false;
let processCheckedAt = 0;

function checkApp(force) {
	if (force || Date.now() - processCheckedAt >= PROCESS_CHECK_MS) {
		processCheckedAt = Date.now();
		appRunning = appPids().length > 0;
	}
	return appRunning;
}

let launchedAt = 0;

function launch() {
	const env = { ...process.env };
	delete env.ELECTRON_RUN_AS_NODE;
	try {
		fs.unlinkSync(PORT_FILE); // stale from an earlier run
	} catch {}
	const child = childProcess.spawn(appExe, ['--remote-debugging-port=0'], { detached: true, stdio: 'ignore', env, windowsHide: false });
	child.unref();
	launchedAt = Date.now();
	processCheckedAt = 0;
}

// What TIDAL is playing, read from the OS media session (TIDAL can't be asked directly before it
// runs with remote control). Null when unknown.
function osNowPlaying() {
	const run = (file, args) => childProcess.execFileSync(file, args, { windowsHide: true, encoding: 'utf8', timeout: 8000 }).trim();
	try {
		if (process.platform === 'win32') {
			const root = process.env.SystemRoot || 'C:\\Windows';
			const ps = path.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
			return JSON.parse(run(ps, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(__dirname, 'now-playing.ps1')]));
		}
		if (process.platform === 'darwin') {
			const tool = ['/opt/homebrew/bin/media-control', '/usr/local/bin/media-control'].find((p) => fs.existsSync(p));
			if (!tool) return null;
			const info = JSON.parse(run(tool, ['get', '--no-artwork']) || 'null');
			if (!info || info.bundleIdentifier !== 'com.tidal.desktop') return null;
			return { title: info.title, playing: !!info.playing, position_ms: Math.round((info.elapsedTime || 0) * 1000) };
		}
		const [status, position, title] = run('playerctl', ['-p', 'tidal-hifi', 'metadata', '--format', '{{status}}\t{{position}}\t{{title}}']).split('\t');
		return { title, playing: status === 'Playing', position_ms: Math.round(Number(position) / 1000) };
	} catch {
		return null;
	}
}

// Where to pick up after a restart: { title, playing, position_ms, at }.
let resume = null;

async function relaunch() {
	launchedAt = Date.now(); // the restart counts as starting from here
	const playing = osNowPlaying();
	resume = playing && playing.title ? { ...playing, at: Date.now() } : null;
	for (const pid of appPids()) {
		try {
			process.kill(pid);
		} catch {}
	}
	for (let i = 0; i < 50 && appPids().length > 0; i++) await sleep(100);
	launch();
}

// TIDAL comes back paused on the track it had, at the position it last saved; put it back where it
// was and play if it was playing. Runs once, after the first report with a track.
async function resumePlayback() {
	const r = resume;
	resume = null;
	if (!r || !state || !state.track) return;
	const sameTrack = state.track.title.startsWith(r.title) || r.title.startsWith(state.track.title);
	try {
		await sleep(300); // let TIDAL finish loading the track it restored
		if (sameTrack) await command('seek', String(r.position_ms + (r.playing ? Date.now() - r.at : 0)));
		if (r.playing && state && state.state !== 'PLAYING') await command('toggle', '');
	} catch (error) {
		log('resume: ' + error.message);
	}
}

// Restarts TIDAL by itself when it runs without remote control. Gives up (and leaves it to the
// player's Restart button) when a restart didn't bring the port up.
let autoRelaunches = 0;

function maybeRelaunch() {
	if (ws || connecting || !appRunning) return;
	if (Date.now() - launchedAt < 20000) return; // still starting
	if (autoRelaunches >= 1) return;
	autoRelaunches++;
	log('TIDAL runs without remote control; restarting it');
	relaunch().catch((error) => log('relaunch: ' + error.message));
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ---- DevTools ------------------------------------------------------------------------------

let ws = null;
let nextId = 0;
const pending = new Map();
let connecting = false;

function send(method, params = {}) {
	if (!ws || ws.readyState !== WebSocket.OPEN) return Promise.reject(new Error("Not connected to TIDAL"));
	const id = ++nextId;
	ws.send(JSON.stringify({ id, method, params }));
	return new Promise((resolve, reject) => {
		pending.set(id, { resolve, reject });
		setTimeout(() => {
			if (pending.delete(id)) reject(new Error("TIDAL didn't answer in time"));
		}, 3000);
	});
}

let connectedAt = 0;

// Installs the page side, or makes an existing install report its state again.
async function install() {
	await send('Runtime.evaluate', { expression: PAGE_SCRIPT });
}

async function connect() {
	if (connecting || (ws && ws.readyState <= WebSocket.OPEN)) return;
	connecting = true;
	try {
		let port;
		try {
			port = Number(fs.readFileSync(PORT_FILE, 'utf8').split('\n')[0]);
		} catch {
			return;
		}
		const targets = await (await fetch('http://127.0.0.1:' + port + '/json/list', { signal: AbortSignal.timeout(2000) })).json();
		const page = targets.find((t) => t.type === 'page' && /tidal\.com/.test(t.url));
		if (!page) return;
		const socket = new WebSocket(page.webSocketDebuggerUrl);
		await new Promise((resolve, reject) => {
			socket.onopen = resolve;
			socket.onerror = () => reject(new Error('DevTools connection failed'));
		});
		ws = socket;
		socket.onmessage = (event) => onMessage(JSON.parse(event.data));
		socket.onclose = () => {
			if (ws === socket) ws = null;
			for (const { reject } of pending.values()) reject(new Error('TIDAL closed'));
			pending.clear();
			state = null;
			publish();
		};
		// With Runtime enabled the binding also reaches documents TIDAL creates later (it reloads its
		// page at times); the new-document script reinstalls the page side there.
		await send('Runtime.enable');
		await send('Runtime.addBinding', { name: '__ternTidal' });
		await send('Page.addScriptToEvaluateOnNewDocument', { source: PAGE_SCRIPT });
		await install();
		connectedAt = Date.now();
		appRunning = true;
	} catch (error) {
		// Refused or reset: the app isn't up yet, or it was started without the port.
	} finally {
		connecting = false;
	}
}

function onMessage(message) {
	if (message.id && pending.has(message.id)) {
		const { resolve, reject } = pending.get(message.id);
		pending.delete(message.id);
		if (message.error) reject(new Error(message.error.message));
		else resolve(message.result);
		return;
	}
	if (message.method === 'Runtime.bindingCalled' && message.params.name === '__ternTidal') {
		try {
			state = JSON.parse(message.params.payload);
		} catch (error) {
			log('bad state: ' + error.message);
			return;
		}
		autoRelaunches = 0; // connected: a later restart without the port may be retried
		if (resume && state.track) resumePlayback();
		publish();
	}
}

// ---- Snapshot ------------------------------------------------------------------------------

let state = null; // the page's latest report
let timeline = 0;
let lastSync = '';
let reply = null;
let lastBody = '';
let wroteAt = 0;

function publish() {
	const connected = !!(ws && ws.readyState === WebSocket.OPEN);
	const snap = { v: 1, os: process.platform, pid: process.pid, app: connected || appRunning, playing: false, timeline };
	// Running without the port: the bridge restarts TIDAL itself once; this asks only if that failed.
	if (!connected && Date.now() - launchedAt <= 20000) {
		snap.starting = true;
		snap.app = true;
	} else if (!connected && appRunning && autoRelaunches > 0) {
		snap.problem = "TIDAL didn't come back with remote control.";
		snap.relaunch = true;
	}
	const s = connected ? state : null;
	const track = s && s.track;
	if (track) {
		const sync = [track.id, s.state, s.time_s, s.synced_at].join('|');
		if (sync !== lastSync) {
			lastSync = sync;
			timeline++;
		}
		const playing = s.state === 'PLAYING';
		let position = s.time_s * 1000 + (playing && s.synced_at ? Date.now() - s.synced_at : 0);
		if (track.length_ms) position = Math.min(position, track.length_ms);
		Object.assign(snap, {
			track: {
				id: track.id,
				title: track.title,
				artist: track.artist,
				album: track.album,
				length_ms: track.length_ms || undefined,
				artist_id: track.artist_id || undefined,
				album_id: track.album_id || undefined,
				color: track.color || undefined,
				liked: !!track.liked,
			},
			playing,
			position_ms: Math.max(0, Math.round(position)),
			timeline,
			shuffle: s.shuffle,
			repeat: s.repeat,
			volume: Math.round(s.volume),
			muted: s.muted,
			quality: s.quality || undefined,
			format: s.format || undefined,
			source: s.source || undefined,
			next: s.next || undefined,
			queue: s.queue || undefined,
			can: { toggle: true, next: true, prev: true, seek: !!track.length_ms, shuffle: true, repeat: true, volume: true },
		});
		if (track.cover) snap.cover = { key: track.cover, url: track.cover };
	} else {
		if (lastSync) {
			lastSync = '';
			snap.timeline = ++timeline;
		}
		snap.can = { toggle: false, next: false, prev: false, seek: false, shuffle: false, repeat: false, volume: false };
	}
	if (reply) snap.reply = reply;
	if (sleepTimer) snap.sleep = sleepTimer.at ? { at_s: Math.round(sleepTimer.at / 1000) } : { end_of_track: true };

	// Position moves every write; compare without it.
	const body = JSON.stringify({ ...snap, position_ms: undefined });
	if (body === lastBody && Date.now() - wroteAt < HEARTBEAT_MS) return;
	snap.beat = nowS();
	const target = path.join(data, 'now.json');
	try {
		fs.writeFileSync(target + '.tmp', JSON.stringify(snap));
		fs.renameSync(target + '.tmp', target);
		lastBody = body;
		wroteAt = Date.now();
	} catch {} // a reader holds it on Windows; the next write retries
}

// ---- Commands ------------------------------------------------------------------------------

async function command(op, arg) {
	const result = await send('Runtime.evaluate', {
		expression: 'window.__ternTidalCommand(' + JSON.stringify(op) + ', ' + JSON.stringify(arg) + ')',
		returnByValue: true,
		awaitPromise: true,
	});
	if (result.exceptionDetails) throw new Error(errorText(result.exceptionDetails));
}

function errorText(details) {
	const ex = details.exception;
	return (ex && ex.description ? ex.description.split('\n')[0] : details.text).replace(/^Error: /, '');
}

function writeJson(name, value) {
	const target = path.join(data, name);
	fs.writeFileSync(target + '.tmp', JSON.stringify(value));
	fs.renameSync(target + '.tmp', target);
}

// Runs one of the page's async lookups. The answer goes to a file of its own, not the snapshot,
// which is rewritten every second.
async function lookup(file, out, expression, field) {
	try {
		const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
		if (result.exceptionDetails) out.error = errorText(result.exceptionDetails);
		else Object.assign(out, field ? { [field]: result.result.value } : result.result.value);
	} catch (error) {
		out.error = error.message;
	}
	writeJson(file, out);
}

// Searches and artist/album lists share search.json: the plugin shows either in the same panel.
const search = (id, query) => lookup('search.json', { id, query }, 'window.__ternTidalSearch(' + JSON.stringify(query) + ')', 'items');

function list(id, arg) {
	const [kind, itemId] = arg.split(' ');
	return lookup('search.json', { id, query: '', list: { kind, id: itemId } },
		'window.__ternTidalList(' + JSON.stringify(kind) + ', ' + JSON.stringify(itemId) + ')');
}

const lyrics = (id, trackId) => lookup('lyrics.json', { id, track: trackId }, 'window.__ternTidalLyrics(' + JSON.stringify(trackId) + ')');

// ---- Sleep timer ---------------------------------------------------------------------------

// { at } (wall-clock ms) or { track } (pause when this track ends); null when off.
let sleepTimer = null;

function setSleep(arg) {
	if (arg === 'off') sleepTimer = null;
	else if (arg === 'track') {
		if (!state || !state.track) throw new Error('Nothing is playing');
		sleepTimer = { track: state.track.id };
	} else {
		const minutes = Number(arg);
		if (!(minutes > 0)) throw new Error('Bad sleep time ' + arg);
		sleepTimer = { at: Date.now() + minutes * 60000 };
	}
}

// Pauses when the timer runs out, or as the watched track ends (before the next one starts).
function checkSleep() {
	if (!sleepTimer || !state || !state.track) return;
	const playing = state.state === 'PLAYING';
	let due = false;
	if (sleepTimer.at) due = Date.now() >= sleepTimer.at;
	else if (state.track.id !== sleepTimer.track) due = true; // it already moved on
	else if (playing && state.track.length_ms) {
		const position = state.time_s * 1000 + (state.synced_at ? Date.now() - state.synced_at : 0);
		due = state.track.length_ms - position < 400;
	}
	if (!due) return;
	sleepTimer = null;
	if (playing) command('pause', '').catch((error) => log('sleep timer: ' + error.message));
	publish();
}

async function execute(id, op, arg) {
	if (op === 'launch') {
		if (ws) return;
		if (checkApp(true)) return relaunch();
		return launch();
	}
	if (op === 'relaunch') return relaunch();
	if (op === 'sleep') return setSleep(arg);
	if (!ws) throw new Error(checkApp(true) ? 'TIDAL is restarting with remote control' : "TIDAL isn't running");
	// Lookups run alongside other commands; the plugin orders their answers.
	if (op === 'search' || op === 'list' || op === 'lyrics') {
		(op === 'search' ? search(id, arg) : op === 'list' ? list(id, arg) : lyrics(id, arg)).catch(() => {});
		return;
	}
	return command(op, arg);
}

let draining = false;

async function drainInbox() {
	if (draining) return;
	draining = true;
	try {
		let names;
		try {
			names = fs.readdirSync(INBOX).filter((n) => n.endsWith('.cmd')).sort();
		} catch {
			return;
		}
		// Only the newest search of a batch is worth running: typing sends one per pause.
		let lastSearch = -1;
		names.forEach((name, i) => {
			try {
				if (fs.readFileSync(path.join(INBOX, name), 'utf8').startsWith('search ')) lastSearch = i;
			} catch {}
		});
		for (const [index, name] of names.entries()) {
			const file = path.join(INBOX, name);
			let text;
			try {
				text = fs.readFileSync(file, 'utf8').trim();
			} catch {
				continue;
			}
			const id = name.slice(0, -4);
			const stamp = Number(id.split('-')[0]);
			const stale = !stamp || nowS() - stamp > COMMAND_MAX_AGE_S;
			// The plugin can't write atomically; an empty file is one caught between create and write.
			if (!text && !stale) continue;
			try {
				fs.unlinkSync(file);
			} catch {}
			if (stale) continue;
			if (text.startsWith('search ') && index < lastSearch) continue;
			const space = text.indexOf(' ');
			const op = space < 0 ? text : text.slice(0, space);
			const arg = space < 0 ? '' : text.slice(space + 1).trim();
			reply = { id };
			try {
				await execute(id, op, arg);
			} catch (error) {
				reply.error = error.message;
			}
			publish();
		}
	} finally {
		draining = false;
	}
}

// ---- Main ----------------------------------------------------------------------------------

function pluginAgeS() {
	try {
		return nowS() - Number(fs.readFileSync(path.join(data, 'alive'), 'utf8'));
	} catch {
		return Infinity;
	}
}

fs.mkdirSync(INBOX, { recursive: true });
if (!lock()) process.exit(0);

try {
	fs.watch(INBOX, () => drainInbox());
} catch {} // the poll below still picks commands up

setInterval(() => drainInbox(), 250);
setInterval(checkSleep, 200);
setInterval(() => {
	if (Date.now() - started > ORPHAN_AFTER_S * 1000 && pluginAgeS() > ORPHAN_AFTER_S) process.exit(0);
	if (!ws) {
		checkApp(false);
		connect();
		maybeRelaunch();
	} else if (!state && Date.now() - connectedAt > 3000) {
		// Connected but the page hasn't reported: it was replaced before the binding reached it.
		connectedAt = Date.now();
		send('Runtime.addBinding', { name: '__ternTidal' }).then(install).catch((error) => log('reinstall: ' + error.message));
	}
	publish();
}, RECONNECT_MS);
connect().then(publish);
process.on('uncaughtException', (error) => log('uncaught: ' + (error && error.stack ? error.stack : error)));
