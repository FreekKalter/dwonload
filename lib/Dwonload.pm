package Dwonload;
use Dancer ':syntax';
use Dancer::Plugin::Database;
use Dancer::Plugin::Facebook;
use Dancer::Plugin::Email;
use Dancer::Logger::Console;

use Data::Dumper;
use Template;
use Captcha::reCAPTCHA;
use Digest::SHA qw(sha256_hex);
use Math::Random::MT::Perl;
use DateTime::Format::MySQL;
use DateTime::Format::Epoch;
use YAML::Loader;
use Dancer::FileUtils 'read_file_content';

our $VERSION = '0.1';

my $content = read_file_content("../dwonload.yml");
my $loader = YAML::Loader->new;
my $hash = $loader->load($content);
my $recaptcha_config = $hash->{'recaptcha'}; 
my $files_path = $hash->{'files_path'};

get '/' => sub {
   if(session('access_token')){
    redirect '/me';
 }else{
    redirect '/about';
 }
};

get '/about' => sub{
   template 'about';
};


get '/logout' => sub{
   session->destroy;
   redirect '/me';
};


get '/facebook/login' => sub { #eenmaal geauthiriseerd, vliegt door deze en postback heen
    my $fb = Facebook::Graph->new( config->{facebook} );
    redirect $fb ->authorize
                 ->extend_permissions( qw(email offline_access publish_stream create_event rsvp_event) )
                 ->uri_as_string;
};

get '/facebook/postback/' => sub {
    my $params = request->params;
    my $fb = Facebook::Graph->new( config->{facebook} );
    $fb->request_access_token($params->{code});
    session access_token => $fb->access_token;

    my $response = $fb->query->find('me')->request;
    my $user = $response->as_hashref;
    session name => $user->{first_name};

    #check if user exists in user database, if not add him
    my $sth = database->prepare(
            'SELECT fb_id FROM users WHERE fb_id=?',
         );
    $sth->execute($user->{id}) or die $sth->errstr;
    my $row = $sth->fetchrow_hashref;
    if(!$row) #user does not existst
    {
         $sth = database->prepare(
            'INSERT INTO users (name, email, fb_id)
             VALUES (?, ?, ?)',
         );
         $sth->execute($user->{first_name}, $user->{email}, $user->{id}) or die $sth->errstr;
    }
    $sth = database->prepare( 'SELECT id FROM users WHERE fb_id=?');
    $sth->execute($user->{id});
    $row = $sth->fetchrow_hashref;
    session user_id => $row->{id};
    redirect '/me';
};

