use 5.010;
use strict;
use warnings;

package dip;
BEGIN {
  $dip::VERSION = '1.111460';
}

# ABSTRACT: Dynamic instrumentation like DTrace, using aspects
use Aspect 1.00;
use Data::Dumper;
use Carp;
use autodie;
use Time::HiRes qw(gettimeofday tv_interval);  # so they're available to aspects
our %opt;
$dip::dip = sub { instrument() };

sub import {
    shift;

    # perl -Mdip='before { counter("constructor", $_->{sub_name}) }
    # splits on ',' even inside a quoted string... :/
    while ($_[0] =~ /^-(\w+)$/) {
        $opt{$1}++;
        shift;
    }
    our $advice = join ',' => @_;
    die "dip: no instrumentation found\n" unless length $advice;
}

sub instrument {
    our $did_instrument;
    warn "warning: dip::instrument() run more than once\n" if $did_instrument++;
    ## no critic
    no strict;
    eval our $advice;
    die $@ if $@;
}

sub run {
    my $file = shift;
    $file =~ s!~/!$ENV{HOME}/!;

    # Don't assign do() to a lexical otherwise
    # the aspects will go out of scope here.
    do $file;
    warn "couldn't parse $file: $@" if $@;
    warn "couldn't do $file: $!"    if $!;
}

sub ustack {
    my $depth     = shift || 20;
    my $trace     = '';
    my $min_level = -1;
    while (1) {
        my ($pkg, $sub) = (caller(++$min_level))[ 0, 3 ];
        last unless [ $pkg, $sub ] ~~ /^(Aspect::|dip\b)/o;
    }
    for my $level ($min_level .. $min_level + $depth - 1) {
        my $sub = (caller($level))[3];
        next unless $sub;
        $trace .= $sub . "\n";
    }
    $trace;
}

sub cluck {
    local %Carp::CarpInternal = %Carp::CarpInternal;
    $Carp::CarpInternal{$_}++ for qw(dip Aspect::Hook);
    Carp::cluck @_;
}

sub count ($@) {
    my ($type, @value) = @_;
    our %counter;
    my $value = join "\n" => @value;
    $counter{$type}{$value}++;
}

sub _dump_counters {
    while (my ($type, $hash) = each our %counter) {
        print "Counter '$type':\n";
        _dump_counter_hash($hash);
    }
}

sub _dump_counter_hash {
    my $hash = shift;
    my ($max_length_key, $max_length_value) = (0, 0);
    my $seen_newline = 0;
    while (my ($key, $value) = each %$hash) {
        if (index($key, "\n") != -1) {
            $seen_newline++;
            $max_length_key = 0;
        }
        if (!$seen_newline && length($key) > $max_length_key) {
            $max_length_key = length($key);
        }
        $max_length_value = length($value)
          if length($value) > $max_length_value;
    }
    for my $key (sort { $hash->{$a} <=> $hash->{$b} } keys %$hash) {
        print "\n" if index($key, "\n") != -1;
        printf "  %-${max_length_key}s %${max_length_value}d\n", $key,
          $hash->{$key};
    }
}

# helpers for direct use in command-line aspects
sub dump_var {
    no warnings 'once';
    local $Data::Dumper::Quotekeys = 0;
    local $Data::Dumper::Indent    = 1;
    print Dumper \@_;
}

sub rtrim {
    local $_ = shift;
    s/\s+$//gs;
    1 while chomp;
    "$_\n";
}
sub rref ($) { ref $_[0] || $_[0] }

# In advice, $_->{args} contains a reference to the wrapped sub's @_.
# Use this like ARGS(2,1) === $_->{args}[2] . " " . $_->{args}[1]
sub ARGS {
    return $_->{args}[$_[0]] if @_ == 1;
    join ' ' => (@{ $_->{args} })[@_];
}
######################################################################
# quantize                                                           #
######################################################################
sub quantize ($$) {
    my ($names, $value) = @_;
    $names = [$names] unless ref $names eq 'ARRAY';
    for my $name (@$names) {
        our %quantize;
        $quantize{$name} //= [];
        my $index = int(log($value) / log(2));
        $index = 0 if $index < 0;
        $quantize{$name}[$index]++;
    }
}

sub _dump_quantize (;$$) {
    my ($width, $char) = @_;
    for my $name (sort keys our %quantize) {
        _dump_one_quantize($name, $width, $char);
    }
}

