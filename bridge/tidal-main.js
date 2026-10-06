// Runs inside the TIDAL app's main (Electron) process, through the Node inspector that bridge.js
// turns on when TIDAL was started without --remote-debugging-port. It gives the bridge the same
// DevTools protocol access to TIDAL's page that the port would, through Electron's
// webContents.debugger: commands go in through `__ternTidalMain.send`, the page's events come back
// through the `__ternTidalRelay` binding. Evaluating it again (a new bridge) takes over cleanly.
(() => {
	const load = process.mainModule ? process.mainModule.require : require;
	const { webContents } = load('electron');
	const relay = (message) => {
		try {
			globalThis.__ternTidalRelay(JSON.stringify(message));
		} catch {} // no bridge listening
	};

	const main = globalThis.__ternTidalMain || (globalThis.__ternTidalMain = {});
	// Listeners from an earlier bridge would relay everything twice.
	if (main.detach) main.detach();

	const page = () => webContents.getAllWebContents().find((w) => !w.isDestroyed() && /tidal\.com/.test(w.getURL()));

	let attached = null;
	const onMessage = (_event, method, params) => relay({ method, params });
	const onDetach = (_event, reason) => {
		attached = null;
		relay({ detached: String(reason) });
	};

	const attach = () => {
		if (attached && !attached.isDestroyed() && attached.debugger.isAttached()) return attached;
		const contents = page();
		if (!contents) throw new Error("TIDAL's page isn't loaded");
		// Still attached from an earlier bridge that ended without detaching: reuse it.
		if (!contents.debugger.isAttached()) contents.debugger.attach('1.3');
		contents.debugger.on('message', onMessage);
		contents.debugger.on('detach', onDetach);
		attached = contents;
		return contents;
	};

	main.send = (method, params) => attach().debugger.sendCommand(method, params || {});

	// Leaves TIDAL as it was: no debugger on the page, and with `inspector`, no inspector port.
	main.detach = (closeInspector) => {
		if (attached && !attached.isDestroyed()) {
			attached.debugger.removeListener('message', onMessage);
			attached.debugger.removeListener('detach', onDetach);
			try {
				attached.debugger.detach();
			} catch {}
		}
		attached = null;
		if (closeInspector) setTimeout(() => load('inspector').close(), 0);
	};

	attach();
	return process.pid;
})();
