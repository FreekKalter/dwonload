use DBI;
use Data::Dumper qw(Dumper);

use strict;
use warnings;

my $db = $ARGV[0];

my $dbh = DBI->connect('DBI:mysql:database=dwonload;mysql_socket=/var/run/mysqld/mysqld.sock', 'root','KoWd7pLBT');

my $sth = $dbh->prepare('SHOW tables');
$sth->execute();

my @tables;
while(my $ref = $sth->fetchrow_hashref){
   push @tables, $ref->{'Tables_in_dwonload'};
}

#TODO: foreign key contstraints (this is probably a BITCH)
foreach my $table(@tables){
   $sth = $dbh->prepare("SHOW columns FROM $table");
   $sth->execute();
   my $columns = '';
   my $values= '';
   while(my $column = $sth->fetchrow_hashref){
      $columns .= $column->{'Field'} . ", ";
      if($column->{'Type'} =~ m/varchar\((\d+)\)/){
         $values .= &gen_rand($1) . ', ';
      } 
      if($column->{'Type'} =~ m/int\((\d+)\)/){
         $values .= &gen_rand($1, 'num') . ', ';
      }
   }
   chop($columns);
   chop($values);
   chop($columns);
   chop($values);

   my $sql = "INSERT INTO $table ($columns) VALUES ($values)";
   print "$sql\n\n";

   $sth = $dbh->prepare($sql);
   $sth->execute();
}

sub gen_rand
{
   my ($length, $num) = @_;
   my @alphanumeric = ('a'..'z', 'A'..'Z', 0..9);
   my @numeric = (0..9);
   my $ret;
   if($num){
      for(my $i = 0; $i < $length; $i++) {
         $ret .= $numeric[rand @numeric];
      }
   }else{
      for(my $i = 0; $i < $length; $i++) {
         $ret .= $alphanumeric[rand @alphanumeric];
      }
   }
   return $ret;
}

sub generate_random_string
{
   my ($stringsize, $num) = @_;
   my @alphanumeric = ('a'..'z', 'A'..'Z', 0..9);
   my @numeric = (0..9);
   my $randstring;
   if($num){
      $randstring = join '', (map { $numeric[rand @numeric] } @numeric)[0 .. $stringsize-1];
   }else{
      $randstring = join '', (map { $alphanumeric[rand @alphanumeric] } @alphanumeric)[0 .. $stringsize-1];
   }
   return $randstring;
}
