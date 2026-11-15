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
}
