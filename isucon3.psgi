use 5.14.0;
use utf8;
use IO::Handle;
use Encode;
use POSIX qw/strftime/;
use JSON::XS;
use Digest::SHA qw/ sha256_hex /;
use Text::Markdown::Hoedown qw/markdown/;
use Text::Xslate qw/html_escape/;
use DBIx::Sunny;
use URI::Escape::XS qw/uri_unescape/;


my $header = ['content-type' => 'text/html'];
my $memos = [];
my $memos_public = [];
my $memos_by_user = +{};
my $memos_by_user_public = +{};
my $users = +{};
my $uri_base = 'http://localhost';
my $mysessionstore = +{};

my $user_log_file = '/home/isucon/data/user_logfile';
my $user_log;
my $memo_log_file = '/home/isucon/data/memo_logfile';
my $memo_log;
our $log_read_mode = 0;
{
    # preload
    local $log_read_mode = 1;
    if ( -e $user_log_file ) {
        open $user_log, '<', $user_log_file;
        my @lines = <$user_log>;
        $user_log->close;
        for my $line (@lines) {
            chomp $line;
            my $user = decode_json($line);
            _create_user_old($user);
        }
        open $user_log, '>>', $user_log_file;
    }
    else {
        open $user_log, '>', $user_log_file;
    }

    if ( -e $memo_log_file ) {
        open $memo_log, '<', $memo_log_file;
        my @lines = <$memo_log>;
        $memo_log->close;
        for my $line (@lines) {
            chomp $line;
            my $memo = decode_json($line);
            _post_memo(+{
                user       => $users->{$memo->{username}},
                content    => $memo->{content},
                is_private => $memo->{is_private},
                created_at => $memo->{created_at},
            });
        }
        open $memo_log, '>>', $memo_log_file;
    }
    else {
        open $memo_log, '>', $memo_log_file;
    }

    for ( 1..@{$memos}/100 ) {
        content_index($_);
    }
}


sub init {
    close $user_log;
    close $memo_log;
    open $user_log, '>', $user_log_file;
    open $memo_log, '>', $memo_log_file;

    $memos = [];
    $memos_public = [];
    $memos_by_user = +{};
    $memos_by_user_public = +{};
    $users = +{};
    my $dbh = DBIx::Sunny->connect(
        "dbi:mysql:database=isucon;host=localhost;port=3306", 'isucon', '', {
            RaiseError => 1,
            PrintError => 0,
            AutoInactiveDestroy => 1,
            mysql_enable_utf8   => 1,
            mysql_auto_reconnect => 1,
        },
    );
    my $init_users = $dbh->select_all("SELECT username, password, salt, last_access FROM users");
    for my $user ( @{$init_users} ) {
        _create_user_old($user);
    }
    my $init_memos = $dbh->select_all(q{
        SELECT content, is_private, memos.created_at, username
        FROM memos join users on (users.id = memos.user) ORDER BY created_at asc
    });
    for my $memo ( @{$init_memos} ) {
        _post_memo(+{
            user       => $users->{$memo->{username}},
            content    => $memo->{content},
            is_private => $memo->{is_private},
            created_at => $memo->{created_at},
        });
    }
}

if ( 0 ) {
# for test
    my $chiba = _create_user('chiba', 'chiba');
    my $tester = _create_user('test', 'test');
    my $isucon1 = _create_user('isucon1', 'isucon1');
    my $test_content = q{
A First Level Header
====================

A Second Level Header
---------------------

Now is the time for all good men to come to
the aid of their country. This is just a
regular paragraph.

The quick brown fox jumped over the lazy
dog's back.

### Header 3

> This is a blockquote.
> 
> This is the second paragraph in the blockquote.
>
> ## This is an H2 in a blockquote        
};
    for my $id ( 1..500 ) {
        _post_memo(+{
            user       => $isucon1,
            content    => sprintf("test %s\ndesu\n%s",$id, $test_content),
            is_private => $id % 3 == 0 ? 1 : 0,
        });
    }
}

sub notfound() {q{<!doctype html>
<html>
<head>
<meta charset=utf-8 />
<style type="text/css">
.message {
  font-size: 200%;
  margin: 20px 20px;
  color: #666;
}
.message strong {
  font-size: 250%;
  font-weight: bold;
  color: #333;
}
</style>
</head>
<body>
<p class="message">
<strong>404</strong> Not Found
</p>
</div>
</body>
</html>}}


