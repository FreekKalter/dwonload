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

#before sub{
#   if (! session('user') && request->path_info !~ m{^/login}) #check if user is logged or on the login page
#   {
#      var requested_path => request->path_info;
#      request->path_info('/login');
#   }
#};
 
get '/' => sub {
    redirect '/files';
};

get '/logout' => sub{
   session->destroy;
   redirect '/files';
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
    redirect '/me';
};

get '/me' => sub{
   my $fb = Facebook::Graph->new( config->{facebook} );
   $fb->access_token(session('access_token')); #get facebook access token from users session
   my $user = $fb->fetch('me');

   #generate list of uploaded files
   my $sth = database->prepare(
      'SELECT files.id, files.filename, files.description
       FROM files, users
       WHERE files.owner = users.id
       AND users.fb_id=?',
    );
    $sth->execute($user->{id});
      $sth->bind_columns( \my($id, $filename, $description ));
      my $file_list = '';
      while($sth->fetch())
      {
         $file_list .= '<li><a href=/details/' .$id .'>'.$filename.'</a></li>';
      }
      template 'index', {file_list => $file_list , username => session('name')};
};


get '/files' => sub{
   my $sth = database->prepare(
      'select * from files',
   );
   $sth->execute();
#     my $filenames = $sth->fetchrow_hashref;
   $sth->bind_columns( \my($id, $filename, $description, $owner));
   my $file_list = '';
   while($sth->fetch())
   {
      $file_list .= '<li><a href=/details/' .$id .'>'.$filename.'</a></li>';
   }
   template 'index', {file_list => $file_list , username => session('name')};
};          

get '/details/:id' => sub{
   my $content = read_file_content("../dwonload.yml");
   my $loader = YAML::Loader->new;
   my $hash = $loader->load($content);
   my $recaptcha_config = $hash->{'recaptcha'}; 
   debug('public key: ',$recaptcha_config->{'public-key'}); 

   my $id = params->{id};   
   my $sth = database->prepare(
      'SELECT description FROM files WHERE id = ?',
   );
   $sth->execute( $id);  
   my $row = $sth->fetchrow_hashref;
   #debug('Session: ', session('freek')); 
   if(! session('freek'))
   {
      #recaptcha
      my $c = Captcha::reCAPTCHA->new;
      template 'details', {id => $id, 
                           description => $row->{'description'} ,
                           recaptcha => $c->get_html($recaptcha_config->{'public-key'} )#public recapthca key
                           }; 
   }else{
      template 'details', {id => $id,
                           description => $row->{'description'},
                           download_link => "<a href=" . &generate_temp($id) . ">Download</a>"
                        };
   }
};

post '/details' => sub{
   my $content = read_file_content("../dwonload.yml");
   my $loader = YAML::Loader->new;
   my $hash = $loader->load($content);
   my $recaptcha_config = $hash->{'recaptcha'}; 

    my $challenge = params->{'recaptcha_challenge_field'};
   my $response = params->{'recaptcha_response_field'};
   my $id = params->{'id'};   

   # Verify submission
   my $c = Captcha::reCAPTCHA->new;
   debug('remote ip: ', request->remote_address);
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
         if($return_value){
           return send_file('files/' . $return_value->{'filename'}, 
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
   $random_download_id = '/download_file/' . $random_download_id;

   #redirect to this page  /download_file/generated_string
   $sth = database->prepare(
      'SELECT description FROM files WHERE id = ?',
   );
   $sth->execute( $id);  
   my $row = $sth->fetchrow_hashref;
   return $random_download_id;
   #template 'download', {description => $row->{'description'}, download_link => $random_download_id }; 
};
true;
