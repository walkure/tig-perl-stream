#!/usr/bin/env perl

# tig-perl-stream 
#
# by walkure at kmc.gr.jp

use strict;
use warnings;

use diagnostics;

use Encode;
use IO::Select;
use JSON;
use Data::Dumper;
use YAML::Syck;

use Date::Parse;

use StreamSock;
use IRCSock;
use UpdateSock;

use bigint;
use Math::Int2Base qw(int2base base2int);

$| = 1;

my $path = $ARGV[0] || 'config.yaml';
print "++Loading YAML:$path\n";
my $yaml = YAML::Syck::LoadFile($path);

$yaml->{irc}{channels} = join(',',values %{$yaml->{channels}});

print "++Creating sockets\n";
my $stream = StreamSock->new($yaml->{account}); 
my $irc    = IRCSock->new($yaml->{irc});

my $s = new IO::Select;

$s->add($stream);
$s->add($irc);

my (%buffer,$footer);
$footer = '';

print "++Registering callback\n";

$stream->set_callback(\&stream_callback);
$irc->set_callback('privmsg',\&privmsg_callback);

$irc->login();

print "++Send Initial Requests\n";

$stream->send_request();

print "++Begin message loop\n";
while(1){
	my @socks = $s->can_read((defined $stream && defined $irc) ? undef : 5);
	
	unless(defined $stream){
		$stream = StreamSock->new($yaml->{account});
		if(defined $stream){
			print "++Reconnect Stream Success!\n";
			$s->add($stream);
			$stream->set_callback(\&stream_callback);
			$stream->send_request();
		}else{
			print "--Failure to connect Stream Server\n";
		}	
	}

	unless(defined $irc){
		$irc = IRCSock->new($yaml->{irc});
		if(defined $irc){
			print "++Reconnect IRC\n";
			$s->add($irc);
			$irc->login();
			$irc->set_callback('privmsg',\&privmsg_callback);
		}else{
			print "--Failure to connect IRC server\n";
		}
	}

	foreach my $sock(@socks){
		my $buf;
		my $len = $sock->sysread($buf,65535);
		if($len){
			#successfully read
			$buf =~ s/\x0D\x0A|\x0D|\x0A/\n/g;
			$buf = $buffer{$sock} . $buf if defined $buffer{$sock} && length $buffer{$sock};
			my $i;
			while (($i = index($buf,"\n")) >= 0){ #index for the head of string is 0
				my $line = substr($buf,0,$i);
				$buf = substr($buf,$i+1);
				$sock->parse_line($line);
			}
			$buffer{$sock} = $buf;
		}else{
			#connection closed
			print "++Connection closed...\n";
			$s->remove($sock);
			$sock->close();

			if(ref($sock) eq 'StreamSock'){
				$stream = StreamSock->new($yaml->{account});
				if(defined $stream){
					print "++Reconnect Stream Success!\n";
					$s->add($stream);
					$stream->set_callback(\&stream_callback);
					$stream->send_request();
				}else{
					print "--Failure to connect Stream Server\n";
				}	
			}elsif(ref($sock) eq 'IRCSock'){
				$irc = IRCSock->new($yaml->{irc});
				if(defined $irc){
					print "++Reconnect IRC\n";
					$s->add($irc);
					$irc->login();
					$irc->set_callback('privmsg',\&privmsg_callback);
				}else{
					print "--Failure to connect IRC server\n";
				}
			}elsif(ref($sock) eq 'UpdateSock'){
				print "Status Updated\n";
			}else{
				print ref($sock).":Unknown socket error\n";
			}
		}
	}
}

print "--Unexpected codepath...\n";
exit;

