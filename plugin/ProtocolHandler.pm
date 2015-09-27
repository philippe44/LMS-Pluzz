package Plugins::Pluzz::ProtocolHandler;
use base qw(Slim::Formats::RemoteStream);

use strict;

use List::Util qw(min max first);
use HTML::Parser;
use URI::Escape;
use Scalar::Util qw(blessed);
use JSON::XS;
use Data::Dumper;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;

use constant MAX_INBUF  => 102400;
use constant MAX_OUTBUF => 4096;
use constant MAX_READ   => 32768;

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

sub request {
	my $self = shift;
	my $args = shift;
	my $index = ${*$self}{vars}->{index} || $args->{index};
			
	if ( my $streamInfo = @{$args->{song}->pluginData('streams')}[$index] )	{
	
		$args->{url} = $streamInfo->{url};
		
		$log->info("requested url: $args->{url} (i:$index)");
			
		${*$self}{vars}->{streamBytes} = 0;
		${*$self}{vars}->{index} = $index + 1;
				
		return $self->SUPER::request($args);
	}	
	
	return undef;
}

sub new {
	my $class = shift;
	my $args  = shift;
	my $song  = $args->{'song'};
	my $index = 0;
	my ($server, $port) = Slim::Utils::Misc::crackURL(@{$song->pluginData('streams')}[0]->{url});
		
	my $seekdata   = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
		
	if (my $newtime = $seekdata->{'timeOffset'}) {
		my $streams = \@{$args->{song}->pluginData('streams')};
		
		$index = first { $streams->[$_]->{position} >= int $newtime } 0..scalar @$streams;
		
		$song->can('startOffset') ? $song->startOffset($newtime) : $song->{startOffset} = $newtime;
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $newtime);
	}

	$log->info("url: $args->{url}");	
	
	$args->{url}   = "http://$server:$port";
	$args->{index} = $index;		# need to set starting index BEFORE 1st request
	
	my $self = $class->open($args);
	
	if (defined($self)) {
		${*$self}{'client'}  = $args->{'client'};
		${*$self}{'song'}    = $args->{'song'};
		#${*$self}{'url'}     = $args->{'url'};
		${*$self}{'vars'} = {         # variables which hold state for this instance: (created by "open")
			%{${*$self}{'vars'}},
			'inBuf'       => '',      #  buffer of received flv packets/partial packets
			'outBuf'      => '',      #  buffer of processed audio
			'state'       => SYNCHRO, #  expected protocol fragment
			'streaming'   => 1,       #  flag for streaming, changes to 0 when input socket closes
			'tagSize'     => undef,   #  size of tag expected
			'adtsbase'    => undef,   #  base for adts output header
			'count'       => 0,       #  number of tags processed
			'audioBytes'  => 0,       #  audio bytes extracted
		};
	}

	return $self;
}

sub formatOverride {
	my $class = shift;
	my $song = shift;

	return $song->pluginData('format') || 'aac';
}

sub isAudio { 1 }

sub requestString { 
	shift; 
	my $request = Slim::Player::Protocols::HTTP->requestString(@_);
	
	# FIXME: this is way too hacky
	$request =~ s/close/keep-alive/;
	return $request;
}

sub parseHeaders {
	my ( $self,  @headers ) = @_;
	
	foreach my $header (@headers) {
	
		# Tidy up header to make no stray nulls or \n have been left by caller.
		$header =~ s/[\0]*$//;
		$header =~ s/\r/\n/g;
		$header =~ s/\n\n/\n/g;

		if ($header =~ /^Location:\s*(.*)/i) {
			${*$self}{redirect} = $1;
		}
		
		#FIXME: what happens if there is no content-length ?
		if ($header =~ /^Content-Length:\s*(.*)/i) {
			${*$self}{length} = $1;
		}
	}
}

sub songBytes {}

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
	my $bytes;
	
	while (length($v->{'inBuf'}) < MAX_INBUF && length($v->{'outBuf'}) < MAX_OUTBUF && $v->{streaming}) {
			
		$bytes = CORE::sysread($self, $v->{'inBuf'}, MAX_READ, length($v->{'inBuf'}));
		next unless defined $bytes;
		
		$self->processTS;
		$v->{streamBytes} += $bytes;
		
		$log->debug("streaming (read:$bytes) (in:", length($v->{'inBuf'}), " out: ", length($v->{'outBuf'}), " - [$v->{streamBytes} / ${*$self}{length}]");
	
		if ( $v->{streamBytes} == ${*$self}{length} ) {
			$v->{streaming} = 0 if ( !$self->request({ song => ${*$self}{song} }) )
		}
							
	}	
	
	my $len = length($v->{'outBuf'});
	
	if ($len > 0) {

		$bytes = min($len, $maxBytes);

		$_[1] = substr($v->{'outBuf'}, 0, $bytes);

		$v->{'outBuf'} = substr($v->{'outBuf'}, $bytes);
		
		return $bytes;

	} elsif (!$v->{'streaming'}) {

		$log->info("stream ended");

		$self->close;

		return 0;

	} elsif (!$self->connected) {

		$log->info("input socket not connected");

		$self->close;

		return 0;

	} else {

		$! = EWOULDBLOCK;
		return undef;
	}
}