sub base_top() {qq{<!DOCTYPE html>
<html>
<head>
<meta http-equiv="Content-Type" content="text/html" charset="utf-8">
<title>Isucon3</title>
<link rel="stylesheet" href="${uri_base}/css/bootstrap.min.css">
<style>
body {
  padding-top: 60px;
}
</style>
<link rel="stylesheet" href="${uri_base}/css/bootstrap-responsive.min.css">
</head>
<body>
<div class="navbar navbar-fixed-top">
<div class="navbar-inner">
<div class="container">
<a class="btn btn-navbar" data-toggle="collapse" data-target=".nav-collapse">
<span class="icon-bar"></span>
<span class="icon-bar"></span>
<span class="icon-bar"></span>
</a>
<a class="brand" href="${uri_base}/">Isucon3</a>
<div class="nav-collapse">
<ul class="nav">
<li><a href="${uri_base}/">Home</a></li>
}}

sub header {
    my $env = shift;
    my @body = ();

    my $user = $env->{user};
    if ( $user ) {
        push @body, \sprintf(
            qq{<li><a href="${uri_base}/mypage">MyPage</a></li><li>
              <form action="${uri_base}/signout" method="post">
                <input type="hidden" name="sid" value="%s">
                <input type="submit" value="SignOut">
              </form>
            </li>},
            $env->{"psgix.session"}{token}
        );
    }
    else {
        push @body, \qq{<li><a href="${uri_base}/signin">SignIn</a></li>\n};
    }

    return @body, \sprintf(
        q{</ul></div> <!--/.nav-collapse --></div></div></div><div class="container"><h2>Hello %s!</h2>},
        $user ? $user->{username_escaped} : ''
    );
}

sub base_bottom() {\qq{</div> <!-- /container -->

<script type="text/javascript" src="${uri_base}/js/jquery.min.js"></script>
<script type="text/javascript" src="${uri_base}/js/bootstrap.min.js"></script>
</body>
</html>
}}

sub content_index {
    my $page = shift;

    my $total = @{$memos_public};

    my @body = (\sprintf(
        q{<h3>public memos</h3><p id="pager"> recent %s - %s / total <span id="total">%s</span></p><ul id="memos">},
        $page * 100 + 1,
        $page * 100 + 100,
        $total
    ));
    for my $index (($page * 100)..($page*100+99)) {
        last if $total < $index+1;
        my $memo = $memos_public->[$total-$index-1];

        push @body, $memo->{_li_public} //= \sprintf(
            qq{<li><a href="${uri_base}/memo/%s">%s</a> by %s (%s)</li>\n},
            $memo->{id},
            $memo->{title_escaped},
            $memo->{user}{username_escaped},
            $memo->{created_at},
        );
    }
    return @body, \'</ul>';
}

sub mypage {
    my $env = shift;
    my $user = $env->{user};

    my @before_body = (\sprintf(qq{<form action="${uri_base}/memo" method="post">
  <input type="hidden" name="sid" value="%s">
  <textarea name="content"></textarea>
  <br>
  <input type="checkbox" name="is_private" value="1"> private
  <input type="submit" value="post">
</form>
<h3>my memos</h3>
<ul>},
        $env->{"psgix.session"}{token}
    ));

    my @body = ();

    my $user_memos = $memos_by_user->{$user->{username}} //= [];
    
    for my $memo (reverse @{$user_memos}) {
        push @body, $memo->{_li_private} //= \sprintf(
            qq{<li><a href="${uri_base}/memo/%s">%s</a> by %s (%s)%s</li>\n},
            $memo->{id},
            $memo->{title_escaped},
            $memo->{username_escaped},
            $memo->{created_at},
            $memo->{is_private} ? '[private]' : '',
        );
    }
    return @before_body, @{$user->{_mypage} //= [@body, \'</ul>']};
}

sub get_signin() {\qq{<form action="${uri_base}/signin" method="post">
username <input type="text" name="username" size="20">
<br>
password <input type="password" name="password" size="20">
<br>
<input type="submit" value="signin">
</form>
}}

