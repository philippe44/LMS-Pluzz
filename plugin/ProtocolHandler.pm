package Plugins::FranceTV::ProtocolHandler;
use base qw(IO::Handle);

use strict;

use List::Util qw(first);
use JSON::XS;
use XML::Simple;
use Crypt::Mode::CBC;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;

use Plugins::FranceTV::m4a;
use Plugins::FranceTV::MPEGTS;

my $log   = logger('plugin.francetv');
my $prefs = preferences('plugin.francetv');
my $cache = Slim::Utils::Cache->new;

Slim::Player::ProtocolHandlers->registerHandler('francetv', __PACKAGE__);

=comment
This new version handles MPD format that I really hate, it is such a mess. As many bad standards,
it has probably been defined by folks who only care of the server side of things and have no idea 
of the client implementation problems. So they have fun inventing an insane amount of permutations
and combinations to do the same thing. Let's fo BaseURL at all levels, then SegmentTimelines, then
SegmentTemplate, then Time or Number for repeats and so on... so much fun and in addition everyone
wants "his way" implemented in the standard because of course my way is better than your way.
At the end, you have a totally asymetrical specification with no capabilities negotiation/handshake
so the server of course can decide to implement any of the gazillion of options to encode the source 
and the client, whose software is the most difficult to update, has to implement all the options 
THIS IS RIDICULOUS.

for HLS, see https://datatracker.ietf.org/doc/html/draft-pantos-http-live-streaming
=cut

sub new {
	my $class = shift;
	my $args  = shift;
	my $song  = $args->{'song'};
	my ($index, $offset, $repeat) = (0, 0, 0);
	my $seekdata = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
	my $params = $song->pluginData('params');
	
	$log->debug("params ", Data::Dump::dump($params));
	
	# erase last position from cache
	$cache->remove("ft:lastpos-" . ($class->getId($args->{'url'}))[0]);
	
	if ( my $newtime = ($seekdata->{'timeOffset'} || $song->pluginData('lastpos')) ) {

		if ($params->{source} =~ /hls/) {
			$index = $params->{fragmentDuration} ? int($newtime / $params->{fragmentDuration}) : 0;		
		} elsif (my $segments = $song->pluginData('segments')) {
			TIME: foreach (@{$segments}) {
				$offset = $_->{t} if $_->{t};
				for my $c (0..$_->{r} || 0) {
					$repeat = $c;
					last TIME if $offset + $_->{d} > $newtime * $params->{timescale};
					$offset += $_->{d};				
				}	
				$index++;			
			}
		} else {
			$index = int($newtime / ($params->{d} / $params->{timescale}));
		}	
			
		$song->can('startOffset') ? $song->startOffset($newtime) : ($song->{startOffset} = $newtime);
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $newtime);
	}

	my $self = $class->SUPER::new;
	
	# context that will be used by sysread variants
	my $vars = {
			'inBuf'       => undef,   # (reference to) buffer of received packets
			'index'  	  => $index,  # current index in segments
			'offset'	  => $offset, # time offset, maybe be used to build URL
			'fetching'    => 0,		  # flag for waiting chunk data
			'retry'		  => 5,
			'session' 	  => Slim::Networking::Async::HTTP->new( { socks => Plugins::FranceTV::API::getSocks } ),
			'baseURL'     => $params->{baseURL}, 
			'query'       => $params->{query}, 
	};		
	
	if (defined($self)) {
		${*$self}{'song'} = $args->{'song'};
		${*$self}{'vars'} = $vars;
		
		if ($params->{source} eq 'hls-aac') {
			$vars->{sysread} = \&sysreadHLS_AAC;
		} elsif ($params->{source} eq 'hls-mpeg') {
			$vars->{sysread} = \&sysreadHLS_MPEG;
		} else {
			$vars->{context} = { };		# context for mp4		
			$vars->{repeat} = $repeat;	# might start in a middle of a repeat
			$vars->{sysread} = \&sysreadMPD;
			Plugins::FranceTV::m4a::setEsds($vars->{context}, $params->{samplingRate}, $params->{channels});
		}	
		
		$log->debug("vars ", Data::Dump::dump(${*$self}{'vars'}));
	}

	return $self;
}

