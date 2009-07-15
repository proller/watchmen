#!/usr/bin/perl
# $Id$ $URL$ Oleg Alexeenkov <proler@gmail.com>

=head1 NAME

 watchmen - watch daemons

=head1 SYNOPSIS

 watchmen.pl [--configkey=configvalue] [-svcname__svckey=svcvalue] ...

=head1 EXAMPLES

 # check and restart default services
 watchmen.pl

 #list of enabled services
 watchmen.pl list

 #list of available services
 watchmen.pl avail

 # full log
 watchmen.pl --log_all

 # reatart apache if more than 5 httpd proc, dont check sshd, load custom config
 watchmen.pl -apache__max_proc=5 -sshd__enable=0 --config=/path/to/my/config

=head1 INSTALL

 recommended libs: LWP, URI
 freebsd: cd /usr/ports/www/p5-libwww && make install clean
 or 
 perl -MCPAN -e "install LWP, URI"


 cp watchmen.pl /usr/local/bin/watchmen ; cp watchmen.conf.pl.dist /usr/local/etc/watchmen.conf.pl
 edit /usr/local/etc/watchmen.conf.pl

 add to crontab:
 echo "*       *       *       *       *       root    /usr/local/bin/watchmen" >> /etc/crontab

=head1 CONFIGURE

 by default some of default services enabled

 read [and edit] watchmen.conf.pl

 you can configure services from /etc/rc.conf[.local] file[s]:
 for config string  $svc{service}{key} = 'value'; write to rc.conf:
 service_key="value"
 ex:
 apache22_http="81" 
 # or define new service, with one of correct keys: process tcp udp http https :
 nginx_enable="YES"
 nginx_process="nginx"
 nginx_http="8001"
 nginx_http_check="<html"


=head1 TODO

 self pid & check
 mail errors
 various handlers
 rsync --daemon
 resort daemons (system, local)
 more default ports

=head1 COPYRIGHT

watchmen
Copyright (C) 2008-2009 Oleg Alexeenkov proler@gmail.com

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

=cut
package watchmen;
use strict;
use IO::Socket;
use Time::HiRes qw(time sleep);
use POSIX qw(strftime);
use Cwd;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
our ( %config, %svc );
our $root_path;

BEGIN {
  ( $ENV{'SCRIPT_FILENAME'} || $0 ) =~ m|^(.+)[/\\].+?$|;    #v0w
  $root_path = $1 if $1;
  $root_path ||= getcwd;
  $root_path .= '/';
  $root_path =~ s|\\|/|g;
}
# lib funcs ===
sub get_params_one(@) {
  my $ret = ( ref $_[0] eq 'HASH' ? shift : undef ) || {};
  for (@_) {
    local %_;
    @_{ 'k', 'v' } = (/^([^=]+=?)=(.+)$/) ? ( $1, $2 ) : ( ( (/^([^=]*)=?$/)[0] ), ( /^-/ ? 1 : '' ) );
    $_{$_} =~ tr/+/ /, $_{$_} =~ s/%([a-fA-F0-9]{2})/pack('C', hex($1))/eg for qw(k v);
    #    $ret->{ $1 . '_mode' . $2 } .= $3 if $_{'k'} =~ s/^(.+?)(\d*)([=!><~@]+)$/$1$2/;
    #    $_{'k'} =~ s/(\d*)$/($1 < 100 ? $1 + 1 : last)/e while ( defined( $ret->{ $_{'k'} } ) );
    $ret->{ $_{'k'} } = $_{'v'};
  }
  return wantarray ? %$ret : $ret;
}

