# Copyright (C) 2026
#
# This file is part of Gmusicbrowser.
# Gmusicbrowser is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3, as
# published by the Free Software Foundation

=for gmbplugin LASTFMPLAYCOUNTSYNC
name	Last.fm playcount sync
title	Last.fm playcount sync
desc	Pull track play counts from a Last.fm account and update gmusicbrowser play counts.
version	0.1
=cut

package GMB::Plugin::LASTFMPLAYCOUNTSYNC;
use strict;
use warnings;
use Digest::MD5 'md5_hex';
use JSON::PP;
use POSIX 'strftime';
require $::HTTP_module;
use constant
{	OPT => 'PLUGIN_LASTFMPLAYCOUNTSYNC_',
	API_URL => 'http://ws.audioscrobbler.com/2.0/',
	AUTH_URL => 'https://ws.audioscrobbler.com/2.0/',
	BACKUP_DIR => 'lastfm_playcount_sync_backups',
};

::SetDefaultOptions(OPT,
	USER => '',
	PASS => '',
	API_KEY => '',
	API_SECRET => '',
	LIMIT => 1000,
	MAX_PAGES => 0,
	ONLY_INCREASE => 1,
	BACKUP_BEFORE_SYNC => 1,
);

my $self=bless {},__PACKAGE__;
my $Log= Gtk3::ListStore->new('Glib::String');
my ($waiting,$syncing,$stop_requested);
my ($test_waiting,$testing);
my (%LocalTrackIDs,%LastfmCounts);
my ($page,$total_pages,$seen,$updated,$skipped,$not_found);
my $status_label;

sub Start
{	$self->{on}=1;
}

sub Stop
{	AbortSync();
	AbortTest();
	$self->{on}=undef;
}

sub prefbox
{	my $vbox= Gtk3::VBox->new(0, 6);
	my $sg1= Gtk3::SizeGroup->new('horizontal');
	my $sg2= Gtk3::SizeGroup->new('horizontal');

	my $entry_user=::NewPrefEntry(OPT.'USER', _("username :"), sizeg1=>$sg1, sizeg2=>$sg2, width=>24);
	my $entry_pass=::NewPrefEntry(OPT.'PASS', _("password :"), sizeg1=>$sg1, sizeg2=>$sg2, hide=>1, width=>24,
		tip=>_("Optional. Used only to validate the account before sync when API secret is also set."));
	my $entry_key=::NewPrefEntry(OPT.'API_KEY', _("API key :"), sizeg1=>$sg1, sizeg2=>$sg2, width=>36,
		tip=>_("Required for Last.fm user.getTopTracks."));
	my $entry_secret=::NewPrefEntry(OPT.'API_SECRET', _("API secret :"), sizeg1=>$sg1, sizeg2=>$sg2, hide=>1, width=>36,
		tip=>_("Optional. Used with password for Last.fm mobile authentication validation."));
	my $limit=::NewPrefSpinButton(OPT.'LIMIT', 50, 1000, step=>50, page=>100, text=>_("tracks per request : %d"),
		sizeg1=>$sg1, sizeg2=>$sg2, tip=>_("Last.fm defaults to 50; larger requests need fewer pages."));
	my $max_pages=::NewPrefSpinButton(OPT.'MAX_PAGES', 0, 10000, step=>1, page=>10, text=>_("maximum pages, 0 for all : %d"),
		sizeg1=>$sg1, sizeg2=>$sg2);
	my $only_increase=::NewPrefCheckButton(OPT.'ONLY_INCREASE', _("Only increase local play counts"),
		tip=>_("Leave enabled to avoid reducing local play counts that include non-scrobbled plays."));
	my $backup_before=::NewPrefCheckButton(OPT.'BACKUP_BEFORE_SYNC', _("Backup play counts before sync"),
		tip=>_("Create a restore file before importing Last.fm play counts."));

	my $api_link= Gtk3::Button->new(_("Get Last.fm API key/secret"));
	$api_link->signal_connect(clicked=> sub { ::openurl('https://www.last.fm/api/accounts'); });
	my $backup= Gtk3::Button->new(_("Backup now"));
	$backup->signal_connect(clicked=> sub { BackupPlaycounts('manual'); });
	my $restore= Gtk3::Button->new(_("Restore latest backup"));
	$restore->signal_connect(clicked=> sub { RestoreLatestBackup(); });
	my $test= Gtk3::Button->new(_("Test API"));
	$test->signal_connect(clicked=> sub { TestApi(); });
	$status_label= Gtk3::Label->new(_("Idle"));
	$status_label->set_alignment(0,.5);
	my $force= Gtk3::Button->new(_("Force sync"));
	$force->signal_connect(clicked=> sub { ForceSync(); });
	my $stop= Gtk3::Button->new_from_stock('gtk-stop');
	$stop->signal_connect(clicked=> sub { AbortSync(); AbortTest(); });

	$vbox->pack_start($_,0,0,0) for
		$entry_user,$entry_pass,$entry_key,$entry_secret,$api_link,$limit,$max_pages,$only_increase,$backup_before,
		::Hpack($backup,$restore),
		::Hpack($status_label,'_',$test,$force,$stop);
	$vbox->add( ::LogView($Log) );
	return $vbox;
}

