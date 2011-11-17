package Dwonload;
use Dancer ':syntax';
use Dancer::Plugin::Database;
use Dancer::Plugin::Facebook;
use Dancer::Plugin::Email;
use Dancer::Logger::Console;
use Dancer::FileUtils 'read_file_content';

use Data::Dumper;
use Template;
use Captcha::reCAPTCHA;
use Digest::SHA qw(sha256_hex);
use Math::Random::MT::Perl;
use DateTime::Format::MySQL;
use DateTime::Format::Epoch;

our $VERSION = '0.1';

get '/' => sub {
    if (session('access_token')) {
        redirect '/me';
    }
    else {
        redirect '/about';
    }
};

get '/about' => sub {
    template 'about';
};

get '/logout' => sub {
    session->destroy;
    redirect '/me';
};


get '/login' =>
  sub {    #eenmaal geauthiriseerd, vliegt door deze en postback heen
    my $fb = Facebook::Graph->new(config->{'facebook'});
    redirect $fb ->authorize->extend_permissions(
        qw(email offline_access publish_stream create_event rsvp_event))
      ->uri_as_string;
  };

get '/facebook/postback/' => sub {

    #get fb access token and store it in the session for futher use
    my $params = request->params;
    my $fb     = Facebook::Graph->new(config->{facebook});
    $fb->request_access_token($params->{code});
    session access_token => $fb->access_token;

    my $response = $fb->query->find('me')->request;
    my $user     = $response->as_hashref;
    session name => $user->{first_name};

    #check if user exists in user database, if not add him
    my $sth = database->prepare('SELECT fb_id FROM users WHERE fb_id=?');
    $sth->execute($user->{id}) or die $sth->errstr;
    my $row = $sth->fetchrow_hashref;
    if (!$row)    #user does not existst
    {
        $sth = database->prepare(
            'INSERT INTO users (name, email, fb_id)
             VALUES (?, ?, ?)',
        );
        $sth->execute($user->{first_name}, $user->{email}, $user->{id})
          or die $sth->errstr;
    }
    $sth = database->prepare('SELECT id FROM users WHERE fb_id=?');
    $sth->execute($user->{id});
    $row = $sth->fetchrow_hashref;
    session user_id => $row->{id};
    redirect '/me';
};

get '/me' => sub {
    my $fb = Facebook::Graph->new(config->{facebook});
    if (!session('access_token')) {
        redirect '/';
    }
    else {
        $fb->access_token(session('access_token'))
          ;    #get facebook access token from users session
        my $user = $fb->fetch('me');

        #generate list of friends to share files with
        my $friends_response = $fb->query->find('me/friends')->request;
        my $friends_hash     = $friends_response->as_hashref->{data};
        my @friend_array     = @$friends_hash;
        my $friends          = '';
        my $half             = scalar(@friend_array) / 2;
        my $counter          = 0;
        foreach my $friend (@friend_array) {
            $counter++;
            $friends
              .= '<label><input type="checkbox" value="'
              . $friend->{'id'}
              . '" name="shared" ><span>'
              . $friend->{name}
              . '</span></input></label>';

            #      if($counter == $half){
            #         $friends .= '</div><div class="span6 columns">';
            #      }
        }

        #generate list of uploaded files
        my $sth = database->prepare(
            'SELECT files.id, files.filename, files.description, files.owner, files.size
          FROM files, users
          WHERE files.owner = users.id
          AND users.fb_id=?',
        );
        $sth->execute($user->{id});
        $sth->bind_columns(\my ($id, $filename, $description, $owner, $size));
        my $file_list = '';
        while ($sth->fetch()) {
            $file_list .= '<tr>
                           <td><a href="/details/' 
              . $id
              . '?details=1">'
              . $filename
              . '</a><a href="/details/'
              . $id
              . '"> <em>download</em> </a></td>
                           <td>' . &get_size($size) . '</td>
                        </tr>';
        }

        #get file_ids that are new since last login
        $sth = database->prepare(
            'SELECT new
          FROM users
          WHERE id=?'
        );
        $sth->execute(&get_database_user_id($user->{'id'}))
          or die $sth->errstr;
        my $new_files_hash = $sth->fetchrow_hashref;
        my $new_files      = $new_files_hash->{'new'};

        #empty the new field, cause the user has seen them now
        $sth = database->prepare(
            'UPDATE users
          SET new=""
          WHERE id=?'
        );
        $sth->execute(&get_database_user_id($user->{'id'}))
          or die $sth->errstr;

        #generate list of files shared with me
        $sth = database->prepare(
            'SELECT files.*, users.fb_id FROM files, users
          WHERE shared REGEXP ? AND files.owner = users.id'
        );
        $sth->execute($user->{'id'});
        $sth->bind_columns(
            \(  $id,        $filename, $description, $owner,
                my $shared, $size,     my $fb_id
            )
        );

        my $shared_files = '';
        while ($sth->fetch()) {
            my $friend = $fb->fetch($fb_id);
            $shared_files .= '<tr>
                              <td><a href="/details/' 
              . $id
              . '?details=1">'
              . $filename
              . '</a><a href="/details/'
              . $id
              . '"> <em>download</em> </a></td>';
            if (grep $_ eq $id, split(',', $new_files)) {
                $shared_files .= '<span class="label success">New</span>';
            }
            $shared_files .= '</td>
                              <td><em>' . &get_size($size) . '</em></td>
                              <td><em>' . $friend->{'name'} . '</em></td>
                           </tr>';
        }
        template 'me',
          { file_list    => $file_list,
            username     => session('name'),
            friends      => $friends,
            shared_files => $shared_files
          };
    }
};

