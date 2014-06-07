package Porbo::Server;
use strict;
use warnings;

use Socket qw(IPPROTO_TCP TCP_NODELAY);

use URI;

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;

use HTTP::Status;
use HTTP::Date;
use Plack::Util;
use Plack::HTTPParser qw(parse_http_request);

use constant DEBUG => $ENV{PORBO_DEBUG};

open my $null_io, '<', \'';

sub new {
    my ($class, @args) = @_;

    return bless {
        no_delay => 1,
        timeout  => 300,
        read_chunk_size => 4096,
        server_software => 'Porbo',
        @args,
    }, $class;
}

sub start_listen {
    my ($self, $app) = @_;
    for my $listen (@{$self->{listen}}) {
        push @{$self->{listen_guards}}, $self->_create_tcp_server($listen, $app);
    }
}

sub register_service {
    my ($self, $app) = @_;

    $self->start_listen($app);

    $self->{exit_guard} = AE::cv {
        # Make sure that we are not listening on a socket anymore, while
        # other events are being flushed
        delete $self->{listen_guards};
    };
    $self->{exit_guard}->begin;
}

sub _create_tcp_server {
    my ($self, $listen, $app) = @_;

    my $url = URI->new($listen);

    my $host = $url->host;
    my $port = $url->port;
    my $ssl = $url->scheme eq 'https' ? 1 : 0;

    my ($listen_host, $listen_port);

    return tcp_server $host, $port, $self->_accept_handler($app, \$listen_host, \$listen_port, $ssl),
        $self->_accept_prepare_handler(\$listen_host, \$listen_port);
}

sub _accept_prepare_handler {
    my ($self, $listen_host_r, $listen_port_r) = @_;

    return sub {
        my ( $fh, $host, $port ) = @_;
        DEBUG && warn "Listening on $host:$port\n";
        $$listen_host_r = $host;
        $$listen_port_r = $port;
        $self->{server_ready}->({
            host => $host,
            port => $port,
            server_software => 'Porbo',
        }) if $self->{server_ready};

        return $self->{backlog} || 0;
    };
}

sub _accept_handler {
    my ($self, $app, $listen_host_r, $listen_port_r, $ssl) = @_;

    return sub {
        my ( $sock, $peer_host, $peer_port ) = @_;

        DEBUG && warn "$sock Accepted connection from $peer_host:$peer_port\n";
        return unless $sock;
        $self->{exit_guard}->begin;

        if ( $self->{no_delay} ) {
            setsockopt($sock, IPPROTO_TCP, TCP_NODELAY, 1)
                or die "setsockopt(TCP_NODELAY) failed:$!";
        }

        my %args;
        if ($ssl) {
            $args{tls} = 'accept';
            $args{tls_ctx} = {
                key_file => $self->{ssl_key_file},
                cert_file  => $self->{ssl_cert_file},
            };
        }

        my $handle;
        $handle = AnyEvent::Handle->new(
            fh => $sock,
            on_error => sub {
                $handle->destroy if $handle;
            },
            on_eof => sub {
                $handle->destroy if $handle;
            },
            %args,
        );

        $handle->push_read(line => "\015\012\015\012", sub {
            my ($hdl, $header) = @_;

            my $env = {
                SERVER_NAME => $$listen_host_r,
                SERVER_PORT => $$listen_port_r,
                SCRIPT_NAME => '',
                REMOTE_ADDR => $peer_host,
                'psgi.version' => [ 1, 0 ],
                'psgi.errors'  => *STDERR,
                'psgi.url_scheme' => $ssl ? 'https' : 'http',
                'psgi.nonblocking' => Plack::Util::TRUE,
                'psgi.streaming' => Plack::Util::TRUE,
                'psgi.run_once' => Plack::Util::FALSE,
                'psgi.multithread' => Plack::Util::FALSE,
                'psgi.multiprocess' => Plack::Util::FALSE,
                'psgi.input'        => undef, # will be set by _run_app()
                'psgix.io'          => $hdl->fh,
                'psgix.input.buffered' => Plack::Util::TRUE,
            };

            my $reqlen = parse_http_request($header."\015\012\015\012", $env);
            if ($reqlen < 0) {
                return $self->_bad_request($handle, 0);
            }

            unless ( eval {
                $self->_run_app($app, $env, $handle);
                1;
            }) {
                my $disconnected = ($@ =~ /^client disconnected/);
                $self->_bad_request($handle, $disconnected);
            }

            undef $handle;
        });
    };
}

