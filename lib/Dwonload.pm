package Dwonload;
use Dancer ':syntax';
use Dancer::Plugin::Ajax;
use Dancer::Plugin::Database;
use Dancer::Plugin::Facebook;
use Dancer::Plugin::Email;
use Dancer::Logger::Console;
use Dancer::FileUtils 'read_file_content';

use Data::Dumper qw(Dumper);
use Template;
use JSON qw(decode_json);
use Captcha::reCAPTCHA;
use Digest::SHA qw(sha256_hex);
use Math::Random::MT::Perl;
use DateTime::Format::MySQL;
use DateTime::Format::Epoch;
use Cache::Memcached::Fast;
use Digest::MD5 qw(md5 md5_hex md5_base64);

use POSIX qw (locale_h);
use Locale::Messages qw (LC_MESSAGES);
use Locale::TextDomain qw(dwonload);

our $VERSION = '0.1';
my $memd = new Cache::Memcached::Fast({
   servers => [ '127.0.0.1:11211' ]
});

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
    redirect '/about';
};


get '/login' => sub {    #eenmaal geauthiriseerd, vliegt door deze en postback heen
    my $fb = Facebook::Graph->new(config->{'facebook'});
    redirect $fb ->authorize->extend_permissions( qw(email offline_access publish_stream ))
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

    my $sth = database->prepare('SELECT fb_id,status FROM users WHERE fb_id=?');
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
    }else{
       if($row->{'status'} eq '0') {
            $sth = database->prepare(
                'UPDATE users
                SET email=?, status=1
                WHERE id=?'
            );
            $sth->execute($user->{email}, $user->{'id'});
         }
    }
    my ($mem, $sql, $key);
    $sql = 'SELECT id FROM users WHERE fb_id=?';
    $key = 'SQL:' . $user->{id} . ':' . md5($sql);
    if(defined ($mem = $memd->get($key))){
       session user_id => $mem;
    }else{
       $sth = database->prepare($sql);
       $sth->execute($user->{id});
       $row = $sth->fetchrow_hashref;
       session user_id => $row->{id};
       $memd->set($key, $row->{id}, 600);
    }
    redirect '/me';
};


get '/me/:tab' => sub {
   my $fb = &check_auth();
   if(!$fb){
      redirect '/about';
   }
   my $template_options = &get_basic_template_variables; 
   $template_options->{'tab'}  = params->{'tab'};
   template 'me', $template_options ;
};

get '/me' => sub {
   redirect '/me/others';

   #my $fb = &check_auth();
   #if(!$fb){
   #   redirect '/about';
   #}
   #my $template_options = &get_basic_template_variables; 
   #$template_options->{'tab'} = 'others';
   #template 'me', $template_options ;
};

ajax '/me/files_shared_with_me' => sub{
   my $fb = &check_auth();
   if(!$fb){
      redirect '/about';
   }
    my $response = $fb->query->find('me')->request;
    my $user     = $response->as_hashref;
    my $database_id = &get_database_user_id($user->{'id'});
  #get file_ids that are new since last login
  my $sth = database->prepare(
      'SELECT file_id
       FROM new
       WHERE user_id=?'
  );
  $sth->execute($database_id) or debug $sth->errstr;
  $sth->bind_columns( \my($file_id));

  my @files;
  while($sth->fetch){
   push(@files, $file_id);
  }

  #empty the new field, cause the user has seen them now
  database->quick_delete('new', {user_id => $database_id});

   #generate list of files shared with me
   my ($mem, $sql, $key);
   my $shared_files = '';
   $sql = 'SELECT files.*
          FROM files, shares
          WHERE shares.user_id = ? 
          AND shares.file_id == files.id';
   $key = 'SQL:' . $user->{id} . ':' . md5($sql);
   if(defined ($mem = $memd->get($key))){
      $shared_files = $mem;
   }else{
     $sth = database->prepare($sql);
     $sth->execute($database_id) or die $sth->errstr;
     $sth->bind_columns( \my($id,  $filename,  $description,  $owner, $size));
     while ($sth->fetch()) {
         #get owner's name
         my $sth2 = database->prepare(
            'SELECT name
             FROM users
             WHERE id=?'
         );
         $sth2->execute($owner);
         my $res = $sth2->fetchrow_hashref;
         my $owner = $res->{'name'};

         $shared_files .= '<tr> <td><a href="/details/' . $id . '?details=1">' . $filename . '</a> <a class="download" href="/details/' . $id . '">download</a>';
         #add label if its the first time the user sees the file
         if (grep $_ eq $id, @files) {
             $shared_files .= '<span class="label success">'. __("New") . '</span>';
         }
         $shared_files .= '</td> <td><em>' . &get_size($size) . '</em></td> <td><em>' . $owner . '</em></td> </tr>';
     }
     $memd->set($key, $shared_files, 600); 
  }
  return $shared_files;
};

