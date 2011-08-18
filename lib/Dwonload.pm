package Dwonload;
use Dancer ':syntax';
use Dancer::Plugin::Database;
use Data::Dumper;
use Template;

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

get '/files' => sub{
   my $sth = database->prepare(
      'select * from files',
   );
   $sth->execute();
   my $filenames = $sth->fetchrow_hashref;
   
   template 'index', {file_names => $filenames->{'filename'}, file_description => $filenames->{'description'}};
};          

post '/login' => sub{
   if(params->{user} eq 'freek'  && params->{pass} eq 'freek')
   {
      session user => params->{user};
      template 'index', {name => params->{user}}  || '/';
      #rewrite adres bar
   }else{
      redirect '/login?failed=1';
   }
};

any qr{.*} => sub {
   status 'not found';
   template 'special_404', {path => request->path};
};
true;