sub TestApi
{	if ($testing)
	{	Log(_("API test is already running"));
		return;
	}
	if ($syncing)
	{	Log(_("Sync is running; wait for it to finish before testing"));
		return;
	}

	my $user=$::Options{OPT.'USER'} || '';
	my $api_key=$::Options{OPT.'API_KEY'} || '';
	if ($user eq '')
	{	Log(_("Last.fm username is required"));
		SetStatus(_("Missing username"));
		return;
	}
	if ($api_key eq '')
	{	Log(_("Last.fm API key is required"));
		SetStatus(_("Missing API key"));
		return;
	}

	$testing=1;
	Log(_("Testing Last.fm API key and username"));
	SetStatus(_("Testing Last.fm API"));
	my %params=
	(	method => 'user.getTopTracks',
		user => $user,
		api_key => $api_key,
		format => 'json',
		period => 'overall',
		limit => 1,
		page => 1,
	);
	$test_waiting=Simple_http::get_with_cb(url=>API_URL.'?'.JoinParams(%params), cb=> sub { TestTopTracksLoaded(@_); });
}

sub TestTopTracksLoaded
{	my ($body,%meta)=@_;
	$test_waiting=undef;
	unless (defined $body)
	{	return FinishTest(_("Last.fm API test failed : ").($meta{error} || _("unknown error")));
	}

	my $json=eval { JSON::PP->new->utf8->decode($body) };
	if ($@ || ref $json ne 'HASH')
	{	return FinishTest(_("Last.fm API test failed: could not parse response"));
	}
	if (my $error=$json->{error})
	{	return FinishTest(::__x(_("Last.fm API test failed ({code}) : {message}"), code=>$error, message=>($json->{message}||'')));
	}

	my $top=ref $json->{toptracks} eq 'HASH' ? $json->{toptracks} : {};
	my $attr=$top->{'@attr'} || {};
	my $total=defined $attr->{total} ? $attr->{total} : '?';
	Log(::__x(_("Last.fm API key and username OK; account has {count} top tracks"), count=>$total));

	if (($::Options{OPT.'PASS'} || '') ne '')
	{	if (($::Options{OPT.'API_SECRET'} || '') eq '')
		{	return FinishTest(_("API test OK; password was not tested because API secret is missing"));
		}
		return TestAuth();
	}
	FinishTest(_("API test OK"));
}