sub post_signin {
    my $env = shift;

    my $param = $env->{param};
    my $username = $param->{username};
    my $password = $param->{password};
    my $user     = $users->{$username};

    if ( $user && $user->{password} eq sha256_hex($user->{salt} . $password) ) {
        $env->{"psgix.session.options"}{change_id} = 1;
        my $session = $env->{"psgix.session"};

        $session->{username} = $username;
        $session->{token}     = sha256_hex(rand());

        $user->{last_access} = time();

        $env->{user} = $user;

        use Digest::SHA1;
        my $sid = Digest::SHA1::sha1_hex(rand() . $$ . {} . time);
        $mysessionstore->{$sid} = $session;
        return ['302', [Location => "${uri_base}/mypage", 'Set-Cookie' => "isucon_session=$sid; path=/; HttpOnly"], []];
    }
    else {
        return ['200', $header, [
            base_top(),
            header($env),
            get_signin(),
            base_bottom(),
        ]];
    }
}
sub signout {
    my $env = shift;
    my $sid = $env->{HTTP_X_ISUCON_SESSION_ID};
    delete $mysessionstore->{$sid};
    return ['302', [Location => "${uri_base}/", 'Set-Cookie' => "isucon_session=$sid; path=/; HttpOnly; expires=Fri, 31-Dec-1999 23:59:59 GMT"], []];
}

sub _create_user {
    my ($username, $password) = @_;
    
    my $salt = substr( sha256_hex( time() . $username ), 0, 8 );
    my $password_hash = sha256_hex( $salt, $password );
    my $user = $users->{$username} = +{
        username         => $username,
        username_escaped => "" . html_escape($username),
        password         => $password_hash,
        salt             => $salt,
        last_access      => undef,
    };
    $user_log->printflush(encode_json($user), "\n") unless $log_read_mode;
    return $user;
}
sub _create_user_old {
    my ($user) = @_;

    $user_log->printflush(encode_json($user), "\n") unless $log_read_mode;

    $user->{username_escaped} //= "" . html_escape($user->{username});
    return $users->{$user->{username}} = $user;
}

sub signup {
    my $env = shift;

    my $param = $env->{param};
    my $username = $param->{username};
    my $password = $param->{password};
    my $user     = $users->{$username};

    if ($user) {
        return ['400', [], []];
    }
    else {
        _create_user($username, $password);
        $env->{"psgix.session"}{username} = $username;
        return ['302', [Location => "${uri_base}/mypage"], []];
    }
}
sub get_signup() {qq{<form action="${uri_base}/signup" method="post">
username <input type="text" name="username" size="20">
<br>
password <input type="password" name="password" size="20">
<br>
<input type="submit" value="signup">
</form>
}}

sub _post_memo {
    my $memo = shift;

    $memo->{content_html}  //= markdown($memo->{content});
    $memo->{title}         //= [split /[\r\n]/, $memo->{content}]->[0];
    $memo->{title_escaped} //= html_escape($memo->{title});
    $memo->{created_at}    //= strftime('%Y-%m-%d %H:%M:%S', localtime());

    my $id = @{$memos} + 1;
    $memo->{id} = $id;
    push $memos, $memo;

    my $user_memos = $memos_by_user->{$memo->{user}{username}} //= [];
    my $user_memo_id = @{$user_memos} + 1;
    if ( $user_memo_id > 1 ) {
        $memo->{older_private} = $user_memos->[$user_memo_id-2];
        $memo->{older_private}{newer_private} = $memo;
    }
    push $user_memos, $memo;

    if ( !$memo->{is_private} ) {
        push $memos_public, $memo;

        my $user_memos_public = $memos_by_user_public->{$memo->{user}{username}} //= [];
        my $user_memo_public_id = @{$user_memos_public} + 1;
        if ( $user_memo_public_id > 1 ) {
            $memo->{older_public} = $user_memos_public->[$user_memo_public_id-2];
            $memo->{older_public}{newer_public} = $memo;
        }
        push $user_memos_public, $memo;
    }

    $memo_log->printflush(encode_json(+{
        username   => $memo->{user}{username},
        content    => $memo->{content},
        is_private => $memo->{is_private},
        created_at => $memo->{created_at},
    }), "\n") unless $log_read_mode;

    delete $memo->{user}{_mypage};

    return $id;
}

sub post_memo {
    my $env = shift;

    my $param = $env->{param};

    my $id = _post_memo(+{
        user       => $env->{user},
        content    => Encode::decode('utf-8', $param->{content}),
        is_private => $param->{is_private} ? 1 : 0,
    });
    return ['302', [Location => "${uri_base}/memo/" . $id], []];
}

