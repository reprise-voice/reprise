define(function(require) {
	return {
		api: {
			'default': window.location.origin + '/v2/',
			socket: (window.location.protocol === 'https:' ? 'wss://' : 'ws://') + window.location.host + '/socket'
		},
		whitelabel: {
			companyName: 'Reprise',
			applicationTitle: 'Reprise'
		}
	};
});
