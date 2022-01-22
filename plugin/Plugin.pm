package Plugins::FranceTV::Plugin;

# Plugin to stream audio from FranceTV videos streams
#
# Released under GPLv2

use strict;
use base qw(Slim::Plugin::OPMLBased);

use File::Spec::Functions;
use Encode qw(encode decode);
use HTML::Entities;

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::FranceTV::API;
use Plugins::FranceTV::ProtocolHandler;
use Plugins::FranceTV::ListProtocolHandler;

# see if HTTP(S)Socks is available
eval "require Slim::Networking::Async::Socket::HTTPSocks" or die "Please update your LMS version to recent build";

my $WEBLINK_SUPPORTED_UA_RE = qr/iPeng|SqueezePad|OrangeSqueeze/i;

use constant IMAGE_URL => 'http://api-front.yatta.francetv.fr';

my	$log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.francetv',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_FRANCETV',
});

my $prefs = preferences('plugin.francetv');
my $cache = Slim::Utils::Cache->new;

$prefs->init({ 
	prefer_lowbitrate => 0, 
	recent => [], 
	max_items => 200, 
});

tie my %recentlyPlayed, 'Tie::Cache::LRU', 50;

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(
		feed   => \&toplevel,
		tag    => 'francetv',
		menu   => 'radios',
		is_app => 1,
		weight => 10,
	);

=comment	
	Slim::Menu::TrackInfo->registerInfoProvider( francetv => (
		after => 'bottom',
		func  => \&webVideoLink,
	) );

	Slim::Menu::GlobalSearch->registerInfoProvider( francetv => (
		after => 'middle',
		name  => 'PLUGIN_FRANCETV',
		func  => \&searchInfoMenu,
	) );
=cut	

	if ( main::WEBUI ) {
		require Plugins::FranceTV::Settings;
		Plugins::FranceTV::Settings->new;
	}
	
	for my $recent (reverse @{$prefs->get('recent')}) {
		$recentlyPlayed{ $recent->{'url'} } = $recent;
	}
	
#        |requires Client
#        |  |is a Query
#        |  |  |has Tags
#        |  |  |  |Function to call
	Slim::Control::Request::addDispatch(['francetv', 'info'], 
		[1, 1, 1, \&cliInfoQuery]);
		
	
}

sub shutdownPlugin {
	my $class = shift;

	$class->saveRecentlyPlayed('now');
}

sub getDisplayName { 'PLUGIN_FRANCETV' }

sub updateRecentlyPlayed {
	my ($class, $info) = @_;

	$recentlyPlayed{ $info->{'url'} } = $info;

	$class->saveRecentlyPlayed;
}

sub saveRecentlyPlayed {
	my $class = shift;
	my $now   = shift;

	unless ($now) {
		Slim::Utils::Timers::killTimers($class, \&saveRecentlyPlayed);
		Slim::Utils::Timers::setTimer($class, time() + 10, \&saveRecentlyPlayed, 'now');
		return;
	}

	my @played;

	for my $key (reverse keys %recentlyPlayed) {
		unshift @played, $recentlyPlayed{ $key };
	}

	$prefs->set('recent', \@played);
}

sub toplevel {
	my ($client, $callback, $args) = @_;
  
    addChannels($client, sub {
			my $items = shift;
            unshift @$items, { name => cstring($client, 'PLUGIN_FRANCETV_RECENTLYPLAYED'), image => Plugins::FranceTV::ProtocolHandler->getIcon(), url  => \&recentHandler };
			$callback->( $items );
		}, $args
	);
}

sub recentHandler {
	my ($client, $callback, $args) = @_;
	my @menu;

	for my $item(reverse values %recentlyPlayed) {
		my ($id) = Plugins::FranceTV::ProtocolHandler->getId($item->{'url'});
		
		if (my $lastpos = $cache->get("ft:lastpos-$id")) {
			my $position = Slim::Utils::DateTime::timeFormat($lastpos);
			$position =~ s/^0+[:\.]//;
				
			unshift  @menu, {
				name => $item->{'name'},
				image => $item->{'icon'},
				type => 'link',
				items => [ {
						title => cstring(undef, 'PLUGIN_FRANCETV_PLAY_FROM_BEGINNING'),
						type   => 'audio',
						url    => $item->{'url'},
					}, {
						title => cstring(undef, 'PLUGIN_FRANCETV_PLAY_FROM_POSITION_X', $position),
						type   => 'audio',
						url    => $item->{'url'} . "&lastpos=$lastpos",
					} ],
				};
		} else {	
			unshift  @menu, {
				name => $item->{'name'},
				play => $item->{'url'},
				on_select => 'play',
				image => $item->{'icon'},
				type => 'playlist',
			};
		}	
	}

	$callback->({ items => \@menu });
}

