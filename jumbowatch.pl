use strict;
use vars qw($VERSION %IRSSI);

use POSIX;
use Irssi;
$VERSION = '0.02';
%IRSSI = (
    authors     => 'knielsen',
    contact     => 'knielsen@knielsen-hq.org',
    name        => 'Jumbotron_bell',
    description => 'Ring a bell in the space when someone pings Jumbotron',
    license     => 'GPL v2+',
    );

sub trigger_action {
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
    if ($target =~ m/#(?:labitat|test)/ && $msg =~ m/jumbotron/i) {
	trigger_action();
    }
}

sub private_hook {
    my ($server, $msg, $nick, $nick_addr) = @_;
    trigger_action();
}

Irssi::signal_add('message public' => \&public_hook);
Irssi::signal_add('message private' => \&private_hook);
