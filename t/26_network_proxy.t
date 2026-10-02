#!/usr/bin/perl
use strict;
use warnings;
use Test::More;

# Inline stubs for the LMS modules Net.pm depends on
BEGIN {
    package Slim::Utils::Prefs;
    my %store;
    sub preferences { return bless {}, 'Slim::Utils::Prefs' }
    sub get { return $store{$_[1]} }
    sub set { $store{$_[1]} = $_[2] }
    $INC{'Slim/Utils/Prefs.pm'} = 1;

    package Slim::Utils::Log;
    sub logger { return bless {}, 'Slim::Utils::Log' }
    sub AUTOLOAD { }
    sub DESTROY { }
    $INC{'Slim/Utils/Log.pm'} = 1;

    package Slim::Networking::SimpleAsyncHTTP;
    sub new { my ($class, @args) = @_; return bless { args => \@args }, $class }
    $INC{'Slim/Networking/SimpleAsyncHTTP.pm'} = 1;

    # Stand-in for LMS's HTTPS socket class (real one: Net::HTTPS::NB, which
    # isa Net::HTTPS isa IO::Socket::SSL). Only the IO::Socket::SSL part is
    # needed for HTTPSConnect->new; it is optional (skip if not installed).
    package Slim::Networking::Async::Socket::HTTPS;
    our @ISA;
    @ISA = ('IO::Socket::SSL') if eval { require IO::Socket::SSL; 1 };
    $INC{'Slim/Networking/Async/Socket/HTTPS.pm'} = 1;

    package main;
    no warnings 'redefine';
    *Slim::Utils::Prefs::import = sub {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::preferences"} = \&Slim::Utils::Prefs::preferences;
    };
    *Slim::Utils::Log::import = sub {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::logger"} = \&Slim::Utils::Log::logger;
    };
}

use FindBin qw($Bin);
use lib "$Bin/..";
use Plugins::SpotOn::Net qw(parseProxyUrl currentProxy proxyFor binaryProxyArgs);

sub set_pref { Slim::Utils::Prefs->set(@_) }

# parseProxyUrl - valid
is_deeply((parseProxyUrl('http://proxy.lan:3128'))[0], {host=>'proxy.lan', port=>3128, url=>'http://proxy.lan:3128'}, 'plain host');
is((parseProxyUrl('  http://10.0.0.1:8080  '))[0]{url}, 'http://10.0.0.1:8080', 'whitespace trimmed');
is((parseProxyUrl('http://127.0.0.1:8888'))[0]{host}, '127.0.0.1', 'local proxy allowed');
is_deeply((parseProxyUrl('http://[::1]:8080'))[0], {host=>'::1', port=>8080, url=>'http://[::1]:8080'}, 'IPv6');
is((parseProxyUrl('http://host:3128/'))[0]{url}, 'http://host:3128', 'trailing slash dropped');
is((parseProxyUrl('HTTP://Host:3128'))[0]{url}, 'http://host:3128', 'case normalised');
is((parseProxyUrl('http://host:65535'))[0]{port}, 65535, 'max port');

# parseProxyUrl - errors
is((parseProxyUrl(''))[1], 'empty', 'empty');
is((parseProxyUrl(undef))[1], 'empty', 'undef');
is((parseProxyUrl('   '))[1], 'empty', 'blank');
is((parseProxyUrl('http://host'))[1], 'port', 'no port');
is((parseProxyUrl('http://host:0'))[1], 'port', 'port 0');
is((parseProxyUrl('http://host:70000'))[1], 'port', 'port too big');
is((parseProxyUrl('http://host:abc'))[1], 'port', 'port not numeric');
is((parseProxyUrl('http://u:p@host:3128'))[1], 'userinfo', 'userinfo');
is((parseProxyUrl('http://host:3128/x'))[1], 'path', 'path');
is((parseProxyUrl('http://host:3128/?a=1'))[1], 'path', 'query');
is((parseProxyUrl('https://host:3128'))[1], 'scheme', 'https');
is((parseProxyUrl('socks5://host:1080'))[1], 'socks_unsupported', 'socks5');
is((parseProxyUrl('socks://host:1080'))[1], 'socks_unsupported', 'socks');
is((parseProxyUrl('garbage'))[1], 'scheme', 'garbage');
is((parseProxyUrl('http://:3128'))[1], 'host', 'empty host');
ok(!defined((parseProxyUrl('garbage'))[0]), 'no hashref on error');

