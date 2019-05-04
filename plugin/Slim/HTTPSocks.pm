package Slim::Networking::Async::Socket::HTTPSocks;

use strict;

use base qw(IO::Socket::Socks Net::HTTP::Methods Slim::Networking::Async::Socket);

sub new {
	my ($class, %args) = @_;
	
	$args{SocksVersion} ||= 4;
	my $sock = $class->SUPER::new(%args) || return;
	$sock->blocking(0);

	bless $sock;
}

sub close {
	my $self = shift;
	
	# remove self from select loop
	Slim::Networking::Select::removeError($self);
	Slim::Networking::Select::removeRead($self);
	Slim::Networking::Select::removeWrite($self);
	Slim::Networking::Select::removeWriteNoBlockQ($self);

	$self->SUPER::close();
}

1;