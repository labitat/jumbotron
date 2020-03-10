use strict;
use vars qw($VERSION %IRSSI);

use JSON;
use Irssi;
use AnyEvent;
use AnyEvent::HTTP;
use AnyEvent::HTTPD;
use XML::LibXML;
use HTML::Entities();
use DateTime;
use DateTime::Format::RFC3339;

$VERSION = '0.01';
%IRSSI = (
    authors     => 'knielsen',
    contact     => 'knielsen@knielsen-hq.org',
    name        => 'Jumbotron_chatter',
    description => 'Talk about power usage and other cool stuff',
    license     => 'GPL v2+',
    );

my $recent_poll_interval = 5*60;
my $RECENT_MAX_ENTRY = 4;
my $RECENT_MAX_TITLE = 50;
my $RECENT_MAX_INFO = 80;
my $RECENT_MAX_URL = 200;
my $RECENT_MAX_AUTHOR = 25;
my $RECENT_FEED_URL =
    'https://labitat.dk/w/api.php?action=feedrecentchanges&feedformat=atom&days=30&limit=30';


my $f = DateTime::Format::RFC3339->new();

sub public_hook {
    my ($server, $msg, $nick, $nick_addr, $target) = @_;
    if ($target =~ m/#(?:labitat|(?:kn)?test)/i &&
        $msg =~ m/jumbotron/i &&
        $msg =~ m/power|str..?m/i) {
        blipreq_start($server, lc($target), $msg);
    } elsif ($target =~ m/#(?:labitat|(?:kn)?test)/i &&
             ( ($msg =~ m/jumbotron/i && $msg =~ m/recent|nylig/i) ||
               $msg =~ m/^!(recent|nylig)/i )) {
        recent_start($server, lc($target), $msg);
    }
}

sub private_hook {
    my ($server, $msg, $nick, $nick_addr) = @_;
    return if $nick =~ /^#/;
    if ($msg =~ m/power|str..?m/i) {
        blipreq_start($server, $nick, $msg);
    } elsif ($msg =~ m/recent|nylig/i) {
      recent_start($server, $nick, $msg);
    }
}


sub blipreq_start {
  my ($server, $target, $msg) = @_;

  if ($msg =~ /stram/i) {
    $server->command("MSG $target http://www.stram.cz/");
    return;
  }
  if ($msg =~ /begejstr/i) {
    $server->command("MSG $target http://www.bs.dk/publikationer/andre/faglig/images/s26.jpg");
    return;
  }
  if ($msg =~ /fr[iou]str[iou]m/i) {
    $server->command("MSG $target http://www.jf-koeleteknik.dk/produkter/koele-og-frostanlaeg/");
    return;
  }
  unless ($msg =~ /power/i || $msg =~ /str(?:\x{c3}\x{b8}|\x{f8})m/i) {
    $server->command("MSG $target https://www.youtube.com/watch?v=Ka8bIPqKxiA");
    return;
  }

  AnyEvent::HTTP::http_get('https://power.labitat.dk/last/900000',
  sub {
    my ($res, $hdrs) = @_;
    return unless defined($res) && $res ne '';
    # Catch any exception due to invalid data or similar.
    eval {
      my $data = from_json($res);
      my $usage_now = 3600000 / $data->[-1][1];
      my $sum = 0;
      my $count = 0;
      for my $e (@$data) {
        $sum += $e->[1];
        ++$count;
      }
      my $usage_15min = 3600000*$count / $sum;
      my $text = sprintf("Power usage: %.1f W. 15 minute average: %.1f W",
                         $usage_now, $usage_15min);
      $server->command("MSG $target $text");
      1;
    } or print "Error showing power usage: $@\n";
  });
  # A bit tricky here, http_get() return is very magic. Unless called in a void
  # context, a "cancellation guard" is returned, which if destroyed will cancel
  # the request! And if http_get() was the last call, it would inherit return
  # context from caller, randomly getting cancelled or not...
  # So explicitly return undef here, ensuring void context for the http_get()
  # call.
  undef;
}


sub max_string {
  my ($s, $max) = @_;
  if (length($s) > $max) {
    $s = substr($s, 0, $max-3) . "...";
  }
  return $s;
}


sub extract_info_from_summary {
  my ($sum_xml_content) = @_;
  my $content = HTML::Entities::decode_entities($sum_xml_content);
  my $info = '';
  if ($content =~ m:^\s*<p>([^<>]*)</p>:s) {
    $info = HTML::Entities::decode_entities($1);
  }

  return $info;
}