post '/upload' => sub {
    my $fb = Facebook::Graph->new(config->{facebook});
    if (!session('access_token')) {
        redirect '/';
    }
    else {
        $fb->access_token(session('access_token'))
          ;    #get facebook access token from users session
        my $user       = $fb->fetch('me');
        my $file       = request->upload('datafile');
        my $shared_str = '';
        my @shared_arr;
        unless (ref(params->{'shared'}))    # not a ref
        {
            $shared_str = params->{'shared'};
            @shared_arr = ($shared_str);

        }
        else {
            $shared_str = join(',', @{params->{'shared'}});
            @shared_arr = @{params->{'shared'}};
        }

        $file->link_to(config->{'files_path'}->{'path'} . $file->filename);

        #insert file info into database
        my $sth = database->prepare(
            'INSERT INTO files (filename, description, owner, shared, size)
          VALUES (?, ?, ?, ?, ?)'
        );
        $sth->execute($file->filename, params->{'comment'}, session('user_id'),
            $shared_str, $file->size);
        my $file_id = database->last_insert_id(undef, undef, undef, undef);

        #insert value about new files
        foreach my $user (split(',', $shared_str)) {
            $sth = database->prepare(
                'UPDATE users
             SET new = CONCAT(new, ?)
             WHERE id=?'
            );
            $sth->execute($file_id . ',', &get_database_user_id($user));
            if (params->{'wallpost'}) {
                my $response =
                  $fb->add_post->to($user)->set_message(params->{'comment'})
                  ->set_link_uri('http://dwonloader.kalteronline.org/details/' 
                      . $file_id
                      . '?details=1')->set_link_caption($file->filename)
                  ->publish;

#            my $html_response = $response->response();
#            if($html_response->is_success)
#            {
#               debug($html_response->decoded_content);
#            }else{
#               debug($html_response->status_line);
#            }
            }
        }
        redirect '/me';

        my $friends_response = $fb->query->find('me/friends')->request;
        my $friends_hash     = $friends_response->as_hashref->{data};
        my @friend_array     = @$friends_hash;

        #add friends to own database
        foreach my $friend (@shared_arr) {

            #add tot users database
            debug(
                'friend',
                Dumper(
                    $fb->query->find($friend)->request->as_hashref->{'name'}
                )
            );
        }
    }
};

