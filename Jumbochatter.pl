use strict;
use vars qw($VERSION %IRSSI);

use JSON;
use Irssi;
use AnyEvent;
use AnyEvent::HTTP;
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

my $RECENT_MAX_ENTRY = 4;
my $RECENT_MAX_TITLE = 50;
my $RECENT_MAX_INFO = 80;
my $RECENT_MAX_URL = 200;
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
             ( ($msg =~ m/jumbotron/i && $msg =~ m/recent/i) ||
               $msg =~ m/^!recent|nylig/i )) {
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
    } or print STDERR "Error showing power usage: $@\n";
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

    push @$res, { TITLE=>$title, LINK=>$link, UPD=>$upd, INF=>$inf };
  }

  return $res;
}


sub upd2str {
  my ($upd) = @_;
  my $dt = $f->parse_datetime($upd);
  my $now_dt = DateTime->now();
  my $diff = $now_dt->subtract_datetime_absolute($dt);
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
      my $lines = recent_info($res);
      for my $text (@$lines) {
        $server->command("MSG $target $text");
      }
      1;
    } or print STDERR "Error showing power usage: $@\n";
  });
  undef;
}


sub recent_info {
  my ($feed) = @_;

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
    my $upd_since = upd2str($upd);
    next if exists($seenb4->{$link});
    $seenb4->{$link} = 1;
    if (length($inf) > 3) {
      $inf = ' "'. max_string($inf, $RECENT_MAX_INFO) .'"';
    } else {
      $inf = '';
    }
    $title = max_string($title, $RECENT_MAX_TITLE);
    $link = max_string($link, $RECENT_MAX_URL);
    push @$list, "($upd_since): $title$inf - $link";
    ++$count;
    last if $count >= $RECENT_MAX_ENTRY;
  }

  return $list;
}

Irssi::signal_add('message public' => \&public_hook);
Irssi::signal_add('message private' => \&private_hook);
