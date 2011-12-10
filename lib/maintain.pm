package Maintain;

use DBI;
use Email::Stuff;
use DateTime;
use DateTime::Format::MySQL;

use strict;
use warnings;

my $mailer = Email::Send->new({mailer => 'SMTP'});
$mailer->mailer_args([Host => 'smtp.gmail.com:465', ssl => 1, username => 'freekkalter@gmail.com', password => 'dbxwuscstyywbgoq']);
my $dbh = DBI->connect('DBI:mysql:database=dwonload;mysql_socket=/var/run/mysqld/mysqld.sock', 'root','KoWd7pLBT');

#finde files who are about to expire
my $sth = $dbh->prepare('
   SELECT files.id, files.filename, files.owner
   FROM files 
   WHERE expiration <= ?'
);
my $dt = DateTime->now(time_zone => 'local');
$dt->add(days => 1);
$sth->execute( DateTime::Format::MySQL->format_datetime($dt));
$sth->bind_columns(\my($file_id, $file_name, $owner));

while($sth->fetch()){
   #generate activation link
   my $sth2 = $dbh->prepare('
      UPDATE files
      SET reactivation = ?
      WHERE id = ?'
   );
   my $reactivation = &generate_random_string(19);
   $sth2->execute($reactivation, $file_id);

   #find users email, and mail them
   $sth2 = $dbh->prepare('
      SELECT name, email
      FROM users
      WHERE id = ?'
   );
   $sth2->execute($owner);
   my $row = $sth2->fetchrow_hashref;

   #TODO: add language preferece in database and use it here for email langua

   my $msg = "Hallo $row->{'name'}, \n
Je hebt een tijdje terug een bestand op dwonloader.net geplaats om te delen met je vrienden.\n
Dit is al weer dertig dagen geleden. Als je wil dat het bestand beschikbaar blijft klik dan binnen 3 dagen op onderstaande link om het te behouden.\n
Anders word het verwijderd van de servers.\n
http://dwonloaderdev.kalteronline.org/reactivate/$file_id/$reactivation
http://dwonloader.net/reactivate/$file_id/$reactivation

Dwonloader.net";
   print Email::Stuff->to($row->{'email'})
               ->from('admin@dwonloader.net')
              ->text_body($msg)
              ->using($mailer)
              ->send;
}


sub generate_random_string
{
   my $stringsize = shift;
   my @alphanumeric = ('a'..'z', 'A'..'Z', 0..9);
   my $randstring = join '', (map { $alphanumeric[rand     
      @alphanumeric] } @alphanumeric)[0 .. $stringsize];
   return $randstring;
}

