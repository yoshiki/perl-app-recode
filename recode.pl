#!/usr/bin/env perl

use strict;
use Mojolicious::Lite;
use HTML::Entities ();
use URI::Escape ();
use Path::Class;
use Cwd ();
use Digest::SHA1 ();
use Encode ();

our $VERSION   = 0.01;
our $SERVER    = '127.0.0.1';
our $BASE_DIR  = Cwd::getcwd();
our $REPOS_DIR = dir( "$BASE_DIR/repos" );
our $BARE_DIR  = dir( "$BASE_DIR/bare" );

sub init {
    $REPOS_DIR->mkpath unless -d $REPOS_DIR;
    $BARE_DIR->mkpath  unless -d $BARE_DIR;
}

sub digest {
    my $len = shift || 8;
    substr Digest::SHA1::sha1_hex({} . time . $$), 0, $len;
}

sub uri_escape {
    my $str = shift;
    $str = URI::Escape::uri_escape( $str );
    return $str;
}

sub html_escape {
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

sub read_commit {
    my $digest = shift;
    my $repos = "$REPOS_DIR/$digest";
    my $cmd = sprintf 'cd %s && git log -z', $repos;
    my $log = qx( $cmd );
    my @commits;
    for my $commit ( split /\0/, $log ) {
        my ( $sha1, $author, $date ) = split /\r?\n/, $commit;
        $sha1   =~ s/^commit\s+(.+)$/$1/;
        $author =~ s/Author:\s+([^\s]+).+$/$1/;
        $date   =~ s/Date:\s+(.+)$/$1/;
        push @commits, {
            sha1   => $sha1,
            author => $author,
            date   => $date,
        };
    }
    return \@commits;
}

sub create_repos {
    my ( $name, $contents ) = @_;
    my $digest = digest();
    my $repos = dir( "$REPOS_DIR/$digest" );
    $repos->mkpath unless -d $repos;
    my $file = file( "$repos/$name" );
    my $fh = $file->openw;
    print $fh $contents;
    close $fh;

    # init repos
    my $bare = dir( "$BARE_DIR/${digest}.git" );
    system( sprintf 'cd %s && git init && git add . && git commit -m "init"', $repos );
    # clone repos
    clone_bare_repos( $digest );
    # touch setting file
    system( sprintf 'touch %s/git-daemon-export-ok', $bare );

    # re-clone repos
    $repos->rmtree if -d $repos;
    clone_repos( $digest );
    return $digest;
}

sub read_repos {
    my $digest = shift;
    my $repos = dir( "$REPOS_DIR/$digest" );
    my $cmd = sprintf 'cd %s && git ls-tree refs/heads/master | grep blob', $repos;
    my $tree = qx( $cmd );
    my @blobs;
    for my $obj ( split /\r?\n/, $tree ) {
        my ( $mode, $kind, $sha1, $name ) = split /\s+/, $obj;
        my $cmd = sprintf 'cd %s && git cat-file %s %s', $repos, $kind, $sha1;
        my $contents = qx( $cmd );
        push @blobs, {
            name     => $name =~ /^".+"$/ ? eval $name : $name,
            contents => $contents,
        };
    }
    return \@blobs;
}

sub clone_repos {
    my $digest = shift;
    my $repos = dir( "$REPOS_DIR/$digest" );
    my $bare = dir( "$BARE_DIR/${digest}.git" );
    $repos->rmtree if -d $repos;
    system( sprintf 'git clone %s %s', $bare, $repos );
}

sub clone_bare_repos {
    my $digest = shift;
    my $repos = dir( "$REPOS_DIR/$digest" );
    my $bare = dir( "$BARE_DIR/${digest}.git" );
    $bare->rmtree if -d $bare;
    system( sprintf 'git clone --bare %s %s', $repos, $bare );
}

sub create_blob {
    my ( $digest, $name, $contents ) = @_;
    my $repos = dir( "$REPOS_DIR/$digest" );
    my $file = file( "$repos/$name" );
    my $fh = $file->openw;
    print $fh $contents;
    close $fh;
    system( sprintf 'cd %s && git add %s && git commit -a -m "blob created"', $repos, $name );
    system( sprintf 'cd %s && git push origin master', $repos );
    return $digest;
}

sub read_blob {
    my ( $digest, $name ) = @_;
    my $file = file( "$REPOS_DIR/$digest/$name" );
    my $fh = $file->openr;
    return join '', <$fh>;
}

sub update_blob {
    my ( $digest, $old_name, $name, $contents ) = @_;
    my $repos = dir( "$REPOS_DIR/$digest" );
    if ( $old_name ne $name ) {
        system(
            sprintf 'cd %s && git mv %s %s && git commit -a -m "blob moved"',
            $repos, $old_name, $name
        );
    }

    my $file = file( "$repos/$name" );
    my $fh = $file->openw;
    print $fh $contents;
    close $fh;
    system( sprintf 'cd %s && git commit -a -m "blob updated"', $repos, $name );
    system( sprintf 'cd %s && git push origin master', $repos );

    return $digest;
}

sub delete_blob {
    my ( $digest, $name ) = @_;
    my $repos = dir( "$REPOS_DIR/$digest" );
    my $file = file( "$repos/$name" );
    $file->remove;
    system( sprintf 'cd %s && git commit -a -m "removed blob"', $repos );
    system( sprintf 'cd %s && git push origin master', $repos );
}

sub set_routes {
    get '/' => 'root';
    post '/' => sub {
        my $self = shift;
        my $name     = $self->req->param( 'name' ) || digest( 4 );
        my $contents = $self->req->param( 'contents' );
        my $lang     = $self->req->param( 'lang' );
        if ( $contents ) {
            my $digest = create_repos( $name, $contents );
            $self->res->code( 302 );
            $self->res->headers->header( location => '/' . $digest );
        }
        else {
            $self->res->code( 302 );
            $self->res->headers->header( location => '/' );
        }
    };
    get '/:digest' => [ digest => qr/\w{8}/ ] => sub {
        my $self = shift;
        my $digest = $self->stash( 'digest' );
        if ( $digest ) {
            clone_repos( $digest );
            my $blobs = read_repos( $digest );
            my $meta = read_commit( $digest );
            $self->stash(
                server   => $SERVER,
                blobs    => $blobs,
                meta     => $meta,
            );
            $self->render( template => 'view' );
        }
        else {
            $self->res->code( 302 );
            $self->res->headers->header( location => '/' );
        }
    };
    get '/add/:digest' => [ digest => qr/\w{8}/ ] => sub {
        my $self = shift;
        my $digest = $self->stash( 'digest' );
        if ( $digest ) {
            $self->render( template => 'root' );
        }
        else {
            $self->res->code( 302 );
            $self->res->headers->header( location => '/' );
        }
    };
    post '/add/:digest' => [ digest => qr/\w{8}/ ] => sub {
        my $self = shift;
        my $digest   = $self->stash( 'digest' );
        my $name     = $self->req->param( 'name' ) || digest( 4 );
        my $contents = $self->req->param( 'contents' );
        my $lang     = $self->req->param( 'lang' );
        if ( $digest && $contents ) {
            my $digest = create_blob( $digest, $name, $contents );
            $self->res->code( 302 );
            $self->res->headers->header( location => '/' . $digest );
        }
        else {
            $self->res->code( 302 );
            $self->res->headers->header( location => '/' );
        }
    };
    get '/edit/:digest/:name' => [ digest => qr/\w{8}/ ] => sub {
        my $self = shift;
        my $digest   = $self->stash( 'digest' );
        my $name     = $self->stash( 'name' );
        my $contents = read_blob( $digest, $name );
        $self->stash( contents => $contents );
        $self->render( template => 'root' );
    };
    post '/edit/:digest/:name' => [ digest => qr/\w{8}/ ] => sub {
        my $self = shift;
        my $digest   = $self->stash( 'digest' );
        my $old_name = $self->stash( 'name' );
        my $name     = $self->req->param( 'name' ) || digest( 4 );
        my $contents = $self->req->param( 'contents' );
        my $lang     = $self->req->param( 'lang' );
        if ( $contents ) {
            my $digest = update_blob( $digest, $old_name, $name, $contents );
            $self->res->code( 302 );
            $self->res->headers->header( location => '/' . $digest );
        }
        else {
            $self->res->code( 302 );
            $self->res->headers->header( location => '/' );
        }
    };
    get '/delete/:digest/:name' => [ digest => qr/\w{8}/ ] => sub {
        my $self = shift;
        my $digest   = $self->stash( 'digest' );
        my $name     = $self->stash( 'name' );
        warn $digest; warn $name;
        delete_blob( $digest, $name );
        $self->res->code( 302 );
        $self->res->headers->header( location => '/' . $digest );
    };
}

init;
set_routes;
shagadelic;

__DATA__
@@ exception.html.epl
% my $self = shift;
% $self->stash( layout => 'base' );

error occured.

@@ error.html.epl
% my $self = shift;
% $self->stash( layout => 'base' );

<%= $self->stash( 'error' ) %>

@@ view.html.epl
% my $self = shift;
% $self->stash( layout => 'base' );

<div id="data">
<div class="repos"><span class="label">Clone URL: </span><span class="repos_url"><a href="git://<%= $self->stash( 'server' ) %>/<%= $self->stash( 'digest' ) %>.git">git://<%= $self->stash( 'server' ) %>/<%= $self->stash( 'digest' ) %>.git</a></span></div>
% for my $blob ( @{ $self->stash( 'blobs' ) } ) {
<div class="blob">
    <div class="name"><span><%= html_escape( $blob->{ name } ) %></span><span class="edit"><a href="/edit/<%= $self->stash( 'digest' ) %>/<%= uri_escape( $blob->{ name } ) %>">edit</a></span><span class="delete"><a href="/delete/<%= $self->stash( 'digest' ) %>/<%= uri_escape( $blob->{ name } ) %>">delete</a></span></div>
    <div class="contents">
        <div class="line">
% my $line_num = 0;
% for my $line ( split /\r?\n/, $blob->{ contents } ) {
            <div class="line_number"><%= ++$line_num %></div>
% }
        </div>
        <div class="body"><%= nl2br( html_escape( $blob->{ contents } ) ) %></div>
    </div>
    <div class="clear"><hr /></div>
</div>
% }
</div>
<div id="meta">
<div id=""><a href="/add/<%= $self->stash( 'digest' ) %>">add file</a></div>
% my $meta = $self->stash( 'meta' );
% for my $m ( @$meta ) {
<%= $m->{ date } %> <%= substr( $m->{ sha1 }, 0, 6 ) %><br />
% }
</div>

@@ root.html.epl
% my $self = shift;
% $self->stash( layout => 'base' );

<div id="data">
% if ( $self->stash( 'digest' ) && $self->stash( 'name' ) ) {
<form action="/edit/<%= $self->stash( 'digest' ) %>/<%= uri_escape( $self->stash( 'name' ) ) %>" method="post">
% } elsif ( $self->stash( 'digest' ) ) {
<form action="/add/<%= $self->stash( 'digest' ) %>" method="post">
% } else {
<form action="/" method="post">
% }
<input type="text" name="name" class="form_name" value="<%= html_escape( $self->stash( 'name' ) ) %>"/>
<textarea name="contents" class="form_contents"><%= html_escape( $self->stash( 'contents' ) ) %></textarea>
<div class="submit">
<input type="submit" value="Paste it" class="form_paste" />
</div>
</form>
</div>
<div id="meta"></div>

@@ layouts/base.html.epl
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
    margin: 0;
    padding: 0;
}