sub onStop {
    my ($class, $song) = @_;
	my $elapsed = $song->master->controller->playingSongElapsed;
	my ($id) = $class->getId($song->track->url);
	
	if ($elapsed > 15 && $elapsed < $song->duration - 15) {
		$cache->set("ft:lastpos-$id", int ($elapsed), '30days');
		$log->info("Last position for $id is $elapsed");
	} else {
		$cache->remove("ft:lastpos-$id");
	}	
}

sub contentType { 'aac' }
sub isAudio { 1 }
sub isRemote { 1 }
sub songBytes { }
sub canSeek { 1 }

sub formatOverride {
	my $class = shift;
	my $song = shift;

	return $song->pluginData('format') || 'aac';
}

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;

	return { timeOffset => $newtime };
}

sub sysread {
	my $self  = $_[0];
	my $v = ${*{$self}}{'vars'};

	# waiting to get next chunk, nothing sor far	
	if ( $v->{'fetching'} ) {
		$! = EINTR;
		return undef;
	}
	
	# call the right sysread
	return $v->{'sysread'}($v, @_);
}	

sub sysreadHLS_AAC {
	use bytes;
	my $v = shift;
	
	my $song = ${*${$_[0]}}{song};
	my $fragments = $song->pluginData('fragments');
	my $total = scalar @$fragments;

	# here inBuf is not a reference but the bytes themselves
	if ( $v->{index} < $total && $v->{retry} && length($v->{'inBuf'}) < $_[2] ) {
		# this substitutes the xxxx.m3u8 in http://.../xxxx.m3u8?...
		my $url = $v->{baseURL} =~ s/(?<=\/)[^\/]*(?=\?)/$fragments->[$v->{index}]/r;	

		my $request = HTTP::Request->new( GET => $url );
		my $params = $song->pluginData('params');

		$request->header( 'Connection', 'keep-alive' );
		$request->protocol( 'HTTP/1.1' );
		$v->{fetching} = 1;
		
		$log->info("HLS-AAC: fetching index:$v->{'index'}/$total url:$url");		

		$v->{'session'}->send_request( {
				request => $request,
				onRedirect => sub {
					my $request = shift;
					my $redirect = $request->uri;
					$v->{'baseURL'} = $redirect;
					$log->info("being redirected from $url to ", $request->uri, "using new base $v->{baseURL}");
				},
				onBody => sub {
					$v->{'fetching'} = 0;
					$v->{'retry'} = 5;
					$v->{'index'}++;
					my $iv = pack("v", $params->{'index'} + $v->{'index'}) . "\0" x 14;
					$v->{inBuf} .= $params->{'cipher'}->decrypt(shift->response->content, $params->{'key'}, $iv);					
					$log->debug("data length is now: ", length $v->{'inBuf'});
				},
				onError => sub {
					$v->{'session'}->disconnect;
					$v->{'fetching'} = 0;					
					$v->{'retry'} = $v->{index} < $total - 1 ? $v->{'retry'} - 1 : 0;
					$v->{'baseURL'} = $params->{'baseURL'};
					$log->error("cannot open session for $url ($_[1]) moving back to base URL");					
				},
				socks => Plugins::FranceTV::API::getSocks,
		} );
		
		# we will get data on next call
		if (length $v->{'inBuf'} == 0) {
			$! = EINTR;
			return undef;
		}	
	} 	
	
	# consume bytes and return them
	$_[1] = substr($v->{'inBuf'}, 0, $_[2], '');
	return length $_[1];
}

