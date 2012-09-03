package UpdateSock;

# tig-perl-stream 
#
# by walkure at 3pf.jp

use strict;
use warnings;

use Encode;
use OAuth::Lite::Consumer;
use Data::Dumper;
use base qw/IO::Socket::INET/;

sub configure
{
	my ( $self, $args ) = @_;

	*$self->{consumer} = OAuth::Lite::Consumer -> new(%{$args->{PeerAddr}});
	*$self->{token}    = OAuth::Lite::Token    -> new(%{$args->{PeerAddr}});
	$args->{PeerAddr} = 'api.twitter.com:http';
	$self->SUPER::configure($args);
}

sub update
{
	my ($self,$params) = @_;

	my $request = *$self->{consumer}->gen_oauth_request(
		method => 'POST',
		url    => 'http://api.twitter.com/1/statuses/update.json',
		token  => *$self->{token},
		params => $params,
	);

	$self->process_request($request);
}

sub destroy
{
	my ($self,$id) = @_;

	my $request = *$self->{consumer}->gen_oauth_request(
		method => 'POST',
		url    => "http://api.twitter.com/1/statuses/destroy/$id.json",
		token  => *$self->{token},
		params => {id => $id},
	);
	$self->process_request($request);
}

sub favorite
{
	my ($self,$id,$state) = @_;

	my $mode = defined $state ? 'destroy' : 'create';

	my $request = *$self->{consumer}->gen_oauth_request(
		method => 'POST',
		url    => "http://api.twitter.com/1/favorites/$mode/$id.json",
		token  => *$self->{token},
		params => {id => $id},
	);

	$self->process_request($request);
}

sub retweet
{
	my ($self,$id) = @_;

	my $request = *$self->{consumer}->gen_oauth_request(
		method => 'POST',
		url    => "http://api.twitter.com/1/statuses/retweet/$id.json",
		token  => *$self->{token},
		params => {id => $id},
	);
	
	$self->process_request($request);
}

sub process_request
{
	my ($self,$request) = @_;

	$request->header(Host => $request->uri->host);
#	print $request->uri->path."\n";

	print $self $request->method.' '.$request->uri->path." HTTP/1.0\r\n";
	print $self $request->headers->as_string."\r\n";
	print $self $request->content()."\r\n";
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

	my $obj = eval{ decode_json($line) };
	unless(defined $obj){
		print "Cannot decode JSON[$line]\n";
		return;
	}
#	print Dumper $obj;
}

1;
