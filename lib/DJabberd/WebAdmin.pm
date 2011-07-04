#!/usr/bin/perl
#
# DJabberd Web Admin interface
# using Twiggy as its HTTP server
#
# This is really just a proof-of-concept at the moment, and doesn't do anything particularly useful
#
# Copyright 2007 Martin Atkins <mart@degeneration.co.uk>
# This package and any part thereof may be freely distributed, modified, and used in other products.
#

package DJabberd::WebAdmin;

# Need 5.8 because we use PerlIO
require 5.008;

use strict;
use Twiggy; # To get its version number
use Twiggy::Server;
use Plack::Request;
use Plack::Response;
use Symbol;
use Template;

use base qw(DJabberd::Plugin);

our $logger = DJabberd::Log->get_logger();

my $server = undef;

# FIXME: Make this configurable so that
# this module can be installed sensibly.
my $lib_path = __FILE__;
$lib_path =~ s!/[^/]+$!!;
my $static_path = $lib_path . "/../../stat";
my $template_path = $lib_path . "/../../templates";

my $tt = Template->new({
    INCLUDE_PATH => $template_path,
    
    START_TAG => quotemeta("[["),
    END_TAG => quotemeta("]]"),
    PRE_CHOMP => 2, # CHOMP_COLLAPSE
    POST_CHOMP => 2, # CHOMP_COLLAPSE
    RECURSION => 1,
});

sub error404(); # implemented below

sub set_config_listenaddr {
    my ($self, $addr) = @_;
    
    $self->{listenaddr} = DJabberd::Util::as_bind_addr($addr);

    # We default to localhost if no interface is specified
    # User can explicitly say 0.0.0.0: to bind to everything.
    $self->{listenaddr} = "127.0.0.1:".$self->{listenaddr} if $self->{listenaddr} =~ /^\d+$/;
}

sub finalize {
    my ($self) = @_;

    $logger->logdie("No ListenAddr specified for WebAdmin") unless $self->{listenaddr};

    my ($host, $port) = split(/:/, $self->{listenaddr}, 2);

    $logger->info("Initializing web admin service");

    my $twiggy = Twiggy::Server->new(
        host => $host,
        port => $port,
    );
    $twiggy->register_service(\&handle_web_request);

    $self->{twiggy} = $twiggy;

    # By now Twiggy should've bound its listen port and
    # dropped the relevant AnyEvent watchers it needs
    # so we can just return.

    $logger->info("Web admin service is ready to accept requests");

    return 1;
}

sub register {
    my ($self, $vhost) = @_;
    
    unless ($server) {
        $server = $vhost->server;
        $logger->info("Web admin service will report on $server");
    }
    else {
        $logger->logdie("Can't load DJabberd::WebAdmin into more than one VHost");
    }

}

sub handle_web_request {
    my ($env) = @_;

    my $req = Plack::Request->new($env);

    my $path = $req->path_info;

    $logger->info("Incoming request for $path");

    # If the URL starts with /_/ then it's a static file request.
    if ($path =~ m!^/_/(\w+)$!) {
        my $resource_name = $1;
        return handle_static_resource($req, $resource_name);
    }
    elsif ($path eq '/favicon.ico') {
        return handle_static_resource($req, 'favicon');
    }

    # All valid paths end with a slash
    # (because it makes it easier to construct relative links)
    if (0 && substr($path, -1) ne '/') {
        $logger->debug("Redirecting $path to $path/");
        return [
            302,
            [ 'Location' => $path . '/' ],
            [ "..." ],
        ];
    }

    my $page = determine_page_for_request($req);

    unless (defined $page) {
        $logger->debug("No page matched for $path");
        return error404;
    }

    unless (ref $page) {
        # It's a string containing a relative URL to redirect to
        $logger->debug("Redirecting $path to $path$page");
        return [
            302,
            [ 'Location' => $path . $page ],
            [ "..." ],
        ];
    }
    
    if ($page) {
        return output_page($req, $page);
    }
    else {
        return error404;
    }
}

sub handle_static_resource {
    my ($req, $name) = @_;
    
    my $fn = undef;
    my $type = undef;

    if ($name eq 'style') {
        $fn = "$static_path/style.css";
        $type = 'text/css';
    }
    else {
        $fn = "$static_path/$name.png";
        $type = 'image/png';
    }

    $logger->info("Serving static file $fn as $type");

    return error404 unless defined($fn) && -f $fn;

    return [
        200,
        [ 'Content-Type' => $type ],
        IO::File->new($fn, 'r'),
    ];
}

sub determine_page_for_request {
    my ($req) = @_;

    my $path = $req->path_info;

    my @pathbits = split(m!/!, $path);
    shift @pathbits; # zzap empty string on the front because of the leading slash

    warn Data::Dumper::Dumper(\@pathbits);
    
    if (scalar(@pathbits) == 0) {
        return DJabberd::WebAdmin::Page::Home->new();
    }
    
    my $vhost_name = shift @pathbits;
    
    my $vhost = $server->lookup_vhost($vhost_name);
    
    return undef unless $vhost;
    
    if (scalar(@pathbits) == 0) {
        return "summary/";
    }
    
    my $tabname = shift @pathbits;
    
    if ($tabname eq 'summary') {
        if (scalar(@pathbits) == 0) {
            return DJabberd::WebAdmin::Page::VHostSummary->new($vhost);
        }
    }
    
    return undef;
}

