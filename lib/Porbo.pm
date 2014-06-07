package Porbo;
use 5.008005;
use strict;
use warnings;

our $VERSION = "0.01";



1;
__END__

=encoding utf-8

=head1 NAME

Porbo - Porbo HTTP development psgi server

=head1 SYNOPSIS

    plackup -s Porbo \
            --listen http://127.0.0.1:3000 \
            --listen https://127.0.0.1:3001 \
            --ssl-key-file tools/server.key \
            --ssl-cert-file tools/server.crt \
            app.psgi

=head1 DESCRIPTION

Porbo is a standalone, single-process and PSGI compatible HTTP server implementations.

This server should be great for the development and testing, but might not be suitable for a production use.

This server supports listening on multi ports and TLS like L<Mojo::Server::Morbo>.

=head1 LICENSE

Copyright (C) Uchiko.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Uchiko E<lt>memememomo@gmail.comE<gt>

=cut

