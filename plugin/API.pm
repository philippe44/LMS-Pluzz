package Plugins::Pluzz::API;

#use strict;

use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;
use List::Util qw(min max);

use Data::Dumper;

use constant API_URL => 'http://pluzz.webservices.francetelevisions.fr';

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
	
use Plugins::Pluzz::AsyncSocks;

my $prefs = preferences('plugin.pluzz');
my $log   = logger('plugin.pluzz');
my $cache = Slim::Utils::Cache->new();


sub searchProgram {
	my ( $class, $cb, $params ) = @_;
	
	$log->debug("get program $params->{channel}");
	
	search( sub {
	
		my $result = shift;
		my @input = grep { $_->{chaine_id} eq $params->{channel} } @{$result->{reponse}->{emissions} || []};
		my @list;
				
		#keep only 1st instance of all shows for the requested channel
		foreach my $item (@input) {
			push(@list, $item) if !grep {$_->{code_programme} eq $item->{code_programme} } @list;
		}
		
		$cb->( \@list );
		
	}, $params );	

}

sub searchEpisode {
	my ( $class, $cb, $params ) = @_;
	
	$log->debug("get episode $params->{code_programme} ($params->{channel})");
	
	search( sub {
		my $result = shift;
						
		#keep all shows for the requested channel
		my @list = grep { $_->{code_programme} eq $params->{code_programme} } @{$result->{reponse}->{emissions} || []};
		
		for my $entry (@list) {
			my ($date) =  ($entry->{date_diffusion} =~ m/(\S*)T/);
			
			$cache->set("pz:meta-" . $entry->{id_diffusion}, 
				{ title  => $entry->{soustitre} || "$entry->{titre} ($date)",
				  icon     => "http://pluzz.francetv.fr$entry->{image_medium}",
				  cover    => "http://pluzz.francetv.fr$entry->{image_medium}",
				  duration => $entry->{duree_reelle},
				  artist   => $entry->{presentateurs},
				  album    => $entry->{titre_programme},
				  type	   => 'Pluzz',
				}, 900) if ( !$cache->get("pz:meta-" . $entry->{id_diffusion}) );
		}
		
		$cb->( \@list );
	
	}, $params ); 
	
}	


sub search	{
	my ( $cb, $params ) = @_;
	my $url = API_URL . "/pluzz/liste/type/replay/chaine/$params->{channel}/nb/500?";
	my $cacheKey = md5_hex($url);
	my $cached;
	
	$log->debug("wanted url: $url");
	
	if ( !$prefs->get('no_cache') && ($cached = $cache->get($cacheKey)))  {
		main::INFOLOG && $log->info("Returning cached data for: $url");
		$cb->($cached);
		return;
	}

	Plugins::Pluzz::AsyncSocks->new(
	
		sub {
			my $response = shift;
			my $result = eval { decode_json($response->content) };
			
			$result ||= {};
			
			$cache->set($cacheKey, $result, 900);
			
			$cb->($result);
		},

		sub {
			$log->error($_[1]);
			$cb->( { error => $_[1] } );
		}

	)->get($url);
			
	
}


1;