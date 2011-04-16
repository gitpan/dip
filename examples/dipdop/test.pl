#!/usr/bin/env perl

use warnings;
use strict;
use Plack::Util;
use Plack::Test;
use HTTP::Request;
use Test::More;

my $base = 'http://localhost:3000';
test_psgi
    app => Plack::Util::load_psgi('dancr.pl'),
    client => sub {
        my $cb = shift;
        $dip::dip && $dip::dip->();
        for (1..100) {
            my $res = $cb->(HTTP::Request->new(GET => "$base/"));
            ok $res->is_success, 'request was a success' or warn $res->content, "\n";
            $res = $cb->(HTTP::Request->new(GET => "$base/login"));
            ok $res->is_success, 'request was a success' or warn $res->content, "\n";
        }
    };

pass 'dummy';
done_testing;
