package Slim::Utils::Misc;

sub obfuscate {
  # this is vain unless we have a machine-specific ID	
  return MIME::Base64::encode(scalar(reverse(unpack('H*', $_[0]))));
}

sub unobfuscate {
  # this is vain unless we have a machine-specific ID	
  return pack('H*', scalar(reverse(MIME::Base64::decode($_[0]))));
}

1;