sub stream_callback
{
	my $obj = shift;
	my $event = $obj->{event};
	my $dm = $obj->{direct_message};

	if(defined $obj->{text}){
		my $text = Encode::encode($yaml->{irc}{charset},$obj->{text});
		my $talker = Encode::encode($yaml->{irc}{charset},$obj->{user}->{name});
		my @epoch = localtime(str2time($obj->{created_at}));
		my $date = sprintf('%02d:%02d:%02d',$epoch[2],$epoch[1],$epoch[0]);
		my $id = int2base($obj->{id},62);

		my $msg;
		if(defined $obj->{retweeted_status}){
		   	$msg = "$date <$talker($obj->{user}->{screen_name}):$id>R $text";
		}else{
			$msg = "$date <$talker($obj->{user}->{screen_name}):$id> $text";
		}

		$msg =~ s/\n//g;
		$msg =~ s/&lt;/</g;
		$msg =~ s/&gt;/>/g;
		$msg =~ s/&amp/&/g;
		$msg .= "\n";

		print $irc 'PRIVMSG '.$yaml->{channels}{'*'}.' :'.$msg;
		if($text =~ /$yaml->{account}{name}/i ){
			print $irc 'PRIVMSG '.$yaml->{channels}{'@'}.' :'.$msg
				if defined $yaml->{channels}{'@'};
		}
	}elsif(defined $event){
		my $text = Encode::encode($yaml->{irc}{charset},$obj->{target_object}{text});
		my $src_name= Encode::encode($yaml->{irc}{charset},$obj->{source}{name});
		my $dst_name = Encode::encode($yaml->{irc}{charset},$obj->{target}{name});
		my $src = $obj->{source}{screen_name};
		my $dst = $obj->{target}{screen_name};
		my @epoch = localtime(str2time($obj->{created_at}));
		my $date = sprintf('%02d:%02d:%02d',$epoch[2],$epoch[1],$epoch[0]);
		my $msg;
		my $id = int2base($obj->{target_object}{id},62);

		if($event eq 'favorite'){
			$msg = "$date Fav by $src_name($src) <$dst_name($dst):$id> $text";
		}elsif($event eq 'unfavorite'){
			$msg = "$date UFav by $src_name($src) <$dst_name($dst):$id> $text";
		}elsif($event eq 'follow'){
			$msg = "$date [$src_name($src)] becomes [$dst_name($dst)] follower.";
		}elsif($event eq 'list_member_added'){
			my $list = Encode::encode($yaml->{irc}{charset},$obj->{target_object}{full_name});
			$msg = "$date [$src_name($src)] added $list.";
		}

		if(defined $msg){
			$msg =~ s/\n//g;
			$msg =~ s/&lt;/</g;
			$msg =~ s/&gt;/>/g;
			$msg =~ s/&amp/&/g;
			$msg .= "\n";

			print $irc 'PRIVMSG '.$yaml->{channels}{'*'}.' :'.$msg;
			if(defined $yaml->{account}{name} && length $yaml->{account}{name} ){
				print $irc 'PRIVMSG '.$yaml->{channels}{'@'}.' :'.$msg
					if defined $yaml->{channels}{'@'};
			}
		}
	}elsif(defined $dm){
		my $text = Encode::encode($yaml->{irc}{charset},$dm->{text});
		my $talker = Encode::encode($yaml->{irc}{charset},$dm->{sender}{name});
		my $src = $dm->{sender}{screen_name};
		my @epoch = localtime(str2time($dm->{created_at}));
		my $date = sprintf('%02d:%02d:%02d',$epoch[2],$epoch[1],$epoch[0]);

		my $msg = "$date DM <$talker($src)> $text";

		$msg =~ s/\n//g;
		$msg =~ s/&lt;/</g;
		$msg =~ s/&gt;/>/g;
		$msg =~ s/&amp/&/g;
		$msg .= "\n";

		print $irc 'PRIVMSG '.$yaml->{channels}{'*'}.' :'.$msg;
		if(defined $yaml->{account}{name} && length $yaml->{account}{name} ){
			print $irc 'PRIVMSG '.$yaml->{channels}{'@'}.' :'.$msg
				if defined $yaml->{channels}{'@'};
		}
	}
	
}

sub privmsg_callback
{
	my($self,$line,$sender,$target,$args,$fragment) = @_;

	Encode::from_to($fragment,$yaml->{irc}{charset},'utf-8');
	
	my $updater = UpdateSock->new($yaml->{account});
	$s->add($updater);
	my $action = substr($fragment,0,1);
	my $msg = $fragment;
	if($action eq '+' || $action eq '-' || $action eq '='){
		print "Received unknown command char\n";
		return;
	}

	if($action eq '>' || $action eq '@' || $action eq '*' || $action eq '$' || $action eq '#'){

		# command message format:[>@*#]string
		# [>@*]stringA stringB or[>@*#]stringA
		my $index = index($msg,' ');
		my ($key,$text);
		if($index > 0){
			$key  = substr($msg,1,$index-1);
			$text = substr($msg,$index+1,length($msg)-$index);
		}else{
			$key  = substr($msg,1,length($msg)-1);
			$text = undef;
		}

		if($action eq '#'){
			if(length $key){
				print "++Set Tag\n";
				$footer = ' '.$key;
			}else{
				print "++Remove Tag\n";
				$footer = '';
			}
		}else{

			#send command when successfully get UID.If failure to get UID,ignore line.
			#If you forget to convet your UID 'num' to 'string', die at Net::Twitter::Lite
			if(my $uid = get_uid($key)){
				if($action eq '>' && defined $text){
					print "Send Reply to [$uid]\n";
					$text .= $footer;
					$updater->update({status => $text, in_reply_to_status_id => "$uid"});
				}elsif($action eq '*'){
					print "Add/Remove Favorite to [$uid]\n";
					$updater->favorite("$uid",$text);
				}elsif($action eq '@'){
					print "Send Retweet [$uid]\n";
					$updater->retweet("$uid");
				}elsif($action eq '$'){
					print "Destroy [$uid]\n";
					$updater->destroy("$uid");
				}else{
					print "reply[$uid] without text...\n";
				}
			}else{
				print "UIDKey[$key] is missing...\n";
			}
		}	
	}else{
		print "Simply post message\n";
		$msg .= $footer;
		$updater->update({status => $msg});
	}
}

sub get_uid
{
	my $key = shift;
	my $uid;

	return $1 if($key =~ /(\d{17,})/);
	return $uid if(defined ($uid = eval('base2int($key,62);')));

	undef;
}