sub get_params(;$$) {    #v6
  my ( $par_string, $delim ) = @_;
  $delim ||= '&';
  local %_;
  read( STDIN, local $_ = '', $ENV{'CONTENT_LENGTH'} ) if !$par_string and $ENV{'CONTENT_LENGTH'};
  %_ = (
    %_,
    $par_string
    ? ( get_params_one( undef, split( $delim, $par_string ) ) )
    : (
      get_params_one( undef, @ARGV ), map { get_params_one( undef, split $delim, $_ ) } split( /;\s*/, $ENV{'HTTP_COOKIE'} ),
      $ENV{'QUERY_STRING'}, $_
    )
  );
  return wantarray ? %_ : \%_;
}
{
  my %fh;
  my $savetime;

  sub file_append(;$@) {
    local $_ = shift;
    for ( defined $_ ? $_ : keys %fh ) { close( $fh{$_} ), delete( $fh{$_} ) if $fh{$_} and !@_; }
    return if !@_;
    unless ( $fh{$_} ) { return unless open( $fh{$_}, '>>', $_ ); }
    print { $fh{$_} } @_;
    if ( time() > $savetime + 5 ) {
      close( $fh{$_} ), delete( $fh{$_} ) for keys %fh;
      $savetime = time();
    }
    return @_;
  }
  END { close( $fh{$_} ) for keys %fh; }
}

