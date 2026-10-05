// Runs inside the TIDAL desktop app's page (evaluated over the DevTools protocol by the bridge).
// TIDAL's UI keeps all player state in a Redux store; this finds it through React's fiber tree,
// reports every change through the `__ternTidal` binding the bridge registered, and exposes
// `__ternTidalCommand(op, arg)` for the bridge to drive playback with TIDAL's own actions.
(() => {
	// Bump with any change here, so a newer bridge replaces what an older one installed.
	const VERSION = 6;
	if (window.__ternTidalVersion === VERSION) {
		// Installed already: report again, for a bridge that just (re)connected.
		window.__ternTidalEmit();
		return 'installed';
	}
	if (window.__ternTidalDispose) window.__ternTidalDispose();
	window.__ternTidalVersion = VERSION;

	const findStore = () => {
		// The bridge also installs this before TIDAL's page has a body.
		if (!document.body) return null;
		for (const element of document.body.querySelectorAll('*')) {
			const key = Object.keys(element).find((k) => k.startsWith('__reactFiber'));
			for (let fiber = key && element[key]; fiber; fiber = fiber.return) {
				const store = fiber.memoizedProps && fiber.memoizedProps.store;
				if (store && store.dispatch && store.getState) return store;
			}
		}
		return null;
	};

	const REPEAT = ['off', 'all', 'one'];
	let store = null;
	let last = '';

	const coverUrl = (id) => (id ? 'https://resources.tidal.com/images/' + id.replace(/-/g, '/') + '/320x320.jpg' : null);

	const artists = (media) => (media.artists || []).map((a) => a.name).join(', ');
	const titled = (media) => media.title + (media.version ? ' (' + media.version + ')' : '');

	// ISO 8601 durations from the open API ("PT5M26S") in seconds.
	const isoSeconds = (text) => {
		const m = /^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$/.exec(text || '');
		return m ? (+m[1] || 0) * 3600 + (+m[2] || 0) * 60 + (+m[3] || 0) : null;
	};

	// A queued track's details: from the classic catalog when TIDAL loaded them there, else from the
	// open-API entities (title and length only), else unknown.
	const queuedTrack = (s, id) => {
		const item = s.content.mediaItems[id] && s.content.mediaItems[id].item;
		if (item) return { title: titled(item), artist: artists(item), length_s: item.duration || null };
		const tracks = s.entities.tracks && s.entities.tracks.entities;
		const entity = tracks && tracks[id] && tracks[id].attributes;
		if (entity) return { title: titled(entity), artist: '', length_s: isoSeconds(entity.duration) };
		return null;
	};

	// The track after the current one in the queue, when TIDAL has loaded its details.
	const upNext = (s) => {
		const queue = s.playQueue;
		const element = queue.elements && queue.elements[queue.currentIndex + 1];
		const next = element && queuedTrack(s, String(element.mediaItemId));
		return next ? { title: next.title, artist: next.artist } : null;
	};

	const QUEUE_BEFORE = 2;
	const QUEUE_AFTER = 40;

	// The queue around the current track: a couple already played, then what comes up.
	const queueWindow = (s) => {
		const queue = s.playQueue;
		const elements = queue.elements || [];
		const from = Math.max(0, queue.currentIndex - QUEUE_BEFORE);
		const to = Math.min(elements.length, queue.currentIndex + 1 + QUEUE_AFTER);
		const items = [];
		for (let i = from; i < to; i++) {
			const known = queuedTrack(s, String(elements[i].mediaItemId));
			items.push({ title: known ? known.title : null, artist: known ? known.artist : '', length_s: known ? known.length_s : null });
		}
		return { current: queue.currentIndex - from, total: elements.length, position: queue.currentIndex, items };
	};

	// "24-bit 48 kHz FLAC", from what the player actually streams.
	const format = (context) => {
		const parts = [];
		if (context.bitDepth) parts.push(context.bitDepth + '-bit');
		if (context.sampleRate) parts.push(+(context.sampleRate / 1000).toFixed(1) + ' kHz');
		if (context.codec) parts.push(String(context.codec).toUpperCase());
		return parts.join(' ') || null;
	};

	const snapshot = () => {
		const s = store.getState();
		const pc = s.playbackControls;
		const queue = s.playQueue;
		const id = pc.mediaProduct && pc.mediaProduct.productId;
		const media = id && s.content.mediaItems[id] && s.content.mediaItems[id].item;
		const context = pc.playbackContext || {};
		return {
			track: media
				? {
						id: String(id),
						title: titled(media),
						artist: artists(media),
						album: (media.album && media.album.title) || '',
						length_ms: Math.round((context.actualDuration || media.duration || 0) * 1000) || null,
						cover: coverUrl(media.album && media.album.cover),
					}
				: null,
			next: upNext(s),
			queue: queueWindow(s),
			// PLAYING, NOT_PLAYING, STALLED, ...
			state: pc.playbackState,
			// The position TIDAL last synced, and the wall-clock ms when it did.
			time_s: pc.latestCurrentTime,
			synced_at: pc.latestCurrentTimeSyncTimestamp,
			shuffle: !!queue.shuffleModeEnabled,
			repeat: REPEAT[queue.repeatMode] || 'off',
			volume: pc.volume,
			muted: !!pc.muted,
			quality: context.actualAudioQuality || null,
			format: format(context),
			source: queue.sourceName || null,
		};
	};

	const emit = () => {
		// Before the store is found, or before the bridge's binding reaches this document.
		if (!store || typeof window.__ternTidal !== 'function') return;
		const text = JSON.stringify(snapshot());
		if (text !== last) {
			last = text;
			window.__ternTidal(text);
		}
	};
	window.__ternTidalEmit = () => {
		last = '';
		emit();
	};

	const dispatch = (type, payload) => store.dispatch(payload === undefined ? { type } : { type, payload });

	window.__ternTidalCommand = (op, arg) => {
		if (!store) throw new Error('TIDAL is still loading');
		const s = store.getState();
		switch (op) {
			case 'toggle':
				return dispatch(s.playbackControls.playbackState === 'PLAYING' ? 'playbackControls/PAUSE' : 'playbackControls/PLAY');
			case 'next':
				return dispatch('playbackControls/SKIP_NEXT');
			case 'prev':
				return dispatch('playbackControls/SKIP_PREVIOUS');
			case 'seek':
				return dispatch('playbackControls/SEEK', Math.max(0, Number(arg)) / 1000);
			case 'shuffle':
				if (s.playQueue.shuffleModeEnabled !== (arg === 'on')) dispatch('playQueue/TOGGLE_SHUFFLE');
				return;
			case 'repeat': {
				// Toggling cycles off → all → one.
				const want = REPEAT.indexOf(arg);
				if (want < 0) throw new Error('Bad repeat mode ' + arg);
				for (let i = 0; i < 3 && store.getState().playQueue.repeatMode !== want; i++) dispatch('playQueue/TOGGLE_REPEAT_MODE');
				return;
			}
			case 'volume':
				return dispatch('playbackControls/SET_VOLUME', { volume: Math.max(0, Math.min(100, Number(arg))) });
			case 'mute':
				if (!!s.playbackControls.muted !== (arg === 'on')) dispatch('playbackControls/TOGGLE_MUTE');
				return;
			case 'radio': {
				// The current track's radio (TIDAL's track mix), played the way TIDAL's "Go to track radio" does.
				const id = s.playbackControls.mediaProduct && s.playbackControls.mediaProduct.productId;
				const item = id && s.content.mediaItems[id] && s.content.mediaItems[id].item;
				const tracks = s.entities.tracks && s.entities.tracks.entities;
				const related = id && tracks && tracks[id] && tracks[id].relationships;
				const mixId = (item && item.mixes && item.mixes.TRACK_MIX)
					|| (related && related.radio && related.radio.data && related.radio.data[0] && related.radio.data[0].id);
				if (!mixId) throw new Error('TIDAL has no radio for this track');
				return dispatch('mix/PLAY_MIX', { mixId });
			}
			case 'play': {
				// `<kind> <id>` from a search result; the same actions TIDAL's own search uses.
				const [kind, id] = String(arg).split(' ');
				if (!id) throw new Error('Bad item ' + arg);
				if (kind === 'track') return dispatch('content/FETCH_AND_PLAY_MEDIA_ITEM', { itemId: id, itemType: 'track', sourceContext: { type: 'search' } });
				if (kind !== 'album' && kind !== 'playlist' && kind !== 'artist') throw new Error('Bad item ' + arg);
				return dispatch('playQueue/ADD_TRACK_LIST_TO_PLAY_QUEUE', {
					clearActives: true,
					context: { id, type: kind },
					disableShuffle: true,
					forceShuffle: false,
					position: 'now',
					trackListName: kind === 'artist' ? 'artists/' + id + '/toptracks' : kind + 's/' + id,
				});
			}
			default:
				throw new Error('Unknown command ' + op);
		}
	};

	// TIDAL's credentials provider lives in one of its bundled modules; importing an already-loaded
	// module URL returns the same instance. The token never leaves the page.
	let credentials = null;
	const findCredentials = async () => {
		if (credentials) return credentials;
		const urls = performance.getEntriesByType('resource').map((e) => e.name).filter((u) => /\/assets\/[^/]+\.js$/.test(u));
		for (const url of urls) {
			let mod;
			try {
				mod = await import(url);
			} catch {
				continue;
			}
			for (const value of Object.values(mod)) {
				const provider = value && typeof value === 'object' && value.credentialsProvider;
				if (provider && typeof provider.getCredentials === 'function') return (credentials = provider);
			}
		}
		throw new Error("Couldn't find TIDAL's sign-in to search with");
	};

	// Tracks, then albums, artists and playlists: one line each.
	window.__ternTidalSearch = async (query) => {
		if (!store) throw new Error('TIDAL is still loading');
		const { token } = await (await findCredentials()).getCredentials();
		const country = store.getState().session.countryCode;
		const url = 'https://api.tidal.com/v1/search/top-hits?types=TRACKS,ALBUMS,ARTISTS,PLAYLISTS&limit=8&offset=0'
			+ '&countryCode=' + encodeURIComponent(country) + '&query=' + encodeURIComponent(query);
		const response = await fetch(url, { headers: { Authorization: 'Bearer ' + token } });
		if (!response.ok) throw new Error('TIDAL search failed (' + response.status + ')');
		const found = await response.json();
		const items = (key) => (found[key] && found[key].items) || [];
		return [
			...items('tracks').map((t) => ({ kind: 'track', id: String(t.id), title: titled(t), detail: artists(t), length_s: t.duration })),
			...items('albums').map((a) => ({ kind: 'album', id: String(a.id), title: titled(a), detail: artists(a) })),
			...items('artists').slice(0, 3).map((a) => ({ kind: 'artist', id: String(a.id), title: a.name, detail: '' })),
			...items('playlists').slice(0, 5).map((p) => ({ kind: 'playlist', id: p.uuid, title: p.title, detail: (p.creator && p.creator.name) || '' })),
		];
	};

	let unsubscribe = null;
	let retry = null;
	const attach = () => {
		store = findStore();
		if (!store) {
			retry = setTimeout(attach, 500);
			return;
		}
		unsubscribe = store.subscribe(emit);
		emit();
	};
	window.__ternTidalDispose = () => {
		clearTimeout(retry);
		if (unsubscribe) unsubscribe();
	};
	attach();
	return 'installed';
})();
