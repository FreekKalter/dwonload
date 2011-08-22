package Dwonload;
use Dancer ':syntax';
use Dancer::Plugin::Database;
use Data::Dumper;
use Template;
use Math::Random::MT::Perl;
use Dancer::Logger::Console;
use DateTime::Format::MySQL;
use DateTime::Format::Epoch;

our $VERSION = '0.1';

get '/' => sub {
    template 'index';
};

before sub{
   if (! session('user') && request->path_info !~ m{^/login})
   {
      var requested_path => request->path_info;
      request->path_info('/login');
   }
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
      redirect params->{'path'} || '/';
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
      $file_list .= '<li><a href=/download/' .$id .'>'.$filename.'</a></li>';
   }
   $file_list .= '</ul>';
   template 'index', {file_list => $file_list};
};          

get '/download/:id' => sub{
   my $gen = Math::Random::MT::Perl->new();
   my $id = params->{id};   
    my $sth = database->prepare(
      'SELECT description FROM files WHERE id = ?',
   );
   $sth->execute( $id);  
   my $row = $sth->fetchrow_hashref;

   #generate random string
   my $string= '';
   for(0 .. 10)
   {
      $string .= int($gen->rand(9));
   }
   debug('Generated string:', $string);
   
   #add this to the database with a timeout
   $sth = database->prepare(
      'INSERT INTO downloads VALUES (? , ? , ?)',
   );
   my $dt = DateTime->now(time_zone => 'local');
   $dt->add(hours => 1);

   $sth->execute($id, $string,  DateTime::Format::MySQL->format_datetime($dt));
   $string = '/download_file/' . $string;
   template 'download', {description => $row->{'description'}, download_link => $string };
   
   #redirect to this page  /download_file/generated_string

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
         send_file('files/LCD.png');
      }else{
         template 'download_started', {status => '<p class="error">download expired</p>'};
      }
   }else{
      template 'download_started', {status => '<p class="error">invalid link</p>'};
   }
};


any qr{.*} => sub {
   status 'not found';
   template 'special_404', {path => request->path};
};
true;
