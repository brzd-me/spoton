package Plugins::SpotOn::Net;

# Network proxy support: proxy URL validation, bypass rules and HTTP factory.
# The proxied transport lives in Net::SimpleAsyncHTTP / Net::AsyncHTTP.

use strict;
use warnings;
use Exporter 'import';

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Networking::SimpleAsyncHTTP;

our @EXPORT_OK = qw(parseProxyUrl currentProxy proxyFor binaryProxyArgs proxyBlockedReason);

my $prefs = preferences('plugin.spoton');
my $log   = logger('plugin.spoton');

# Returns ($hashref, undef) on success or (undef, $errorKey) on failure.
sub parseProxyUrl {
    my ($str) = @_;

    return (undef, 'empty') unless defined $str;
    $str =~ s/^\s+|\s+$//g;
    return (undef, 'empty') unless length $str;

    my ($scheme, $rest) = $str =~ m{^([a-z][a-z0-9+.-]*)://(.*)$}si
        or return (undef, 'scheme');
    $scheme = lc $scheme;

    return (undef, 'socks_unsupported') if $scheme =~ /^socks/;
    return (undef, 'scheme')            if $scheme ne 'http';

    my $authority = $rest;
    my $tail      = '';
    if ($rest =~ m{^([^/?#]*)(.*)$}s) {
        ($authority, $tail) = ($1, $2);
    }

    return (undef, 'userinfo') if $authority =~ /@/;
    return (undef, 'path')     unless $tail eq '' || $tail eq '/';

    my ($host, $port);
    if ($authority =~ /^\[([0-9a-f:.]+)\](?::(.*))?$/i) {
        ($host, $port) = ($1, $2);
    }
    elsif ($authority =~ /^([^:\[\]]*)(?::(.*))?$/) {
        ($host, $port) = ($1, $2);
    }
    else {
        return (undef, 'host');
    }

    return (undef, 'port') unless defined $port && $port =~ /^[0-9]+$/ && $port >= 1 && $port <= 65535;
    # librespot's proxy socket has no default port and the url crate drops
    # ":80", so the binary refuses --proxy on port 80; reject it up front.
    return (undef, 'port80') if $port == 80;
    return (undef, 'host') unless defined $host && length $host && $host !~ /\s/;

    $host = lc $host;
    $port += 0;
    my $url = 'http://' . ($host =~ /:/ ? "[$host]" : $host) . ':' . $port;

    return ({ host => $host, port => $port, url => $url }, undef);
}

sub currentProxy {
    my ($proxy) = parseProxyUrl($prefs->get('networkProxy'));
    return $proxy;
}

# proxyFor($uri, $proxy?) -> ($host, $port) or ()
# A second argument (even undef) overrides the configured proxy.
sub proxyFor {
    my ($uri) = @_;
    my $proxy = @_ >= 2 ? $_[1] : currentProxy();

    return () unless $proxy;

    my $str = "$uri";
    if ($str =~ m{^[a-z][a-z0-9+.-]*://(?:[^@/?#]*@)?(\[[^\]]*\]|[^:/?#]*)}i) {
        my $dest = lc $1;
        $dest =~ s/^\[|\]$//g;
        return () if $dest eq 'localhost' || $dest eq '::1' || $dest =~ /^127(?:\.[0-9]{1,3}){3}$/;
    }

    return ($proxy->{host}, $proxy->{port});
}

sub binaryProxyArgs {
    my $proxy = currentProxy() or return ();
    return ('--proxy', $proxy->{url});
}

# Fail-closed guard for spawning the spoton binary: a proxy is configured but
# the binary cannot take --proxy. Returns undef (ok) or 'binary_no_proxy'.
sub proxyBlockedReason {
    return undef unless currentProxy();
    require Plugins::SpotOn::Helper;
    return Plugins::SpotOn::Helper->getCapability('proxy') ? undef : 'binary_no_proxy';
}

# Class method, drop-in for Slim::Networking::SimpleAsyncHTTP->new.
# Without a proxy (and without a proxyOverride key in %params) this is exactly
# the stock class. Otherwise the subclass routes the request via the proxy
# (proxyOverride: hashref from parseProxyUrl = that proxy, undef = direct).
sub http {
    my ($class, $cb, $ecb, $params) = @_;

    if ((ref $params eq 'HASH' && exists $params->{proxyOverride}) || currentProxy()) {
        require Plugins::SpotOn::Net::SimpleAsyncHTTP;
        return Plugins::SpotOn::Net::SimpleAsyncHTTP->new($cb, $ecb, $params);
    }

    return Slim::Networking::SimpleAsyncHTTP->new($cb, $ecb, $params);
}

1;