get '/details/:id' => sub {
    my $id  = params->{id};
    my $sth = database->prepare('SELECT * FROM files WHERE id = ?',);
    $sth->execute($id);
    my $row = $sth->fetchrow_hashref;
    if (!session('name')) {

        #recaptcha
        my $c = Captcha::reCAPTCHA->new;
        template 'details', {
            id          => $id,
            description => $row->{'description'},
            recaptcha   => $c->get_html(
                config->{'recaptcha'}->{'public-key'})    #public recapthca key
        };
    }
    else {    #a session has ben made
        if (params->{'details'}) {
            my $owner = undef;
            if ($row->{'owner'} eq session('user_id')) {
                $owner = "Yes";
            }
            my $shared = '';
            foreach my $friend (split($row->{'shared'})) {
                $sth = database->prepare(
                    'SELECT name
                FROM users
                WHERE fb_id=?'
                );
                $sth->execute($friend);
                $row = $sth->fetchrow_hashref;
                $shared .= $row->{'name'};
            }

            template 'details',
              { id            => $id,
                description   => $row->{'description'},
                size          => $row->{'size'},
                download_link => "<a href="
                  . &generate_temp($id)
                  . ">Download</a>",
                friends => $shared,
                owner   => $owner
              };
        }
        else {
            if (!params->{'action'}) {
                redirect &generate_temp($id);
            }
            else {

                #check if users is owner of the file
                $sth = database->prepare(
                    'SELECT owner
             FROM files
             WHERE id=?'
                );
                $sth->execute($id);
                $row = $sth->fetchrow_hashref;
                if ($row->{'owner'} eq session('user_id')) {
                    if (params->{'action'} eq 'delete') {
                        if (database->quick_delete('files', {id => $id})) {
                            template 'details',
                              {error => 'y', description => 'File deleted'};
                        }
                        else {
                            template 'details',
                              { error       => 'y',
                                description => 'Something went wrong'
                              };
                        }

                        #delete acutal file
                    }
                }
                else {
                    template 'details',
                      { error       => 'y',
                        description => 'You are not the owner of the file'
                      };
                }
            }
        }
    }
};

get '/details/:id/edit' => sub {
    my $id = params->{'id'};
    my $fb = Facebook::Graph->new(config->{facebook});
    if (!session('access_token')) {
        redirect '/';
    }
    else {

        #check if users is owner of the file
        my $sth = database->prepare(
            'SELECT owner
          FROM files
          WHERE id=?'
        );
        $sth->execute($id);
        my $row = $sth->fetchrow_hashref;
        if ($row->{'owner'} ne session('user_id')) {
            template 'details',
              { error       => 'y',
                description => 'You are not the owner of the file'
              };
        }
        else {

            #get already checked friends
            $sth = database->prepare(
                'SELECT shared, description
             FROM files
             WHERE id=?'
            );
            $sth->execute($id);
            $row = $sth->fetchrow_hashref;
            if (!defined($row)) {
                if ($sth->err) {
                    debug('database error', $sth->errstr);
                }
                else {
                    template 'details',
                      {error => 'y', description => 'no such file'};
                }
            }
            my @already_shared = split(',', $row->{'shared'});

            $fb->access_token(session('access_token'))
              ;    #get facebook access token from users session
            my $user = $fb->fetch('me');

            #generate list of friends to share files with
            my $friends_response = $fb->query->find('me/friends')->request;
            my $friends_hash     = $friends_response->as_hashref->{data};
            my @friend_array     = @$friends_hash;
            my $friends          = '';
            foreach my $friend (@friend_array) {
                if (grep $_ eq $friend->{'id'}, @already_shared) {
                    $friends
                      .= '<label><input type="checkbox" value="'
                      . $friend->{'id'}
                      . '" name="shared" checked="yes"><span>'
                      . $friend->{name}
                      . '</span></input></label>';
                }
                else {
                    $friends
                      .= '<label><input type="checkbox" value="'
                      . $friend->{'id'}
                      . '" name="shared" ><span>'
                      . $friend->{name}
                      . '</span></input></label>';
                }
            }
            template 'details_form',
              { action  => '/details/' . $id . '/edit',
                comment => $row->{'description'},
                friends => $friends
              };
        }    #owner check
    }    #session check
};