sub get_memo {
    my ($env, $id) = @_;
    $id=$id+0;
    if ( !$id || $id > @{$memos} ) {
        return ['404', [], []];
    }
    my $memo = $memos->[$id-1];
    my $user = $env->{user};

    if ($memo->{is_private}) {
        if ( !$user || $user->{username} ne $memo->{user}{username} ) {
            return ['404', [], []];
        }
    }

    my @body = (\sprintf(
        q{<p id="author">%s Memo by %s (%s)</p><hr>},
        $memo->{is_private} ? 'Private' : 'Public',
        $memo->{user}{username_escaped},
        $memo->{created_at},
    ));

    my $older_memo;
    my $newer_memo;
    if ( $user && $user->{username} eq $memo->{user}{username} ) {
        $older_memo = $memo->{older_private};
        $newer_memo = $memo->{newer_private};
    }
    else {
        $older_memo = $memo->{older_public};
        $newer_memo = $memo->{newer_public};
    }

    if ( $older_memo ) {
        #older
        push @body, \sprintf(
            qq{<a id="older" href="${uri_base}/memo/%s">&lt; older memo</a>},
            $older_memo->{id}, # old memo id
        );
    }
    push @body, \'|';
    if ( $newer_memo ) {
        #newr
        push @body, \sprintf(
            qq{<a id="newer" href="${uri_base}/memo/%s">newer memo &gt;</a>},
            $newer_memo->{id}, # new memo id
        );
    }

    push @body, \sprintf(q{<hr><div id="content_html">%s</div>}, $memo->{content_html});

    return ['200', $header, [
        base_top(),
        header($env),
        @body,
        base_bottom(),
    ]];
}

sub app {
    my $env = shift;
    my $res = _app($env);
    if ( $res->[0] == 404 ) {
        $res->[2] = [notfound()];
    }
    if ( exists $env->{user} ) {
        my $myheader = [@{$res->[1]}];
        push $myheader, 'Cache-Control', 'private';
        $res->[1] = $myheader;
    }
    return $res;
}

sub _app {
    my $env = shift;
    my $method    = $env->{REQUEST_METHOD};
    my $path_info = $env->{PATH_INFO};

    $path_info =~ s{\A/user}{};

    $uri_base = 'http://' . $env->{HTTP_HOST};

    my $session = $env->{HTTP_X_ISUCON_SESSION_ID} ? $mysessionstore->{$env->{HTTP_X_ISUCON_SESSION_ID}} : undef;
    if ( $session && exists $session->{username} && exists $users->{$session->{username}} ) {
        $env->{user} = $users->{$session->{username}};
    }

    if ( $method eq 'GET' ) {
        if ( $path_info eq '/' ) {
            return ['200', $header, [
                base_top(),
                header($env),
                content_index(0),
                base_bottom(),
            ]];
        }
        elsif ( $path_info =~ m{\A/memo/(\d+)\z}o ) {
            return get_memo($env, $1);
        }
        elsif ( $path_info =~ m{\A/recent/(\d+)\z}o ) {
            return ['200', $header, [
                base_top(),
                header($env),
                content_index($1),
                base_bottom(),
            ]];
        }
        elsif ( $path_info eq '/mypage' ) {
            return ['302', [Location => "${uri_base}/"], []] unless $env->{user};
            return ['200', $header, [
                base_top(),
                header($env),
                mypage($env),
                base_bottom(),
            ]];
        }
        elsif ( $path_info eq '/signin' ) {
            delete $env->{user};
            return ['200', $header, [
                base_top(),
                header($env),
                get_signin(),
                base_bottom(),
            ]];
        }
        elsif ( $path_info eq '/signup' ) {
            delete $env->{user};
            return ['200', $header, [
                base_top(),
                header($env),
                get_signup(),
                base_bottom(),
            ]];
        }
        elsif ( $path_info eq '/init' ) {
            init();
            return ['200', [], ['OK']];
        }
    }
    elsif ( $method eq 'POST' ) {
        my $input = delete $env->{'psgi.input'};
        my $body = '';
        $input->read($body, $env->{CONTENT_LENGTH});
        $env->{param} = { map { split('=',$_,2) } split('&',$body)};
        for ( values $env->{param} ) {
            s/\+/ /g;
            $_ = uri_unescape($_);
        }

        if ( $path_info eq '/signin' ) {
            return post_signin($env);
        }
        else {
            if ( $env->{param}->{sid} ne $env->{"psgix.session"}{token} ) {
                return ['400', [], []];
            }

            if ( $path_info eq '/memo' ) {
                return ['302', [Location => "${uri_base}/"], []] unless $env->{user};
                return post_memo($env);
            }
            elsif ( $path_info eq '/signout' ) {
                return ['302', [Location => "${uri_base}/"], []] unless $env->{user};
                return signout($env);
            }
            elsif ( $path_info eq '/signup' ) {
                return signup($env);
            }
        }
    }

    return ['404', $header, ['not found']];
}


\&app;

