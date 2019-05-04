package Slim::Networking::Async::HTTP;

=comment
	This file is overriding the default Slim::Networking::Async::HTTP
	new_socket method and adds a new method to enable socks options 
	to the original implementation. The new method reads the proxy 
	informations it needs for socks and then discards additionals 
	parameters
=cut

use strict;

my $log = logger('network.asynchttp');

__PACKAGE__->mk_accessor( rw => qw(
	socksAddr socksPort
) );

# BEGIN - new method
sub new {
	my ($class, $args) = @_;
	my $self = $class->SUPER::new;
	$self->socksAddr( $args->{socksAddr} ); 
	$self->socksPort( $args->{socksPort} || 1080 ); 
	return $self;
}
# END

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

	# BEGIN - add socks arguments
	my %args = @_;
	my %socks = ();
	
	if ($self->socksAddr) {
		require Plugins::Pluzz::Slim::HTTPSocks;
		require Plugins::Pluzz::Slim::HTTPSSocks if hasSSL();
		%socks = ( 	
			ProxyAddr => $self->socksAddr,
			ProxyPort => $self->socksPort,
			ConnectAddr => $args{PeerAddr} || $args{Host},
			ConnectPort => $args{PeerPort},
			Blocking => 1,
		);
		main::DEBUGLOG && $log->debug("Using SOCKS proxy ", $self->socksAddr, ":", $self->socksPort);
	}	
	# END	
	
	# Create SSL socket if URI is https
	# BEGIN - too many small changes to describe one by one
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
	
			if (%socks) {
				$sock = Slim::Networking::Async::Socket::HTTPSSocks->new( %args, %socks );
			}
			else {		
				$sock = Slim::Networking::Async::Socket::HTTPS->new( @_ );
			}	
			return $sock if $sock;

			# Failed. Try again with an explicit SNI.
			$args{SSL_hostname} = $args{Host};
			$args{SSL_verify_mode} = Net::SSLeay::VERIFY_NONE();
			if (%socks) {
				return Slim::Networking::Async::Socket::HTTPSSocks->new( %socks, %args );
			}
			else {		
				return Slim::Networking::Async::Socket::HTTPS->new( %args );
			}
		}
		else {
			# change the request to port 80
			$self->request->uri->scheme( 'http' );
			$self->request->uri->port( 80 );
			$args{PeerPort} = 80;
			
			if (%socks) {
				$socks{ConnectPort} => $args{PeerPort};
				return Slim::Networking::Async::Socket::HTTPSocks->new( %socks, %args );
			}
			else {		
				return Slim::Networking::Async::Socket::HTTP->new( %args );
			}
		}
	}
	elsif (%socks) {
		return Slim::Networking::Async::Socket::HTTPSocks->new( %args, %socks );
	}
	# END
	else { 	
		return Slim::Networking::Async::Socket::HTTP->new( @_ );
	}
}

1;
