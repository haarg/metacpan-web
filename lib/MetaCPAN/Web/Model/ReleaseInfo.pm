package MetaCPAN::Web::Model::ReleaseInfo;

use strict;
use warnings;
use MetaCPAN::Moose;

extends 'Catalyst::Model';

use List::Util qw( all max );
use Ref::Util qw( is_hashref );
use URI ();
use URI::Escape qw(uri_escape uri_unescape);
use URI::QueryParam;    # Add methods to URI.
use Future;

my %models = (
    _release      => 'API::Release',
    _author       => 'API::Author',
    _contributors => 'API::Contributors',
    _changes      => 'API::Changes',
    _rating       => 'API::Rating',
    _favorite     => 'API::Favorite',
);

has [ keys %models ] => ( is => 'ro' );
has full_details => ( is => 'ro' );

sub ACCEPT_CONTEXT {
    my ( $class, $c, @args ) = @_;
    @args = %{ $args[0] }
        if @args == 1 and is_hashref( $args[0] );
    push @args, map +( $_ => $c->model( $models{$_} ) ), keys %models;
    return $class->new(@args);
}

sub find {
    my ( $self, $dist ) = @_;
    my $release   = $self->_release->find($dist);
    my %dist_data = $self->_dist_data($dist);
    $release->then( sub {
        my $data = shift;
        if ( !$data->{release} ) {
            $_->cancel for values %dist_data;
            return Future->fail( { code => 404, message => 'Not found' } );
        }
        $self->_wrap(
            release => $data,
            %dist_data,
            $self->_release_data(
                $data->{release}{author},
                $data->{release}{name}
            ),
        );
    } )->then( $self->normalize );
}

sub get {
    my ( $self, $author, $release_name ) = @_;
    my $release      = $self->_release->get( $author, $release_name );
    my %release_data = $self->_release_data( $author, $release_name );
    $release->then( sub {
        my $data = shift;
        if ( !$data->{release} ) {
            $_->cancel for values %release_data;
            return Future->fail( { code => 404, message => 'Not found' } );
        }
        $self->_wrap(
            release => $data,
            %release_data,
            $self->_dist_data( $data->{release}{distribution} ),
        );
    } )->then( $self->normalize );
}

sub _wrap {
    my ( $self, %data ) = @_;
    my @keys   = keys %data;
    my @values = values %data;
    Future->needs_all( map { Future->wrap($_)->else_done( {} ) } @values )
        ->transform(
        done => sub {
            my %out;
            @out{@keys} = @_;
            \%out;
        }
        );
}

sub _dist_data {
    my ( $self, $dist ) = @_;
    return (
        favorites    => $self->_favorite->get( undef, $dist ),
        plussers     => $self->_favorite->find_plussers($dist),
        rating       => $self->_rating->get($dist),
        versions     => $self->_release->versions($dist),
        distribution => $self->_release->distribution($dist),
    );
}

sub _release_data {
    my ( $self, $author, $release ) = @_;
    return (
        author       => $self->_author->get($author),
        contributors => $self->_contributors->get( $author, $release ),
        coverage     => $self->_release->coverage($release),
        (
            $self->full_details
            ? (
                files =>
                    $self->_release->interesting_files( $author, $release ),
                modules => $self->_release->modules( $author, $release ),
                changes => $self->_changes->release_changes(
                    [ $author, $release ],
                    include_dev => 1
                ),
                )
            : ()
        ),
    );
}

sub normalize {
    my $self = shift;
    sub {
        my $data = shift;
        my $dist = $data->{release}{release}{distribution};
        Future->done( {
            took => max(
                grep defined,
                map $_->{took},
                grep is_hashref($_),
                values %$data
            ),
            coverage     => $data->{coverage},
            release      => $data->{release}{release},
            favorites    => $data->{favorites}{favorites}{$dist},
            rating       => $data->{rating}{distributions}{$dist},
            versions     => $data->{versions}{releases},
            distribution => $data->{distribution},
            author       => $data->{author},
            contributors => $data->{contributors},
            irc          => $self->groom_irc( $data->{release}{release} ),
            repository   => $self->normalize_repo( $data->{release}{release} ),
            issues       => $self->normalize_issues(
                $data->{release}{release},
                $data->{distribution}
            ),
            %{ $data->{plussers} },
            (
                $self->full_details
                ? (
                    files   => $data->{files}{files},
                    modules => $data->{modules}{files},
                    changes => $data->{changes},
                    )
                : ()
            ),
        } );
    };
}