a, a:link, a:visited, a:hover {
    text-decoration: none;
    color: #3399ff;
}

#wrapper {
    margin: 1% 1.1% 1% 0.9%;
}

#header {}
#footer {}
#inner {
    margin: 0 4.0em;
    text-align: center;
}

#logo {
    font: 2.5em Monaco,"Courier New",monospace;
    margin: 0.4em 0 0 0;
}

#subtitle {
    font: 0.9em Monaco,"Courier New",monospace;
    margin: 0 0 1.2em 0;
}

select, input, textarea {
    margin: 5px 0 5px 0;
}

textarea {
    font: 0.8em Monaco,"Courier New",monospace;
    border: 1px solid #ccc;
    height: 40em;
    width: 100%;
}

input {
    border: 1px solid #ccc;
    font-size: 1.4em;
}

.form_name {
    width: 100%;
    margin: 0;
    font-family: Monaco,"Courier New",monospace;
}

.form_contents {
    margin: 10px 0;
    font-family: Monaco,"Courier New",monospace;
}

.form_paste {
    margin: 0;
    font-size: 20px;
}

.submit {
    text-align: right;
}

.label {
    font: 1.2em bold helvetica, arial, sans-serif;
    margin-right: 5px;
}

.repos_url {
    font: 1.2em bold Monaco,"Courier New",monospace;
}

