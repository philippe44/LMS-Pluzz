package Plugins::FranceTV::ListProtocolHandler;

use strict;

use Slim::Utils::Log;

use Plugins::FranceTV::API;
use Plugins::FranceTV::Plugin;

Slim::Player::ProtocolHandlers->registerHandler('ftplaylist', __PACKAGE__);

my $log = logger('plugin.francetv');

sub canDirectStream { 1 }
sub contentType { 'francetv' }
sub isRemote { 1 }

sub explodePlaylist {
	my ( $class, $client, $url, $cb ) = @_;
	
	my ($channel, $program) = $url =~ m|(?:ftplaylist)://channel=([^&]+)&program=(\S*)|i;
	return undef unless $channel & $program;
	
	Plugins::FranceTV::Plugin->programHandler( sub {
			my $items = shift;
			$items = [ map { $_->{play} } @{$items} ] if $main::VERSION lt '8.2.0';
			$cb->( { items => $items } );
		}, 
		{ index => 1 }, 
		{ channel => $channel, program => $program },
	);	
}	

=comment
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
=cut


1;