# currentProxy
set_pref(networkProxy => '');
ok(!defined currentProxy(), 'currentProxy empty');
set_pref(networkProxy => 'http://p:3128');
is(currentProxy()->{port}, 3128, 'currentProxy valid');

# proxyFor
set_pref(networkProxy => '');
is_deeply([proxyFor('https://api.spotify.com/v1/me')], [], 'no proxy configured');
set_pref(networkProxy => 'http://p:3128');
is_deeply([proxyFor('https://api.spotify.com/v1/me')], ['p', 3128], 'api via proxy');
is_deeply([proxyFor('https://accounts.spotify.com/api/token')], ['p', 3128], 'accounts via proxy');
is_deeply([proxyFor('http://127.0.0.1:9000/x')], [], 'loopback bypass');
is_deeply([proxyFor('http://127.4.5.6:1/x')], [], '127/8 bypass');
is_deeply([proxyFor('http://localhost:9000/x')], [], 'localhost bypass');
is_deeply([proxyFor('http://[::1]:9000/x')], [], '::1 bypass');
is_deeply([proxyFor('http://192.168.1.5:9000/x')], ['p', 3128], 'private LAN is not bypassed');
set_pref(networkProxy => 'http://127.0.0.1:8888');
is_deeply([proxyFor('https://api.spotify.com/')], ['127.0.0.1', 8888], 'proxy on localhost works');
is_deeply([proxyFor('https://api.spotify.com/', {host=>'o', port=>1})], ['o', 1], 'explicit override');
is_deeply([proxyFor('https://api.spotify.com/', undef)], [], 'explicit direct');
is_deeply([proxyFor('http://localhost/', {host=>'o', port=>1})], [], 'override still bypasses localhost');

# binaryProxyArgs
set_pref(networkProxy => '');
is_deeply([binaryProxyArgs()], [], 'args empty');
set_pref(networkProxy => 'http://p:3128');
is_deeply([binaryProxyArgs()], ['--proxy', 'http://p:3128'], 'args proxy');
set_pref(networkProxy => 'socks5://p:1');
is_deeply([binaryProxyArgs()], [], 'invalid = empty');

# http() without proxy
set_pref(networkProxy => '');
my $cb = sub {};
my $o = Plugins::SpotOn::Net->http($cb, $cb, {timeout=>5});
isa_ok($o, 'Slim::Networking::SimpleAsyncHTTP');
is(ref $o, 'Slim::Networking::SimpleAsyncHTTP', 'exact class');
is_deeply($o->{args}, [$cb, $cb, {timeout=>5}], 'args passed through');

# ---------------------------------------------------------------------------
# tunnel: Plugins::SpotOn::Net::Socket::HTTPSConnect
# ---------------------------------------------------------------------------
use IO::Socket::IP;
use IO::Select;
use File::Temp qw(tempfile tempdir);
use POSIX ();
use Time::HiRes qw(time sleep);

alarm 90;    # safety net: the whole file must never hang

require_ok('Plugins::SpotOn::Net::Socket::HTTPSConnect');
*_tunnel = \&Plugins::SpotOn::Net::Socket::HTTPSConnect::_tunnel;

my @children;
END { kill 'KILL', @children if @children; waitpid($_, 0) for @children }