sub groom_irc {
    my ( $self, $release ) = @_;

    my $irc = $release->{metadata}{resources}{x_IRC}
        or return {};
    my $irc_info = ref $irc ? {%$irc} : { url => $irc };

    if ( !$irc_info->{web} && $irc_info->{url} ) {
        my $url    = URI->new( $irc_info->{url} );
        my $scheme = $url->scheme;
        if ( $scheme && ( $scheme eq 'irc' || $scheme eq 'ircs' ) ) {
            my $ssl  = $scheme eq 'ircs';
            my $host = $url->authority;
            my $port;
            my $user;
            if ( $host =~ s/:(\+)?(\d+)$// ) {
                $port = $2;
                if ($1) {
                    $ssl = 1;
                }
            }
            if ( $host =~ s/^(.*)@// ) {
                $user = $1;
            }
            my $path = uri_unescape( $url->path );
            $path =~ s{^/}{};
            my $channel
                = $path || $url->fragment || $url->query_param('channel');
            $channel =~ s/^(?![#~!+])/#/;

            my $link
                = 'irc://'
                . $host
                . (
                  $ssl ? q{:+} . ( $port || 6697 )
                : $port ? ":$port"
                :         q{}
                )
                . '/'
                . $channel
                . '?nick=mc-guest-?';
            $irc_info->{web} = 'https://kiwiirc.com/nextclient/#' . $link;
        }
    }

    return $irc_info;
}

# Normalize issue info into a simple hashref.
# The view was getting messy trying to ensure that the issue count only showed
# when the url in the 'release' matched the url in the 'distribution'.
# If a release links to github, don't show the RT issue count.
# However, there are many ways for a release to specify RT :-/
# See t/model/issues.t for examples.

sub rt_url_prefix {
    'https://rt.cpan.org/Public/Dist/Display.html?Name=';
}

sub normalize_issues {
    my ( $self, $release, $distribution ) = @_;

    my $issues = {};

    my $bugtracker = ( $release->{resources} || {} )->{bugtracker} || {};

    if ( $bugtracker->{web} && $bugtracker->{web} =~ /^https?:/ ) {
        $issues->{url} = $bugtracker->{web};
    }
    elsif ( $bugtracker->{mailto} ) {
        $issues->{url} = 'mailto:' . $bugtracker->{mailto};
    }
    else {
        $issues->{url}
            = $self->rt_url_prefix . uri_escape( $release->{distribution} );
    }

    for my $bugs ( values %{ $distribution->{bugs} || {} } ) {

       # Include the active issue count, but only if counts came from the same
       # source as the url specified in the resources.
        if (
           # If the specified url matches the source we got our counts from...
            $self->normalize_issue_url( $issues->{url} ) eq
            $self->normalize_issue_url( $bugs->{source} )

            # or if both of them look like rt.
            or all {m{^https?://rt\.cpan\.org(/|$)}}
            ( $issues->{url}, $bugs->{source} )
            )
        {
            $issues->{active} = $bugs->{active};
        }
    }

    return $issues;
}

sub normalize_issue_url {
    my ( $self, $url ) = @_;
    $url
        =~ s{^https?:// (?:www\.)? ( github\.com / ([^/]+) / ([^/]+) ) (.*)$}{https://$1}x;
    $url =~ s{
        ^https?:// rt\.cpan\.org /
        (?:
            NoAuth/Bugs\.html\?Dist=
        |
            (?:Public/)?Dist/Display\.html\?Name=
        )
    }{https://rt.cpan.org/Dist/Display.html?Name=}x;

    return $url;
}

sub normalize_repo {
    my ( $self, $release ) = @_;
    my %repo = %{ ( $release->{resources} || {} )->{repository} || return {} };
    $repo{type} ||= 'git'
        if $repo{url} =~ /git/;
    my $url = $repo{web} || $repo{url}
        or return {};
    $url =~ s{^(?:git|https?)://(github\.com/)}{https://$1}
        && $url =~ s/\.git//;
    $repo{web} = $url;
    return \%repo;
}

__PACKAGE__->meta->make_immutable;

1;
