package Maintain;

use DBI;
use Email::Stuff;
use DateTime;
use DateTime::Format::MySQL;

use strict;
use warnings;

my $dbh = DBI->connect('DBI:mysql:database=dwonload;mysql_socket=/var/run/mysqld/mysqld.sock', 'root','KoWd7pLBT');

#finde files who are about to expire
my $sth = $dbh->prepare('
   SELECT files.id, files.filename
   FROM files 
   WHERE expiration <= ?'
);
my $dt = DateTime->now(time_zone => 'local');
$dt->add(days => 1);
$sth->execute( DateTime::Format::MySQL->format_datetime($dt));
$sth->bind_columns(\my($file_id, $file_name));
while($sth->fetch()){
   #find users email, and mail them
   print "$file_name\n";
}



#my $mailer = Email::Send->new({mailer => 'SMTP'});
#$mailer->mailer_args([Host => 'smtp.gmail.com:465', ssl => 1, username => 'freekkalter@gmail.com', password => 'dbxwuscstyywbgoq']);
#
#print Email::Stuff->to('freekkalter@gmail.com')
#            ->from('Santa@northpole.org')
#           ->text_body("You've been a good boy this year. No coal for you.")
#           ->using($mailer)
#           ->send;