# Fake proxy: listens on $addr, forks a child that accepts one connection,
# reads the request up to \r\n\r\n, stores it in a file and then plays the
# scenario: $response is written as-is, then $after runs ('echo', 'close',
# 'silent', 'trickle' or a coderef receiving the client socket).
# Returns (client socket connected to it, request file, listen port).
sub fake_proxy {
    my ($response, $after, $addr) = @_;
    $addr //= '127.0.0.1';
    my $l = IO::Socket::IP->new(Listen => 5, LocalHost => $addr, LocalPort => 0, ReuseAddr => 1)
        or die "listen on $addr: $@";
    my (undef, $reqfile) = tempfile(UNLINK => 1);
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        alarm 15;
        my $c = $l->accept or POSIX::_exit(1);
        my $req = q();
        while ($req !~ /\r\n\r\n/) {
            sysread($c, $req, 1, length $req) or last;
        }
        open my $fh, q(>), $reqfile; print $fh $req; close $fh;
        syswrite($c, $response) if length $response;
        $after //= 'close';
        if (ref $after eq 'CODE') { $after->($c) }
        elsif ($after eq 'echo')   { while (sysread($c, my $buf, 4096)) { syswrite($c, $buf) } }
        elsif ($after eq 'silent') { 1 while sysread($c, my $buf, 4096) }
        elsif ($after eq 'trickle') { for (1 .. 20) { syswrite($c, 'H') or last; sleep 0.25 } }
        POSIX::_exit(0);
    }
    push @children, $pid;
    my $port = $l->sockport;
    my $s = IO::Socket::IP->new(PeerHost => $addr, PeerPort => $port, Timeout => 5)
        or die "connect to fake proxy: $@";
    close $l;
    return ($s, $reqfile, $port);
}
sub fake        { (fake_proxy($_[0], 'silent'))[0] }
sub fake_close  { (fake_proxy('', 'close'))[0] }
sub fake_silent { (fake_proxy('', 'silent'))[0] }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; my $d = <$fh>; $d // '' }
sub read_echo {
    my ($s, $want) = @_;
    $want //= 4;
    my $buf = '';
    my $sel = IO::Select->new($s);
    while (length $buf < $want && $sel->can_read(5)) {
        sysread($s, $buf, $want - length $buf, length $buf) or last;
    }
    return $buf;
}

{
    my ($s, $reqfile) = fake_proxy("HTTP/1.1 200 Connection established\r\n\r\n", 'echo');
    my ($ok, $err) = _tunnel($s, 'api.spotify.com', 443, 5);
    ok($ok, 'HTTP/1.1 200 opens the tunnel');
    is($err, undef, 'no error on success');
    like(slurp($reqfile), qr/^CONNECT api\.spotify\.com:443 HTTP\/1\.1\r\nHost: api\.spotify\.com:443\r\n\r\n\z/,
        'CONNECT request line and Host header');
    print $s "ping"; $s->flush;
    is(read_echo($s), 'ping', 'data flows through the tunnel');
}

# Review Focus 1: HTTP/1.0 200 (tinyproxy, old squid)
ok((_tunnel(fake("HTTP/1.0 200 Connection established\r\n\r\n"), 'h', 443, 5))[0], 'HTTP/1.0 200 accepted');
ok((_tunnel(fake("HTTP/1.1 200 OK\r\nProxy-Agent: x\r\n\r\n"), 'h', 443, 5))[0], '200 with headers accepted');

{
    my ($s) = fake_proxy("HTTP/1.1 200 OK\r\n\r\nEXTRA", 'silent');
    ok((_tunnel($s, 'h', 443, 5))[0], '200 followed by tunnel bytes');
    is(read_echo($s, 5), 'EXTRA', 'bytes after the header block stay in the socket');
}

# Rejections
is((_tunnel(fake("HTTP/1.1 403 Forbidden\r\n\r\n"), 'h', 443, 5))[1], 'proxy: CONNECT rejected: 403 Forbidden', 'rejected: 403');
like((_tunnel(fake("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic\r\n\r\n"), 'h', 443, 5))[1],
    qr/^proxy: CONNECT rejected: 407/, 'rejected: 407');
like((_tunnel(fake("HTTP/1.1 502 Bad Gateway\r\n\r\n"), 'h', 443, 5))[1], qr/^proxy: CONNECT rejected: 502/, 'rejected: 502');
is((_tunnel(fake("HTTP/1.1 201 Created\r\n\r\n"), 'h', 443, 5))[1], 'proxy: CONNECT rejected: 201 Created', 'only 200 opens');
is((_tunnel(fake("HTTP/1.1 503\r\n\r\n"), 'h', 443, 5))[1], 'proxy: CONNECT rejected: 503', 'no reason phrase');
is((_tunnel(fake("garbage\r\n\r\n"), 'h', 443, 5))[1], 'proxy: malformed response', 'garbage');
is((_tunnel(fake("HTTP/2 200\r\n\r\n"), 'h', 443, 5))[1], 'proxy: malformed response', 'HTTP/2 status line');
is((_tunnel(fake('X' x 9000), 'h', 443, 5))[1], 'proxy: malformed response', 'header block over 8 KB');
is((_tunnel(fake_close(), 'h', 443, 5))[1], 'proxy: connection closed', 'closed before reply');
is((_tunnel((fake_proxy("HTTP/1.1 200 OK\r\n", 'close'))[0], 'h', 443, 5))[1], 'proxy: connection closed',
    'closed mid-headers');