sub sysreadHLS_MPEG {
	use bytes;

	my $v = shift;
	my $song = ${*${$_[0]}}{song};
	my $fragments = $song->pluginData('fragments');
	my $total = scalar @$fragments;
	
	# end of current segment, get next one
	if ( !defined $v->{'inBuf'} || length ${$v->{'inBuf'}} == 0 ) {
	
		# end of stream
		return 0 if $v->{index} == $total;
		
		# get next fragment/chunk
		my $url = $fragments->[$v->{index}];
		$v->{'pos'} = 0;
		$v->{'fetching'} = 1;
		$v->{'disconnect'} = 0;
						
		my $request = HTTP::Request->new( GET => $url );
		my $params = $song->pluginData('params');

		$request->header( 'Connection', 'keep-alive' );
		$request->protocol( 'HTTP/1.1' );
		
		$log->info("HLS-MPEG: fetching index:$v->{'index'}/$total url:$url");
		
		$v->{'session'}->send_request( {
				request => $request,
				onRedirect => sub {
					# maybe we could mangle next URL, but for now just close session
					$v->{'disconnect'} = 1;
					$log->info("being redirected from $url to ", $request->uri, "closing connection");
				},
				onBody => sub {
					$v->{'fetching'} = 0;
					$v->{'retry'} = 5;
					$v->{'index'}++;
					$v->{'inBuf'} = \shift->response->content;					
					$v->{'session'}->disconnect if $v->{'disconnect'};					
					$log->debug("received data length is: ", length ${$v->{'inBuf'}});
				},
				onError => sub {
					$v->{'session'}->disconnect;
					$v->{'fetching'} = 0;					
					$v->{'retry'} = $v->{index} < $total - 1 ? $v->{'retry'} - 1 : 0;
					$log->error("cannot open session for $url ($_[1])");					
				},
		} );
			
		$! = EINTR;
		return undef;
	}	
				
	my $len = Plugins::FranceTV::MPEGTS::processTS($v, $_[1], $_[2]);
	return $len if $len;
	
	$! = EINTR;
	return undef;
}
	
