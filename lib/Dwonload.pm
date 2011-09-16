package Dwonload;
use Dancer ':syntax';
use Dancer::Plugin::Database;
use Data::Dumper;
use Template;
use Math::Random::MT::Perl;
use Dancer::Logger::Console;
use DateTime::Format::MySQL;
use DateTime::Format::Epoch;
use Captcha::reCAPTCHA;
use Dancer::Plugin::Email;
use Digest::SHA qw(sha256_hex);

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
   redirect '/login';
};

get '/login' => sub{
   template 'login', {path => vars->{requested_path}};
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

get '/files' => sub{
   my $sth = database->prepare(
      'select * from files',
   );
   $sth->execute();
#     my $filenames = $sth->fetchrow_hashref;
   $sth->bind_columns( \my($id, $filename, $description));
   my $file_list = '<ul>';
   while($sth->fetch())
   {
      $file_list .= '<li><a href=/details/' .$id .'>'.$filename.'</a></li>';
   }
   $file_list .= '</ul>';
   template 'index', {file_list => $file_list};
};          

get '/details/:id' => sub{
   my $id = params->{id};   
   my $sth = database->prepare(
      'SELECT description FROM files WHERE id = ?',
   );
   $sth->execute( $id);  
   my $row = $sth->fetchrow_hashref;
   
   if(! session('user'))
   {
      #recaptcha
      my $c = Captcha::reCAPTCHA->new;
      template 'details', {id => $id, 
                           description => $row->{'description'} ,
                           recaptcha => $c->get_html('6LdzFcgSAAAAALE3Lsw7VTkLjYVLTDS1c2CaYBf1')
                           }; 
   }else{
      template 'details', {id => $id,
                           description => $row->{'description'},
                           download_link => "<a href=" . &generate_temp($id) . ">Download</a>"
                        };
   }
};

post '/details' => sub{
    my $challenge = params->{'recaptcha_challenge_field'};
   my $response = params->{'recaptcha_response_field'};
   my $id = params->{'id'};   

   # Verify submission
   my $c = Captcha::reCAPTCHA->new;
   debug('remote ip: ', $ENV{'REMOTE_ADDR'}); 
    my $result = $c->check_answer( 
       '6LdzFcgSAAAAAIBJLZFXC8J7_ldwdKQZpx0IC-yd', $ENV{'REMOTE_ADDR'},
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

post '/signup' => sub{
   #validate user input (again)
   
   #add user to database 
   my $sth = database->prepare(
      'INSERT INTO users (name, email, password, type)
       VALUES (? , ? , ?, ?)',
   );
   $sth->execute(params->{'name'} , params->{'email'}, sha256_hex(params->{'password'}), 'inactive');
   my $id = $sth->last_insert_id(undef, undef,undef,undef);
   debug('Last inserted id: ', $id);

   #send email to me with link to accept

#   my $msg = "<html><body>" . join('<br>', params->{'name'} , params->{'email'});
#   $msg .=  "<br><a href=http://192.168.2.5:3000/activate_account/". 2 . ">Activate</a></body></html>";       
#   email{             
#      to => params->{'email'},
#      from => 'dwonload@kalteronline.org',
#      subject => params->{'name'},
#      type => 'html',
#      message => $msg
#   };
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