ajax '/me/files_i_shared' => sub{
   my $fb = &check_auth();
   if(!$fb){
      redirect '/about';
   }
   
    my $response = $fb->query->find('me')->request;
    my $user     = $response->as_hashref;
    my $database_id = &get_database_user_id($user->{'id'});
   #generate list of uploaded files
   my $sth = database->prepare(
      'SELECT *
       FROM files
       WHERE owner = ?'
   );
   $sth->execute($database_id);
   $sth->bind_columns(\my ($id, $filename, $description, $owner, $size));
   my $file_list = '';
   while ($sth->fetch()) {
      $file_list .= '<tr>
      <td><a href="/details/' . $id . '?details=1">' . $filename . '</a> <a class="download" href="/details/' . $id .'">download </a></td>
                  <td>' . &get_size($size) . '</td>
                  </tr>';
   } 
   return $file_list;
};

ajax '/me/friends_upload_form' => sub{
   my $fb = &check_auth();
   if(!$fb){
      redirect '/about';
   }
     #generate list of friends to share files with
     my $friends_response = $fb->query->find('me/friends')->request;
     my $friends_hash     = $friends_response->as_hashref->{data};
     my @friend_array     = @$friends_hash;
     my $friends          = '<div class="row"><div class="span4">';
     my $half             = int(scalar(@friend_array)/2 + 0.5);
     my $counter          = 0;
     foreach my $friend (@friend_array) {
         $counter++;
         $friends .= '<label class="check"><input type="checkbox" value="' . $friend->{'id'} . '" name="shared" ><span>' . $friend->{name} . '</span></input></label>';
         if($counter == $half){
            $friends .= '</div><div class="span4">';
         }
     }
     $friends .= '</div></div>'; #close div.span6 and div.column
   return $friends;
};

post '/add_friends' => sub{
   set serializer => 'JSON';
   my $friends = decode_json params->{'friends'};
   foreach my $friend (@$friends){
        my $sth = database->prepare(
           'SELECT fb_id
            FROM users
            WHERE fb_id = ?'
        );
        $sth->execute($friend->{'fb_id'});
        if(!defined($sth->fetchrow_hashref)) {#no such user exist yet
           $sth = database->prepare(
               'INSERT INTO users (name, fb_id, status)
                VALUES (?, ?, ?)'
           );
           $sth->execute($friend->{'name'}, $friend->{'fb_id'}, 0),
        }
   }
};


post '/upload' => sub {
    my $fb = &check_auth();
    if (!$fb) {
        redirect '/about';
    }
    else {
        my $user       = $fb->fetch('me');
        my $file       = request->upload('datafile');
        my $shared_str = '';
        my @shared_arr;
        unless (ref(params->{'shared'})){    # not a ref 
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
            'INSERT INTO files (filename, description, owner, size)
             VALUES (?, ?, ?, ?)'
        );
        $sth->execute($file->filename, params->{'comment'}, session('user_id'), $file->size);
        my $file_id = database->last_insert_id(undef, undef, undef, undef);

        foreach my $user (split(',', $shared_str)) {
             my $db_user_id = &get_database_user_id($user);

           #insert shares into db
           $sth = database->prepare(
              'INSERT INTO shares (file_id, user_id)
               VALUES (?, ?)'
           );
           $sth->execute($file_id, $db_user_id) or debug($sth->errstr);

           #insert values about new files
           $sth = database->prepare(
              'INSERT INTO new (file_id, user_id)
               VALUES (?, ?)'
           );
           $sth->execute($file_id, $db_user_id) or debug($sth->errstr);

            if (params->{'wallpost'}) {
                my $response =
                  $fb->add_post->to($user)->set_message(params->{'comment'})
                  ->set_link_uri('http://dwonloader.kalteronline.org/details/' . $file_id . '?details=1')
                  ->set_link_caption($file->filename)
                  ->publish;
            }
        }
    }
    redirect '/me/shared';
};