sub addChannels {
	my ($client, $cb, $args) = @_;
	my $page = '/publish/channels';  
	
	Plugins::FranceTV::API::search( $page, sub {
		my $items = [];
		my $data = shift;
		
		for my $entry (@{$data->{result}}) {
			push @$items, {
				name  => $entry->{label},
				type  => 'link',
				url   => \&channelsHandler,
				image => getImage($entry->{media_image}->{patterns}, 'carre') || Plugins::FranceTV::ProtocolHandler->getIcon(),
				passthrough 	=> [ { channel => $entry->{url} } ],
			};
		}
		
		@$items = sort {lc($a->{name}) cmp lc($b->{name})} @$items;
		$cb->( $items );
	
	}, { _ttl => '30days' } );	
}	

sub channelsHandler {
	my ($client, $cb, $args, $params) = @_;
	
	Plugins::FranceTV::API::searchProgram( sub {
		my $result = shift;
		my $items = [];
		
		for my $entry (@$result) {
			push @$items, {
				name  => $entry->{label} || $entry->{title},
				type  => 'playlist',
				url   => \&programHandler,
				image => getImage($entry->{media_image}->{patterns}, 'carre', 1) || Plugins::FranceTV::ProtocolHandler->getIcon(),
				passthrough 	=> [ { %${params}, program => $entry->{url} } ],
				favorites_url  	=> "ftplaylist://channel=$params->{channel}&program=$entry->{url}",
				favorites_type 	=> 'playlist',
			};
		}
		
		@$items = sort {lc($a->{name}) cmp lc($b->{name})} @$items;
		$cb->( $items );
		
	}, $params );
}

sub programHandler {
	my ($client, $cb, $args, $params) = @_;
	
	Plugins::FranceTV::API->searchEpisode( sub {
		my $result = shift;
		my $items = [];
				
		for my $entry (@$result) {
			my ($video) = grep { $_->{type} eq 'main' } @{$entry->{content_has_medias}};
			my $meta = $cache->get("ft:meta-" . $video->{media}->{si_id});
			
			if ((my $lastpos = $cache->get("ft:lastpos-" . $video->{media}->{si_id})) && $args && length $args->{index}) {
				my $position = Slim::Utils::DateTime::timeFormat($lastpos);
				$position =~ s/^0+[:\.]//;
				
				push @$items, {
					name 		=> $meta->{title},
					type 		=> 'link',
					image 		=> $meta->{cover},
					items => [ {
						title => cstring(undef, 'PLUGIN_FRANCETV_PLAY_FROM_BEGINNING'),
						type   => 'audio',
						url    => "francetv://$video->{media}->{si_id}&channel=$params->{channel}&program=$params->{program}",
					}, {
						title => cstring(undef, 'PLUGIN_FRANCETV_PLAY_FROM_POSITION_X', $position),
						type   => 'audio',
						url    => "francetv://$video->{media}->{si_id}&channel=$params->{channel}&program=$params->{program}&lastpos=$lastpos",
					} ],
				};
				
			} else {
				# $entry->{description} =~ s|<p>(.+?)</p>|$1\n|g;
				push @$items, {
					name 		=> $meta->{title},
					description	=> decode_entities($entry->{description} =~ s|<.+?>||gr),
					pubdate		=> $entry->{first_publication_date},
					duration	=> $meta->{duration},
					type 		=> 'playlist',
					on_select 	=> 'play',
					play 		=> "francetv://$video->{media}->{si_id}&channel=$params->{channel}&program=$params->{program}",
					image 		=> $meta->{cover},
				};
			}	
			
		}
		
		$cb->( $items );
		
	}, $params );
}

sub getImage {
	my ($images, $type, $index) = @_;
	my ($image) = grep { $_->{type} eq $type} @{$images};
	return undef unless $image;
	
	my @sorted = sort {lc $a cmp lc $b} keys %{$image->{urls}};
	$index = int ($#sorted * ($index || 0) / $#sorted);

	return IMAGE_URL . $image->{urls}->{$sorted[$index]};
}

=comment
sub webVideoLink {
	my ($client, $url, $obj, $remoteMeta, $tags, $filter) = @_;
	
	return unless $client;

	if (my $id = Plugins::YouTube::ProtocolHandler->getId($url)) {

		# only web UI (controllerUA undefined) and certain controllers allow watching videos
		if ( ($client->controllerUA && $client->controllerUA =~ $WEBLINK_SUPPORTED_UA_RE) || not defined $client->controllerUA ) {
			return {
				type    => 'text',
				name    => cstring($client, 'PLUGIN_FRANCETV_WEBLINK'),
				weblink => sprintf(VIDEO_BASE_URL, $id),
				jive => {
					actions => {
						go => {
							cmd => [ 'youtube', 'info' ],
							params => {
								id => $id,
							},
						},
					},
				},
			};
		}
	}
}

# special query to allow weblink to be sent to iPeng
sub cliInfoQuery {
	my $request = shift;

	if ($request->isNotQuery([['youtube'], ['info']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $id = $request->getParam('id');

	$request->addResultLoop('item_loop', 0, 'text', cstring($request->client, 'PLUGIN_YOUTUBE_PLAYLINK'));
	$request->addResultLoop('item_loop', 0, 'weblink', sprintf(VIDEO_BASE_URL, $id));
	$request->addResult('count', 1);
	$request->addResult('offset', 0);

	$request->setStatusDone();
}
=cut

1;