# Just a debugging function
sub dump_object_html {
    print "<pre>".DJabberd::Util::exml(Data::Dumper::Dumper(@_))."</pre>";
}

*ehtml = \&DJabberd::Util::exml;

sub output_page {
    my ($req, $page) = @_;

    my $title = $page->title;

    my $path = $req->path_info;
    my @pathbits = split(m!/!, $path);
    shift @pathbits;

    my @tabs = (
        {
            caption => 'Summary',
            urlname => 'summary',
        },
        {
            caption => 'Client Sessions',
            urlname => 'clients',
        },
        {
            caption => 'Server Sessions',
            urlname => 'servers',
        },
    );

    my $result = '';
    $tt->process('page.tt', {
        section_title => $title ? $title : "DJabberd Web Admin",
        page_title => 'Summary',
        head_title => sub { ($title ? $title.' - ' : '')."DJabberd Web Admin"; },
        body => sub { return ${ capture_output(sub { $page->print_body; }) }; },
        tabs => [
            map {
                {
                    caption => $_->{caption},
                    url => '../'.$_->{urlname}.'/',
                    current => ($pathbits[1] eq $_->{urlname} ? 1 : 0),
                }
            } @tabs
        ],
        vhosts => sub {
            my @ret = ();
            $server->foreach_vhost(sub {
                my $vhost = shift;
                my $name = $vhost->server_name;
                push @ret, {
                    hostname => $name, # The real hostname
                    url => '/'.$name.'/summary/', # FIXME: should urlencode $name here
                    name => $name, # Some display name (just the hostname for now)
                    current => ($pathbits[0] eq $name ? 1 : 0),
                };
            });
            return [ sort { $a->{name} cmp $b->{name} } @ret ];
        },
        djabberd_version => $DJabberd::VERSION,
        twiggy_version => $Twiggy::VERSION,
    }, \$result);

    return [
        200,
        [ 'Content-Type' => 'text/html' ],
        [ $result ],
    ];
}

sub capture_output {
    my $sub = shift;
    
    my $fh = Symbol::gensym();
    my $ret = "";
    open($fh, '>', \$ret);
    
    my $oldfh = select($fh);
    
    $sub->(@_);
    
    select($oldfh);
    close($fh);
    
    return \$ret;
}

sub error404() {
    return [
        '404',
        [ 'Content-Type' => 'text/plain' ],
        [ "Not Found" ],
    ];
}

package DJabberd::WebAdmin::Page;

# Abstract subclass for standalone pages

sub new {
    my ($class) = @_;
    return bless {}, $class;
}

sub title {
    my ($self, $r) = @_;
    return "";
}

sub print_body {
    my ($self, $r) = @_;

}

# Borrow the ehtml function
*ehtml = \&DJabberd::WebAdmin::ehtml;

package DJabberd::WebAdmin::Page::WithVHost;

# Abstract subclass for pages which are about a specific vhost
# (which is most of them)

use base qw(DJabberd::WebAdmin::Page);

sub new {
    my ($class, $vhost) = @_;
    return bless { vhost => $vhost }, $class;
}

sub vhost {
    return $_[0]->{vhost};
}

package DJabberd::WebAdmin::Page::Home;

use base qw(DJabberd::WebAdmin::Page);

sub title {
    return "Home";
}

sub print_body {
    my ($self, $r) = @_;

    print "<p>Welcome to the DJabberd Web Admin interface</p>";

}

package DJabberd::WebAdmin::Page::VHostSummary;

use base qw(DJabberd::WebAdmin::Page::WithVHost);

sub title {
    my ($self) = @_;
    return $self->vhost->server_name;
}

sub print_body {
    my ($self, $r) = @_;

    my $vhost = $self->vhost;

    # FIXME: Should add some accessors to DJabberd::VHost to get this stuff, rather than
    #    grovelling around inside.
    print "<h3>Client Sessions</h3>";
    print "<ul>";
    foreach my $jid (keys %{$vhost->{jid2sock}}) {
        my $conn = $vhost->{jid2sock}{$jid};
        print "<li>" . DJabberd::WebAdmin::Page::ehtml($jid) . " " . DJabberd::WebAdmin::Page::ehtml($conn->{peer_ip}) . " " . ($conn->{ssl} ? ' (SSL)' : '') . "</li>";
    }
    print "</ul>";
    
    print "<h3>Plugins Loaded</h3>";
    print "<ul>";
    foreach my $class (keys %{$vhost->{plugin_types}}) {
        print "<li>" . DJabberd::WebAdmin::Page::ehtml($class) . "</li>";
    }
    print "</ul>";

    #DJabberd::WebAdmin::dump_object_html($self->vhost);

}

1;