# Review Focus 2: silent / trickling proxy must time out within the limit
{
    my $t0 = time; my @r = _tunnel(fake_silent(), 'h', 443, 1);
    is($r[1], 'proxy: timeout', 'silent proxy times out');
    cmp_ok(time - $t0, '<', 3, 'silent proxy: bounded by timeout');
    $t0 = time; @r = _tunnel((fake_proxy('', 'trickle'))[0], 'h', 443, 1);
    is($r[1], 'proxy: timeout', 'trickling proxy times out');
    cmp_ok(time - $t0, '<', 3, 'trickling proxy: deadline is total, not per read');
}

# Review Focus 4: IPv6 proxy on ::1
SKIP: {
    my $probe = IO::Socket::IP->new(Listen => 1, LocalHost => '::1', LocalPort => 0);
    skip 'IPv6 loopback not available', 2 unless $probe;
    close $probe;
    my ($s, $reqfile) = fake_proxy("HTTP/1.1 200 OK\r\n\r\n", 'silent', '::1');
    ok((_tunnel($s, 'api.spotify.com', 443, 5))[0], 'tunnel through IPv6 proxy');
    like(slurp($reqfile), qr/^CONNECT api\.spotify\.com:443 /, 'IPv6 proxy got the CONNECT');
}

# ---------------------------------------------------------------------------
# HTTPSConnect->new: TCP to proxy + CONNECT + TLS to the target (real TLS,
# self-signed cert). Needs Net::HTTP, IO::Socket::SSL and openssl (not core):
# skipped when unavailable. Net::HTTPS::NB is replaced by the stub above.
# ---------------------------------------------------------------------------
SKIP: {
    skip 'Net::HTTP / IO::Socket::SSL not installed', 17
        unless eval { require Net::HTTP; require IO::Socket::SSL; 1 };
    my $class = 'Plugins::SpotOn::Net::Socket::HTTPSConnect';
    my $dir = tempdir(CLEANUP => 1);
    my ($crt, $key) = ("$dir/c.pem", "$dir/k.pem");
    system("openssl req -x509 -newkey rsa:2048 -nodes -keyout $key -out $crt -days 2"
        . " -subj /CN=api.test -addext subjectAltName=DNS:api.test >/dev/null 2>&1");
    skip 'openssl cannot create a test certificate', 17 unless -s $crt && -s $key;

    # Child side after CONNECT: TLS server presenting the api.test cert, echo.
    my $tls_echo = sub {
        my ($c) = @_;
        my $ssl = IO::Socket::SSL->start_SSL($c, SSL_server => 1, SSL_cert_file => $crt,
            SSL_key_file => $key, Timeout => 5) or return;
        while (defined(my $line = <$ssl>)) { print $ssl $line }
    };
    # fake_proxy() also connects a client; new() makes its own connection,
    # so this variant only listens and hands back the port.
    my $proxy_for_new = sub {
        my ($response, $after) = @_;
        my $l = IO::Socket::IP->new(Listen => 5, LocalHost => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
            or die "listen: $@";
        my (undef, $reqfile) = tempfile(UNLINK => 1);
        my $pid = fork // die "fork: $!";
        if (!$pid) {
            alarm 15;
            my $c = $l->accept or POSIX::_exit(1);
            my $req = '';
            while ($req !~ /\r\n\r\n/) { sysread($c, $req, 1, length $req) or last }
            open my $fh, '>', $reqfile; print $fh $req; close $fh;
            syswrite($c, $response) if length $response;
            if (ref $after eq 'CODE') { $after->($c) }
            elsif (($after // '') eq 'silent') { 1 while sysread($c, my $buf, 4096) }
            POSIX::_exit(0);
        }
        push @children, $pid;
        my $port = $l->sockport;
        close $l;
        return ($port, $reqfile);
    };

    my %base = (Host => 'api.test', PeerAddr => '192.0.2.1', PeerPort => 443, Timeout => 30);

    {
        my ($port, $reqfile) = $proxy_for_new->("HTTP/1.1 200 OK\r\n\r\n", $tls_echo);
        my $sock = $class->new(%base, SSL_ca_file => $crt, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        ok($sock, 'new: tunnel + verified TLS established') or diag("error: $@");
        isa_ok($sock, 'Slim::Networking::Async::Socket::HTTPS');
        like(slurp($reqfile), qr/^CONNECT api\.test:443 HTTP\/1\.1\r\n/, 'new: CONNECT to the target, not PeerAddr');
        SKIP: {
            skip 'no socket', 3 unless $sock;
            ok(!$sock->blocking, 'new: socket is non-blocking once established');
            is($sock->peerport, $port, 'new: TCP peer is the proxy');
            syswrite($sock, "hello\n");
            my $buf = '';
            my $sel = IO::Select->new($sock);
            for (1 .. 50) {
                my $n = sysread($sock, $buf, 100, length $buf);
                last if $buf =~ /\n/;
                $sel->can_read(0.1) unless defined $n && $n;
            }
            is($buf, "hello\n", 'new: application data flows over TLS through the tunnel');
            $sock->close;
        }
    }

    {
        my ($port) = $proxy_for_new->("HTTP/1.1 403 Forbidden\r\n\r\n", 'silent');
        $@ = '';
        my $sock = $class->new(%base, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        ok(!defined $sock, 'new: rejected CONNECT gives undef');
        is($@, 'proxy: CONNECT rejected: 403 Forbidden', 'new: rejection reason in $@');
    }

    {
        my ($port) = $proxy_for_new->('', 'silent');
        my $t0 = time;
        my $sock = $class->new(%base, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        is($@, 'proxy: timeout', 'new: silent proxy times out');
        cmp_ok(time - $t0, '<', 7, 'new: handshake bounded by 5 s even with Timeout => 30');
    }

    {
        # bind+close to get a port nobody listens on
        my $l = IO::Socket::IP->new(Listen => 1, LocalHost => '127.0.0.1', LocalPort => 0);
        my $port = $l->sockport; close $l;
        my $sock = $class->new(%base, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        like($@, qr/^proxy: cannot connect to 127\.0\.0\.1:\d+: /, 'new: proxy down');
    }

    {
        # untrusted cert (no CA given): verification must fail ...
        my ($port) = $proxy_for_new->("HTTP/1.1 200 OK\r\n\r\n", $tls_echo);
        my $sock = $class->new(%base, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        like($@, qr/^proxy: TLS handshake failed/, 'new: certificate is verified by default');
        # ... unless the LMS server pref insecureHTTPS is set
        set_pref(insecureHTTPS => 1);
        ($port) = $proxy_for_new->("HTTP/1.1 200 OK\r\n\r\n", $tls_echo);
        $sock = $class->new(%base, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        ok($sock, 'new: insecureHTTPS disables verification') or diag("error: $@");
        $sock->close if $sock;
        set_pref(insecureHTTPS => 0);
    }

    {
        # the certificate is checked against the target Host, not the proxy
        my ($port) = $proxy_for_new->("HTTP/1.1 200 OK\r\n\r\n", $tls_echo);
        my $sock = $class->new(%base, Host => 'other.test', SSL_ca_file => $crt,
            ProxyAddr => '127.0.0.1', ProxyPort => $port);
        like($@, qr/^proxy: TLS handshake failed/, 'new: certificate name must match the target host');
    }

    {
        # slow CONNECT reply, then silence during TLS: 5 s is the total budget
        my ($port) = $proxy_for_new->('', sub {
            sleep 3; syswrite($_[0], "HTTP/1.1 200 OK\r\n\r\n"); 1 while sysread($_[0], my $b, 4096);
        });
        my $t0 = time;
        my $sock = $class->new(%base, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        like($@, qr/^proxy: TLS handshake failed/, 'new: TLS stalls after CONNECT');
        cmp_ok(time - $t0, '<', 6.5, 'new: TCP + CONNECT + TLS share one 5 s deadline');
    }

    SKIP: {
        my $probe = IO::Socket::IP->new(Listen => 1, LocalHost => '::1', LocalPort => 0);
        skip 'IPv6 loopback not available', 1 unless $probe;
        my $port = $probe->sockport;
        my $pid = fork // die;
        if (!$pid) {
            alarm 15;
            my $c = $probe->accept or POSIX::_exit(1);
            my $req = '';
            while ($req !~ /\r\n\r\n/) { sysread($c, $req, 1, length $req) or last }
            syswrite($c, "HTTP/1.1 403 Forbidden\r\n\r\n");
            POSIX::_exit(0);
        }
        push @children, $pid;
        close $probe;
        $class->new(%base, ProxyAddr => '::1', ProxyPort => $port);
        is($@, 'proxy: CONNECT rejected: 403 Forbidden', 'new: IPv6 proxy address (no brackets) reaches the proxy');
    }
}

done_testing;
