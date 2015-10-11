package Plugins::Pluzz::Settings;
use base qw(Slim::Web::Settings);

use strict;

use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log = logger('plugin.pluzz');

sub name {
	return 'PLUGIN_PLUZZ';
}

sub page {
	return 'plugins/Pluzz/settings/basic.html';
}

sub prefs {
	return (preferences('plugin.pluzz'), qw(socks socks_server socks_port no_cache));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;
	
	$callback->($client, $params, $class->SUPER::handler($client, $params), @args);
}

	
1;