sub sysreadMPD {
	use bytes;
	my $v = shift;

	# end of current segment, get next one
	if ( !defined $v->{'inBuf'} || length ${$v->{'inBuf'}} == 0 ) {
	
		my $song = ${*${$_[0]}}{song};
		my $segments = $song->pluginData('segments');
		my $params = $song->pluginData('params');
		my $total = $segments ? scalar @{$segments} : int($params->{duration} / ($params->{d} / $params->{timescale})); 
		
		# end of stream
		return 0 if $v->{index} >= $total || !$v->{retry};
		
		$v->{fetching} = 1;	
		
		# get next fragment/chunk
		my $item = $segments ? @{$segments}[$v->{index}] : { d => $params->{duration} };
		my $suffix = $item->{media} || $params->{media};
		
		# don't think that 't' can be set at anytime, but just in case...
		$v->{offset} = $item->{t} if $item->{t};
		
		# probably need some formatting for Number & Time
		$suffix =~ s/\$RepresentationID\$/$params->{representation}->{id}/;
		$suffix =~ s/\$Bandwidth\$/$params->{representation}->{bandwidth}/;
		$suffix =~ s/\$Time\$/$v->{offset}/;
		my $number = $v->{index} + 1;
		$suffix =~ s/\$Number\$/$number/;

		my $url = $v->{'baseURL'} . "/$suffix" . $v->{'query'};
		
		my $request = HTTP::Request->new( GET => $url );
		$request->header( 'Connection', 'keep-alive' );
		$request->protocol( 'HTTP/1.1' );
		
		$log->info("fetching index:$v->{'index'}/$total url:$url");		

		$v->{'session'}->send_request( {
				request => $request,
				onRedirect => sub {
					my $request = shift;
					my $redirect = $request->uri;
					my $match = (reverse ($suffix) ^ reverse ($redirect)) =~ /^(\x00*)/;
					$v->{'baseURL'} = substr $redirect, 0, -$+[1] if $match;
					$log->info("being redirected from $url to ", $request->uri, "using new base $v->{'baseURL'}");
				},
				onBody => sub {
					$v->{fetching} = 0;
					$v->{offset} += $item->{d};
					$v->{repeat}++;	
					$v->{retry} = 5;
				
					if ($v->{repeat} > ($item->{r} || 0)) {
						$v->{index}++;
						$v->{repeat} = 0;
					}
					
					$v->{inBuf} = \shift->response->content;
					$log->debug("got chunk length: ", length ${$v->{'inBuf'}});
				},
				onError => sub {
					$v->{'session'}->disconnect;
					$v->{'fetching'} = 0;					
					$v->{'retry'} = $v->{index} < $total - 1 ? $v->{'retry'} - 1 : 0;
					$v->{'baseURL'} = $params->{'baseURL'};
					$log->error("cannot open session for $url ($_[1]) moving back to base URL");					
				},
		} );
		
		$! = EINTR;
		return undef;
	}	

	my $len = Plugins::FranceTV::m4a::getAudio($v->{'inBuf'}, $v->{'context'}, $_[1], $_[2]);
	return $len if $len;
	
	$! = EINTR;
	return undef;
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	my $url = $song->track()->url;
	my $client = $song->master();
	my ($step1, $step2, $step3HLS, $step3MPD, $step4, $step5, $getAACParams, $extractADTS);
	my ($duration, $format, $root);
	
	$song->pluginData(lastpos => ($url =~ /&lastpos=([\d]+)/)[0] || 0);
	$url =~ s/&lastpos=[\d]*//;				
	
	my ($id) = $class->getId($url);

	$log->info("getNextTrack : $url (id: $id)");
	
	if (!$id) {
		$errorCb->();
		return;
	}	
	
	# get the token's url (and starts auth if needed)
	$step1 = sub {
		my $data = shift->content;	
		eval { $data = decode_json($data)->{video} };
		$log->debug("step 1 ", Data::Dump::dump($data));

		if ( !$data || $data->{drm} ) {
			$log->error("WE HAVE DRM OR AN ERROR $data->{drm}");
			return $errorCb->();
		}
		
		$duration = $data->{duration};
		$format = $data->{format};
	
		# get the token's url (the is will give the mpd's url)
		my $http = Slim::Networking::SimpleAsyncHTTP->new ( $step2, $errorCb, { socks => Plugins::FranceTV::API::getSocks } );
		$http->get( $data->{token} );  
	};
	
	# intercept the MPD usable url
	$step2 = sub {
		my $data = shift->content;	
		eval { $data = decode_json($data) };
		$log->debug("step 2 ", Data::Dump::dump($data));

		$errorCb->() unless $data->{url};
	
		# need to intercept the redirected url
		$root = $data->{url};
		my $http = Slim::Networking::Async::HTTP->new ( { socks => Plugins::FranceTV::API::getSocks } );
		my $next = $format eq 'hls' ? $step3HLS : $step3MPD;
		
		$http->send_request( {
			request => HTTP::Request->new( GET => $root ),
			onBody	=> $next,
			# TODO: verify that $root is not captured (closure)
			onRedirect => sub {	
				$root = shift->uri =~ s/[^\/]+$//r;
				$root =~ s/\/$//;
			},
		} );		
	};
	
	# process HLS master file
	$step3HLS = sub {
		my $m3u8 = shift->response->content;	
		my $url;
		
		$log->info("processing HLS format");
		$log->debug($m3u8);
		
		$errorCb->() unless $m3u8;

		my ($audioUrl) = $m3u8 =~ /^#EXT-X-MEDIA:TYPE=AUDIO.*URI="([^"]+)"/m;
		
		if ($audioUrl) {
			# this is equivalent of
			# my ($target) = $url =~ /\S+\/([^\?]+)\?\S+/;
			# $url =~ s/$target/$audioUrl/;	
			$url = $root =~ s/(?<=\/)[^\/]*(?=\?)/$audioUrl/r;	
			$song->pluginData(params => { baseURL => $root, source => 'hls-aac' } );					
			$log->info("HLS audio-aac $audioUrl with root url $root");
		} else {
			my $bandwidth;
			for my $item ( split (/#EXT-X-STREAM-INF/, $m3u8) ) {
				next unless $item =~ /\S+BANDWIDTH=(\d+).*\n(^http\S+)/m;
				next if $bandwidth && $1 > $bandwidth;
				$bandwidth = $1;
				$url = $2;
			}
			$song->pluginData(params => { baseURL => $root, source => 'hls-mpeg' } );					
			$log->info("HLS mpeg-ts bandwidth $bandwidth using $audioUrl with root url $root");
		}	
		
		# get the token's url (the is will give the HLS's url)
		my $http = Slim::Networking::SimpleAsyncHTTP->new ( $step4, $errorCb, { socks => Plugins::FranceTV::API::getSocks } );
		$http->get( $url );  
	};
	
	# process HLS slave file
	$step4 = sub {
		my $m3u8 = shift->content;	
		
		$errorCb->() unless $m3u8;
		
		my @fragments;
		for my $item ( split (/#EXTINF/, $m3u8) ) {
			# this is not a great regex...
			next unless $item =~ /\S+\n(\S+\.aac|^http\S+)/m;
			push @fragments, $1;
		}
		$song->pluginData(fragments => \@fragments);

		$m3u8 =~ /^#EXT-X-TARGETDURATION:(\d+)/m;
		$song->pluginData('params')->{'fragmentDuration'} = $1 || 0;
		
		$m3u8 =~ /^#EXT-X-MEDIA-SEQUENCE:(\d+)/m;
		$song->pluginData('params')->{'index'} = $1 || 0;
		
		# are the files encrypted (really...)
		my ($keyUrl) = $m3u8 =~ /^#EXT-X-KEY:METHOD=AES-128.*URI="([^"]+)"/m;
		return $getAACParams->() unless $keyUrl;
		
		$log->info("This file is encrypted with $keyUrl");
		my $http = Slim::Networking::SimpleAsyncHTTP->new ( $step5, $errorCb, { socks => Plugins::FranceTV::API::getSocks } );
		$http->get( $keyUrl );  
	};
	
	$step5 = sub {
		my $key = shift->content;
		
		$errorCb->() unless $key;		
		
		$log->info("got key $key length", length $key);

		$song->pluginData('params')->{'key'} = $key;
		$song->pluginData('params')->{'cipher'} = Crypt::Mode::CBC->new('AES');
		
		$getAACParams->();
	};
	
	$extractADTS = sub {
		my $data = shift;
		my @rates = (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350);
		my $params = $song->pluginData('params');
		
		# decrypt if needed
		if ($params->{cipher}) {
			my $iv = pack("v", $params->{index}) . "\0" x 14;
			$data = $params->{cipher}->decrypt($data, $params->{key}, $iv);					
		}	
				
		# search pattern
		$data =~ /\xff(?:\xf1|\xf0)(.{2})/;
				
		my $adts = unpack("n", $1);
		$params->{samplingRate} = $rates[($adts >> 10) & 0x0f];
		$params->{channels} = ($adts >> 6) & 0x3;
				
		$song->track->secs( $duration );
		$song->track->samplerate( $params->{samplingRate} );
		$song->track->channels( $params->{channels} ); 
		
		if ( my $meta = $cache->get("ft:meta-" . $id) ) {
			$meta->{duration} = $duration;
			$meta->{type} = "aac\@$params->{samplingRate}Hz";
			$cache->set("ft:meta-" . $id, $meta);
		}	
		
		$client->currentPlaylistUpdateTime( Time::HiRes::time() );
		Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );	
	};
	
	$getAACParams = sub {
		# can continue now...		
		$successCb->();
		
		# get a bit of first ADTS segment to have sample rate and channels		
		my $params = $song->pluginData('params');
		my $fragments = $song->pluginData('fragments');
		
		if ($params->{source} eq 'hls-mpeg') {
			Slim::Networking::SimpleAsyncHTTP->new ( 
				sub {
					my $v = { inBuf => shift->contentRef };
					Plugins::FranceTV::MPEGTS::processTS($v, my $data, 256);
					$extractADTS->($data);
				}, 
				sub {
					$log->warn("cannot get hls-mpeg trackinfo");
				},
				{ socks => Plugins::FranceTV::API::getSocks } 
			)->get( $fragments->[0], Range => 'bytes=0-128000' );
		} else {
			my $url = $params->{baseURL} =~ s/(?<=\/)[^\/]*(?=\?)/$fragments->[0]/r;	
			Slim::Networking::SimpleAsyncHTTP->new ( 
				sub {
					$extractADTS->(shift->content);
				}, 
				sub {
					$log->warn("cannot get hls-aac trackinfo");
				},
				{ socks => Plugins::FranceTV::API::getSocks } 
			)->get( $url, Range => 'bytes=0-255' );  
		}	
	};

	# process the MPD
	$step3MPD = sub {
		my $mpd = shift->response->content;	
		$log->info("processing mpd format");
		$log->debug($mpd);
		
		eval { $mpd = XMLin( $mpd, KeyAttr => [], ForceContent => 1, ForceArray => [ 'AdaptationSet', 'Representation', 'Period' ] ) };
		return $errorCb->() if $@;
		
		my ($adaptation, $representation);
		foreach my $item (@{$mpd->{Period}[0]->{AdaptationSet}}) { 
			if ($item->{mimeType} eq 'audio/mp4') {
				$adaptation = $item;
				my @bandwidth = sort { $a->{bandwidth} < $b->{bandwidth} } @{$item->{Representation}};
				$representation = $bandwidth[0];
				last;
			}	
		}			
				
		return $errorCb->() unless $representation;
	
		($root, my $query) = $root =~ /(.*)\/(?:[^\?]*)(.*)$/;
		my $baseURL = getValue(['BaseURL', 'content'], [$mpd, $mpd->{Period}[0], $adaptation, $representation], '.');
		$baseURL = "$root/$baseURL" unless $baseURL =~ /^https?:/i;
		$baseURL =~ s/\/$//;		
		
		my $duration = getValue('duration', [$representation, $adaptation, $mpd->{Period}[0], $mpd]);
		my ($misc, $hour, $min, $sec) = $duration =~ /P(?:([^T]*))T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/;
		$duration = ($sec || 0) + (($min || 0) * 60) + (($hour || 0) * 3600);

		# set of useful parameters for the $song object
		my $segments = $adaptation->{SegmentList}->{SegmentURL} || $adaptation->{SegmentTemplate}->{SegmentTimeline}->{S};
		my $params = {
			samplingRate => getValue('audioSamplingRate', [$representation, $adaptation]),
			channels => getValue('AudioChannelConfiguration', [$representation, $adaptation])->{value},
			duration => $duration,			
			representation => $representation,
			media => $adaptation->{SegmentTemplate}->{media},
			d => $adaptation->{SegmentTemplate}->{duration},
			timescale => getValue('timescale', [$adaptation->{SegmentList}, $adaptation->{SegmentTemplate}]),
			baseURL => $baseURL,
			query => $query,
			source => 'mpd',
		};
		
		$log->info("MPD parameters ", Data::Dump::dump($params));
				
		$song->pluginData(segments => $segments);
		$song->pluginData(params => $params);	
		
		$song->track->secs( $duration );
		$song->track->samplerate( $params->{samplingRate} );
		$song->track->channels( $params->{channels} ); 
		#$song->track->bitrate(  );
		
		if ( my $meta = $cache->get("ft:meta-" . $id) ) {
			$meta->{duration} = $duration;
			$meta->{type} = "aac\@$params->{samplingRate}Hz";
			$cache->set("ft:meta-" . $id, $meta);
		}	
		
		$client->currentPlaylistUpdateTime( Time::HiRes::time() );
		Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
		
		# ready to start
		$successCb->();
	};
	
	# start the sequence of requests and callbacks
	my $http = Slim::Networking::SimpleAsyncHTTP->new ( $step1, $errorCb, { socks => Plugins::FranceTV::API::getSocks } );
	$http->get( "https://player.webservices.francetelevisions.fr/v1/videos/$id?country_code=FR&device_type=desktop&browser=chrome" );  
}

sub getMetadataFor {
	my ($class, $client, $url) = @_;
		
	main::DEBUGLOG && $log->debug("getmetadata: $url");

	$url =~ s/&lastpos=[\d]*//;				
	my ($id, $channel, $program) = $class->getId($url);
	return unless $id && $channel && $program;
	
	if ( my $meta = $cache->get("ft:meta-$id") ) {
						
		Plugins::FranceTV::Plugin->updateRecentlyPlayed({
			url   => $url, 
			name  => $meta->{title}, 
			icon  => $meta->{icon},
		});
		
		main::DEBUGLOG && $log->debug("cache hit: $id");
		
		return $meta;
	}	
		
	# that sets cache for whole program
	Plugins::FranceTV::API->searchEpisode( sub {
		if ($client) {
			$client->currentPlaylistUpdateTime( Time::HiRes::time() );
			Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
		}
	}, { channel => $channel, program => $program } );
			
	my $icon = $class->getIcon();
	
	return { type	=> 'FranceTV',
			 title	=> "FranceTV",
			 icon	=> $icon,
			 cover	=> $icon,
			};
}	

sub getValue {
	my ($keys, $where, $mode) = @_;
	my $value;
	
	$keys = [$keys] unless ref $keys eq 'ARRAY';
	
	foreach my $hash (@$where) {
		foreach my $k (@$keys) {
			$hash = $hash->{$k};
			last unless $hash;
		}	
		next unless $hash;
		if ($mode eq '.') {
			$value .= $hash;
		} elsif ($mode eq 'f') {
			return $hash if $hash;
		} else {
			$value ||= $hash;
		}	
	}

	return $value;
}

sub getIcon {
	my ( $class, $url ) = @_;

	return Plugins::FranceTV::Plugin->_pluginDataFor('icon');
}

sub getId {
	my ($class, $url) = @_;

	if ($url =~ m|francetv://([^&]+)&channel=([^&]+)&program=([^&]+)|) {
		return ($1, $2, $3);
	}
		
	return undef;
}


1;