sub processTS {
	use bytes;

	my $self = shift;
	my $v = $self->vars;
	my $len = length $v->{inBuf};
	my $state = $v->{state};
	my $packet;
	
	#$v->{inBuf} =~ s/G/H/g;
	while ($len >= 188) {
		my $offset = 0;
	
		#find synchro			
		if ($state == SYNCHRO)	{
		
			if ( $v->{inBuf} =~ m/(G.{187}G)/s ) {
				my $p = $1;
				$log->debug ("Synchro found at: ", index($v->{inBuf}, $p));
				$v->{inBuf} = substr $v->{inBuf}, index($v->{inBuf}, $p);
				$state = PIDPAT;
			} else { 
				$v->{inBuf} = substr $v->{inBuf}, length $v->{inBuf} - 187;
				last;
			}
			
			$len = length $v->{inBuf};
		} 
		
		#get a packet
		$packet = substr $v->{inBuf}, 0, 188;
		$v->{inBuf} = substr $v->{inBuf}, 188;
		$len -= 188;
				
		if (substr($packet, 0, 1) ne 'G') {
			$log->error("Synchro lost!");
			$state = SYNCHRO;
		}
		
		my $pid = decode_u16(substr $packet, 1, 2) & 0x1fff;
						
		# PAT and PMT could be spread over multiple TS packets, but this is
		# just to complicated to handle and probably not needed here
		
		#find the PMT pid's 
		if ($state == PIDPAT && $pid == 0) {
			my $fill = decode_u8(substr($packet, 4, 1));
		
			# 4 for pid, 1 + $fill for pointer, 3 for table header, 5 for table syntax, 2 for PAT
			$v->{pidPMT} = decode_u16(substr($packet, 4 + $fill + 1 + 3 + 5 + 2, 2)) & 0x1fff;
		
			$log->debug("found PAT, pidPMT: $v->{pidPMT}");
			$state = PIDPMT;
		}
	
		#find the ES pid's
		if ($state == PIDPMT && defined $v->{pidPMT} && $pid == $v->{pidPMT}) {
			my $streams;
			
			$streams = getPMT($packet);
			
			foreach my $stream (@{$streams}) {
				my $type = $stream->{type};
				
				if ($type == 0x03 || $type == 0x04) {
					$v->{stream} = { format => 'mp3', pid => $stream->{pid} } 
				} 
				
				if ($type == 0x0f) {
					$v->{stream} = { format => 'aac', pid => $stream->{pid} } 
				}	
			}
			
			$log->debug ("Stream selected:", Dumper($v->{stream}));
			$state = AUDIO unless !defined $v->{stream};
		}	
		
		#finally, we do audio
		if ($state == AUDIO && defined $v->{stream} && $pid == $v->{stream}->{pid}) {
			my $flags = decode_u8(substr($packet, 3, 1));
			my $alen = ($flags & 0x20) ? decode_u8(substr($packet, 4, 1)) + 1 : 0;
			my $pflags = decode_u16(substr($packet, 1, 2));
						
			if ($pflags & 0x4000) {
				my $plen = decode_u16(substr($packet, 4 + $alen + 4, 2));
				my $hdr = decode_u8(substr($packet, 4 + $alen + 6, 1));
								
				if ($hdr & 0x80) {
					$alen += 2 + 1 + decode_u8(substr($packet, 4 + $alen + 6 + 2, 1));
				}
				
				$alen += 6;
			}
			
			$v->{outBuf} .= substr($packet, 4 + $alen) if ($flags & 0x10);
		}	
		
		$v->{state} = $state;
	}
	
	return $len;
}

sub decode_u8  { unpack('C', $_[0]) }
sub decode_u16 { unpack('n', $_[0]) }
sub decode_u24 { unpack('N', ("\0" . $_[0]) ) }
sub decode_u32 { unpack('N', $_[0]) }