sub TestAuth
{	my %params=
	(	method => 'auth.getMobileSession',
		username => $::Options{OPT.'USER'},
		password => $::Options{OPT.'PASS'},
		api_key => $::Options{OPT.'API_KEY'},
	);
	$params{api_sig}=ApiSignature(%params);
	Log(_("Testing Last.fm password and API secret"));
	SetStatus(_("Testing Last.fm password"));
	$test_waiting=Simple_http::get_with_cb(url=>AUTH_URL, post=>JoinParams(%params), cb=> sub { TestAuthLoaded(@_); });
}

sub TestAuthLoaded
{	my ($body,%meta)=@_;
	$test_waiting=undef;
	unless (defined $body)
	{	return FinishTest(_("Last.fm password/API secret test failed : ").($meta{error} || _("unknown error")));
	}
	if ($body=~m#<key>([^<]+)</key>#)
	{	return FinishTest(_("API test OK; password and API secret validated"));
	}
	if ($body=~m#<error[^>]*code="([^"]+)"[^>]*>(.*?)</error>#s)
	{	my ($code,$message)=($1,$2);
		$message=~s/<[^>]+>//g;
		return FinishTest(::__x(_("Last.fm password/API secret test failed ({code}) : {message}"), code=>$code, message=>$message));
	}
	FinishTest(_("Last.fm password/API secret test failed"));
}

sub FinishTest
{	my $text=$_[0];
	$testing=0;
	Log($text);
	SetStatus($text);
}

sub AbortTest
{	if ($test_waiting)
	{	$test_waiting->abort;
		$test_waiting=undef;
	}
	if ($testing)
	{	$testing=0;
		Log(_("API test stopped"));
		SetStatus(_("API test stopped"));
	}
}

sub ForceSync
{	if ($syncing)
	{	Log(_("Sync is already running"));
		return;
	}

	my $user=$::Options{OPT.'USER'} || '';
	my $api_key=$::Options{OPT.'API_KEY'} || '';
	if ($user eq '')
	{	Log(_("Last.fm username is required"));
		SetStatus(_("Missing username"));
		return;
	}
	if ($api_key eq '')
	{	Log(_("Last.fm API key is required"));
		SetStatus(_("Missing API key"));
		return;
	}
	unless ($::Library && @$::Library)
	{	Log(_("No songs in the gmusicbrowser library"));
		SetStatus(_("No songs to sync"));
		return;
	}

	%LocalTrackIDs=BuildLocalIndex();
	%LastfmCounts=();
	($page,$total_pages,$seen,$updated,$skipped,$not_found)=(1,undef,0,0,0,0);
	$stop_requested=0;
	$syncing=1;
	if ($::Options{OPT.'BACKUP_BEFORE_SYNC'})
	{	unless (BackupPlaycounts('auto'))
		{	$syncing=0;
			return;
		}
	}
	if (($::Options{OPT.'PASS'} || '') ne '')
	{	if (($::Options{OPT.'API_SECRET'} || '') ne '')
		{	return Authenticate();
		}
		Log(_("Password entered but API secret is missing; skipping password validation"));
	}
	StartFetch();
}

sub StartFetch
{	Log(::__x(_("Starting Last.fm playcount sync for {user}"), user=>$::Options{OPT.'USER'}));
	SetStatus(_("Fetching Last.fm play counts"));
	FetchPage();
}

sub Authenticate
{	my %params=
	(	method => 'auth.getMobileSession',
		username => $::Options{OPT.'USER'},
		password => $::Options{OPT.'PASS'},
		api_key => $::Options{OPT.'API_KEY'},
	);
	$params{api_sig}=ApiSignature(%params);
	SetStatus(_("Validating Last.fm password"));
	Log(_("Validating Last.fm password"));
	$waiting=Simple_http::get_with_cb(url=>AUTH_URL, post=>JoinParams(%params), cb=> sub { AuthLoaded(@_); });
}

sub AuthLoaded
{	my ($body,%meta)=@_;
	$waiting=undef;
	return FinishSync() if $stop_requested;

	unless (defined $body)
	{	return FailSync(_("Last.fm password validation failed : ").($meta{error} || _("unknown error")));
	}
	if ($body=~m#<key>([^<]+)</key>#)
	{	Log(_("Last.fm password validation OK"));
		return StartFetch();
	}
	if ($body=~m#<error[^>]*code="([^"]+)"[^>]*>(.*?)</error>#s)
	{	my ($code,$message)=($1,$2);
		$message=~s/<[^>]+>//g;
		return FailSync(::__x(_("Last.fm password validation failed ({code}) : {message}"), code=>$code, message=>$message));
	}
	FailSync(_("Last.fm password validation failed"));
}

sub AbortSync
{	$stop_requested=1;
	if ($waiting)
	{	$waiting->abort;
		$waiting=undef;
	}
	if ($syncing)
	{	$syncing=0;
		Log(_("Sync stopped"));
		SetStatus(_("Stopped"));
	}
}

sub FetchPage
{	return FinishSync() if $stop_requested;

	my $max_pages=$::Options{OPT.'MAX_PAGES'} || 0;
	if ($max_pages && $page>$max_pages)
	{	Log(::__x(_("Stopped after {pages} configured pages"), pages=>$max_pages));
		return ApplyCounts();
	}
	if (defined $total_pages && $page>$total_pages)
	{	return ApplyCounts();
	}

	my $limit=$::Options{OPT.'LIMIT'} || 1000;
	$limit=50 if $limit<1;
	$limit=1000 if $limit>1000;

	my %params=
	(	method => 'user.getTopTracks',
		user => $::Options{OPT.'USER'},
		api_key => $::Options{OPT.'API_KEY'},
		format => 'json',
		period => 'overall',
		limit => $limit,
		page => $page,
	);
	my $url=API_URL.'?'.JoinParams(%params);
	SetStatus(defined $total_pages
		? ::__x(_("Fetching Last.fm page {page}/{pages}"), page=>$page, pages=>$total_pages)
		: ::__x(_("Fetching Last.fm page {page}"), page=>$page));

	$waiting=Simple_http::get_with_cb(url=>$url, cb=> sub { PageLoaded(@_); });
}

sub PageLoaded
{	my ($body,%meta)=@_;
	$waiting=undef;
	return FinishSync() if $stop_requested;

	unless (defined $body)
	{	Log(_("Last.fm request failed : ").($meta{error} || _("unknown error")));
		return FinishSync();
	}

	my $json=eval { JSON::PP->new->utf8->decode($body) };
	if ($@ || ref $json ne 'HASH')
	{	Log(_("Could not parse Last.fm response : ").($@ || _("unknown error")));
		return FinishSync();
	}

	if (my $error=$json->{error})
	{	Log(::__x(_("Last.fm error {code}: {message}"), code=>$error, message=>($json->{message}||'')));
		return FinishSync();
	}

	my $top=ref $json->{toptracks} eq 'HASH' ? $json->{toptracks} : {};
	my $attr=$top->{'@attr'} || {};
	$total_pages=$attr->{totalPages} if defined $attr->{totalPages} && $attr->{totalPages}=~m/^\d+$/;
	my $tracks=$top->{track} || [];
	$tracks=[$tracks] if ref $tracks eq 'HASH';
	$tracks=[] unless ref $tracks eq 'ARRAY';
	return ApplyCounts() if !@$tracks && !defined $total_pages;

	for my $track (@$tracks)
	{	next unless ref $track eq 'HASH';
		my $title=$track->{name};
		my $count=$track->{playcount};
		my $artist= ref $track->{artist} eq 'HASH' ? $track->{artist}{name} : $track->{artist};
		next unless defined $title && defined $artist && defined $count && $count=~m/^\d+$/;
		$seen++;
		my $key=TrackKey($artist,$title);
		$LastfmCounts{$key}=$count if !exists $LastfmCounts{$key} || $count>$LastfmCounts{$key};
	}

	$page++;
	FetchPage();
}

sub ApplyCounts
{	my %by_count;
	for my $key (keys %LastfmCounts)
	{	my $ids=$LocalTrackIDs{$key};
		if (!$ids)
		{	$not_found++;
			next;
		}
		my $count=$LastfmCounts{$key};
		for my $id (@$ids)
		{	my $old=Songs::Get($id,'playcount') || 0;
			if ($::Options{OPT.'ONLY_INCREASE'} && $count <= $old)
			{	$skipped++;
				next;
			}
			next if $count == $old;
			push @{$by_count{$count}}, $id;
		}
	}

	SetStatus(_("Updating gmusicbrowser play counts"));
	for my $count (keys %by_count)
	{	my $ids=$by_count{$count};
		$updated+=@$ids;
		Songs::Set($ids, playcount=>$count);
	}
	FinishSync();
}

sub FinishSync
{	$waiting=undef;
	$syncing=0;
	%LocalTrackIDs=();
	%LastfmCounts=();
	my $summary=::__x(_("Sync finished: {seen} Last.fm tracks, {updated} local tracks updated, {skipped} skipped, {missing} not in library"),
		seen=>$seen||0, updated=>$updated||0, skipped=>$skipped||0, missing=>$not_found||0);
	Log($summary);
	SetStatus($summary);
}

sub FailSync
{	my $text=$_[0];
	$waiting=undef;
	$syncing=0;
	%LocalTrackIDs=();
	%LastfmCounts=();
	Log($text);
	SetStatus($text);
}

sub BackupPlaycounts
{	my $reason=$_[0] || 'manual';
	unless ($::Library && @$::Library)
	{	Log(_("No songs in the gmusicbrowser library"));
		SetStatus(_("No songs to backup"));
		return 0;
	}

	my $dir=BackupDir();
	unless (-d $dir || mkdir $dir)
	{	my $msg=::__x(_("Could not create backup folder {folder}: {error}"), folder=>$dir, error=>$!);
		Log($msg);
		SetStatus($msg);
		return 0;
	}

	my $time=time;
	my @songs;
	for my $id (@$::Library)
	{	my ($title,$artist,$album,$fullfilename,$playcount)=Songs::Get($id,qw/title artist album fullfilename playcount/);
		push @songs,
		{	title => $title,
			artist => $artist,
			album => $album,
			fullfilename => $fullfilename,
			track_key => TrackKey($artist,$title),
			playcount => $playcount || 0,
		};
	}

	my $file=BackupFilename($dir,$time);
	my $fh;
	unless (open $fh,'>:utf8',$file)
	{	my $msg=::__x(_("Could not write playcount backup {file}: {error}"), file=>$file, error=>$!);
		Log($msg);
		SetStatus($msg);
		return 0;
	}
	print $fh JSON::PP->new->pretty->canonical->encode(
	{	created => $time,
		reason => $reason,
		song_count => scalar @songs,
		songs => \@songs,
	});
	close $fh;

	my $msg=::__x(_("Backed up play counts for {count} songs to {file}"), count=>scalar @songs, file=>$file);
	Log($msg);
	SetStatus($msg);
	return 1;
}

sub RestoreLatestBackup
{	my $file=LatestBackupFile();
	unless ($file)
	{	Log(_("No playcount backup found"));
		SetStatus(_("No backup found"));
		return;
	}
	RestoreBackup($file);
}

sub RestoreBackup
{	my $file=$_[0];
	my $fh;
	unless (open $fh,'<:utf8',$file)
	{	my $msg=::__x(_("Could not read playcount backup {file}: {error}"), file=>$file, error=>$!);
		Log($msg);
		SetStatus($msg);
		return;
	}
	local $/;
	my $body=<$fh>;
	close $fh;

	my $json=eval { JSON::PP->new->decode($body) };
	if ($@ || ref $json ne 'HASH' || ref $json->{songs} ne 'ARRAY')
	{	my $msg=::__x(_("Could not parse playcount backup {file}"), file=>$file);
		Log($msg);
		SetStatus($msg);
		return;
	}

	my (%by_file,%by_key);
	for my $id (@$::Library)
	{	my ($title,$artist,$fullfilename)=Songs::Get($id,qw/title artist fullfilename/);
		push @{$by_file{$fullfilename}}, $id if defined $fullfilename && $fullfilename ne '';
		push @{$by_key{TrackKey($artist,$title)}}, $id if defined $title && defined $artist && $title ne '' && $artist ne '';
	}

	my (%by_count,%done);
	my ($restored,$skipped)=(0,0);
	for my $song (@{$json->{songs}})
	{	next unless ref $song eq 'HASH';
		my $count=$song->{playcount};
		next unless defined $count && $count=~m/^\d+$/;
		my $ids;
		if (defined $song->{fullfilename} && exists $by_file{$song->{fullfilename}} && @{$by_file{$song->{fullfilename}}}==1)
		{	$ids=$by_file{$song->{fullfilename}};
		}
		elsif (defined $song->{track_key} && exists $by_key{$song->{track_key}} && @{$by_key{$song->{track_key}}}==1)
		{	$ids=$by_key{$song->{track_key}};
		}
		else
		{	$skipped++;
			next;
		}
		for my $id (@$ids)
		{	next if $done{$id}++;
			my $old=Songs::Get($id,'playcount') || 0;
			next if $old == $count;
			push @{$by_count{$count}}, $id;
			$restored++;
		}
	}

	for my $count (keys %by_count)
	{	Songs::Set($by_count{$count}, playcount=>$count);
	}
	my $msg=::__x(_("Restored play counts for {count} songs from {file}; skipped {skipped} unmatched songs"),
		count=>$restored, file=>$file, skipped=>$skipped);
	Log($msg);
	SetStatus($msg);
}

sub BuildLocalIndex
{	my %index;
	for my $id (@$::Library)
	{	my ($title,$artist)=Songs::Get($id,qw/title artist/);
		next unless defined $title && defined $artist && $title ne '' && $artist ne '';
		push @{$index{TrackKey($artist,$title)}}, $id;
	}
	return %index;
}

sub TrackKey
{	my ($artist,$title)=@_;
	return Normalize($artist)."\x1D".Normalize($title);
}

sub Normalize
{	my $s=defined $_[0] ? $_[0] : '';
	$s=~s/^\s+//;
	$s=~s/\s+$//;
	$s=~s/\s+/ /g;
	return lc $s;
}

sub JoinParams
{	my %params=@_;
	return join '&', map { ::url_escapeall($_).'='.::url_escapeall($params{$_}) } sort keys %params;
}

sub ApiSignature
{	my %params=@_;
	my $secret=$::Options{OPT.'API_SECRET'} || '';
	return md5_hex((join '', map { $_.$params{$_} } sort keys %params).$secret);
}

sub BackupDir
{	return $::HomeDir.BACKUP_DIR;
}

sub BackupFilename
{	my ($dir,$time)=@_;
	my $base=$dir.'/playcounts-'.strftime('%Y%m%d-%H%M%S',localtime $time);
	my $file=$base.'.json';
	my $i=1;
	while (-e $file)
	{	$file="$base-$i.json";
		$i++;
	}
	return $file;
}

sub LatestBackupFile
{	my $dir=BackupDir();
	return unless -d $dir;
	opendir my $dh,$dir or return;
	my @files=sort grep { /^playcounts-\d{8}-\d{6}(?:-\d+)?\.json$/ && -f "$dir/$_" } readdir $dh;
	closedir $dh;
	return @files ? "$dir/$files[-1]" : undef;
}

sub SetStatus
{	my $text=$_[0];
	$status_label->set_text($text) if $status_label;
}

sub Log
{	my $text=$_[0];
	$Log->set( $Log->prepend,0, localtime().'  '.$text );
	warn "$text\n" if $::debug;
	if (my $iter=$Log->iter_nth_child(undef,100)) { $Log->remove($iter); }
}

1;
