This is a simple Dancer web application used to demonstrate some
features of dip. The web application itself consists of these files:

    dancr.pl
    public/css/style.css
    schema.sql
    views/layouts/main.tt
    views/login.tt
    views/show_entries.tt

Then there is a test program that uses Plack::Test to do some simple
requests.

    test.pl

Finally we have two simple dip scripts:

    dump-requests.dip
    quant-requests.dip

To dump each request object the server encounters, use:

    dip -d -s dump-requests.dip test.pl

To get an overview of how long requests take to process, use:

    dip -d -s quant-requests.dip test.pl