my $prev_upd = undef;

sub extr_latest_changes {
  my ($dom) = @_;

  my $xpc = XML::LibXML::XPathContext->new($dom);
  $xpc->registerNs('a',  'http://www.w3.org/2005/Atom');

  my $entries = [$xpc->findnodes('/a:feed/a:entry')];
  my $res = [ ];

  for my $e (@$entries) {
    my ($title_node) = $xpc->findnodes('a:title', $e);
    my $title = $title_node->to_literal();
    my ($link_attr) = $xpc->findnodes('a:link/@href', $e);
    my $link = $link_attr->to_literal();
    $link =~ s/\&diff=[0-9]+//;
    $link =~ s/\&oldid=[0-9]+//;
    $link =~ s:/w/index\.php\?title=:/wiki/:;
    my ($upd_node) = $xpc->findnodes('a:updated', $e);
    my $upd = $upd_node->to_literal();
    my ($sum_node) = $xpc->findnodes('a:summary', $e);
    my $inf = extract_info_from_summary($sum_node->to_literal());
    my ($author_node) = $xpc->findnodes('a:author/a:name', $e);
    my $author = defined($author_node) ? $author_node->to_literal() : '<Anon>';

    push @$res, { TITLE=>$title, LINK=>$link, UPD=>$upd, INF=>$inf, AUT=>$author };
  }

  return $res;
}


sub upd_date_diff_to_now {
  my ($upd) = @_;
  my $dt = $f->parse_datetime($upd);
  my $now_dt = DateTime->now();
  my $diff = $now_dt->subtract_datetime_absolute($dt);
  return $diff;
}


sub upd_date_newer_than_prev {
  my ($upd, $prev) = @_;
  my $dt = $f->parse_datetime($upd);
  my $prev_dt = $f->parse_datetime($prev);
  my $cmp = DateTime->compare($dt, $prev_dt);
  return ($cmp > 0);
}


sub upd2str {
  my ($upd) = @_;
  my $diff = upd_date_diff_to_now($upd);
  my ($seconds_since) = $diff->in_units('seconds');
  if ($seconds_since <= 3600) {
    return "just now";
  } elsif ($seconds_since <= 2*3600) {
    return "1 hour";
  } elsif ($seconds_since <= 86400) {
    return int($seconds_since/3600) ." hours";
  } elsif ($seconds_since <= 2*86400) {
    return "1 day";
  } else {
    return int($seconds_since/86400) ." days";
  }
}


sub recent_start {
  my ($server, $target, $msg) = @_;

  AnyEvent::HTTP::http_get($RECENT_FEED_URL,
  sub {
    my ($res, $hdrs) = @_;
    return unless defined($res) && $res ne '';

    # Catch any exception due to invalid data or similar.
    eval {
      my $lines = recent_info($res, 0);
      for my $text (@$lines) {
        $server->command("MSG $target $text");
      }
      1;
    } or print "Error showing power usage: $@\n";
  });
  undef;
}


sub recent_info {
  my ($feed, $only_since_last) = @_;

  my $next_prev_upd = $prev_upd;
  my $dom = XML::LibXML->load_xml(string => $feed);
  my $latest_changes = extr_latest_changes($dom);

  my $seenb4 = { };
  my $count = 0;
  my $list = [ ];
  for my $h (@$latest_changes) {
    my $title = $h->{TITLE};
    my $link = $h->{LINK};
    my $upd = $h->{UPD};
    my $inf = $h->{INF};
    my $author = $h->{AUT};
    my $upd_since = upd2str($upd);

    if (!defined($prev_upd)) {
      $next_prev_upd = $upd
          if !defined($next_prev_upd) || upd_date_newer_than_prev($upd, $next_prev_upd);
    } elsif (upd_date_newer_than_prev($upd, $prev_upd)) {
      $next_prev_upd = $upd if upd_date_newer_than_prev($upd, $next_prev_upd);
    } elsif ($only_since_last) {
      # Skip if not newer than what we saw in last poll.
      next;
    }

    next if exists($seenb4->{$link});
    $seenb4->{$link} = 1;

    if (length($inf) > 3) {
      $inf = max_string($inf, $RECENT_MAX_INFO);
      if ($only_since_last) {
        $inf = ' ('. $inf .')';
      } else {
        $inf = ' "'. $inf .'"';
      }
    } else {
      $inf = '';
    }
    $title = max_string($title, $RECENT_MAX_TITLE);
    $link = max_string($link, $RECENT_MAX_URL);
    $author = max_string($author, $RECENT_MAX_AUTHOR);
    my $msg;
    if ($only_since_last) {
      $msg = "$author updated \"$title\"$inf - $link"
    } else {
      $msg = "($upd_since): $title$inf - $link"
    }
    push @$list, $msg;
    ++$count;
    last if $count >= $RECENT_MAX_ENTRY;
  }

  $prev_upd = $next_prev_upd;
  return $list;
}


