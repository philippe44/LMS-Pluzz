package Plugins::FranceTV::ListProtocolHandler;

use strict;

use Slim::Utils::Log;

use Plugins::FranceTV::API;
use Plugins::FranceTV::Plugin;

Slim::Player::ProtocolHandlers->registerHandler('ftplaylist', __PACKAGE__);

my $log = logger('plugin.francetv');

sub overridePlayback {
	my ( $class, $client, $url ) = @_;
		
	if ( $url !~ m|(?:ftplaylist)://channel=([^&]+)&program=(\S*)|i ) {
		return undef;
	}
	
	my ($channel, $program) = ($1, $2);
	
	$log->debug("playlist override $channel, $program");
	
	Plugins::FranceTV::Plugin->programHandler( sub {
			my $result = shift;
			createPlaylist($client, $result); 	
		}, undef, { channel => $channel, program => $program } );
			
	return 1;
}

sub createPlaylist {
	my ( $client, $items ) = @_;
	my @tracks;
		
	for my $item (@{$items}) {
		push @tracks, Slim::Schema->updateOrCreate( {
				'url' => $item->{play} 
			});
	}	
	
	$client->execute([ 'playlist', 'clear' ]);
	$client->execute([ 'playlist', 'addtracks', 'listRef', \@tracks ]);
	$client->execute([ 'play' ]);
}

sub canDirectStream {
	return 1;
}

sub contentType {
	return 'francetv';
}

sub isRemote { 1 }


1;
