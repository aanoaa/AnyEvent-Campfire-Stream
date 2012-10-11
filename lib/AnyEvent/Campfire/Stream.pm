package AnyEvent::Campfire::Stream;

# Abstract: Receive Campfire streaming API in an event loop
use Moose;
use namespace::autoclean;

use AnyEvent;
use AnyEvent::HTTP;
use URI;
use MIME::Base64;
use JSON::XS;

has 'token' => (
    is  => 'rw',
    isa => 'Str',
);

has 'authorization' => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

has 'rooms' => ( is => 'rw' );

has '_events' => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {} },
);

sub _build_authorization { 'Basic ' . encode_base64( shift->token . ':x' ) }

sub emit {
    my ( $self, $name ) = ( shift, shift );
    if ( my $s = $self->_events->{$name} ) {
        for my $cb (@$s) { $self->$cb(@_) }
    }
    return $self;
}

sub on {
    my ( $self, $name, $cb ) = @_;
    push @{ $self->{_events}{$name} ||= [] }, $cb;
    return $cb;
}

sub BUILD {
    my $self = shift;

    $self->rooms( [ split( /,/, $self->rooms ) ] );
    if ( !$self->authorization || !scalar @{ $self->rooms } ) {
        print STDERR
          "Not enough parameters provided. I Need a token and rooms\n";
        exit(1);
    }

    my %headers = (
        Accept        => '*/*',
        Authorization => $self->authorization,
    );

    my $on_json = sub {
        my $json = shift;
        if ( $json !~ /^\s*$/ ) {
            $self->emit( 'stream', decode_json($json) );
        }
    };

    my $on_header = sub {
        my ($hdr) = @_;
        if ( $hdr->{Status} !~ m/^2/ ) {
            $self->emit( 'error', $hdr->{Status}, $hdr->{Reason} );
            return;
        }
        return 1;
    };

    my $callback = sub {
        my ( $handle, $headers ) = @_;

        return unless $handle;

        my $chunk_reader = sub {
            my ( $handle, $line ) = @_;

            $line =~ /^([0-9a-fA-F]+)/ or die 'bad chunk (incorrect length)';
            my $len = hex $1;

            $handle->push_read(
                chunk => $len,
                sub {
                    my ( $handle, $chunk ) = @_;

                    $handle->push_read(
                        line => sub {
                            length $_[1]
                              and die 'bad chunk (missing last empty line)';
                        }
                    );

                    $on_json->($chunk);
                }
            );
        };
        my $line_reader = sub {
            my ( $handle, $line ) = @_;
            $on_json->($line);
        };

        $handle->on_error(
            sub {
                undef $handle;
                $self->emit( 'error', $_[2] );
            }
        );

        $handle->on_eof( sub { undef $handle } );
        if ( ( $headers->{'transfer-encoding'} || '' ) =~ /\bchunked\b/i ) {
            $handle->on_read(
                sub {
                    my ($handle) = @_;
                    $handle->push_read( line => $chunk_reader );
                }
            );
        }
        else {
            $handle->on_read(
                sub {
                    my ($handle) = @_;
                    $handle->push_read( line => $line_reader );
                }
            );
        }
    };

    for my $room ( @{ $self->rooms } ) {
        my $uri = URI->new(
            sprintf "https://streaming.campfirenow.com/room/$room/live.json" );
        http_request(
            'GET',
            $uri,
            headers          => \%headers,
            keepalive        => 1,
            want_body_handle => 1,
            on_header        => $on_header,
            $callback,
        );
    }
}

__PACKAGE__->meta->make_immutable;

1;

=pod

=head1 SYNOPSIS

    use AnyEvent::Campfire::Stream;
    my $stream = AnyEvent::Campfire::Stream->new(
        token => 'xxx',
        rooms => '1234',    # hint: room id is in the url
                            # seperated by comma `,`
    );

    $stream->on('stream', sub {
        my ($s, $data) = @_;    # $s is $stream
        print "$data->{id}: $data->{body}\n";
    });

    $stream->on('error', sub {
        my ($s, $error) = @_;
        print STDERR "$error\n";
    });

=head1 SEE ALSO

=over

=item L<https://github.com/37signals/campfire-api/blob/master/sections/streaming.md>

=back

=cut