post '/details/:id/edit' => sub {

    #check if user is owner of file (again) TRUST NOBODY!
    debug('in edit post');
    my $comment = params->{'comment'};
    chomp($comment);
    my $id = params->{'id'};

    my $shared = '';
    unless (ref(params->{'shared'}))    # not a ref
    {
        $shared = params->{'shared'};
    }
    else {
        $shared = join(',', @{params->{'shared'}});
    }
    my $sth = database->prepare(
        'UPDATE files
       SET description=?, shared=?
       WHERE id=?'
    );
    $sth->execute($comment, $shared, $id);
    redirect('/details/' . $id . '?details=1');
};

post '/details' => sub {
    my $challenge = params->{'recaptcha_challenge_field'};
    my $response  = params->{'recaptcha_response_field'};
    my $id        = params->{'id'};

    # Verify submission
    my $c      = Captcha::reCAPTCHA->new;
    my $result = $c->check_answer(
        config->{'recaptcha'}->{'private-key'},    #private key
        request->remote_address,
        $challenge, $response
    );

    if ($result->{is_valid}) {
        redirect &generate_temp($id);
    }
    else {

        # Error
        print "No";
    }
};

get '/download_file/:generated_id' => sub {
    my $gen_id = params->{generated_id};
    debug('id: ', $gen_id);
    my $sth =
      database->prepare('SELECT * FROM downloads WHERE download_id = ?',);
    $sth->execute($gen_id);
    my $return_value = $sth->fetchrow_hashref;
    if ($return_value) {
        my $dt = DateTime::Format::MySQL->parse_datetime(
            $return_value->{'expire_time'});
        my $dt_now = DateTime->now(time_zone => 'local');
        if (DateTime->compare($dt_now, $dt) < 1) {
            template 'download_started', {status => '<p>download started</p>'};

            #get filename from database
            $sth = database->prepare('SELECT filename FROM files WHERE id=?',);
            $sth->execute($return_value->{'id'});
            $return_value = $sth->fetchrow_hashref;
            if ($return_value) {
                return send_file(
                    config->{'files_path'}->{'path'}
                      . $return_value->{'filename'},
                    system_path  => 1,
                    content_type => 'application/octet-stream ',
                    filename     => $return_value->{'filename'}
                );
                template 'download_started',
                  {status => '<p >Download started!</p>'};
            }
        }
        else {
            template 'download_started',
              {status => '<p class="error">download expired</p>'};
        }
    }
    else {
        template 'download_started',
          {status => '<p class="error">invalid link</p>'};
    }
};

any qr{.*} => sub {
    status 'not found';
    template 'special_404', {path => request->path};
};

sub get_database_user_id {
    my $fb_id = shift;

    #get users database id
    my $sth = database->prepare(
        'SELECT id
       FROM users
       WHERE fb_id=?'
    );
    $sth->execute($fb_id);
    my $user_hash = $sth->fetchrow_hashref;
    return $user_hash->{'id'};
}

sub get_size {
    my $size = shift;
    if ($size > 1000) {
        $size = $size / 1000;
        if ($size > 1000) {
            $size = $size / 1000;
            debug('size: ', $size);
            if ($size > 1000) {
                $size = $size / 1000;
                return sprintf("%.2f", $size) . "GB";
            }
            return sprintf("%.2f", $size) . "MB";
        }
        return sprintf("%.2f", $size) . "KB";
    }
    return sprintf("%.2f", $size) . "B";
}

sub generate_temp {

    #generate random string
    my $id                 = shift;
    my $gen                = Math::Random::MT::Perl->new();
    my $random_download_id = '';
    for (0 .. 10) {
        $random_download_id .= int($gen->rand(9));
    }
    debug('Generated string:', $random_download_id);

    #add this to the database with a timeout
    my $sth = database->prepare('INSERT INTO downloads VALUES (? , ? , ?)',);
    my $dt = DateTime->now(time_zone => 'local');
    $dt->add(hours => 1);
    $sth->execute($id, $random_download_id,
        DateTime::Format::MySQL->format_datetime($dt));
    return '/download_file/' . $random_download_id;
}
true;
