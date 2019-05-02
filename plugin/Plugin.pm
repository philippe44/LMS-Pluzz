package Plugins::Pluzz::Plugin;

# Plugin to stream audio from Pluzz videos streams
#
# Released under GPLv2

use strict;
use base qw(Slim::Plugin::OPMLBased);
use File::Spec::Functions;

use FindBin qw($Bin);
use lib catdir($Bin, 'Plugins', 'Pluzz', 'lib');
use IO::Socket::Socks;

use Data::Dumper;
use Encode qw(encode decode);

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::Pluzz::API;
use Plugins::Pluzz::ProtocolHandler;
use Plugins::Pluzz::ListProtocolHandler;

# override default Slim::Networking::SimpleAsyncHTTP
use Plugins::Pluzz::Slim::SimpleAsyncHTTP;
# override default Slim::Networking::Async::HTTP
eval { require Plugins::Pluzz::Slim::HTTP };

my $WEBLINK_SUPPORTED_UA_RE = qr/iPeng|SqueezePad|OrangeSqueeze/i;

use constant IMAGE_URL => 'http://refonte.webservices.francetelevisions.fr';

my	$log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.pluzz',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_PLUZZ',
});

my $prefs = preferences('plugin.pluzz');
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
		tag    => 'pluzz',
		menu   => 'radios',
		is_app => 1,
		weight => 10,
	);

=comment	
	Slim::Menu::TrackInfo->registerInfoProvider( pluzz => (
		after => 'bottom',
		func  => \&webVideoLink,
	) );

	Slim::Menu::GlobalSearch->registerInfoProvider( pluzz => (
		after => 'middle',
		name  => 'PLUGIN_PLUZZ',
		func  => \&searchInfoMenu,
	) );
=cut	

	if ( main::WEBUI ) {
		require Plugins::Pluzz::Settings;
		Plugins::Pluzz::Settings->new;
	}
	
	for my $recent (reverse @{$prefs->get('recent')}) {
		$recentlyPlayed{ $recent->{'url'} } = $recent;
	}
	
#        |requires Client
#        |  |is a Query
#        |  |  |has Tags
#        |  |  |  |Function to call
	Slim::Control::Request::addDispatch(['pluzz', 'info'], 
		[1, 1, 1, \&cliInfoQuery]);
		
	
}

sub shutdownPlugin {
	my $class = shift;

	$class->saveRecentlyPlayed('now');
}

sub getDisplayName { 'PLUGIN_PLUZZ' }

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
			
	$callback->([
		{ name => 'France 2', type => 'url', image => '/plugins/Pluzz/html/images/france2.png', url => \&channelsHandler, passthrough => [ { channel => 'france2' } ] },
		
		{ name => 'France 3', type => 'url', image => '/plugins/Pluzz/html/images/france3.png', url => \&channelsHandler, passthrough => [ { channel => 'france3' } ] },
		
		{ name => 'France 4', type => 'url', image => '/plugins/Pluzz/html/images/france4.png', url => \&channelsHandler, passthrough => [ { channel => 'france4' } ] },
		
		{ name => 'France 5', type => 'url', image => '/plugins/Pluzz/html/images/france5.png', url => \&channelsHandler, passthrough => [ { channel => 'france5' } ] },
		
		{ name => 'France O', type => 'url', image => '/plugins/Pluzz/html/images/franceO.png', url => \&channelsHandler, passthrough => [ { channel => 'franceo' } ] },
		
		{ name => cstring($client, 'PLUGIN_PLUZZ_RECENTLYPLAYED'), image => getIcon(), url  => \&recentHandler, },
	]);
}

sub getIcon {
	my ( $class, $url ) = @_;

	return Plugins::Pluzz::Plugin->_pluginDataFor('icon');
}


sub recentHandler {
	my ($client, $callback, $args) = @_;

	my @menu;

	for my $item(reverse values %recentlyPlayed) {
		unshift  @menu, {
			name => $item->{'name'},
			play => $item->{'url'},
			on_select => 'play',
			image => $item->{'icon'},
			type => 'playlist',
		};
	}

	$callback->({ items => \@menu });
}


sub channelsHandler {
	my ($client, $cb, $args, $params) = @_;
	
	Plugins::Pluzz::API->searchProgram( sub {
		my $result = shift;
		my $items = [];
		
		for my $entry (@$result) {
							
			push @$items, {
				name  => $entry->{titre_programme},
				type  => 'playlist',
				url   => \&searchHandler,
				image => IMAGE_URL . "$entry->{image_medium}",
				passthrough 	=> [ { %${params}, code_programme => $entry->{code_programme} } ],
				favorites_url  	=> "pzplaylist://channel=$params->{channel}&program=$entry->{code_programme}",
				favorites_type 	=> 'audio',
			};
			
		}
		
		@$items = sort {lc($a->{name}) cmp lc($b->{name})} @$items;
		
		$cb->( $items );
		
	}, $params );
}


sub searchHandler {
	my ($client, $cb, $args, $params) = @_;
	
	Plugins::Pluzz::API->searchEpisode( sub {
		my $result = shift;
		my $items = [];
				
		for my $entry (@$result) {
			my ($date) =  ($entry->{date_diffusion} =~ m/(\S*)T/);
						
			push @$items, {
				name 		=> $entry->{soustitre} || "$entry->{titre} ($date)",
				type 		=> 'playlist',
				on_select 	=> 'play',
				play 		=> "pluzz://$entry->{id_diffusion}&channel=$params->{channel}&program=$params->{code_programme}",
				image 		=> IMAGE_URL . "$entry->{image_medium}",
			};
			
		}
		
		$cb->( $items );
		
	}, $params );
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
				name    => cstring($client, 'PLUGIN_PLUZZ_WEBLINK'),
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

sub searchInfoMenu {
	my ($client, $tags) = @_;

	my $query = $tags->{'search'};

	return {
		name => cstring($client, 'PLUGIN_PLUZZ'),
		items => [
			{
				name => cstring($client, 'PLUGIN_YOUTUBE_SEARCH'),
				type => 'link',
				url  => \&searchHandler, 
				passthrough => [ { q => $query }]
			},
			{
				name => cstring($client, 'PLUGIN_YOUTUBE_MUSICSEARCH'),
				type => 'link',
				url  => \&searchHandler, 
				passthrough => [ { videoCategoryId => 10, q => $query }]
			},
		   ],
	};
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
