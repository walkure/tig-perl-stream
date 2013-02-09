package DeleteNoticeSock;

use strict;
use warnings;

use Encode;
use OAuth::Lite::Consumer;
use Data::Dumper;
use JSON;

use base qw/IO::Socket::INET/;

sub configure
{
	my ( $self, $args ) = @_;

	*$self->{consumer} = OAuth::Lite::Consumer -> new(%{$args->{PeerAddr}});
	*$self->{token}    = OAuth::Lite::Token    -> new(%{$args->{PeerAddr}});
	$args->{PeerAddr} = 'api.twitter.com:http';
	$self->SUPER::configure($args);
}

sub set_callback
{
	my ($self,$func) = @_;
	*$self->{callback} = $func;
}

sub notice_delete 
{
	my ($self,$user_id,$status_id) = @_;

	print "uid:$user_id,status:$status_id\n";

	#lookup user id
	my $request = *$self->{consumer}->gen_oauth_request(
		method => 'GET',
		url    => 'http://api.twitter.com/1/users/show.json',
		token  => *$self->{token},
		params => {user_id => $user_id},
	);

	*$self->{status_id} = $status_id;
	$self->process_request($request);
}


sub process_request
{
	my ($self,$request) = @_;

	$request->header(Host => $request->uri->host);
#	print $request->uri->path_query."\n";

	print $self $request->method.' '.$request->uri->path_query." HTTP/1.0\r\n";
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
#	print "[$line]\n";
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
		print "Cannot decode JSON($@)[$line]\n";
		return;
	}

#	print Dumper $obj;
	*$self->{callback}->($obj,*$self->{status_id}) if defined *$self->{callback};

}

1;
