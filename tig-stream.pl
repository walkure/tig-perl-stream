#!/usr/bin/env perl

# tig-perl-stream 
#
# by walkure at 3pf.jp

use strict;
use warnings;
use diagnostics;

use utf8;
binmode STDOUT,':utf8';

use Encode;
use IO::Select;
use JSON;
use YAML::Syck;

use Date::Parse;

use StreamSock;
use IRCSock;
use UpdateSock;
use DeleteNoticeSock;

use bigint;
use Math::Int2Base qw(int2base base2int);

use Cache::LRU;

use Data::Dumper;
{
	package Data::Dumper;
	sub qquote { return wantarray? @_ : shift; }
}
$Data::Dumper::Useperl = 1;


$| = 1;

my $path = $ARGV[0] || 'config.yaml';
print "++Loading YAML:$path\n";
my $yaml = YAML::Syck::LoadFile($path);

$yaml->{irc}{channels} = join(',',values %{$yaml->{channels}});
my $uids = Cache::LRU->new(size => 100);

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
				$sock->parse_line($buffer{$sock}."\n");
				print "Status Updated\n";
				updated_process($sock);
			}elsif(ref($sock) eq 'DeleteNoticeSock'){
				print "UID Lookup Done\n";
				$sock->parse_line($buffer{$sock}."\n");
#				notice_delete_tweet($sock);
			}else{
				print ref($sock).":Unknown socket error\n";
			}
		}
	}
}

print "--Unexpected codepath...\n";
exit;

sub expand_url
{
	my $obj = shift;
	my $text = $obj->{text};
	my @short_urls;

	if(defined $obj->{entities}{urls}){
		foreach my $url(@{$obj->{entities}{urls}} ){
			push(@short_urls,{
					offset => $url->{indices}->[0],
					short_url => $url->{url},
					long_url => ' '.$url->{expanded_url}.' ',
				});
		}
	}
	if(defined $obj->{entities}{media}){
		foreach my $url(@{$obj->{entities}{media}}){
			push(@short_urls,{
					offset => $url->{indices}->[0],
					short_url => $url->{url},
					long_url => ' '.$url->{media_url}.' ',
				});

		}
	}
	if(scalar @short_urls) {
		foreach my $url(sort {$b->{offset} <=> $a->{offset}} @short_urls){
			substr($text,$url->{offset},length($url->{short_url}),$url->{long_url});
		}
	}

	$text;
}

sub stream_callback
{
	my $obj = shift;
	my $event = $obj->{event};
	my $dm = $obj->{direct_message};
	my $del = $obj->{delete};

	if(defined $obj->{text}){
		my $talker = Encode::encode($yaml->{irc}{charset},$obj->{user}{name});
		my @epoch = localtime(str2time($obj->{created_at}));
		my $date = sprintf('%02d:%02d:%02d',$epoch[2],$epoch[1],$epoch[0]);
		my $id = int2base($obj->{id},62);

		my ($msg,$text);
		if(defined $obj->{retweeted_status}){
			$text = '@'.$obj->{retweeted_status}{user}{screen_name}.': '.Encode::encode($yaml->{irc}{charset},expand_url($obj->{retweeted_status}));

		   	$msg = "$date <$talker($obj->{user}{screen_name}):$id>RT $text";
		}else{
			$text = Encode::encode($yaml->{irc}{charset},expand_url($obj));

			$msg = "$date <$talker($obj->{user}{screen_name}):$id> $text";
		}

		$msg =~ s/\n//g;
		$msg =~ s/&lt;/</g;
		$msg =~ s/&gt;/>/g;
		$msg =~ s/&amp/&/g;
		$msg .= "\n";

		if($text =~ /$yaml->{account}{name}/i && defined $yaml->{channels}{'@'}){
			print $irc 'PRIVMSG '.$yaml->{channels}{'@'}.' :'.$msg;
		}else{
			print $irc 'PRIVMSG '.$yaml->{channels}{'*'}.' :'.$msg;
		}
	}elsif(defined $event){
		my $text = Encode::encode($yaml->{irc}{charset},expand_url($obj->{target_object}));
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
			$msg = "$date [$src_name($src)] added [$dst_name($dst)] to $list.";
		}elsif($event eq 'list_member_removed'){
			my $list = Encode::encode($yaml->{irc}{charset},$obj->{target_object}{full_name});
			$msg = "$date [$src_name($src)] removed [$dst_name($dst)] from $list.";
		}elsif($event eq 'list_user_subscribed'){
			my $list = Encode::encode($yaml->{irc}{charset},$obj->{target_object}{full_name});
			$msg = "$date [$src_name($src)] subscribed $list created by [$dst_name($dst)].";
		}elsif($event eq 'list_user_unsubscribed'){
			my $list = Encode::encode($yaml->{irc}{charset},$obj->{target_object}{full_name});
			$msg = "$date [$src_name($src)] unsubscribed $list created by[$dst_name($dst)].";
		}elsif($event eq 'user_update' || $event eq 'list_created' || $event eq 'list_destroyed' || $event eq 'access_revoked' || 
				$event eq 'access_unrevoked' || $event eq 'block'){
				#do nothing
		}else{
			print Dumper $obj;
		}

		if(defined $msg){
			$msg =~ s/\n//g;
			$msg =~ s/&lt;/</g;
			$msg =~ s/&gt;/>/g;
			$msg =~ s/&amp/&/g;
			$msg .= "\n";

			if(defined $yaml->{account}{name} && length $yaml->{account}{name} &&
					defined $yaml->{channels}{'@'}){
				print $irc 'PRIVMSG '.$yaml->{channels}{'@'}.' :'.$msg;
			}else{
				print $irc 'PRIVMSG '.$yaml->{channels}{'*'}.' :'.$msg;
			}
		}
	}elsif(defined $dm){
		my $text = Encode::encode($yaml->{irc}{charset},$dm->{text});
		my $talker = Encode::encode($yaml->{irc}{charset},$dm->{sender}{name});
		my $listener = Encode::encode($yaml->{irc}{charset},$dm->{recipient}{name});
		my $src = $dm->{sender}{screen_name};
		my $dst = $dm->{recipient}{screen_name};
		my @epoch = localtime(str2time($dm->{created_at}));
		my $date = sprintf('%02d:%02d:%02d',$epoch[2],$epoch[1],$epoch[0]);

		my $msg = "$date DM <$talker($src)> -> <$listener($dst)> $text";

		$msg =~ s/\n//g;
		$msg =~ s/&lt;/</g;
		$msg =~ s/&gt;/>/g;
		$msg =~ s/&amp/&/g;
		$msg .= "\n";

		if(defined $yaml->{account}{name} && length $yaml->{account}{name} &&
				defined $yaml->{channels}{'@'} ){
			print $irc 'PRIVMSG '.$yaml->{channels}{'@'}.' :'.$msg;
		}else{
			print $irc 'PRIVMSG '.$yaml->{channels}{'*'}.' :'.$msg;
		}
	}elsif(defined $del){
#		print Dumper $del->{status};
		my $user_info = $uids->get($del->{status}{user_id_str});
		if(defined $user_info){
			print 'Lookup cache user_info:'.$user_info->{id_str}."\n";
			delete_notice($user_info,$del->{status}{id_str});
		}else{
			my $notice = DeleteNoticeSock->new($yaml->{account});
			$s->add($notice);
			$notice->set_callback(\&delete_callback);
			$notice->notice_delete($del->{status}{user_id_str},$del->{status}{id_str});
		}

	}
	
}