get '/details/:id' => sub {
    my $fb = Facebook::Graph->new(config->{facebook});
    if (!session('access_token')) {
        redirect '/';
    }
    else {
       my $id  = params->{id};
       my $sth = database->prepare('
          SELECT * 
          FROM files 
          WHERE id = ?'
       );
       $sth->execute($id);
       my $file= $sth->fetchrow_hashref;
        if (params->{'details'}) {
            my $owner = undef;
            if ($file->{'owner'} eq session('user_id')) {
                $owner = "Yes";
            }
            #get get user who you shared this file with
            $sth = database->prepare(
               'SELECT user_id
                FROM shares
                WHERE file_id = ?'
             );
            $sth->execute($id);
            $sth->bind_columns( \my($user_id));
            my $shared = '';  
            while($sth->fetch()){
                my $sth2 = database->prepare('
                    SELECT name
                      FROM users
                      WHERE id = ?'
                );
                $sth2->execute($user_id);
                my $row = $sth2->fetchrow_hashref;
                $shared .= $row->{'name'} . ', ';
            }
            chop($shared);
            chop($shared);

            template 'details',
              { id            => $id,
                description   => $file->{'description'},
                size          => &get_size($file->{'size'}),
                download_link => "<a href="
                  . &generate_temp($id)
                  . ">Download</a>",
                friends => $shared,
                owner   => $owner
              };
        }# if(params->{'details'})
        else {
            if (!params->{'action'}) { #just download
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
                my $row = $sth->fetchrow_hashref;
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

                        #TODO:delete acutal file
                    }
                }
                else {
                    template 'details',
                      { error       => 'y',
                        description => 'You are not the owner of the file'
                      };
                }#owner of file check
            }#action check
        }#not details 
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

            #get description
            $sth = database->prepare(
                'SELECT description
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
            # get already checked friends 
            $sth = database->prepare('
               SELECT users.fb_id
               FROM shares, users
               WHERE shares.file_id = ?
               AND users.id = shares.user_id'
            );
            $sth->execute($id);
            $sth->bind_columns(\my($user_id));
            my @already_shared; 
            while($sth->fetch){
               push(@already_shared, $user_id);
            }
            $fb->access_token(session('access_token'));    #get facebook access token from users session
            my $user = $fb->fetch('me');

            #generate list of friends to share files with
            my $friends_response = $fb->query->find('me/friends')->request;
            my $friends_hash     = $friends_response->as_hashref->{data};
            my @friend_array     = @$friends_hash;
            my $friends          = '<div class="row"><div class="span4">';
            my $half             = int(scalar(@friend_array)/2 + 0.5);
            my $counter = 0;
            foreach my $friend (@friend_array) {
               $counter++;
                if (grep $_ eq $friend->{'id'}, @already_shared) {
                    $friends .= '<label><input type="checkbox" value="' . $friend->{'id'} . '" name="shared" checked="yes">
                                 <span>' . $friend->{name} . '</span></input></label>';
                }
                else {
                    $friends .= '<label><input type="checkbox" value="' . $friend->{'id'} . '" name="shared" ><span>'
                               . $friend->{name} . '</span></input></label>';
                }
                if($counter == $half){
                   $friends .= '</div><div class="span4">';
                }
            }
            $friends .= '</div></div>';
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
       SET description=?
       WHERE id=?'
    );
    $sth->execute($comment, $id);

    foreach my $friend (split(',', $shared)){
       #insert new shares
       $sth = database->prepare('
          INSERT INTO shares (user_id, file_id)
          VALUES (?, ?)'
       );
       $sth->execute($id, &get_database_user_id($friend));
       
       #insert new 'new' notifications
       $sth = database->prepare('
          INSERT INTO new (user_id, file_id)
          VALUES (?, ?)'
       );
       $sth->execute($id, &get_database_user_id($friend));
    }
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

any '/setlang' => sub {
   if(params->{'lang'} eq 'nl'){
      session lang => 'nl';
   }
   if(params->{'lang'} eq 'en'){
      session lang => 'en';
   }
   $ENV{LANGUAGE} = session('lang');
   setlocale (LC_MESSAGES, "");
   redirect '/me';
};

any qr{.*} => sub {
    status 'not found';
    template 'special_404', {path => request->path};
};

sub get_basic_template_variables{
    
   my $return_value;
   #menu
   $return_value->{'files_i_shared'} = __"Files I shared";
   $return_value->{'files_shared_with_me'} = __"Files shared with me";
   $return_value->{'upload'} = __"Upload";

   #table
   $return_value->{'filename'} = __"Filename";
   $return_value->{'size'} = __"Size";
   $return_value->{'owner'} = __"Owner";
   
   #upload form
   $return_value->{'comment'} = __"Comment:";
   $return_value->{'file_to_share'} = __"File to share:";
   $return_value->{'post_link'} = __"Post link on friends wall:";
   $return_value->{'friends'} = __"Friends to share with:";
   $return_value->{'subtitle'} = __"A simple filesharing solution for everyone!";
   return $return_value;
};

sub check_auth{
    my $fb = Facebook::Graph->new(config->{facebook});
    if (!session('access_token')) {
      return undef;
    }
    else {
      $fb->access_token(session('access_token'));    #get facebook access token from users session

      #get preferred language form session
      if(!session('lang')){
         session lang => "nl";
      }
      $ENV{LANGUAGE} = session('lang');
      setlocale (LC_MESSAGES, "");
      return $fb;
    }
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

    #add this to the database with a timeout
    my $sth = database->prepare('INSERT INTO downloads VALUES (? , ? , ?)',);
    my $dt = DateTime->now(time_zone => 'local');
    $dt->add(hours => 1);
    $sth->execute($id, $random_download_id,
        DateTime::Format::MySQL->format_datetime($dt));
    return '/download_file/' . $random_download_id;
}
true;
