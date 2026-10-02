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

done_testing;