sub privmsg_callback
{
	my($self,$line,$sender,$target,$args,$fragment) = @_;

	Encode::from_to($fragment,$yaml->{irc}{charset},'utf-8');
	
	my ($updater,$i);
	$i = 5;
	while($i --){
	   	$updater = UpdateSock->new($yaml->{account});
		last if defined $updater;
	}

	unless(defined $updater){
		print "cannot establish twitter updater\n";
		return;
	}

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

sub delete_callback
{
	my ($user_info,$status_id) = @_;
#	$uids->set($user_info->{id_str} => $user_info);
	$uids->set(
		$user_info->{id_str} => {
			id_str 		=> $user_info->{id_str},
			name 		=> $user_info->{name},
			screen_name => $user_info->{screen_name},
		}
	);
	print 'Set UserInfoCache:'.$user_info->{id_str}."\n";
	delete_notice($user_info,$status_id);
}

sub delete_notice
{
	my ($user_info,$status_id) = @_;

	my $name = Encode::encode($yaml->{irc}{charset},$user_info->{name});
	my $scrn = $user_info->{screen_name};
	my $uid  = $user_info->{id_str};
	my $status_64id = int2base($status_id,62);
	print "Get Deleted tweet($status_id)($status_64id) user id $scrn($user_info->{id_str})\n";


	my $msg = "$name($scrn)(id=$uid) deleted tweet ID:$status_64id($status_id)";

	$msg =~ s/\n//g;
	$msg =~ s/&lt;/</g;
	$msg =~ s/&gt;/>/g;
	$msg =~ s/&amp/&/g;
	$msg .= "\n";

	print $irc 'PRIVMSG '.$yaml->{channels}{'*'}.' :'.$msg;
}

sub get_uid
{
	my $key = shift;
	my $uid;

	return $1 if($key =~ /(\d{17,})/);
	return $uid if(defined ($uid = eval('base2int($key,62);')));

	undef;
}

sub updated_process
{
	my $sock = shift;

	my $hdr = *$sock->{header};
	my $obj = *$sock->{json};

	return if($hdr->code == 200);
	return unless defined $obj->{errors};
	
	my $err = $obj->{errors};
	my $msg = $err;

	$msg =  '('.$err->[0]{code}.')'.$err->[0]{message}
		if(ref($err) eq 'ARRAY');
	
	$msg = '+'.$hdr->status_line.':'.$msg."\n";
	print "Error:$msg";

	print $irc 'PRIVMSG '.$yaml->{channels}{'*'}.' :'.Encode::encode($yaml->{irc}{charset},$msg);

}
