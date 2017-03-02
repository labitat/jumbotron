use strict;
use vars qw($VERSION %IRSSI);

use POSIX;
use FileHandle;
use JSON;
use LWP::Simple;
use Irssi;
$VERSION = '0.02';
%IRSSI = (
    authors     => 'knielsen',
    contact     => 'knielsen@knielsen-hq.org',
    name        => 'Jumbotron_bell',
    description => 'Ring a bell in the space when someone pings Jumbotron',
    license     => 'GPL v2+',
    );

my $RATELIMIT_PERIOD = 120;  # Seconds
my $RATELIMIT_COUNT = 2;

my $last_pingtime = undef;
my $ping_count = 0;

sub trigger_action {
    # Basic rate-limiting to avoid people in the space going crazy :)
    $last_pingtime = time()
        unless defined($last_pingtime);
    my $now = time();
    my $delta = $now - $last_pingtime;
    if ($delta <= $RATELIMIT_PERIOD) {
        if ($ping_count >= $RATELIMIT_COUNT) {
            return;
        }
    } else {
        $last_pingtime = $now;
        $ping_count = 0;
    }

    ++$ping_count;
    my $pid1 = fork();
    return unless defined($pid1);
    if ($pid1) {
	waitpid $pid1, 0;
    } else {
	# Child. Double fork to avoid zombies.
	my $pid2 = fork();
	POSIX::_exit(1) unless defined($pid2);
	if ($pid2) {
	    # Intermediate parent.
	    POSIX::_exit(0);
	} else {
	    # Child.
	    exec '/usr/local/bin/jumbotron_ping'
		or POSIX::_exit(1);
	}
    }
}


sub public_hook {
    my ($server, $msg, $nick, $nick_addr, $target) = @_;
    if ($target =~ m/#(?:labitat|test)/i && $msg =~ m/jumbotron/i) {
	trigger_action();
    }
    if ($target =~ m/#(?:labitat|(?:kn)?test)/i &&
        $msg =~ m/jumbotron/i &&
        $msg =~ m/power|str..?m/i) {
        blipreg_start($server, $target);
    }
}

sub private_hook {
    my ($server, $msg, $nick, $nick_addr) = @_;
    trigger_action();
}


my $unit_map = {
  minutter => 60,
  minutes => 60,
  timer => 3600,
  hours => 3600,
  dage => 86400,
  days => 86400
};

sub timeout_handler {
  for my $server (Irssi::servers()) {
    next unless $server->{'connected'};
    for my $channel ($server->channels()) {
      #next unless $channel->{chanop};
      #next unless $channel->{name} eq '#kntest';
      my $topic = $channel->{topic};
      next unless $topic =~ /^(.*)(minutter|timer|dage|minutes|hours|days) (siden|since)([^:]+): *([-a-z_.]*)([0-9]+)(.*)$/i;
      my ($part1, $unit, $part2, $part3, $part4, $count, $part5) = ($1, $2, $3, $4, $5, $6, $7);
      my $last = $channel->{topic_time};
      my $now = time();
      my $delta = $unit_map->{lc($unit)};
      next unless $delta;
      next unless $now >= $last + $delta;
      ++$count;
      my $updated_topic = "$part1$unit $part2$part3: $part4$count$part5";
      $server->send_raw("TOPIC $channel->{name}  :$updated_topic");
    }
  }
}


my $blip_reqs = { };

sub blipreg_start {
  my ($server, $target) = @_;
  return if scalar(keys(%$blip_reqs)) >= 10;
  my $chld = FileHandle->new;
  my $pid = open $chld, '-|';
  if (!defined($pid)) {
    Irssi::print("Could not fork: $!");
    return;
  }
  if (!$pid) {
    # Child.
    $| = 1;
    my $result = get('https://power.labitat.dk/last/900000');
    print STDOUT $result;
    close(STDOUT);
    POSIX::_exit(0)
        or die "Oops, could not die?!?";
  }

  # Parent;
  Irssi::pidwait_add($pid);
  my $tag = Irssi::input_add(fileno($chld), INPUT_READ, \&blipreg_handler, $pid);
  $blip_reqs->{$pid} = { BUF => '', FH => $chld, HDLR => $tag,
                         SERVER => $server, TARGET => lc($target) };
}


sub blipreg_handler {
  my ($pid) = @_;
  return unless exists($blip_reqs->{$pid});
  my $entry = $blip_reqs->{$pid};
  my $chunk = '';
  my $res = sysread($entry->{FH}, $chunk, 4096);
  if ($res) {
    $entry->{BUF} .= $chunk;
    return;
  }

  my $buf = $entry->{BUF};
  my $data = from_json($buf);
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
  $entry->{SERVER}->command("MSG $entry->{TARGET} $text");
  close $entry->{FH};
  Irssi::input_remove($entry->{HDLR});
  delete $blip_reqs->{$pid};
}


sub pidwait_hook {
  my ($pid, $status) = @_;
}


my $timeout_tag = Irssi::timeout_add 60e3, 'timeout_handler', undef;

Irssi::signal_add('message public' => \&public_hook);
Irssi::signal_add('message private' => \&private_hook);
Irssi::signal_add('pidwait' => \&pidwait_hook);