sub _run_app {
    my ($self, $app, $env, $handle) = @_;

    unless ($env->{'psgi.input'}) {
        if ($env->{CONTENT_LENGTH}) {
            my $body;
            $handle->on_read(sub {
                $body .= $_[0]->rbuf;
                $_[0]->rbuf = "";
                if ($env->{CONTENT_LENGTH} <= length $body) {
                    open my $input, '<', \$body;
                    $env->{'psgi.input'} = $input;
                    $self->_run_app($app, $env, $handle);
                }
            });
            return;
        } else {
            $env->{'psgi.input'} = $null_io;
        }
    }

    my $res = Plack::Util::run_app $app, $env;

    if ( ref $res eq 'ARRAY' ) {
        $self->_write_psgi_response($handle, $res);
    } else {
        croak("Unknown response type: $res");
    }
}

sub _bad_request {
    my ( $self, $handle, $disconnected ) = @_;

    my $response = [
        400,
        [ 'Content-Type' => 'text/plain' ],
        [ ],
    ];

    # if client is already gone, don't try to write to it
    $response = [] if $disconnected;

    $self->_write_psgi_response($handle, $response);

    return;
}

sub _format_headers {
    my ( $self, $status, $headers ) = @_;
 
    my $hdr = sprintf "HTTP/1.0 %d %s\015\012", $status, HTTP::Status::status_message($status);
 
    my $i = 0;
 
    my @delim = ("\015\012", ": ");
 
    foreach my $str ( @$headers ) {
        $hdr .= $str . $delim[++$i % 2];
    }
 
    $hdr .= "\015\012";
 
    return \$hdr;
}

sub _write_psgi_response {
    my ($self, $handle, $res ) = @_;


    if (ref $res eq 'ARRAY') {
        if ( scalar @$res == 0 ) {
            # no response
            $self->{exit_guard}->end;
            return;
        }

        $self->_handle_response($res, $handle);
        $self->{exit_guard}->end;
    } elsif (ref $res eq 'CODE') {
        $$res->(sub {
            $self->_handle_response($_[0], $handle);
        });
        $self->{exit_guard}->end;
    } else {
        no warnings 'uninitialized';
        warn "Unknown response type: $res";
        return $self->_write_psgi_response($handle, [ 204, [], [] ]);
    }
}

sub _handle_response {
    my($self, $res, $handle) = @_;
 
    my @lines = (
        "Date: @{[HTTP::Date::time2str()]}\015\012",
        "Server: $self->{server_software}\015\012",
    );
 
    Plack::Util::header_iter($res->[1], sub {
        my ($k, $v) = @_;
        push @lines, "$k: $v\015\012";
    });
 
    unshift @lines, "HTTP/1.0 $res->[0] @{[ HTTP::Status::status_message($res->[0]) ]}\015\012";
    push @lines, "\015\012";
 
    $self->write_all($handle, join('', @lines), $self->{timeout})
        or return;
 
    if (defined $res->[2]) {
        my $err;
        my $done;
        {
            local $@;
            eval {
                Plack::Util::foreach(
                    $res->[2],
                    sub {
                        $self->write_all($handle, $_[0], $self->{timeout})
                            or die "failed to send all data\n";
                    },
                );
                $done = 1;
            };
            $err = $@;
        };
        unless ($done) {
            if ($err =~ /^failed to send all data\n/) {
                return;
            } else {
                die $err;
            }
        }
    } else {
        return Plack::Util::inline_object
            write => sub { $self->write_all($handle, $_[0], $self->{timeout}) },
            close => sub { };
    }
}

sub write_all {
    my ($self, $handle, $buf, $timeout) = @_;
    return 0 unless defined $buf;
    $handle->push_write($buf);
    return length $buf;
}

sub run {
    my $self = shift;
    $self->register_service(@_);

    my $w; $w = AE::signal QUIT => sub { $self->{exit_guard}->end; undef $w };
    $self->{exit_guard}->recv;
}

1;
