package Slim::Networking::SimpleAsyncHTTP;

use strict;

use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $prefs = preferences('server');
my $log = logger('network.asynchttp');

sub _createHTTPRequest {
	my $self = shift;
	my $type = shift;
	my $url  = shift;

	$self->type( $type );
	$self->url( $url );
	
	my $params = $self->_params;
	my $client = $params->{params}->{client};
		
	main::DEBUGLOG && $log->debug("${type}ing $url");
	
	# Check for cached response
	if ( $params->{cache} ) {
		
		my $cache = Slim::Utils::Cache->new();
		
		if ( my $data = $cache->get( _cacheKey($url, $client) ) ) {			
			$self->cachedResponse( $data );
			
			# If the data was cached within the past 5 minutes,
			# return it immediately without revalidation, to improve
			# UI experience
			if ( $data->{_no_revalidate} || time - $data->{_time} < 300 ) {
				
				main::DEBUGLOG && $log->debug("Using cached response [$url]");
				
				return $self->sendCachedResponse();
			}
		}
	}
	
	my $timeout 
		=  $params->{Timeout}
		|| $params->{timeout}
		|| $prefs->get('remotestreamtimeout');
		
	my $request = HTTP::Request->new( $type => $url );
	
	if ( @_ % 2 ) {
		$request->content( pop @_ );
	}
	
	# If cached, add If-None-Match and If-Modified-Since headers
	my $data = $self->cachedResponse;
	if ( $data && ref $data && $data->{headers} ) {
		# gzip encoded results come with a -gzip postfix which needs to be removed, or the etag would not match
		my $etag = $data->{headers}->header('ETag') || undef;
		$etag =~ s/-gzip// if $etag;

		# if the last_modified value is a UNIX timestamp, convert it
		my $lastModified = $data->{headers}->last_modified || undef;
		$lastModified = HTTP::Date::time2str($lastModified) if $lastModified && $lastModified !~ /\D/;

		unshift @_, (
			'If-None-Match'     => $etag,
			'If-Modified-Since' => $lastModified
		);
	}

	# request compressed data if we have zlib
	if ( hasZlib() && !$params->{saveAs} ) {
		unshift @_, (
			'Accept-Encoding' => 'deflate, gzip', # deflate is less overhead than gzip
		);
	}
	
	# Add Accept-Language header
	my $lang;
	if ( $client ) {
		$lang = $client->languageOverride(); # override from comet request
	}

	$lang ||= $prefs->get('language') || 'en';
		
	unshift @_, (
		'Accept-Language' => lc($lang),
	);
	
	if ( @_ ) {
		$request->header( @_ );
	}
	
=pod
	# Use the player for making the HTTP connection if requested
	if ( my $client = $params->{usePlayer} ) {
		# We still have to do DNS lookups in SC unless
		# we have an IP host
		if ( Slim::Utils::Network::ip_is_ipv4( $request->uri->host ) ) {
			sendPlayerRequest( $request->uri->host, $self, $client, $request );
		}
		else {
			my $dns = Slim::Networking::Async->new;
			$dns->open( {
				Host        => $request->uri->host,
				onDNS       => \&sendPlayerRequest,
				onError     => \&onError,
				passthrough => [ $self, $client, $request ],
			} );
		}
		return;
	}
=cut
	# BEGIN 
	my $http = Slim::Networking::Async::HTTP->new( $self->_params );
	# END
	$http->send_request( {
		request     => $request,
		maxRedirect => $params->{maxRedirect},
		saveAs      => $params->{saveAs},
		Timeout     => $timeout,
		onError     => \&onError,
		onBody      => \&onBody,
		passthrough => [ $self ],
	} );
}

1;

