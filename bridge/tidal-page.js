// Runs inside the TIDAL desktop app's page (evaluated over the DevTools protocol by the bridge).
// TIDAL's UI keeps all player state in a Redux store; this finds it through React's fiber tree,
// reports every change through the `__ternTidal` binding the bridge registered, and exposes
// `__ternTidalCommand(op, arg)` for the bridge to drive playback with TIDAL's own actions.
(() => {
	// Bump with any change here, so a newer bridge replaces what an older one installed.
	const VERSION = 19;
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

	const coverUrl = (id) => (id ? 'https://resources.tidal.com/images/' + id.replace(/-/g, '/') + '/640x640.jpg' : null);

	const artists = (media) => (media.artists || []).map((a) => a.name).join(', ');
	const titled = (media) => media.title + (media.version ? ' (' + media.version + ')' : '');
	const mainArtistId = (media) => {
		const list = media.artists || [];
		const main = list.find((a) => a.type === 'MAIN') || list[0];
		return main && main.id ? String(main.id) : null;
	};

	// ISO 8601 durations from the open API ("PT5M26S") in seconds.
	const isoSeconds = (text) => {
		const m = /^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$/.exec(text || '');
		return m ? (+m[1] || 0) * 3600 + (+m[2] || 0) * 60 + (+m[3] || 0) : null;
	};

	// Queue entries whose track TIDAL never stored (added by older versions of this plugin, say) can't
	// play and don't show in TIDAL's own queue. Their tracks are fetched, a few at a time, and stored
	// the way TIDAL stores its own; a track that fails to fetch isn't asked for again.
	const FETCH_AT_ONCE = 4;
	const wanted = [];
	const asked = new Set();
	let fetching = 0;

	const pump = () => {
		while (fetching < FETCH_AT_ONCE && wanted.length > 0) {
			const id = wanted.shift();
			fetching++;
			v1('tracks/' + id)
				.then((t) => storeTracks([t]))
				.catch(() => {})
				.then(() => {
					fetching--;
					pump();
					if (window.__ternTidalEmit) window.__ternTidalEmit();
				});
		}
	};

	const fetchTrack = (id) => {
		if (asked.has(id)) return;
		asked.add(id);
		wanted.push(id);
		pump();
	};

	// Asks for every queue entry's track that TIDAL hasn't stored.
	const fillQueue = (s) => {
		const known = s.content.mediaItems;
		for (const element of s.playQueue.elements || []) {
			const id = String(element.mediaItemId);
			if (!known[id]) fetchTrack(id);
		}
	};

	// A queued track's details: from TIDAL's store, else from the open-API entities (title and length
	// only), else null until it's fetched (see `fillQueue`).
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
		fillQueue(s);
		const queue = s.playQueue;
		const elements = queue.elements || [];
		const from = Math.max(0, queue.currentIndex - QUEUE_BEFORE);
		const to = Math.min(elements.length, queue.currentIndex + 1 + QUEUE_AFTER);
		const items = [];
		for (let i = from; i < to; i++) {
			const known = queuedTrack(s, String(elements[i].mediaItemId));
			items.push({
				uid: elements[i].uid,
				id: String(elements[i].mediaItemId),
				title: known ? known.title : null,
				artist: known ? known.artist : '',
				length_s: known ? known.length_s : null,
			});
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
						// For the artist and album lists and radio.
						artist_id: mainArtistId(media),
						album_id: media.album && media.album.id ? String(media.album.id) : null,
						liked: !!(s.favorites && (s.favorites.tracks || []).some((t) => String(t) === String(id))),
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
		throw new Error("Couldn't find TIDAL's sign-in");
	};

	// A GET against TIDAL's API with the app's own sign-in and country.
	const api = async (base, path, accept) => {
		const { token } = await (await findCredentials()).getCredentials();
		const country = store.getState().session.countryCode;
		const url = base + path + (path.includes('?') ? '&' : '?') + 'countryCode=' + encodeURIComponent(country);
		const headers = { Authorization: 'Bearer ' + token };
		if (accept) headers.Accept = accept;
		const response = await fetch(url, { headers });
		if (!response.ok) throw new Error('TIDAL answered ' + response.status);
		return response.json();
	};
	const v1 = (path) => api('https://api.tidal.com/v1/', path);
	const openApi = (path) => api('https://openapi.tidal.com/v2/', path, 'application/vnd.api+json');

	const trackItem = (t) => ({ kind: 'track', id: String(t.id), title: titled(t), detail: artists(t), length_s: t.duration });

	// Puts tracks (v1 API objects) into TIDAL's content store, as its own track fetch does. TIDAL can
	// only play a queue entry whose track is there; its queue actions don't load tracks themselves.
	const storeTracks = (tracks) => {
		const known = store.getState().content.mediaItems;
		for (const item of tracks) {
			if (known[String(item.id)]) continue;
			dispatch('content/LOAD_SINGLE_MEDIA_ITEM_SUCCESS', { mediaItem: { item: { ...item, contentType: 'track' }, type: 'track' } });
		}
	};

	// Makes sure TIDAL has this track's details before it's played from the queue.
	const ensureTrack = async (id) => {
		if (!store.getState().content.mediaItems[String(id)]) storeTracks([await v1('tracks/' + id)]);
	};

	// The tracks an item adds to the queue (itself, or an album's tracks), stored so they can play.
	const trackIds = async (kind, id) => {
		let tracks;
		if (kind === 'track') tracks = [await v1('tracks/' + id)];
		else if (kind === 'album') tracks = (await v1('albums/' + id + '/tracks?limit=100')).items;
		else throw new Error('Only tracks and albums can be queued');
		storeTracks(tracks);
		return tracks.map((t) => t.id);
	};

	const currentId = (s) => s.playbackControls.mediaProduct && s.playbackControls.mediaProduct.productId;

	// Starts a mix as radio without interrupting the song that's playing: the queue becomes the
	// current track followed by the mix (TIDAL's own PLAY_MIX restarts from the mix's first track,
	// which for a track radio is the same song from the start). `name` labels the queue's source.
	const playRadio = async (s, mixId, name) => {
		const queue = s.playQueue;
		const current = currentId(s);
		if (!current || queue.type === 'cloudV2' || !(queue.elements || [])[queue.currentIndex]) {
			return dispatch('mix/PLAY_MIX', { mixId });
		}
		const items = (await v1('mixes/' + mixId + '/items?limit=100')).items || [];
		const tracks = items.filter((i) => i.type === 'track' && i.item && i.item.allowStreaming !== false && String(i.item.id) !== String(current));
		if (tracks.length === 0) throw new Error('TIDAL has no tracks in this radio');
		storeTracks(tracks.map((t) => t.item));
		// Radio is an ordered list, like TIDAL's own list plays (which turn shuffle off too).
		if (queue.shuffleModeEnabled) dispatch('playQueue/DISABLE_SHUFFLE_MODE');
		dispatch('playQueue/CLEAR_UPCOMING');
		// As ordinary list entries (`priority_none`), the way a played list's tracks are. ADD_LAST would
		// mark them as added by you (`priority_keep`), and TIDAL keeps those in front of the next list
		// you start.
		const batch = Date.now().toString(16);
		dispatch('playQueue/APPEND_ELEMENTS', {
			elements: tracks.map((t, i) => ({
				context: { id: mixId, type: 'mix' },
				mediaItemId: t.item.id,
				priority: 'priority_none',
				uid: 'pq__' + batch + '__r' + i,
			})),
		});
		dispatch('playQueue/SET_SOURCE_PROPERTIES', {
			entityId: mixId,
			entityType: 'mix',
			limit: queue.sourceLimit,
			name,
			trackListName: 'mixes/' + mixId,
			url: '/mix/' + mixId,
		});
		// CLEAR_UPCOMING drops TIDAL's preloaded next track and appending doesn't line up a new one;
		// without this the song ends and playback stops instead of moving on to the radio.
		dispatch('player/PRELOAD_NEXT_ITEM');
	};

	window.__ternTidalCommand = async (op, arg) => {
		if (!store) throw new Error('TIDAL is still loading');
		const s = store.getState();
		const [first, second] = String(arg).split(' ');
		switch (op) {
			case 'toggle':
				return dispatch(s.playbackControls.playbackState === 'PLAYING' ? 'playbackControls/PAUSE' : 'playbackControls/PLAY');
			case 'pause':
				return dispatch('playbackControls/PAUSE');
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
			case 'like': {
				// What TIDAL's heart does: toggles the current track in your collection.
				const id = currentId(s);
				if (!id) throw new Error('Nothing is playing');
				return dispatch('content/TOGGLE_FAVORITE_ITEMS', { from: 'heart', items: [{ itemId: parseInt(id, 10), itemType: 'track' }], moduleId: undefined });
			}
			case 'jump': {
				// To the queue entry at this index; what clicking a row in TIDAL's own queue does.
				const index = Number(arg);
				const length = (s.playQueue.elements || []).length;
				if (!Number.isInteger(index) || index < 0 || index >= length) throw new Error('No queue entry ' + arg);
				// Entries added before tracks were stored on the way in can't play until their track is.
				await ensureTrack(s.playQueue.elements[index].mediaItemId);
				return dispatch('playQueue/MOVE_TO', index);
			}
			case 'remove': {
				// `<uid>` of a queue entry.
				if (!(s.playQueue.elements || []).some((e) => e.uid === arg)) throw new Error('That entry left the queue');
				dispatch('playQueue/REMOVE_ELEMENT', { uid: arg });
				// The removed entry may be the track TIDAL had lined up next.
				return dispatch('player/PRELOAD_NEXT_ITEM');
			}
			case 'move': {
				// `<from> <to>` queue indices.
				const from = Number(first), to = Number(second);
				const length = (s.playQueue.elements || []).length;
				if (![from, to].every((n) => Number.isInteger(n) && n >= 0 && n < length)) throw new Error('No queue entry there');
				// TIDAL's `toIndex` is the gap the entry is dropped into (before the entry there), so
				// moving down lands one further than the final position.
				dispatch('playQueue/MOVE_TRACK', { fromIndex: from, toIndex: to > from ? to + 1 : to });
				// What plays next may have changed.
				return dispatch('player/PRELOAD_NEXT_ITEM');
			}
			case 'queue-next':
			case 'queue-last': {
				// `<kind> <id>`: after the current track, or at the end, as TIDAL's "Play next" / "Add to queue".
				const mediaItemIds = await trackIds(first, second);
				const context = first === 'album' ? { id: second, type: 'album' } : { type: 'search' };
				return op === 'queue-next'
					? dispatch('playQueue/ADD_NEXT', { context, mediaItemIds, offset: 0 })
					: dispatch('playQueue/ADD_LAST', { context, mediaItemIds });
			}
			case 'radio': {
				// The current track's radio (TIDAL's track mix); the song keeps playing and the mix follows.
				const id = currentId(s);
				const item = id && s.content.mediaItems[id] && s.content.mediaItems[id].item;
				const tracks = s.entities.tracks && s.entities.tracks.entities;
				const related = id && tracks && tracks[id] && tracks[id].relationships;
				const mixId = (item && item.mixes && item.mixes.TRACK_MIX)
					|| (related && related.radio && related.radio.data && related.radio.data[0] && related.radio.data[0].id);
				if (!mixId) throw new Error('TIDAL has no radio for this track');
				const entity = tracks && tracks[id] && tracks[id].attributes;
				return playRadio(s, mixId, (item && titled(item)) || (entity && titled(entity)) || 'Track radio');
			}
			case 'artist-radio': {
				// `<artist id>`: the artist's mix, after the song that's playing.
				const artist = await v1('artists/' + arg);
				const mixId = artist.mixes && artist.mixes.ARTIST_MIX;
				if (!mixId) throw new Error('TIDAL has no radio for this artist');
				return playRadio(s, mixId, artist.name || 'Artist radio');
			}
			case 'play': {
				// `<kind> <id>` from a search result or list; the same actions TIDAL's own search uses.
				// Either way the queue starts over: nothing from before stays after the new item.
				if (!second) throw new Error('Bad item ' + arg);
				if (first === 'track') {
					// TIDAL's track play keeps entries you added (play next / add to queue) after the new
					// song. Clearing first makes the new song the whole queue; it's checked first so a song
					// that can't play doesn't cost you the queue.
					const track = await v1('tracks/' + second);
					if (track.allowStreaming === false) throw new Error("TIDAL can't play this track");
					dispatch('playQueue/CLEAR_UPCOMING');
					return dispatch('content/FETCH_AND_PLAY_MEDIA_ITEM', { itemId: second, itemType: 'track', sourceContext: { type: 'search' } });
				}
				if (first !== 'album' && first !== 'playlist' && first !== 'artist') throw new Error('Bad item ' + arg);
				return dispatch('playQueue/ADD_TRACK_LIST_TO_PLAY_QUEUE', {
					clearActives: true,
					context: { id: second, type: first },
					disableShuffle: true,
					forceShuffle: false,
					position: 'now',
					trackListName: first === 'artist' ? 'artists/' + second + '/toptracks' : first + 's/' + second,
				});
			}
			default:
				throw new Error('Unknown command ' + op);
		}
	};

	// Tracks, then albums, artists and playlists: one line each.
	window.__ternTidalSearch = async (query) => {
		if (!store) throw new Error('TIDAL is still loading');
		const found = await v1('search/top-hits?types=TRACKS,ALBUMS,ARTISTS,PLAYLISTS&limit=8&offset=0&query=' + encodeURIComponent(query));
		const items = (key) => (found[key] && found[key].items) || [];
		return [
			...items('tracks').map(trackItem),
			...items('albums').map((a) => ({ kind: 'album', id: String(a.id), title: titled(a), detail: artists(a) })),
			...items('artists').slice(0, 3).map((a) => ({ kind: 'artist', id: String(a.id), title: a.name, detail: '' })),
			...items('playlists').slice(0, 5).map((p) => ({ kind: 'playlist', id: p.uuid, title: p.title, detail: (p.creator && p.creator.name) || '' })),
		];
	};

	const ARTIST_TOP = 20;

	// An artist's top tracks or an album's tracks, as `{ title, items }`.
	window.__ternTidalList = async (kind, id) => {
		if (!store) throw new Error('TIDAL is still loading');
		if (kind === 'artist') {
			const [artist, top] = await Promise.all([v1('artists/' + id), v1('artists/' + id + '/toptracks?limit=' + ARTIST_TOP)]);
			return { title: artist.name, subtitle: 'top tracks', items: top.items.map(trackItem) };
		}
		if (kind === 'album') {
			const [album, tracks] = await Promise.all([v1('albums/' + id), v1('albums/' + id + '/tracks?limit=100')]);
			return { title: titled(album), subtitle: artists(album), items: tracks.items.map(trackItem) };
		}
		throw new Error('No list for ' + kind);
	};

	// A track's lyrics: `{ lines: [{ ms, text }] }` when TIDAL has them synced, `{ text }` when
	// plain, `{}` when none.
	window.__ternTidalLyrics = async (id) => {
		if (!store) throw new Error('TIDAL is still loading');
		const found = await openApi('tracks/' + id + '/relationships/lyrics?include=lyrics');
		const lyrics = (found.included || []).find((r) => r.type === 'lyrics');
		const attrs = lyrics && lyrics.attributes;
		if (!attrs) return {};
		if (attrs.lrcText) {
			const lines = [];
			for (const line of attrs.lrcText.split('\n')) {
				const m = /^\[(\d+):(\d+(?:\.\d+)?)\](.*)$/.exec(line.trim());
				if (m) lines.push({ ms: Math.round((Number(m[1]) * 60 + Number(m[2])) * 1000), text: m[3].trim() });
			}
			if (lines.length) return { lines, provider: attrs.provider || null };
		}
		return attrs.text ? { text: attrs.text, provider: attrs.provider || null } : {};
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