sub _dump_one_quantize ($;$$) {
    my ($name, $width, $char) = @_;
    $width //= 50;
    $char  //= '@';
    our %quantize;

    # extend by one so we see the next-higher value on an empty last line
    my @q = (@{ $quantize{$name} || [] }, 0);
    $_ //= 0 for @q;
    my $lhs_length = 12;
    my $max_value  = 0;
    for (@q) { $max_value = $_ if $_ > $max_value }
    my $scale = 1 + int($max_value / $width);
    print "$name\n";
    my $title  = ' Distribution ';
    my $dashes = ($width - length($title)) / 2;
    printf "%${lhs_length}s  %${width}s count\n", 'value',
      ('-' x $dashes) . $title . ('-' x $dashes);

    # FIXME use tests to check for off-by-one errors
    my $saw_nonempty_line = 0;
    for (0 .. $#q) {

        # There's at least one bucket so if we didn't see a nonempty line so
        # far, $_+1 will still be in range.
        next if !$saw_nonempty_line && $q[$_] == 0 && $q[ $_ + 1 ] == 0;
        $saw_nonempty_line++;
        my $plot_length = $q[$_] / $scale;
        $plot_length = 1 if $q[$_] && $plot_length < 1;
        printf "%${lhs_length}d |%-${width}s %d\n", 2**$_,
          $char x $plot_length, $q[$_];
    }
    print "\n";
}
INIT {
    instrument() unless $opt{delay};
}

END {
    _dump_counters();
    _dump_quantize();
    ## no critic
    no strict;
    my $namespace = __PACKAGE__ . '::';

    # taken from Package::Stash::PP->list_all_symbols
    my @hash_symbols = grep {
        ref(\$namespace->{$_}) eq 'GLOB'
          && defined(*{ $namespace->{$_} }{HASH})
    } keys %{$namespace};
    for my $hash_symbol (@hash_symbols) {
        next if $hash_symbol ~~ [qw(counter quantize opt)];
        my $hash = *{ $namespace . $hash_symbol }{HASH};
        no warnings 'once';
        local $Data::Dumper::Quotekeys = 0;
        local $Data::Dumper::Indent    = 1;
        print Data::Dumper->Dump([$hash], [$hash_symbol]);
    }
}
1;


__END__
=pod

=for stopwords DTrace rref rtrim ustack

=for test_synopsis 1;
__END__

=head1 NAME

dip - Dynamic instrumentation like DTrace, using aspects

=head1 VERSION

version 1.111460

=head1 SYNOPSIS

    $ dip -e 'aspect Profiled => call qr/^Person::set_/' myapp.pl
    $ dip -s toolkit/count_new.dip -- -S myapp.pl
    $ dip -e 'before { count("constructor", ARGS(1), ustack(5)); $c{total}++ }
        call qr/URI::new$/' test.pl

    $ cat quant-requests.dip
    # quantize request handling time, separated by request URI
    before { $ts_start = [gettimeofday] }
        call qr/Dancer::Handler::handle_request/;
    after { quantize ARGS(1)->request_uri => 10**6*tv_interval($ts_start) }
        call qr/Dancer::Handler::handle_request/;
    $ dip -s request-quant.dip test.pl
    ...
    /
           value  ------------------ Distribution ------------------ count
            1024 |                                                   0
            2048 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@    95
            4096 |@@                                                 4
            8192 |                                                   0
           16384 |@                                                  1
           32768 |                                                   0

    /login
           value  ------------------ Distribution ------------------ count
             512 |                                                   0
            1024 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@                70
            2048 |@@@@@@@@@@@@@@@                                    30
            4096 |                                                   0

=head1 DESCRIPTION

C<dip> is a dynamic instrumentation framework for troubleshooting Perl
programs in real time. C<dip> can provide fine-grained information,
such as a log of the arguments with which a specific function is being
called.

Conceptually, C<dip> sits on top of L<Aspect> and uses pointcuts and
advice - to use Aspect-oriented programming jargon - to define dynamic
instrumentation. These instruments are applied to the program from the
outside, without having to change the program code at all. While most
C<dip> scripts will consist of aspect-oriented instrumentation, they
can also use the full power of Perl.

C<dip> aims to bring some of the power of DTrace to perl. Therefore it
is useful to stick to DTrace terminology. C<dip> pointcuts resemble
DTrace "probes"; C<dip> advice resembles DTrace "actions".

Whenever the condition for a probe is met, the associated action
is executed; the probe "fires". A typical probe might fire when
a certain function is entered or exited. The probe's action may
analyze the run-time situation by accessing the call stack and context
variables and evaluating expressions; it can then print out or log
some information, record it in a database, or modify variables - an
action is, after all, pure Perl code. Using variables allows probes to
pass information to each other, allowing them to cooperatively analyze
the correlation of different events. For example, a probe that fires
when a function is entered could record the current time; another
probe that fires when that function is exited could record how much
time the function took.

Because of the nature of Aspect-oriented programming in Perl, you only
pay for what you use. When probes are defined, all existing possible
locations for running the action are examined, and the probe is only
activated for those locations that match the probe's condition.

