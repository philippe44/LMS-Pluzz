package Plugins::Pluzz::ListProtocolHandler;

use strict;

use Slim::Utils::Log;

use Plugins::Pluzz::API;
use Plugins::Pluzz::Plugin;
use Data::Dumper;

Slim::Player::ProtocolHandlers->registerHandler('pzplaylist', __PACKAGE__);

my $log = logger('plugin.pluzz');

sub overridePlayback {
	my ( $class, $client, $url ) = @_;
		
	if ( $url !~ m|(?:pzplaylist)://channel=([^&]+)&program=(\S*)|i ) {
		return undef;
	}
	
	my ($channel, $program) = ($1, $2);
	
	$log->debug("playlist override $channel, $program");
	
	Plugins::Pluzz::Plugin->searchHandler( sub {
			my $result = shift;
			
			createPlaylist($client, $result); 
			
		}, undef, { channel => $channel, code_programme => $program } );
			
	return 1;
}

sub createPlaylist {
	my ( $client, $items ) = @_;
	my @tracks;
		
	for my $item (@{$items}) {
		push @tracks, Slim::Schema->updateOrCreate( {
				'url'        => $item->{play} });
	}	
	
	$client->execute([ 'playlist', 'clear' ]);
	$client->execute([ 'playlist', 'addtracks', 'listRef', \@tracks ]);
	$client->execute([ 'play' ]);
}

sub canDirectStream {
	return 1;
}

sub contentType {
	return 'pluzz';
}

sub isRemote { 1 }


1;
