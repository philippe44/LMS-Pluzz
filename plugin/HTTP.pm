package Slim::Networking::Async::HTTP;

use strict;

__PACKAGE__->mk_accessor( rw => qw(
	socks
) );

my $base = 'Pluzz';

sub new {
	my ($class, $args) = @_;
	my $self = $class->SUPER::new;
	
	if ( $args->{socks} ) {
		eval {
			require "Plugins::$base::Slim::HTTPSocks";
			require "Plugins::$base::Slim::HTTPSSocks";
		};
	
		if (!$@) {			
			# no need for a hash mk_accessor type as we don't access individual keys
			$self->socks($args->{socks});
			main::INFOLOG && $log->info("Using SOCKS $args->{ProxyAddr}::$args->{ProxyPort} to connect");
		}	
	}	
	
	return $self;
}

sub new_socket {
	my $self = shift;
	
	if ( my $proxy = $self->use_proxy ) {

		main::INFOLOG && $log->info("Using proxy $proxy to connect");
	
		my ($pserver, $pport) = split /:/, $proxy;
	
		return Slim::Networking::Async::Socket::HTTP->new(
			@_,
			PeerAddr => $pserver,
			PeerPort => $pport || 80,
		);
	}
	
	# Create SSL socket if URI is https
	if ( $self->request->uri->scheme eq 'https' ) {
		if ( hasSSL() ) {
			# From http://bugs.slimdevices.com/show_bug.cgi?id=18152:
			# We increasingly find servers *requiring* use of the SNI extension to TLS.
			# IO::Socket::SSL supports this and, in combination with the Net:HTTPS 'front-end',
			# will default to using a server name (PeerAddr || Host || PeerHost). But this will fail
			# if PeerAddr has been set to, say, IPv4 or IPv6 address form. And LMS does that through
			# DNS lookup.
			# So we will probably need to explicitly set "SSL_hostname" if we are to succeed with such
			# a server.
			
			# First, try without explicit SNI, so we don't inadvertently break anything. 
			# (This is the 'old' behaviour.) (Probably overly conservative.)

			my $sock;
						
			if ($self->socks) {
				$sock = Slim::Networking::Async::Socket::HTTPSSocks->new( %{$self->socks}, @_ );
			}
			else {		
				$sock = Slim::Networking::Async::Socket::HTTPS->new( @_ );
			}	
			return $sock if $sock;
			
			my %args = @_;
			
			# Failed. Try again with an explicit SNI.
			$args{SSL_hostname} = $args{Host};
			$args{SSL_verify_mode} = Net::SSLeay::VERIFY_NONE();
			if ($self->socks) {
				return Slim::Networking::Async::Socket::HTTPSSocks->new( %{$self->socks}, %args );
			}
			else {		
				return Slim::Networking::Async::Socket::HTTPS->new( %args );
			}
		}
		else {
			# change the request to port 80
			$self->request->uri->scheme( 'http' );
			$self->request->uri->port( 80 );
			
			my %args = @_;
			$args{PeerPort} = 80;
			
			if ($self->socks) {
				return Slim::Networking::Async::Socket::HTTPSocks->new( %{$self->socks}, %args );
			}
			else {		
				return Slim::Networking::Async::Socket::HTTP->new( %args );
			}
		}
	}
	elsif ($self->socks) {
		return Slim::Networking::Async::Socket::HTTPSocks->new( %{$self->socks}, @_ );
	}
	else { 	
		return Slim::Networking::Async::Socket::HTTP->new( @_ );
	}
}

1;
