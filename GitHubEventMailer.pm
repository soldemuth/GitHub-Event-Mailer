package GitHubEventMailer;

use strict;
use warnings;
use 5.010;

use Config::Tiny;
use Data::Dumper;
use Digest::SHA qw(hmac_sha1_hex);
use Email::Stuffer;
use HTTP::Daemon;
use HTTP::Response;
use JSON qw(decode_json);
use Moo;
use Template;
use Time::Piece;

use base qw(
    Class::Data::Inheritable
    HTTP::Request
);

__PACKAGE__->mk_classdata(classConfig => {});
__PACKAGE__->mk_classdata(daemon      => {});
__PACKAGE__->mk_classdata(jobsConfig  => []);
__PACKAGE__->mk_classdata(template    => {});


my @_cfgElements = qw(
    event
    from
    secret
    to
);

sub loadConfig {
    my ($class, $conffile) = @_;

    my $rConfig = Config::Tiny->read($conffile);

    if (
           $rConfig->{MAIN}
        && ref($rConfig->{MAIN}) eq 'HASH'
    ) {
        $class->classConfig(delete $rConfig->{MAIN});

        if (my $templatePateh = $class->classConfig()->{TEMPLATE_PATH}) {
            $class->template(
                Template->new({
                    INCLUDE_PATH => $templatePateh,
                    INTERPOLATE  => 1,
                    POST_CHOMP   => 1,
                    EVAL_PERL    => 1,
            }));
        }
    }

    # non-main are job blocks
    my $rConfs = [values %$rConfig];

    foreach my $rConf (@{ $rConfs }) {
        if (grep { !$rConf->{$_} } @_cfgElements) {
            die q{Configuration file must be in format:
[<unique_section_name>]
event   = <event>
from    = <from address>
secret  = <GitHub event secret>
tempate = <template file in TEMPLATE_PATH>
to      = <to address>
            };
        }

        $rConf->{to}   = [ split('/[,\s]+/', $rConf->{to}) ];
        $rConf->{from} = [ split('/[,\s]+/', $rConf->{from}) ];
    }

    $class->jobsConfig($rConfs);
}

has errors => (
    is => 'rw',
);

sub pushError {
    my ($self, $error) = @_;

    unless ($self->errors()) {
        $self->errors([]);
    }

    if ($error) {
        push @{ $self->errors() }, $error;
    }
}

sub errorCount {
    return scalar @{ $_[0]->errors() // [] };
}

has body => (
    is => 'lazy',
);

sub _build_body {
    return $_[0]->_transform();
}

has event => (
    is => 'lazy',
);

sub _build_event {
    return $_[0]->getHeader('x-github-event');
}

has from => (
    default => sub { [] },
    is      => 'rw',
);

sub getHeader {
    my ($self, $hdrKey) = @_;

    return $self->header($hdrKey) // '';
}

sub isAuthorizedJob {
    my ($self) = @_;

    my $rv = 0;

    foreach my $conf (@{ $self->jobsConfig() }) {
        if (
               $self->event() eq $conf->{event}
            && $self->signature()
            eq 'sha1=' . hmac_sha1_hex($self->content(), $conf->{secret})
        ) {
            $self->from($conf->{from});
            $self->to($conf->{to});

            $rv = 1;

            last;
        }
    }

    return $rv;
}

has payload => (
    is => 'lazy',
);

sub _build_payload {
    my ($self) = @_;

    my $rPayload = {};

    eval {
        $rPayload = decode_json($self->content() // '');
    };

    if ($@ || ref($rPayload) ne 'HASH') {
        $self->pushError("Unable to parse JSON. $@");

        return {};
    } else {
        $rPayload->{event} = $self->event();
    }

    return $rPayload;
}

has response => (
    is => 'lazy',
);

sub _build_response {
    my ($self) = @_;

    my ($code, $text) = (200, 'OK');

    if ($self->errorCount()) {
        $code = 400;
        $text = 'FAIL' . Dumper($self->errors());
    }

    my $response = HTTP::Response->new($code);

    $response->content_type('text/plain');
    $response->content($text);

    return $response;
}

has signature => (
    is => 'lazy',
);

sub _build_signature {
    return $_[0]->getHeader('x-hub-signature');
}

has subject => (
    is => 'lazy',
);

sub _build_subject {
    return $_[0]->_transform({ isSubject => 1 });
}

has to => (
    default => sub { [] },
    is      => 'rw',
);

sub _transform  {
    my ($self, $rParam) = @_;

    my %payload = %{ $self->payload() };
    my $text    = '';

    if (
           ref($rParam) eq 'HASH'
        && $rParam->{isSubject}
    ) {
        $payload{isSubject} = 1;
    }

    if ($self->template()) {
        $text = $self
            ->template()
            ->process(
                $self
                    ->classConfig()
                    ->{template}
                ,
                \%payload,
            );
    }

    return $text;
}

sub do {
    my ($class, $r) = @_;

    my $self = bless $r->clone(), $class;

    if ($self->isAuthorizedJob()) {
        $self->sendEventMessage();
    } else {
        $self->sendDebugMessage();

        unless ($self->classConfig()->{SUPPRESS_NO_JOB_ERROR}) {
            $self->pushError('No jobs match the event request.');
        }
    }

    return $self->response();
}

sub sendDebugMessage {
    my ($self) = @_;

    if (my $debugTo = $self->classConfig()->{DEBUG_TO}) {
        my $errMsg = 'No jobs match the event request.';

        Email::Stuffer
            ->from($debugTo)
            ->to($debugTo)
            ->subject('GitHub - DEBUG')
            ->text_body("$errMsg\n\n" . Dumper($self))
            ->send()
        || warn "Could not send debug mail" . Dumper($self);
    }
}

sub sendEventMessage {
    my ($self) = @_;

    if (
           $self->body()
        && $self->subject()
        && !$self->errorCount()
    ) {
        Email::Stuffer
            ->from(@{ $self->from() })
            ->to(@{ $self->to() })
            ->subject($self->subject())
            ->text_body($self->body())
            ->send()
        || $self->pushError('Could not send email.');
    }
}

sub start {
    my ($class) = @_;

    my $port = $class->classConfig()->{LISTEN};

    unless ($port) {
        die 'Server is not configured.';
    } else {
        $class->daemon(
            HTTP::Daemon->new(
                LocalPort => $port
            )
        );

        warn "started on $port";

        while (my $c = $class->daemon()->accept()) {
            while (my $r = $c->get_request()) {
                $class->do($r);
            }
        }
    }
}

1;
