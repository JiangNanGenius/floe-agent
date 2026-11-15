if (typeof ENVIRONMENT_IS_PTHREAD === 'undefined' || !ENVIRONMENT_IS_PTHREAD) {
	Module.addRunDependency('IDBFS_sync');
	FS.mkdir('/home/web_user/love');
	FS.mount(IDBFS, {}, '/home/web_user/love');

	FS.syncfs(true, function (err) {
	  if (err) {
	    Module['printErr'](err);
	  } else {
	    Module.removeRunDependency('IDBFS_sync');
	  }
	});
  
	window.addEventListener('beforeunload', function(event) {
		FS.syncfs(false, function (err) {
			if (err) {
				Module['printErr'](err);
			}
		});	
	});

	// Floe: WebKit may tear down the player without firing beforeunload.
	// Expose an explicit flush and also flush on pagehide/visibilitychange.
	Module["flushSave"] = function (callback) {
		var finished = false;
		function finish(err) {
			if (finished) { return; }
			finished = true;
			if (typeof callback === "function") { callback(err || null); }
		}
		try { FS.syncfs(false, finish); } catch (e) { finish(e); }
	};

	function floeSync() {
		try { FS.syncfs(false, function () {}); } catch (e) {}
	}
	window.addEventListener("pagehide", floeSync);
	document.addEventListener("visibilitychange", function () {
		if (document.visibilityState === "hidden") { floeSync(); }
	});

	// Flush after a save file is closed, not only at teardown. This covers
	// love.filesystem.write followed by an app stop before the next event.
	var floeClose = FS.close;
	FS.close = function (stream) {
		var result = floeClose.apply(FS, arguments);
		try {
			if (stream && typeof stream.path === "string" &&
					stream.path.indexOf("/home/web_user/love/") === 0) {
				FS.syncfs(false, function () {});
			}
		} catch (e) {}
		return result;
	};

	// Backstop for writes that do not close a stream promptly.
	setInterval(floeSync, 2000);
}