sub check_new_wiki_changes {
  AnyEvent::HTTP::http_get($RECENT_FEED_URL,
  sub {
    my ($res, $hdrs) = @_;
    return unless defined($res) && $res ne '';

    # Catch any exception due to invalid data or similar.
    eval {
      my $is_first_run = !defined($prev_upd);
      my $lines = recent_info($res, 1);
      # First run we run just to get the $prev_upd initialized, but don't
      # output anything.
      if (!$is_first_run) {
        for my $text (@$lines) {
          send_to_hash_labitat($text);
        }
      }
      1;
    } or print "Error showing new wiki changes: $@\n";
  });
  undef;
}


my $httpd;
# Silly hack to maybe not get $httpd garbage-collected?
our $github_jumbotron_hook_dont_gc_me = [0, undef, "x"];

eval {
  $httpd = AnyEvent::HTTPD->new(port => 17380, host => '::');
  $github_jumbotron_hook_dont_gc_me->[1] = $httpd;

  $httpd->reg_cb (
    '/' => sub { httpd_default("Nothing here!", @_); },
    '/test' => sub { httpd_default("testing...", @_); },
    '/github' => \&http_github_hook,
      );

  print "Github hook: initialization done\n";
  1;
} or print "Github hook: exception during init: $@\n";

$github_jumbotron_hook_dont_gc_me->[2] = AnyEvent->timer(
  after => 5,
  interval => $recent_poll_interval,
  cb => sub {
    check_new_wiki_changes();
  });


sub send_to_hash_labitat {
  my ($msg) = @_;

  for my $server (Irssi::servers()) {
    next unless $server->{'connected'};
    next unless $server->{chatnet} =~ m/labitat/i;

    $server->command("MSG #labitat $msg");
    last;
  }
}

sub httpd_default {
  my ($stuffs, $httpd, $req) = @_;
  $req->respond(
    {content => ['text/plain', $stuffs . "\r\n"]}
      );
}

sub http_github_hook {
  my ($httpd, $req) = @_;
  $req->respond(
    {content => ['text/plain', "Ok\r\n"]}
      );

  eval {
    my $hdrs = $req->headers;
    my %vars = $req->vars;
    if (!exists($hdrs->{'x-github-event'})) {
      print "Github hook: No X-GitHub-Event header, ignoring\n";
      1;
    } elsif ($hdrs->{'x-github-event'} ne 'push') {
      print "Github hook: event type '$hdrs->{'x-github-event'}', ignoring...\n";
      1;
    } else {
      my $payload_json = $vars{payload};
      my $payload = from_json($payload_json);
      my $repo = max_string($payload->{repository}{name}, 25);
      my $branch = $payload->{ref};
      $branch =~ s|^.*/||;
      $branch = max_string($branch, 20);
      my $pusher = max_string($payload->{pusher}{name}, 25);
      my $commits = $payload->{commits};
      my $num = scalar(@$commits);
      my $plural = ($num == 1 ? '' : 's');
      my $head_msg = $payload->{head_commit}{message};
      $head_msg =~ s/[\r\n].*$//s;
      $head_msg =~ s/[\x00-\x1f]/ /g;
      $head_msg = max_string($head_msg, 160);
      my $url = $payload->{head_commit}{url};
      my $urltext = (length($url) <= 160 ? " - $url" : "");
      my $blurb = "$repo: $pusher pushed $num commit$plural to $branch \"$head_msg\"$urltext";
      send_to_hash_labitat($blurb);
      1;
    }
  } or print "Github hook: exception: '$@'\n";
}


Irssi::signal_add('message public' => \&public_hook);
Irssi::signal_add('message private' => \&private_hook);
