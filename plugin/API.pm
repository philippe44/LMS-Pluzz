package Plugins::FranceTV::API;

use strict;

use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;
use List::Util qw(min max);
use MIME::Base64;
use Exporter qw(import);

use constant API_FRONT_URL => 'http://api-front.yatta.francetv.fr/standard';
use constant IMAGE_URL => 'http://api-front.yatta.francetv.fr';

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

our @EXPORT = qw(obfuscate deobfuscate);
	
my $prefs = preferences('plugin.francetv');
my $log   = logger('plugin.francetv');
my $cache = Slim::Utils::Cache->new();

sub getSocks {
	return undef unless $prefs->get('socks');
	my ($server, $port) = split (/:/, $prefs->get('socksProxy'));
	return {
		socks => {
			ProxyAddr => $server,
			ProxyPort => $port,
			Username => deobfuscate($prefs->get('socksUsername')),
			Password => deobfuscate($prefs->get('socksPassword')),
		}	
	};	
}

sub searchProgram {
	my ( $cb, $params ) = @_;
	my $page = "/publish/channels/$params->{channel}/programs";
	
	$log->debug("get program $params->{channel}");
	$params->{_ttl} ||= 3600;
	
	search( $page, sub {
			# keep only shows from the channel and with at least one video
			my @list = grep { $_->{video_count} && $_->{channel} eq $params->{channel} } @{shift->{result} || []};
			$cb->( \@list );
		}, $params 
	);	
}

sub searchEpisode {
	my ( $class, $cb, $params ) = @_;
	my $page = "/publish/channels/$params->{channel}" . '_' . "$params->{program}/contents/?size=100&page=0&sort=begin_date:desc&filter=with-no-vod,only-visible,only-replay";    
	
	$log->debug("get episode $params->{program} ($params->{channel})");
	
	search( $page, sub {
		my ($results, $cached) = @_;
		my @list = grep { $_->{type} eq 'integrale' && $_->{content_has_medias} && $_->{class} eq 'video' } @{$results->{result} || []};		
		
		# don't re-cache metadata if already in cache ...
		$cb->( \@list ) if $cached;

		for my $entry (@list) {
			my ($video) = grep { $_->{type} eq 'main' } @{$entry->{content_has_medias}};
			my ($image) = grep { $_->{type} eq 'image' } @{$entry->{content_has_medias}};			
			$image = Plugins::FranceTV::Plugin::getImage($image->{media}->{patterns}, 'carre') || getIcon();

			$cache->set("ft:meta-" . $video->{media}->{si_id}, 
				{ title  => $entry->{title} || "$video->{media}->{title}, " . substr($entry->{first_publication_date}, 0, 10),
				  icon     => $image,
				  cover    => $image,
				  duration => $video->{media}->{duration},
				  artist   => $entry->{presenter},
				  album    => $video->{media}->{title},
				  type	   => 'FranceTV',
				}, 3600*24) if ( !$cache->get("ft:meta-" . $video->{media}->{si_id}) );
		}

		$cb->( \@list );
	
	}, $params ); 
	
}	

sub search	{
	my ( $page, $cb, $params ) = @_;
	my $url = API_FRONT_URL . $page;
	my $cacheKey = md5_hex($url);
	my $cached;
	
	$log->debug("wanted url: $url");
	
	if ( !$prefs->get('no_cache') && ($cached = $cache->get($cacheKey)))  {
		main::INFOLOG && $log->info("Returning cached data for: $url");
		$cb->($cached, 1);
		return;
	}
	
	Slim::Networking::SimpleAsyncHTTP->new(
	
		sub {
			my $result = eval { decode_json(shift->content) } || {};
			$cache->set($cacheKey, $result, $params->{_ttl} || 900);
			$cb->($result);
		},

		sub {
			$log->error($_[1]);
			$cb->( { error => $_[1] } );
		},
		
		getSocks,

	)->get($url);
			
}

sub obfuscate {
  # this is vain unless we have a machine-specific ID	
  return MIME::Base64::encode(scalar(reverse(unpack('H*', $_[0]))));
}

sub deobfuscate {
  # this is vain unless we have a machine-specific ID	
  return pack('H*', scalar(reverse(MIME::Base64::decode($_[0]))));
}


1;