get '/me' => sub{
   my $fb = Facebook::Graph->new( config->{facebook} );
   if(!session('access_token')){
      redirect '/';
   }else{
      $fb->access_token(session('access_token')); #get facebook access token from users session
      my $user = $fb->fetch('me');

      #generate list of friends to share files with
      my $friends_response = $fb->query->find('me/friends')->request;
      my $friends_hash = $friends_response->as_hashref->{data};
      my @friend_array = @$friends_hash;
      my $friends = '';
      my $half = scalar(@friend_array) / 2;
      my $counter = 0;
      foreach my $friend(@friend_array){
         $counter++;
         $friends .= '<label><input type="checkbox" value="' . $friend->{'id'} . '" name="shared" ><span>' . $friend->{name} . '</span></input></label>';
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
      $sth->bind_columns( \my($id, $filename, $description , $owner, $size));
      my $file_list = '';
      while($sth->fetch())
      {
         $file_list .= '<tr>
                           <td><a href="/details/' .$id .'?details=1">'.$filename .'</a><a href="/details/' .$id .'"> <em>download</em> </a></td>
                           <td>'. &get_size($size) . '</td>
                        </tr>';
      }

      #get file_ids that are new since last login
      $sth = database->prepare(
         'SELECT new
          FROM users
          WHERE id=?'
       );
      $sth->execute(&get_database_user_id($user->{'id'})) or die $sth->errstr;
      my $new_files_hash = $sth->fetchrow_hashref;
      my $new_files = $new_files_hash->{'new'};
      #empty the new field, cause the user has seen them now
      $sth = database->prepare(
         'UPDATE users
          SET new=""
          WHERE id=?' 
       );
      $sth->execute(&get_database_user_id($user->{'id'})) or die $sth->errstr;

      #generate list of files shared with me
      $sth = database->prepare(
         'SELECT files.*, users.fb_id FROM files, users
          WHERE shared REGEXP ? AND files.owner = users.id');
      $sth->execute($user->{'id'});    
      $sth->bind_columns(\($id, $filename, $description, $owner, my $shared, $size, my $fb_id));
     
      my $shared_files = '';
      while($sth->fetch())
      {
         my $friend = $fb->fetch($fb_id);
         $shared_files .= '<tr>
                              <td><a href="/details/' .$id .'?details=1">'.$filename .'</a><a href="/details/' .$id .'"> <em>download</em> </a></td>';
         if(grep $_ eq $id, split(',', $new_files)){
            $shared_files .=  '<span class="label success">New</span>';
         };
         $shared_files .=    '</td>
                              <td><em>' . &get_size($size) .'</em></td>
                              <td><em>' . $friend->{'name'}. '</em></td>
                           </tr>';
      }
      template 'me', {file_list => $file_list , username => session('name'), friends => $friends , shared_files => $shared_files};
   }
};

post '/upload' => sub{
   my $file = request->upload('datafile');
   debug('shared with: ', ref(params->{'shared'}));
   my $shared ='';
   unless(ref(params->{'shared'}))# not a ref
   {
      $shared = params->{'shared'};

   }else{
      $shared =  join(',', @{params->{'shared'}}); 
   }
   $file->link_to($files_path->{'path'} . $file->filename);

   #insert file info into database
   my $sth = database->prepare(
      'INSERT INTO files (filename, description, owner, shared, size)
       VALUES (?, ?, ?, ?, ?)'
    );
   $sth->execute($file->filename, params->{'comment'}, session('user_id'), $shared, $file->size); 
   my $dbh = database;
   my $file_id = $dbh->last_insert_id(undef, undef, undef, undef); 

   #insert value about new files
   my ($user_hash, $id);
   foreach my $user(split(',',$shared)){
      $sth = database->prepare(
         'UPDATE users
          SET new = CONCAT(new, ?)
          WHERE id=?'          
       );
       $sth->execute($file_id . ',', &get_database_user_id($user));
    }
   redirect '/me';
};

get '/details/:id' => sub{
   my $id = params->{id};   
   my $sth = database->prepare(
      'SELECT * FROM files WHERE id = ?',
   );
   $sth->execute( $id);  
   my $row = $sth->fetchrow_hashref;
   if(! session('name'))
   {
      #recaptcha
      my $c = Captcha::reCAPTCHA->new;
      template 'details', {id => $id, 
                           description => $row->{'description'} ,
                           recaptcha => $c->get_html($recaptcha_config->{'public-key'} )#public recapthca key
                           }; 
   }else{
      if(params->{'details'}){
         template 'details', {id => $id,
                              description => $row->{'description'},
                              size => $row->{'size'},
                              download_link => "<a href=" . &generate_temp($id) . ">Download</a>",
                              friends => $row->{'shared'}
                           };
      }else{
         if(!params->{'action'})
         {
            redirect &generate_temp($id);
         }else{
            
            #check if users is owner of the file
            $sth = database->prepare(
               'SELECT owner
                FROM files
                WHERE id=?'
             );
            $sth->execute($id);
            $row = $sth->fetchrow_hashref;
            if($row->{'owner'} eq session('user_id'))
            {
               if(params->{'action'} eq 'delete')
               {
                  if(database->quick_delete('files', { id => $id}))
                  {
                     template 'details', {description => 'File deleted'};
                  }else{
                     template 'details', {description => 'Something went wrong'};
                  }
                  #delete acutal file 
               }
            }else{
               template 'details', {description => 'You are not the owner of the file'};
            }
         }
      }
   }
};

get '/details/:id/edit' =>sub{
   my $id = params->{'id'};
   my $fb = Facebook::Graph->new( config->{facebook} );
   if(!session('access_token')){
      redirect '/';
   }else{

      #check if users is owner of the file
      my $sth = database->prepare(
         'SELECT owner
          FROM files
          WHERE id=?'
       );
      $sth->execute($id);
      my $row = $sth->fetchrow_hashref;
      if($row->{'owner'} ne session('user_id'))
      {
         template 'details', {description => 'You are not the owner of the file'};
         return;
      }

      #get already checked friends
      $sth = database->prepare(
         'SELECT shared, description
          FROM files
          WHERE id=?'
      );
      $sth->execute($id);
      $row = $sth->fetchrow_hashref;
      my @already_shared = split(',', $row->{'shared'});

      $fb->access_token(session('access_token')); #get facebook access token from users session
      my $user = $fb->fetch('me');

      #generate list of friends to share files with
      my $friends_response = $fb->query->find('me/friends')->request;
      my $friends_hash = $friends_response->as_hashref->{data};
      my @friend_array = @$friends_hash;
      my $friends = '';
      foreach my $friend(@friend_array){
         if(grep $_ eq $friend->{'id'}, @already_shared){
            $friends .= '<label><input type="checkbox" value="' . $friend->{'id'} . '" name="shared" checked="yes"><span>' . $friend->{name} . '</span></input></label>';
         }else{
            $friends .= '<label><input type="checkbox" value="' . $friend->{'id'} . '" name="shared" ><span>' . $friend->{name} . '</span></input></label>';
         }
      }
      template 'details_form', {action => '/details/' .$id . '/edit', comment => $row->{'description'}, friends => $friends};

   }#session check
};


post '/details/:id/edit' =>sub{
   #check if user is owner of file (again) TRUST NOBODY!
   debug('in edit post');
   my $comment = params->{'comment'};
   chomp($comment);
   my $id = params->{'id'};

   my $shared ='';
   unless(ref(params->{'shared'}))# not a ref
   {
      $shared = params->{'shared'};
   }else{
      $shared =  join(',', @{params->{'shared'}}); 
   }
   my $sth = database->prepare(
      'UPDATE files
       SET description=?, shared=?
       WHERE id=?' 
   );
   $sth->execute($comment, $shared, $id);
   redirect('/details/' . $id . '?details=1');
};

post '/details' => sub{
    my $challenge = params->{'recaptcha_challenge_field'};
   my $response = params->{'recaptcha_response_field'};
   my $id = params->{'id'};   

   # Verify submission
   my $c = Captcha::reCAPTCHA->new;
    my $result = $c->check_answer( 
       $recaptcha_config->{'private-key'},#private key
       request->remote_address,
        $challenge, $response
    );

    if ( $result->{is_valid} ) {
       redirect &generate_temp($id);
    }
    else {
        # Error
        print "No";
    }                            
};

get '/download_file/:generated_id' => sub{
   my $gen_id = params->{generated_id};
   debug('id: ', $gen_id);
   my $sth = database->prepare(
      'SELECT * FROM downloads WHERE download_id = ?',
   );
   $sth->execute($gen_id);
   my $return_value = $sth->fetchrow_hashref;
   if($return_value){
      my $dt = DateTime::Format::MySQL->parse_datetime($return_value->{'expire_time'});
      my $dt_now = DateTime->now(time_zone => 'local');
      if(DateTime->compare($dt_now, $dt)<1){
         template 'download_started', {status => '<p>download started</p>'};
         #get filename from database
         $sth = database->prepare(
            'SELECT filename FROM files WHERE id=?',
         );
         $sth->execute($return_value->{'id'});
         $return_value = $sth->fetchrow_hashref;
         debug('path: ', $files_path->{'path'});
         if($return_value){
           return send_file($files_path->{'path'} . $return_value->{'filename'}, 
                           system_path => 1,
                           content_type => 'application/octet-stream ',
                           filename =>  $return_value->{'filename'} );
            template 'download_started', {status => '<p >Download started!</p>'};
         }
      }else{
         template 'download_started', {status => '<p class="error">download expired</p>'};
      }
   }else{
      template 'download_started', {status => '<p class="error">invalid link</p>'};
   }
};

get '/signup' => sub{
   template 'signup';
};

get '/login' => sub{
   redirect '/facebook/login';
   #template 'login', {path => vars->{requested_path}};
};

post '/login' => sub{
   if(params->{user} eq 'freek'  && params->{pass} eq 'freek')
   {
      session user => params->{user};
      redirect params->{'path'} || '/files';
   }else{
      redirect '/login?failed=1';
   }
};

post '/signup' => sub{
   #validate user input (again)
   
   #add user to database 
   my $sth = database->prepare(
      'INSERT INTO users (name, email, password, type)
       VALUES (? , ? , ?, ?)',
   );
   $sth->execute(params->{'name'} , params->{'email'}, sha256_hex(params->{'password'}), 'inactive');
   my $dbh = database;
   my $id = $dbh->last_insert_id(undef, undef, undef, undef); 

   #send email to me with link to accept

   my $msg = "<html><body>" . join('<br>', params->{'name'} , params->{'email'});
   $msg .=  "<br><a href=http://192.168.2.5:3000/activate_account/". 2 . ">Activate</a></body></html>";       
   email{             
      to => params->{'email'},
      from => 'dwonload@kalteronline.org',
      subject => params->{'name'},
      type => 'html',
      message => $msg
   };
};

get '/activate_account/:user_id' => sub{
   if(!session('user'))
   {
      #redirect to login with this path
      var requested_path => request->path_info; 
      request->path_info('/login');   
   }else{
      #add the user to the permanent user database
      my $sth = database->prepare(
         'UPDATE users
          SET type = "user"
          WHERE id = ?',
       );
      my $result = $sth->execute(params->{'user_id'});

      if($result)
      {
         template 'download_started', {status => '<p>User added</p>'};
      }else{
         template 'download_started', {status => '<p class="error">Error ' . $result . '</p>'}; 
     }
  }
};

any qr{.*} => sub {
   status 'not found';
   template 'special_404', {path => request->path};
};

sub get_database_user_id
{
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
};

sub get_size
{
   my $size = shift;
   if($size > 1000) {
      $size = $size /1000;
      if($size > 1000) {
         $size = $size /1000;
         debug('size: ', $size);
         if($size > 1000)
         {
            $size = $size /1000;
            return sprintf("%.2f",$size). "GB";
         }
         return sprintf("%.2f",$size). "MB";
      }
      return sprintf("%.2f",$size). "KB";
   }
   return sprintf("%.2f",$size). "B";
};

sub generate_temp
{
   #generate random string
   my $id = shift;
   my $gen = Math::Random::MT::Perl->new();
   my $random_download_id= '';
   for(0 .. 10)
   {
      $random_download_id .= int($gen->rand(9));
   }
   debug('Generated string:', $random_download_id);
   
   #add this to the database with a timeout
   my $sth = database->prepare(
      'INSERT INTO downloads VALUES (? , ? , ?)',
   );
   my $dt = DateTime->now(time_zone => 'local');
   $dt->add(hours => 1);
   $sth->execute($id, $random_download_id,  DateTime::Format::MySQL->format_datetime($dt));
   return '/download_file/' . $random_download_id;
};
true;
