package Plugins::FranceTV::Settings;
use base qw(Slim::Web::Settings);

use strict;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Plugins::FranceTV::API;

my $prefs = preferences('plugin.francetv');
my $log = logger('plugin.francetv');

sub name {
	return 'PLUGIN_FRANCETV';
}

sub page {
	return 'plugins/FranceTV/settings/basic.html';
}

sub prefs {
	return (preferences('plugin.francetv'), qw(socks socksProxy socksUsername socksPassword no_cache));
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup) = @_;
	
	if ($paramRef->{'saveSettings'}) {
		$paramRef->{'pref_socksUsername'} = obfuscate($paramRef->{'pref_socksUsername'});
		$paramRef->{'pref_socksPassword'} = obfuscate($paramRef->{'pref_socksPassword'});
	}
	
	return $class->SUPER::handler($client, $paramRef, $pageSetup);
}

sub beforeRender  {
	my ($class, $paramRef) = @_;
	$paramRef->{'prefs'}->{'pref_socksUsername'} = deobfuscate($prefs->get('socksUsername'));
	$paramRef->{'prefs'}->{'pref_socksPassword'} = deobfuscate($prefs->get('socksPassword'));
}
	
1;