sub getPMT	{
	my $packet = shift;
	my $streams = [];
	my $fill 	  = decode_u8(substr($packet, 4, 1));
	my $table_len = decode_u16(substr($packet, 4 + $fill + 1 + 1, 2)) & 0x3ff;
	my $info_len  = decode_u16(substr($packet, 4 + $fill + 1 + 3 + 5 + 2, 2)) & 0x3ff;
	
	#starts now at ES data
	$packet = substr($packet, 4 + $fill + 1 + 3 + 5 + 4 + $info_len);
		
	my $count = 0;
	while ($count < $table_len - 9 - 4 - $info_len) {
		my $type = decode_u8(substr($packet, $count, 1));
		my $pid = decode_u16(substr($packet, $count + 1, 2)) & 0x1fff;
		$count += 5 + decode_u16(substr($packet, $count + 3, 2)) & 0x3ff;
		push @$streams, { type => $type, pid => $pid};
	}
	
	return $streams;
}


sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	my $url 	 = $song->track()->url;
	my $client   = $song->master();
	my $id 		 = $class->getId($url);
	
	if (!$id) {
		$errorCb->();
		return;
	}	
			
	$log->info("getNextTrack : $url (id: $id)");
	
	getFragmentList( 
	
		sub {
			my $fragments = shift;
					
			return $errorCb->() unless (defined $fragments && scalar @$fragments);
			
			my ($server) = Slim::Utils::Misc::crackURL( $fragments->[0]->{url} );
						
			$song->pluginData(streams => $fragments);	
			$song->pluginData(stream  => $server);
			$song->pluginData(format  => 'aac');
			$song->track->secs( $fragments->[scalar @$fragments - 1]->{position} );
			$class->getMetadataFor($client, $url, undef, $song);
			
			$successCb->();
		} , $id 
		
	);
}	


sub getFragmentList {
	my ($Cb, $id) = @_;
			
	$log->debug("getting fragment list for : $id");
	
	getFragmentURL( 
	
		sub {
			my ($fragmentURL) = @_;
			
			$log->debug("got fragment url: $fragmentURL");
			
			#might be forbidden
			$Cb->(undef) unless $fragmentURL;
		
			Slim::Networking::SimpleAsyncHTTP->new ( 
				sub {
					my $response = shift;
					my $fragmentList = $response->content;
					my @fragments;
					my $position = 0;
					
					$log->debug("got fragment list: $fragmentList");
			
					for my $item ( split (/#EXTINF:/, $fragmentList) ) {
						$item =~ m/([^,]+),([\S\s]*)(http\S*)/s;
						$position += $1 if $3;
						push @fragments, { position => $position, url => $3 } if $3;
					}	
									
					$Cb->(\@fragments);
				},	
			
				sub {
					$Cb->(undef);
				}
					
			)->get($fragmentURL);
								
		}, $id	
	);		
}	


sub getFragmentURL {
	my ($Cb, $id) = @_;
	
	$log->debug("getting master file : $id");
	
	getMasterURL( 
	
		sub {
			my $masterURL = shift;
			
			$log->debug("got master url: $masterURL");
			
			#might be forbidden
			$Cb->(undef) unless $masterURL;
		
			Slim::Networking::SimpleAsyncHTTP->new ( 
				sub {
					my $response = shift;
					my $result = $response->content;
					my $bw;
					my $fragmentURL;
				
					for my $item ( split (/#EXT-X-STREAM-INF:/, $result) ) {
						$item =~ m/BANDWIDTH=(\d+),([\S\s]*)(http\S*)/s;
						if (defined $1 && (!defined $bw || $1 < $bw)) {
							$bw = $1;
							$fragmentURL = $3;
						}
					}
					
					$Cb->($fragmentURL);
				},
			
				sub {
					$Cb->(undef);
				}
					
			)->get($masterURL);
			
		}, $id	
		
	);
}	

		
sub getMasterURL {
	my ($Cb, $id) = @_;
	my $url = API_URL_GLOBAL . "/tools/getInfosOeuvre/v2/?catalogue=Pluzz&idDiffusion=$id";
		
	$log->debug("getting master url for : $id");
	
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $result = eval { decode_json($response->content) };
						
			$result ||= {};
								
			my $master = first { $_->{format} eq 'm3u8-download' } @{$result->{videos}};
			
			$Cb->($master->{url});
		},

		sub {
			$Cb->(undef);
		},

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
			
	my $id = $class->getId($url) || return {};
	
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

	if ($url =~ m|pluzz://(\S*)|) {
		return $1;
	}
		
	return undef;
}


1;
