use strict;
use vars qw($VERSION %IRSSI);

use JSON;
use Irssi;
use AnyEvent;
use AnyEvent::HTTP;

$VERSION = '0.01';
%IRSSI = (
    authors     => 'knielsen',
    contact     => 'knielsen@knielsen-hq.org',
    name        => 'Jumbotron_chatter',
    description => 'Talk about power usage and other cool stuff',
    license     => 'GPL v2+',
    );


sub public_hook {
    my ($server, $msg, $nick, $nick_addr, $target) = @_;
    if ($target =~ m/#(?:labitat|(?:kn)?test)/i &&
        $msg =~ m/jumbotron/i &&
        $msg =~ m/power|str..?m/i) {
        blipreq_start($server, lc($target), $msg);
    }
}

sub private_hook {
    my ($server, $msg, $nick, $nick_addr) = @_;
    return if $nick =~ /^#/;
    if ($msg =~ m/power|str..?m/i) {
        blipreq_start($server, $nick, $msg);
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
  });
  # A bit tricky here, http_get() return is very magic. Unless called in a void
  # context, a "cancellation guard" is returned, which if destroyed will cancel
  # the request! And if http_get() was the last call, it would inherit return
  # context from caller, randomly getting cancelled or not...
  # So explicitly return undef here, ensuring void context for the http_get()
  # call.
  undef;
}


Irssi::signal_add('message public' => \&public_hook);
Irssi::signal_add('message private' => \&private_hook);
