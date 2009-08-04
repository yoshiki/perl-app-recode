#!/usr/bin/env perl

use strict;
use Mojolicious::Lite;
use Git::Class;
use DBI;
use HTML::Entities;
use Encode;
use File::Path;

our $VERSION = 0.01;
our $DB_FILE = 'pist.db';

sub set_routes {
    get '/' => 'index';
    get '/:id' => [ id => qr/\d+$/ ] => sub {
        my $self = shift;
        my $id = $self->stash( 'id' );
        if ( $id ) {
            my $dbh = dbh();
            my $sth = $dbh->prepare( 'SELECT * FROM pists WHERE id = ?' );
            $sth->execute( $id );
            my $rec = $sth->fetchrow_hashref;
            use Devel::Peek;
            Dump $rec->{contents};
            $self->stash( name => escape( $rec->{ name } ) );
            $self->stash( contents => nl2br( escape( $rec->{ contents } ) ) );
            $self->render( template => 'view' );
        }
        else {
            $self->res->code( 302 );
            $self->res->headers->header( location => '/' );
        }
    };
    post '/pists' => sub {
        my $self = shift;
        my $name = $self->req->param( 'name' );
        my $contents = $self->req->param( 'contents' );
        my $lang = $self->req->param( 'lang' );
        my $dbh = dbh();
        my $sth = $dbh->prepare( <<'SQL' );
INSERT INTO pists (name, contents, lang) VALUES (?, ?, ?)
SQL
        my $rv = $sth->execute( $name, $contents, $lang );
        if ( $rv ) {
            $sth = $dbh->prepare( 'SELECT * FROM pists ORDER BY id DESC LIMIT 1' );
            $sth->execute();
            my $rec = $sth->fetchrow_hashref;
            $self->res->code( 302 );
            $self->res->headers->header( location => '/' . $rec->{ id } );
        }
        else {
            $self->stash( error => $dbh->errstr );
            $self->render( template => 'error' );
        }
    };
}

sub escape {
    my $str = shift;
    return HTML::Entities::encode_entities( $str, '<>&"' );
}

sub nl2br {
    my $str = shift;
    $str =~ s{\r?\n}{<br />}g;
    return $str;
}

sub create_repo {
    my ( $id, $name, $contents ) = @_;
    File::Path::make_path( $id );
    open my $fh, '>', "$id/" . ($name || 'pistfile') or die $!;
    print $fh $contents;
    close $fh;

    
}

sub dbh {
    return DBI->connect("dbi:SQLite:$DB_FILE", '', '') or die $!;
}

sub init {
    unless ( -f $DB_FILE ) {
        my $dbh = dbh();
        $dbh->do(<<'SQL');
CREATE TABLE pists (
    id INTEGER NOT NULL PRIMARY KEY,
    name TEXT,
    contents TEXT NOT NULL,
    lang TEXT DEFAULT ''
);
SQL
        $dbh->disconnect;
    }
}

init;
set_routes;
shagadelic;
__DATA__

@@ error.html.eplite
% my $self = shift;
% $self->stash( layout => 'base' );

<%= $self->stash( 'error' ) %>

@@ view.html.eplite
% my $self = shift;
% $self->stash( layout => 'base' );

<div class="name"><%= $self->stash( 'name' ) %></div>
<div class="contents"><%= $self->stash( 'contents' ) %></div>

@@ index.html.eplite
% my $self = shift;
% $self->stash( layout => 'base' );

<form action="pists" method="post">
<div class="input_name">
<input type="text" name="name" class="name"/>
</div>
<div class="textarea_contents">
<textarea name="contents" class="contents"></textarea>
</div>
<div class="input_paste">
<input type="submit" value="Paste" class="paste" />
</div>
</form>

@@ layouts/base.html.eplite
% my $self = shift;
<!doctype>
<!html>
<head>
<meta http-equiv="content-type" content="text/html;charset=UTF-8" />
<title>Pist</title>
<link href="/common.css" rel="stylesheet" type="text/css" />
<link href="/prettify.css" rel="stylesheet" type="text/css" />
<script type="text/css" src="prettify.js"></script>
</head>
<body>
<div id="wrapper">
<div id="logo"><a href="/">Pist</a></div>
<%= $self->render_inner %>
</div>
</body>
</html>
