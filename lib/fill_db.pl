use DBI;
use Data::Dumper qw(Dumper);
use DateTime;
use DateTime::Format::MySQL;
use Term::ProgressBar;

use strict;
use warnings;

my $dbh = DBI->connect('DBI:mysql:database=dwonload;mysql_socket=/var/run/mysqld/mysqld.sock', 'root','KoWd7pLBT');

my $sth = $dbh->prepare('SHOW tables');
$sth->execute();

my @tables;
while(my $ref = $sth->fetchrow_hashref){
   push @tables, $ref->{'Tables_in_dwonload'};
}

my $column_info;
foreach my $table(@tables){
   my $sth = $dbh->prepare("show columns from $table");
   $sth->execute();
   while(my $result = $sth->fetchrow_hashref){
      $column_info->{$table}->{$result->{'Field'}} = $result;
      my $sth2 = $dbh->prepare("
         select TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
         from information_schema.KEY_COLUMN_USAGE
         where TABLE_NAME = '$table' and COLUMN_NAME = '$result->{'Field'}' and REFERENCED_TABLE_NAME IS NOT NULL"
      );
      $sth2->execute();
      if(my $res = $sth2->fetchrow_hashref){
         $column_info->{$table}->{$result->{'Field'}}->{'ref_table'} = $res->{'REFERENCED_TABLE_NAME'};
         $column_info->{$table}->{$result->{'Field'}}->{'ref_column'} = $res->{'REFERENCED_COLUMN_NAME'};
      }
   }
}
my $progress = Term::ProgressBar->new({count => $ARGV[0], name => "progress: "});
$progress->minor(0);
my $next_update=0;

for(my $i=0; $i < $ARGV[0]; $i++){

   foreach my $table(@tables){
      #$sth = $dbh->prepare("SHOW columns FROM $table");
      #$sth->execute();
      my $columns = '';
      my @values;
      my $skip_table = undef;
      while(my($column_name, $column) = each(%{$column_info->{$table}})){
         if($column->{'Extra'} eq ''){   # if the column is auto incremented, nothing needs to be done for this table
            if($column->{'ref_table'}){ #foreign key
               my $sql;
               if($column_info->{$column->{'ref_table'}}->{$column->{'ref_column'}}->{'Extra'} eq 'auto_increment'){ #if referenced column is ai, make use of super fast random function
                  $sth = $dbh->prepare("select max($column->{'ref_column'}) from $column->{'ref_table'}");
                  $sth->execute();
                  my $max = $sth->fetchrow_hashref->{"max($column->{'ref_column'})"};
                  my $random_id;
                  if($max){ # if referenced tables has rows, get one 
                     $random_id = rand $max;
                     $sql = "
                        select $column->{'ref_column'}
                        from $column->{'ref_table'}
                        where $column->{'ref_column'} >= '$random_id'";
                  }else{ # no rows yet in referenced table, skip it
                     $skip_table = 'yes';
                  }
               }else{
                  $sql = " 
                     select $column->{'ref_column'}
                     from $column->{'ref_table'}
                     order by rand() limit 1";
               }
               if(!$skip_table){
                  $sth = $dbh->prepare($sql);
                  $sth->execute();
                  if(my $result = $sth->fetchrow_hashref){ #if 
                     $columns .= $column_name . ", ";
                     push @values, $result->{$column->{'ref_column'}}; #add the just selected id as value
                  }else{
                     $skip_table = 'yes';
                  }
               }
            }else{ # no foreign key, just add random data
               $columns .= $column_name . ", ";
               if($column->{'Key'} eq 'PRI'){
                  &gen_column_value(\@values, $column->{'Type'});
               }else{
                  &gen_column_value(\@values, $column->{'Type'}, 'yes');
               }

            }
         }
      }
      chop($columns);
      chop($columns);
      if(!$skip_table){
         my $sql = "INSERT INTO $table ($columns) VALUES (";
         for(my $i=0; $i< scalar @values; $i++){
            if($i == scalar(@values)-1){
               $sql .= '?';
            }else{
               $sql .= '?,';
            }
         }
         $sql .= ')';
         $sth = $dbh->prepare($sql);
         $sth->execute(@values) or die $!;
         $next_update = $progress->update($i)
            if $i >= $next_update;
      }
   }
}
$progress->update($ARGV[0]);
print "\n";

sub gen_column_value{
   my ($values_ref, $type, $random_length) = @_;
   if($random_length){
      if($type =~ m/varchar\((\d+)\)/){
         push @$values_ref ,  &gen_rand(rand $1);
      } 
      if($type =~ m/int\((\d+)\)/){
         push @$values_ref , &gen_rand(rand $1, 'num');
      }
   }else{
      if($type =~ m/varchar\((\d+)\)/){
         push @$values_ref ,  &gen_rand($1);
      } 
      if($type =~ m/int\((\d+)\)/){
         push @$values_ref , &gen_rand($1, 'num');
      }
   }
   if($type =~ m/datetime/){
      push @$values_ref , &gen_random_date();
   }
}

sub gen_random_date{
   my $dt = DateTime->now(time_zone => 'local');
   $dt->add(days => rand 80);
   $dt->add(hours => rand 59);
   $dt->add(minutes => rand 59);
   return DateTime::Format::MySQL->format_datetime($dt);
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