=head2 Output

At the end of your program run, during C<END> time, all aggregators -
see below - will dump their results. Also any other hashes you have
written to in your dip scripts will be dumped.

For example, if you simply wanted to know which kinds of objects have
been instantiated at least once, you could use:

    before { $c{total}++ } call qr/::new$/

and then C<%c> will be dumped.

=head2 Aggregating functions

C<dip> provides aggregating functions that help in understanding a set
of data. You can keep counts of occurrences, or quantize data, much
like with DTrace.

The C<quantize> aggregating function generates a power-of-two
distribution - see its documentation.

=head1 FUNCTIONS

=head2 import

Remembers the dip script given on the command-line so we can run it in
C<instrument()>. Complains if there was no dip script. The C<--delay>
option is passed in this way as well.

=head2 instrument

Evaluates the dip script we remembered in C<import()>. Dies if there
was a problem evaluating it.

Normally this function will be called automatically during C<INIT>
time, but you can delay by giving the C<--delay> option to C<dip>; you
would use this if your program loads other code at runtime - using
C<do()>, for example - that needs to be instrumented as well. In that
case you have manually activate the instrumentation using:

    $dip::dip && $dip::dip->();

=head2 run

Convenience function that takes a filename and runs the file via
C<do()>. This is what C<dip -s> uses. For example:

    dip -s myscript.dip myapp.pl

is turned into:

    dip -e 'run q!$file!' myapp.pl

and ultimately

    perl -Mdip='run q!$file!' myapp.pl

=head2 ustack

Returns a concise stack trace. Takes an argument of how many levels
deep the stack trace should be; the default is 20 levels. Stack frames
that point to a package name in the C<Aspect::> or C<dip> namespace
are omitted.

Example: count how many times a C<XML::LibXML::NodeList> object is
created, and keep a separate counter for each place it is created
from, remembering three stack frames for each place:

    before { count "constructor", ARGS(0), ustack(3) }
        call qr/XML::LibXML::NodeList::new$/

=head2 cluck

Returns what L<Carp>'s C<cluck()> would return, again with C<Aspect::>
and C<dip> namespaces omitted.

=head2 count

This aggregator function takes a counter name and a value and keeps a
count of how often this value was seen for this counter.

You can pass several values; they will be concatenated using newlines.
See the example for C<ustack()>.

Example: For each class, count how many objects are created. Also keep
a total count.

    before { count("constructor", ARGS(0)); $c{total}++ }
        call qr/::new$/

=head2 dump_var

Convenience method to dump a variable like L<Data::Dumper> does.

Example: Show all requests a L<Dancer> web application handles:

    before { dump_var ARGS(1) }
        call qr/Dancer::Handler::handle_request/

=head2 rtrim

Convenience function to right-trim a string.

=head2 rref

Convenience function that, if given a string - for example, a package
name -, just returns the string, but if given an object, it returns
that object's class.

Useful if objects you want to instrument are sometimes created by
calling C<new()> on existing objects:

    before { count("constructor", rref ARGS(0)) } call qr/::new$/

=head2 ARGS

Convenience function to access the arguments of a function that
you are instrumenting. C<ARGS(0)>, for example, returns the first
argument. You can use several argument indices; in this case the
indicated function arguments will be stringified and concatenated with
a space.

C<ARGS(0)> is equivalent to C<$_->{args}[0]>; C<ARGS(1,2)> is equivalent to
C<join ' ' => ARGS(0), ARGS(1)> - see L<Aspect> for the kind of context
information that is passed to advice code.

=head2 quantize

This aggregator function takes a name, or an reference to a list of
names, and a value. For each name, it keeps track of a power-of-two
frequency distribution of the values of the specified expressions.
Increments the value in the highest power-of-two bucket that is less
than the specified expression.

=head1 INSTALLATION

See perlmodinstall for information and options on installing Perl modules.

=head1 BUGS AND LIMITATIONS

No bugs have been reported.

Please report any bugs or feature requests through the web interface at
L<http://rt.cpan.org/Public/Dist/Display.html?Name=dip>.

=head1 AVAILABILITY

The latest version of this module is available from the Comprehensive Perl
Archive Network (CPAN). Visit L<http://www.perl.com/CPAN/> to find a CPAN
site near you, or see L<http://search.cpan.org/dist/dip/>.

The development version lives at L<http://github.com/hanekomu/dip>
and may be cloned from L<git://github.com/hanekomu/dip.git>.
Instead of sending patches, please fork this project using the standard
git and github infrastructure.

=head1 AUTHOR

Marcel Gruenauer <marcel@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2011 by Marcel Gruenauer.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

