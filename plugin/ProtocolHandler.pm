package Plugins::Pluzz::ProtocolHandler;
use base qw(IO::Handle);

use strict;

use List::Util qw(first);
#use HTML::Parser;
#use URI::Escape;
use JSON::XS;
use Data::Dumper;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;

use Plugins::Pluzz::AsyncSocks;
use Plugins::Pluzz::MPEGTS;

# streaming states
use constant SYNCHRO     => 1;
use constant PIDPAT	     => 2;
use constant PIDPMT	     => 3;
use constant AUDIO	     => 4;

my $log   = logger('plugin.pluzz');
my $prefs = preferences('plugin.pluzz');
my $cache = Slim::Utils::Cache->new;

use constant API_URL => 'http://pluzz.webservices.francetelevisions.fr';
use constant API_URL_GLOBAL => 'http://webservices.francetelevisions.fr';

Slim::Player::ProtocolHandlers->registerHandler('pluzz', __PACKAGE__);

sub new {
	my $class = shift;
	my $args  = shift;
	my $song  = $args->{'song'};
	my $index = 0;
	my ($server, $port) = Slim::Utils::Misc::crackURL(@{$song->pluginData('streams')}[0]->{url});
	my $seekdata   = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
		
	if ( my $newtime = $seekdata->{'timeOffset'} ) {
		my $streams = \@{$args->{song}->pluginData('streams')};
		
		$index = first { $streams->[$_]->{position} >= int $newtime } 0..scalar @$streams;
		
		$song->can('startOffset') ? $song->startOffset($newtime) : ($song->{startOffset} = $newtime);
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $newtime);
	}

	my $self = $class->SUPER::new;
	
	if (defined($self)) {
		${*$self}{'song'}    = $args->{'song'};
		${*$self}{'vars'} = {         # variables which hold state for this instance: (created by "open")
			'inBuf'       => undef,   #  reference to buffer of received packets
			'state'       => SYNCHRO, #  mpeg2ts decoder state
			'index'  	  => $index,  #  current index in fragments
			'fetching'    => 0,		  #  flag for waiting chunk data
			'pos'		  => 0,		  #  position in the latest input buffer
		};
	}

	return $self;
}

sub contentType { 'aac' }
	
sub formatOverride {
	my $class = shift;
	my $song = shift;

	return $song->pluginData('format') || 'aac';
}

sub isAudio { 1 }

sub isRemote { 1 }

sub songBytes { }

sub canSeek { 1 }

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;

	return { timeOffset => $newtime };
}

sub vars {
	return ${*{$_[0]}}{'vars'};
}


sub sysread {
	use bytes;

	my $self  = $_[0];
	# return in $_[1]
	my $maxBytes = $_[2];
	my $v = $self->vars;
		
	# waiting to get next chunk, nothing sor far	
	if ( $v->{'fetching'} ) {
		$! = EINTR;
		return undef;
	}
			
	# end of current segment, get next one
	if ( !defined $v->{'inBuf'} || $v->{'pos'} == length ${$v->{'inBuf'}} ) {
	
		# end of stream
		return 0 if $v->{index} == scalar @{${*$self}{song}->pluginData('streams')};
		
		# get next fragment/chunk
		my $url = @{${*$self}{song}->pluginData('streams')}[$v->{index}]->{url};
		$v->{index}++;
		$v->{'pos'} = 0;
		$v->{'fetching'} = 1;
						
		$log->info("fetching: $url");
			
		Plugins::Pluzz::AsyncSocks->new(
			sub {
				$v->{'inBuf'} = Plugins::Pluzz::AsyncSocks::contentRef($_[0]);
				$v->{'fetching'} = 0;
				$log->debug("got chunk length: ", length ${$v->{'inBuf'}});
			},
			
			sub { 
				$log->warn("error fetching $url");
				$v->{'inBuf'} = undef;
				$v->{'fetching'} = 0;
			}, 
			
		)->get($url);
			
		$! = EINTR;
		return undef;
	}	
				
	my $len;
	
	$len = Plugins::Pluzz::MPEGTS::processTS($v, \$_[1], $maxBytes) if defined $v->{inBuf};
			
	return $len if $len;
	
	$! = EINTR;
	return undef;
}


sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	my $url 	 = $song->track()->url;
	my $client   = $song->master();
	my ($id)	 = $class->getId($url);

	$log->info("getNextTrack : $url (id: $id)");
	
	if (!$id) {
		$errorCb->();
		return;
	}	
			
	getFragments( 
	
		sub {
			my $fragments = shift;
			my $bitrate = shift;
					
			return $errorCb->() unless (defined $fragments && scalar @$fragments);
			
			my ($server) = Slim::Utils::Misc::crackURL( $fragments->[0]->{url} );
						
			$song->pluginData(streams => $fragments);	
			$song->pluginData(stream  => $server);
			$song->pluginData(format  => 'aac');
			$song->track->secs( $fragments->[scalar @$fragments - 1]->{position} );
			$song->track->bitrate( $bitrate );
			$song->track->samplerate( 48000 );
			$class->getMetadataFor($client, $url, undef, $song);
			
			$successCb->();
		} , $id 
		
	);
}	


sub getFragments {
	my ($cb, $id) = @_;
	my $url = API_URL_GLOBAL . "/tools/getInfosOeuvre/v2/?catalogue=Pluzz&idDiffusion=$id";
		
	$log->debug("getting master url for : $id");
	
	Plugins::Pluzz::AsyncSocks->new ( 
		sub {
			my $result = decode_json(shift->content);
			my $master = first { $_->{format} eq 'm3u8-download' } @{$result->{videos}};
			
			$log->debug("master url: $master->{url}");
			
			getFragmentsUrl($cb, $master->{url});
		},

		sub {
			$cb->(undef);
		},

	)->get($url);
}


sub getFragmentsUrl {
	my ($cb, $url) = @_;
				
	Plugins::Pluzz::AsyncSocks->new ( 
		sub {
			my $result = shift->content;
			my $bitrate;
			my $fragmentUrl;
				
			for my $item ( split (/#EXT-X-STREAM-INF:/, $result) ) {
				next if ($item !~ m/BANDWIDTH=(\d+),([\S\s]*)(http\S*)/s); 
					
				if (!defined $bitrate || $1 < $bitrate) {
					$bitrate = $1;
					$fragmentUrl = $3;
				}
			}
			
			$log->debug("fragment url: $fragmentUrl");
			
			getFragmentList($cb, $fragmentUrl, $bitrate);
		},
			
		sub {
			$cb->(undef);
		}
		
	)->get($url);
}	


sub getFragmentList {
	my ($cb, $url, $bitrate) = @_;
			
	Plugins::Pluzz::AsyncSocks->new ( 
		sub {
			my $fragmentList = shift->content;
			my @fragments;
			my $position = 0;
					
			$log->debug("got fragment list: $fragmentList");
			
			for my $item ( split (/#EXTINF:/, $fragmentList) ) {
				$item =~ m/([^,]+),([\S\s]*)(http\S*)/s;
				$position += $1 if $3;
				push @fragments, { position => $position, url => $3 } if $3;
			}	
									
			$cb->(\@fragments, $bitrate);
		},	
			
		sub {
			$cb->(undef);
		}
					
	)->get($url);
}	


sub suppressPlayersMessage {
	my ($class, $client, $song, $string) = @_;

	# suppress problem opening message if we have more streams to try
	if ($string eq 'PROBLEM_OPENING' && scalar @{$song->pluginData('streams') || []}) {
		return 1;
	}

	return undef;
}


sub getMetadataFor {
	my ($class, $client, $url, undef, $song) = @_;
	my $icon = $class->getIcon();
	
	main::DEBUGLOG && $log->debug("getmetadata: $url");
			
	my ($id, $channel, $program) = $class->getId($url);
	return unless $id && $channel && $program;
	
	if (my $meta = $cache->get("pz:meta-$id")) {
		$song->track->secs($meta->{'duration'}) if $song;
				
		Plugins::Pluzz::Plugin->updateRecentlyPlayed({
			url   => $url, 
			name  => $meta->{_fulltitle} || $meta->{title}, 
			icon  => $meta->{icon},
		});

		main::DEBUGLOG && $log->debug("cache hit: $id");
		
		return $meta;
	}
	
	Plugins::Pluzz::API->searchEpisode( sub {
		my $result = shift;
		my $item = 	first { $_->{id_diffusion} eq $id } @{$result || []};
						
		$song->track->secs($item->{duree_reelle}) if $song;
				
		if ($client) {
			$client->currentPlaylistUpdateTime( Time::HiRes::time() );
			Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
		}	
						
	}, { channel => $channel, code_programme => $program } );
	
	return {	
			type	=> 'Pluzz',
			title	=> "Pluzz",
			icon	=> $icon,
			cover	=> $icon,
	};
}	
	
sub getIcon {
	my ( $class, $url ) = @_;

	return Plugins::Pluzz::Plugin->_pluginDataFor('icon');
}


sub getId {
	my ($class, $url) = @_;

	if ($url =~ m|pluzz://([^&]+)&channel=([^&]+)&program=(\S*)|) {
		return ($1, $2, $3);
	}
		
	return undef;
}


1;