.repos {
    font-family: Monaco,"Courier New",monospace;
    font-size: 90%;
    text-align: left;
    border: 1px solid #ccc;
    background: #cceeff;
    padding: 10px 5px;
    width: 690px;
}

.name {
    width: 690px;
    font: 1.4em helvetica, arial, sans-serif;
    margin: 0.3em 0 0 0;
    padding: 10px 5px;
    border-top: 1px solid #ccc;
    border-right: 1px solid #ccc;
    border-left: 1px solid #ccc;
    background-color: #eee;
    text-align: left;
}

.contents {
    width: 702px;
}

.line {
    width: 20px;
    font: 0.9em Monaco,"Courier New",monospace;
    color: #999;
    background: #eee;
    float: left;
    border: 1px solid #ccc;
    padding: 1.5em 0;
}

.body {
    font: 0.9em Monaco,"Courier New",monospace;
    text-align: left;
    border-top: 1px solid #ccc;
    border-right: 1px solid #ccc;
    border-bottom: 1px solid #ccc;
    margin-left: 20px;
    padding: 1.5em 10px;
}

#data {
    width: 700px;
    float: left;
}

#meta {
    margin-left: 707px;
    border: 1px solid #ccc;
    text-align: left;
    padding: 5px;
}

.contents {
}

.blob {
    margin-bottom: 0.8em;
}

.edit, .delete {
    font: 0.7em helvetica, arial, sans-serif;
    padding-left: 0.8em;
    position: relative;
}

.clear { clear: both; }
.clear hr { display: none; }
</style>
</head>
<body>
<div id="wrapper">
<div id="header">
<div id="logo"><a href="/"><span style="color: #ff3300; font-weight: bold;">re</span><span style="color: #0033ff; font-weight: bold;">code</span></a></div>
<div id="subtitle">Paste your code and share it.</div>
</div>
<div id="inner">
<%= $self->render_inner %>
<div class="clear"><hr /></div>
<div id="footer"><a href="/">&copy;2009- recode</a></div>
</div>
</div>
</body>
</html>
