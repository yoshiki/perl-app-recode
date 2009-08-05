#!/usr/bin/env perl

use strict;
use Mojolicious::Lite;
use Git::Class;
use DBI;
use HTML::Entities;
use Encode;
use File::Path;
use Cwd;

our $VERSION = 0.01;
our $SERVER  = '127.0.0.1';
our $DB_FILE = Cwd::getcwd . '/recode.db';
our $GIT_DIR = Cwd::getcwd . '/repos';

sub set_routes {
    get '/' => 'index';
    get '/:id' => [ id => qr/\d+$/ ] => sub {
        my $self = shift;
        my $id = $self->stash( 'id' );
        if ( $id ) {
            my $dbh = dbh();
            my $sth = $dbh->prepare( 'SELECT * FROM recodes WHERE id = ?' );
            $sth->execute( $id );
            my $rec = $sth->fetchrow_hashref;
            $self->stash(
                server   => $SERVER,
                name     => escape( $rec->{ name } ),
                contents => nl2br( escape( $rec->{ contents } ) ),
            );
            $self->render( template => 'view' );
        }
        else {
            $self->res->code( 302 );
            $self->res->headers->header( location => '/' );
        }
    };
    post '/recodes' => sub {
        my $self = shift;
        my $name = $self->req->param( 'name' );
        my $contents = $self->req->param( 'contents' );
        my $lang = $self->req->param( 'lang' );
        my $dbh = dbh();
        my $sth = $dbh->prepare( <<'SQL' );
INSERT INTO recodes (name, contents, lang) VALUES (?, ?, ?)
SQL
        my $rv = $sth->execute( $name, $contents, $lang );
        if ( $rv ) {
            $sth = $dbh->prepare( 'SELECT * FROM recodes ORDER BY id DESC LIMIT 1' );
            $sth->execute();
            my $data = $sth->fetchrow_hashref;
            create_repository( $data );
            $self->res->code( 302 );
            $self->res->headers->header( location => '/' . $data->{ id } );
        }
        else {
            $self->stash( error => $dbh->errstr );
            $self->render( template => 'error' );
        }
    };
}

sub escape {
    my $str = shift;
    $str = HTML::Entities::encode_entities( $str, '<>&"' );
    $str =~ s/ /&nbsp;/g;
    return $str;
}

sub nl2br {
    my $str = shift;
    $str =~ s{\r?\n}{<br />}g;
    return $str;
}

sub create_repository {
    my $data = shift;
    my $dir = Cwd::getcwd . "/$data->{ id }";
    File::Path::mkpath $dir;
    my $file = "$dir/" . ($data->{ name } || 'recodefile');
    open my $fh, '>', $file or die $!;
    print $fh $data->{ contents };
    close $fh;
    my $cmd = sprintf 'cd %s && git init && git add . && git commit -m "init"', $dir;
    system( $cmd );
    $cmd = sprintf 'git clone --bare %s %s/%s.git', $dir, $GIT_DIR, $data->{ id };
    system( $cmd );
    $cmd = sprintf 'touch %s/%s.git/git-daemon-export-ok', $GIT_DIR, $data->{ id };
    system( $cmd );
    File::Path::rmtree $dir;
}

sub dbh {
    return DBI->connect("dbi:SQLite:$DB_FILE", '', '') or die $!;
}

sub init {
    unless ( -f $DB_FILE ) {
        my $dbh = dbh();
        $dbh->do(<<'SQL');
CREATE TABLE recodes (
    id INTEGER NOT NULL PRIMARY KEY,
    name TEXT,
    contents TEXT NOT NULL,
    lang TEXT DEFAULT ''
);
SQL
        $dbh->disconnect;
    }
    unless ( -d $GIT_DIR ) {
        File::Path::mkpath $GIT_DIR;
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

<div id="data">
<div class="repos"><span class="label">Clone URL: </span><span class="repos_url">git://<%= $self->stash( 'server' ) %>/<%= $self->stash( 'id' ) %>.git</span></div>
<div class="name"><%= $self->stash( 'name' ) %></div>
<div class="contents"><%= $self->stash( 'contents' ) %></div>
</div>
<div id="meta">
</div>

@@ index.html.eplite
% my $self = shift;
% $self->stash( layout => 'base' );

<div id="data">
<form action="recodes" method="post">
<div class="input_name">
<input type="text" name="name" class="name"/>
</div>
<div class="textarea_contents">
<textarea name="contents" class="contents"></textarea>
</div>
<div class="input_paste">
<input type="submit" value="&nbsp;&nbsp;Paste&nbsp;&nbsp;" class="paste" />
</div>
</form>
</div>
<div id="meta">
</div>

@@ layouts/base.html.eplite
% my $self = shift;
<!doctype>
<!html>
<head>
<meta http-equiv="content-type" content="text/html;charset=UTF-8" />
<title>recode</title>
<style>
body {
    font: 13.34px helvetica, arial, clean, sans-serif;
    font-size-adjust: none;
    font-style: normal;
    font-variant: normal;
    font-weight: normal;
    line-height: 1.4em;
    text-align: center;
}

a, a:link, a:hover {
    text-decoration: none;
    color: #3399ff;
}

div#wrapper {
    margin: 1% 1.1% 1% 0.9%;
}

div#logo {
    font: 2.5em 'Courier', monospace;
    margin: 0.4em 0;
}

select, input, textarea {
    margin: 5px 0 5px 0;
}

input.name {
    width: 100%;
    border: 1px solid #ccc;
    font-size: 1.4em;
}

div.textarea_contents {
    font-family: 'Courier', monospace;
}

textarea.contents {
    border: 1px solid #ccc;
    height: 40em;
    width: 100%;
    font-size: 0.8em;
}

span.label {
    font-family: helvetica, arial, sans-serif;
    margin-right: 5px;
}

div.input_paste {
    text-align: right;
    font-size: 20px;
}

div.repos {
    padding: 5px;
    font-family: 'Courier', monospace;
    font-size: 90%;
    text-align: left;
}

div.name {
    font: 1.4em helvetica, arial, sans-serif;
    margin: 0.3em 0;
    padding: 5px;
    border: 1px solid #ccc;
    background-color: #eee;
    text-align: left;
}

div.contents {
    font: 0.9em 'Courier', monospace;
    line-height: 1.2em;
    padding: 5px;
    border: 1px solid #ccc;
    text-align: left;
}

div#main {
    margin: 0 8.0em;
    text-align: center;
}

div#data {
    width: 70%;
}
</style>
</head>
<body>
<div id="wrapper">
<div id="header">
<div id="logo"><a href="/">recode</a></div>
</div>
<div id="main">
<%= $self->render_inner %>
</div>
</div>
</body>
</html>