sub printlog (@) {    #v5
  return if defined $config{ 'log_' . $_[0] } and !$config{ 'log_' . $_[0] } and !$config{'log_all'};
  my $file = ( (
      defined $config{'log_all'}
      ? $config{'log_all'}
      : ( defined $config{ 'log_' . $_[0] } ? $config{ 'log_' . $_[0] } : $config{'log_default'} )
    )
  );
  my $noscreen;
  for ( 0 .. 1 ) {
    $noscreen = 1 if $file =~ s/^[\-_]// or !$file;
    $noscreen = 0 if $file =~ s/^[+\#]//;
    $file = $config{'log_default'}, next if $file eq '1';
    last;
  }
  $file = undef if $file eq '1';
  my $html = !$file and ( $ENV{'SERVER_PORT'} or $config{'view'} eq 'html' or $config{'view'} =~ /http/i );
  my $xml = $config{'view'} eq 'xml';
  my @string = (
    ( $xml  ? '<debug><![CDATA['    : () ),
    ( $html ? '<div class="debug">' : () ),
    (
      ( ( $html || $xml ) and !$file ) ? ()
      : (
        human( 'date_time', ), ( $config{'log_micro'} ? human('micro_time') : () ), ( $config{'log_pid'} ? (" [$$]") : () ),
      )
    ), (
      $config{'log_caller'}
      ? (
        ' [', join( ',', grep { $_ and !/^ps/ } ( map { ( caller($_) )[ 2 .. 3 ] } ( 0 .. $config{'log_caller'} - 1 ) ) ), ']'
        )
      : ()
    ),
    ' ',
    join( ' ', @_ ),
    (),
    ( $html ? '</div>'      : () ),
    ( $xml  ? ']]></debug>' : () ),
    ("\n")
  );
  file_append( $config{'log_dir'} . $file, @string );
  print @string if @_ and $config{'log_screen'} and !$noscreen;
  flush() if $config{'log_flush'};
  return @_;
}

sub human($;@) {
  my $via = shift;
  return $config{'human'}{$via}->(@_) if ref $config{'human'}{$via} eq 'CODE';
  return @_;
}

sub alarmed {
  my ( $timeout, $proc, @proc_param ) = @_;
  my $ret;
  eval {
    local $SIG{ALRM} = sub { die "alarm\n" }
      if $timeout;    # NB: \n required
    alarm $timeout if $timeout;
    $ret = $proc->(@proc_param) if ref $proc eq 'CODE';
    alarm 0 if $timeout;
  };
  if ( $timeout and $@ ) {
    printlog( 'err', 'Sorry, unknown error (',
      $@, ') runs:', ' [', join( ',', grep $_, map ( ( caller($_) )[2], ( 0 .. 15 ) ) ), ']' ),
      unless $@ eq "alarm\n";    # propagate unexpected errors
    printlog( 'err', 'Sorry, timeout (', $timeout, ')' );
  } else {
  }
  return $ret;
}
# lib to here ===
%config = (
  'rcd'    => [qw(/usr/local/etc/rc.d/ /etc/rc.d/)],
  'rcdext' => [ '', '.sh' ],
  'ps'     => $^O eq 'freebsd' ? 'ps vxaww' : 'ps xaww',
  rcconf   => [qw(/etc/defaults/rc.conf /etc/rc.conf /etc/rc.conf.local)],
  #log_screen=>1,
  maxexttime => 30,
  'default'  => {
    min_proc                => 1,
    max_proc                => 1000,
    sleep                   => 1,
    host                    => '127.0.0.1',    # for tcp, udp
    timeout                 => 3,              # for tcp, udp
    restart_hard_stop_sleep => 5,
    restart_hard_kill_sleep => 5,
  },
  restart_hard => sub {
    my ($s) = @_;
    printlog( 'warn', $s, 'hard restart' );
    printlog 'warn', $s, 'stop', `daemon $svc{$s}{stop} &`;
    sleep $svc{$s}{restart_hard_stop_sleep} || $config{restart_hard_stop_sleep};
    printlog 'warn', $s, 'kill', `killall $svc{$s}{process}`;
    sleep $svc{$s}{restart_hard_kill_sleep} || $config{restart_hard_kill_sleep};
    printlog 'warn', $s, 'kill-9', `killall -9 $svc{$s}{process}`;
    sleep 1;
    printlog 'warn', $s, 'start', `$svc{$s}{start}`;
  },
  #  config => (grep{-x}"/usr/local/etc/watchmen.conf.pl","${root_path}watchmen.conf.pl")[0] || '',
  # log_all=>'+',
  log_default => '+' . ( $root_path =~ /watch/ ? $root_path : -d '/var/log/' ? '/var/log/' : $root_path ) . 'watchmen.log',
  log_screen  => 1,
  log_enable => 0,
  log_alive   => 0,
  log_info    => 0,
  log_ps      => 0,
  log_dbg     => 0,
  log_port    => 0,
  log_http    => 0,
  http_code => qr/^[1-4]\d\d$/,
  'human'   => {
    'date' => sub {    #v1
      my $d = $_[1] || '/';
      return strftime "%Y${d}%m${d}%d", localtime( $_[0] || time() );
    },
    'time' => sub {
      my $d = $_[1] || ':';
      return strftime "%H${d}%M${d}%S", localtime( $_[0] || time() );
    },
    'date_time' => sub {
      return human( 'date', $_[0] || time(), $_[2] ) . ( $_[1] || '-' ) . human( 'time', $_[0] || time(), $_[3] );
    },
    'float' => sub {    #v1
      return ( $_[0] < 8 and $_[0] - int( $_[0] ) )
        ? sprintf( '%.' . ( $_[0] < 1 ? 3 : $_[0] < 3 ? 2 : 1 ) . 'f', $_[0] )
        : int( $_[0] );
    },
    'micro_time' => sub {
      my $now = time();
      ( $now = human( 'float', abs( int($now) - $now ) ) ) =~ s/^0//;
      return ( $now or '' );
    },
    'time_period' => sub {    #v0
      my ( $tim, $delim, $sign ) = @_;
      $sign = '-', $tim = -$tim if $tim < 0;
      #print("tpern[", $tim, ']'),
      return '' if $tim == 0 or $tim > 1000000000;
      #print("tperf[", $tim, ']'),
      return ( $sign . human( 'float', $tim ) . $delim . "s" ) if $tim < 60;
      $tim = $tim / 60;
      return ( $sign . int($tim) . $delim . "m" ) if $tim < 60;
      $tim = $tim / 60;
      return ( $sign . int($tim) . $delim . "h" ) if $tim < 24;
      $tim = $tim / 24;
      return ( $sign . int($tim) . $delim . "d" ) if $tim <= 31;
      $tim = $tim / 30.5;
      return ( $sign . int($tim) . $delim . "M" ) if $tim < 12;
      $tim = $tim / 12;
      return ( $sign . int($tim) . $delim . "Y" );
      }
  },
);
for ( "/usr/local/etc/watchmen.conf.pl", "/etc/watchmen.conf.pl", "${root_path}watchmen.conf.pl" ) {
  $config{config} ||= $_, last if -r;
}
{
  my $order = 100000;
  sub n(@) { return { order => $order -= 10, @_ }; }
}
%svc = (
  sshd    => n( tcp => 22, no_stop => 1 ),
  syslogd => n,
  cron    => n,
  inetd   => n,
  named     => n( udp => 53 ),
  lpd       => n,
  watchdogd => n,
  ntpd      => n,
  apache     => n( process => 'httpd',    http => 80 ),
  apache2    => n( process => 'httpd',    http => 80 ),
  apache22   => n( process => 'httpd',    http => 80 ),     #tcp=>80 #https=>443
  nginx	     => n(http => 80),
  postgresql => n( process => 'postgres', tcp => 5432 ),
  memcached  => n,
  rsyncd     => n( process => 'rsync',    tcp => 873 ),
  proftpd    => n,
  mysql    => n( process => 'mysqld',       rcdname => 'mysql-server', tcp => 3306, restart => $config{restart_hard}, ),
  dhcpd    => n( rcdname => 'isc-dhcpd',    udp     => 67 ),
  svnserve => n( process => 'svnserve.bin', tcp     => 3690 ),
  snmpd    => n,
  bsnmpd   => n,
  nmbd        => n( rcdname    => 'samba',      rcconfname => 'samba', udp => [ 137, 138 ] ),
  smbd        => n( rcdname    => 'samba',      rcconfname => 'samba', tcp => [ 139, 445 ] ),
  nfsd        => n( rcconfname => 'nfs_server', tcp        => 2049 ),
  mpd4        => n,
  mpd5        => n,
  healthd     => n,
  smartd      => n,
  watchquagga => n
  , # for zebra, bgpd and others use in rc.d: watchquagga_flags=" --daemon --unresponsive-restart --restart-all '/usr/local/etc/rc.d/quagga restart' zebra bgpd"
  snmptrapd => n,
  clamd     => n( rcdname => 'clamav-clamd', rcconfname => 'clamav_clamd' ),
  freshclam => n( rcdname => 'clamav-freshclam', rcconfname => 'clamav_freshclam' ),
  nut        => n( process => 'upsd' ),
  nut_upslog => n( process => 'upslog' ),
  nut_upsmon => n( process => 'upsmon' ),
  icecast    => n( rcdname => 'icecast2', ),
  ipa        => n,
  tinyproxy  => n,         #tcp => 8888
);
if ( $config{config} ) { do $config{config} or printlog( 'info', "using default config because $!, $@ in [$config{config}]" ); }
else                   { printlog( 'info', "using default config because watchmen.conf.pl not exist" ); }
our %prog;

sub param_to_config ($) {
  my ($param) = @_;
  for my $w ( keys %$param ) {
    my $v = $param->{$w};
    next unless $w =~ s/^-//;
    my $where = ( $w =~ s/^-// ? '$config' : '$svc' );
    #    $v =~ s/^NUL$//;
    return 0 unless defined($w) and defined($v);
    local @_ = split( /__/, $w ) or return 0;
    eval( $where . join( '', map { '{$_[' . $_ . ']}' } ( 0 .. $#_ ) ) . ' = $v;' );
  }
  my $wantrun;
  for (@ARGV) {
    next if /^-/;
    ++$wantrun;
    my ( $p, $v ) = get_params_one($_);
    $prog{$p}{run} = 1;
    $prog{$p}{opt} = $v;
    #printlog 'RUN', ($p, $v);
  }
}
sub config ($;$) { return $_[1] ? $svc{ $_[0] }{ $_[1] } || $config{ $_[1] } : $config{ $_[0] } }

sub services() {
  sort { $svc{$b}{order} <=> $svc{$a}{order} || $a cmp $b } grep { $svc{$_}{enable}
and  $svc{$_}{rcd} and -x $svc{$_}{rcd} 
   } keys %svc;
}
param_to_config( scalar get_params() );
{
  my ( $current, $order );

  sub prog(;$$) {
    my ( $name, $setorder ) = @_;
    return $prog{$current} unless $name;
    $prog{ $current = $name }{'order'} ||= ( $setorder or $order += ( $config{'order_step'} || 10 ) );
    return $prog{$current};
  }
}
prog('loadrc')->{force} = 1;
prog()->{func} = sub {
  for my $rcconf ( @{ $config{rcconf} } ) {
    next unless open my $rcconfh, '<', $rcconf;
    while (<$rcconfh>) {
      if (my ($svc, $key, $value) =/^\s*(\w+?)_(\S+)\s*=\s*"([^"]+)"/i) { #"mcedit
        $value = 0  if $value =~ /^no(?:ne)?$/i;
        printlog( 'dbg', "rc.conf $key [$svc]" ) if $value eq 'enable';
if (local @_ = grep { $svc{$_}{rcconfname} eq $svc            } keys %svc) {

        printlog( 'rc', $svc, $key, $_ ),         $svc{$_}{$key} = $value          for @_;
        } else {
$svc{$svc}{rcsource}=$rcconf        unless $svc{$svc};
        printlog( 'rc',$svc, $key,  ), $svc{$svc}{$key} = $value;#, next if exists $svc{$svc};
        
        }
      }
    }
    close $rcconfh;
  }
  
 do $config{config}  if  $config{config};
  
};
#setting defaults
prog('defaults')->{force} = 1;
prog()->{func} = sub {
  for my $s ( keys %svc ) {
    $svc{$s}{$_} ||= $config{default}{$_} for keys %{ $config{default} };
    next unless $svc{$s}{enable};
    $svc{$s}{process} ||= $s unless $svc{$s}{rcsource};
    $svc{$s}{rcdname} ||= $s;
    unless ( $svc{$s}{rcd} ) {
      for my $rcd ( @{ $config{rcd} } ) {
        last if $svc{$s}{rcd};
        for my $rcdext ( @{ $config{rcdext} } ) {
          if ( -x $rcd . $svc{$s}{rcdname} . $rcdext ) {
            $svc{$s}{rcd} ||= $rcd . $svc{$s}{rcdname} . $rcdext;
            last;
          }
        }
      }
      printlog( 'info', "$s: rc.d script not exists [$svc{$s}{rcd}] [$svc{$s}{rcdname}]" ), $svc{$s}{enable} = 0
        unless $svc{$s}{rcd};
      #printlog('rcd', "$s detected [$svc{$s}{rcd}]");
    }
    $svc{$s}{start} ||= $svc{$s}{rcd} . ' ' . ( $svc{$s}{force_restart} ? 're' : '' ) . 'start';
    $svc{$s}{stop} ||= $svc{$s}{rcd} . ' stop';
    $svc{$s}{restart} ||= $svc{$s}{rcd} . ' restart' if !length $svc{$s}{restart};
    #  $svc{$s}{restart} ||= "$svc{$s}{stop} ;; sleep $svc{$s}{sleep} ;; $svc{$s}{start}";
    $svc{$s}{restart} ||= sub {
      my $s = shift;
      printlog( 'stop', $s );
      `$svc{$s}{stop}`;
      printlog( 'sleep', $s, $svc{$s}{sleep} );
      sleep $svc{$s}{sleep};
      printlog( 'start', $s );
      `$svc{$s}{start}`;
    };
    $svc{$s}{sleep} ||= 1 unless defined $svc{$s}{sleep};
    $svc{$s}{rcconf} ||= $s;
  }
};
my (%ps);
prog('ps')->{force} = 1;
prog()->{func} = sub {
  my @ps = `$config{ps}`;
  printlog( 'ps', @ps );
  local $_ = shift @ps;
  s/^\s+//;
  chomp;
  my @format = split /\s+/;
  my %format;
  my $i = 0;
  $format{$_} = $i++ for @format;
  #printlog 'fmt', @format;
  my $psline = 0;
  for (@ps) {
    s/^\s+//;
    chomp;
    local @_ = split /\s+/, $_, @format;
    printlog( 'bad pid', join ':', @_ ), next unless $_[ $format{PID} ] =~ /^\d+$/;
    my $ps = $ps{ $_[ $format{PID} ] } ||= {};
    @{$ps}{@format} = @_;
    $ps->{psline} = $psline++;
    #'COMMAND' => 'proftpd: (accepting connections) (proftpd)',
    #'COMMAND' => 'mc'
    #'COMMAND' => 'sh -c myisamchk -v --recover --force /var/db/mysql/t/*.MYI 2>&1'
    # 'COMMAND' => 'screen -DRa',
    $ps->{process} ||= $1 if $ps->{COMMAND} =~ m{.*\((.+?)\)$};
    $ps->{process} ||= $1 if $ps->{COMMAND} =~ m{^([^\s/\\\[\]]+)};
    $ps->{process} ||= $1 if $ps->{COMMAND} =~ m{^\S*/(\S+)};
  }
  #printlog 'newps', Dumper \%ps;
};
#prog('process')->{force} = 1;
#prog()->{func} = sub {
prog('check')->{func} = sub {
  for my $s (services) {
    #for my $s ( keys %svc ) {
    #  next unless $svc{$s}{enable};
#    printlog( 'info', "$s: rc.d script not exists [$svc{$s}{rcd}]" ), next if !$svc{$s}{rcd} or !-x $svc{$s}{rcd};
next unless $svc{$s}{process};
    printlog( 'info', "looking at [$s] [$svc{$s}{rcd}] [$svc{$s}{process}]" );
    my $founded;
    for my $p ( grep { $svc{$s}{process} eq $ps{$_}{process} } keys %ps ) {
      for my $max ( grep { $svc{$s}{max}{$_} } keys %{ $svc{$s}{max} || {} } ) {
        #printlog('dev', "look at $s limit [$max]", $svc{$s}{max}{$max} , $ps{$p}{$max});
        printlog( 'warn', "$s limit [$max]", $ps{$p}{$max}, '>', $svc{$s}{max}{$max} ), $svc{$s}{action} = 'restart'
          if $ps{$p}{$max} > $svc{$s}{max}{$max};
      }
      ++$founded;
    }
    #  printlog( 'info', "looking at [$s] [$svc{$s}{rcd}] [$founded]" );
    unless ($founded) {
      printlog( 'warn', "$s no_proc!", $svc{$s}{process} );    #start
      $svc{$s}{action} ||= 'start';
    } elsif ( $founded < $svc{$s}{min_proc} ) {
      printlog( 'warn', "$s min_proc[$founded/$svc{$s}{min_proc}]!" );    #restart
      $svc{$s}{action} ||= 'restart';
    } elsif ( $founded > $svc{$s}{max_proc} ) {
      printlog( 'warn', "$s max_proc[$founded/$svc{$s}{max_proc}]!" );    #restart
      $svc{$s}{action} ||= 'restart';
    }
  }
  #};
  #prog('service')->{force} = 1;
  #prog()->{func} = sub {
  for my $s (services) {
    #  next unless $svc{$s}{enable};
    for my $prot (qw(tcp udp)) {
      $svc{$s}{$prot} ||= $svc{$s}{http} if $prot eq 'tcp';
      next unless $svc{$s}{$prot};
      next if $svc{$s}{action};
      for my $port ( ref $svc{$s}{$prot} eq 'ARRAY' ? @{ $svc{$s}{$prot} } : $svc{$s}{$prot} ) {
        printlog( 'port', "connecting to service $s $prot $svc{$s}{host}:$port" );
        my $time   = time();
        my $socket = new IO::Socket::INET(
          'PeerAddr' => $svc{$s}{host},
          'PeerPort' => $port,
          'Proto'    => $prot,
          'Timeout'  => $svc{$s}{timeout},
        );
        $time = human( 'time_period', time() - $time );
        printlog( 'port', "connected per", $time ), next if $socket;
        printlog( 'warn', $s, $prot, $svc{$s}{host}, $port, "no answer", $socket, $time );
        $svc{$s}{action} ||= 'restart';
        last;
      }
    }
    for my $prot (qw(http https)) {
      next unless $svc{$s}{$prot};
      next if $svc{$s}{action};
    PORTOK: for my $port ( ref $svc{$s}{$prot} eq 'ARRAY' ? @{ $svc{$s}{$prot} } : $svc{$s}{$prot} ) {
        $port = 80  if $port == 1 and $prot eq 'http';
        $port = 443 if $port == 1 and $prot eq 'https';
        printlog( 'port', "connecting to service $s $prot $svc{$s}{host}:$port" );
        my $time = time();
        #lwp here
        printlog( 'err', 'no libs LWP, URI' ), last unless ( eval('use LWP::UserAgent; use URI::URL;1;') );
        my $ua = LWP::UserAgent->new( 'timeout' => config( $s, 'timeout' ), %{ config( $s, 'lwp' ) || {} }, );
        my $get =
            'http://'
          . ( config( $s, 'http_host' ) || config( $s, 'host' ) || 'localhost' ) . ':'
          . $port
          . config( $s, 'http_path' );
        my $resp =    #(
          $ua->request(
          new HTTP::Request(
            config( $s, 'http_method' ) || 'GET',
            new URI::URL($get),
            new HTTP::Headers( 'User-Agent' => config( $s, 'http_useragent' ), %{ config( $s, 'http_headers' ) || {} } ),
            config( $s, 'http_content' )
          )
          )
          #    )
          ;
        my $result = $resp->is_success ? $resp->as_string : undef;
        printlog( 'http', 'recv', $get,'per', human( 'time_period', time() - $time ), length $result,'bytes', ':', $result );
        #printlog('dbg', $resp->code(), Dumper $resp);
        my $code = config( $s, 'http_code' );
        if ($code) {
          local $_ = $resp->code();
          printlog( 'http', "code recv [$_], want [$code]", ref $code );
          my $code_ok;
          if   ( ref $code eq 'Regexp' ) { ++$code_ok if $_ =~ $code; }
          else                           { ++$code_ok if $_ =~ /$code/; }
          #          printlog( 'warn', 'http code, recv', $_, ', want ', $code, "[$code_ok]");
          unless ($code_ok) {
            printlog( 'warn', 'no good http code, recv', $_, ', want ', $code, "[$code_ok]" );
            $svc{$s}{action} ||= 'restart';
            last;
          }
        }
        $time = human( 'time_period', time() - $time );
        #!      printlog( 'port', "connected per", $time ), next if $socket;
        #!      printlog( 'warn', $s, $prot, $svc{$s}{host}, $port, "no answer", $socket, $time );
        my $check = $svc{$s}{ $prot . '_check' };
        my @check;
        if ( ref $check eq 'CODE' ) { next if $check->($result) }
        elsif ($check) {
          if   ( ref $check eq 'ARRAY' ) { @check = @$check }
          else                           { @check = $check; }
          for my $check (@check) {
            $check = qr/\Q$check/ if ref $check ne 'Regexp';
printlog('http', 'check match', $check),
            next PORTOK if $result =~ $check;
          }
          printlog( 'restart', 'no', $check, ' in ', $result );
        } else {
          next;
        }
        $svc{$s}{action} ||= 'restart';
        last;
      }
    }
    #  printlog( 'action', $s, $svc{$a}{action}, );
    $svc{$s}{action} ||= $svc{$s}{check}->() if ref $svc{$s}{check} eq 'CODE';
    next unless $svc{$s}{action};
    printlog(
      'action', $s,
      $svc{$s}{action},
      $svc{$s}{ $svc{$s}{action} },
      alarmed(
        $config{maxexttime},
        sub {
          ref $svc{$s}{ $svc{$s}{action} } eq 'CODE'
            ? $svc{$s}{ $svc{$s}{action} }->( $s, $svc{$s}{action} )
            : `$svc{$s}{$svc{$s}{action}}`;
        }
      )
    ) if $svc{$s}{ $svc{$s}{action} };
  }
};
#printlog 'dump', Dumper( \%config, \%svc, $root_path );
prog('stop')->{func}    = sub { };
prog('restart')->{func} = sub { };
prog('list')->{func}    = sub {
  $config{log_all} = 1;
  printlog 'list', services;
};
prog('avail')->{func} = sub {
  $config{log_all} = 1;
  printlog 'list', sort keys %svc;
};
prog('help')->{func} = sub {
  $config{log_all} = 1;
  printlog 'list', services;
};
prog('check')->{force} = 1 unless grep $prog{$_}{run}, keys %prog;
unless(caller) {
for my $prog ( sort { $prog{$a}{order} <=> $prog{$b}{order} } keys %prog ) {
  #next unless $prog{$prog}{run} || (!$wantrun and $prog{$prog}{force});
  next unless $prog{$prog}{run} || $prog{$prog}{force};
  #printlog 'run', $prog;
  $prog{$prog}{func}->( $prog{$prog}{opt} ) if ref $prog{$prog}{func} eq 'CODE';
}
}
#printlog 'dmp', ${root_path}, Dumper  \%config, \%svc, \%prog;
1;