package StreamSock;

# tig-perl-stream 
#
# by walkure at 3pf.jp

use strict;
use warnings;

use Encode;
use OAuth::Lite::Consumer;
use IO::Socket::SSL;
use JSON;
use Data::Dumper;
use base qw/IO::Socket::SSL/;

sub configure
{
	my ( $self, $args ) = @_;

	*$self->{consumer} = OAuth::Lite::Consumer -> new(%{$args->{PeerAddr}});
	*$self->{token}    = OAuth::Lite::Token    -> new(%{$args->{PeerAddr}});
	$args->{PeerAddr} = 'userstream.twitter.com:https';
	$self->SUPER::configure($args);
}

sub set_callback
{
	my ($self,$func) = @_; 
	*$self->{callback} = $func;
}


sub send_request
{
	my $self = shift;

	my $request = *$self->{consumer}->gen_oauth_request(
		method => 'GET',
#		url    => 'https://userstream.twitter.com/2/user.json',
		url    => 'https://userstream.twitter.com/1.1/user.json',
		token  => *$self->{token},
#		params => {replies => 'all'},
	);

	$request->header(Host => $request->uri->host);
	$request->header(UserAgent => 'UserStream Client');

	#Begin Session
	print 'Connect to:'.$request->uri->path_query."\n";
	print $self $request->method.' '.$request->uri->path_query." HTTP/1.1\r\n";
	print $self $request->headers->as_string;
	print $self "\r\n";
}

sub parse_line
{
	my ($self,$line) = @_;
	if(defined *$self->{state}){
		$self->parse_body($line) if length $line;
	}else{
		if(length $line){
			$self->parse_header($line);
		}else{
			*$self->{state} = 1;
#			print Dumper *$self->{header};
		}
	}
}

sub parse_header
{
	my ($self,$line) = @_;
	
	unless(defined *$self->{header}){
		*$self->{header} = HTTP::Response->parse($line);
	}else{
		my($name,$body) = split(/:/,$line);
		*$self->{header}->header($name,$body);
	}
}

sub parse_body
{
	my ($self,$line) = @_;
	
	if($line =~ /^[a-f0-9]+/){
		my $length = hex($line);
		if($length > 0){
			*$self->{length} = $length;
			return;
		}
	}
	
	my $obj = eval{ decode_json($line) };
	unless(defined $obj){
		print "Cannot decode JSON[$line]\n";
		return;
	}

	*$self->{callback}->($obj) if defined *$self->{callback};
}

1;
