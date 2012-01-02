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

$sth = $dbh->prepare('
   select TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
   from information_schema.KEY_COLUMN_USAGE
   where CONSTRAINT_SCHEMA = \'dwonload\''
);
$sth->execute();
my $info_schema;
while(my $tmp = $sth->fetchrow_hashref){
   $info_schema->{$tmp->{'TABLE_NAME'}}->{$tmp->{'COLUMN_NAME'}} = $tmp; 
}

my $progress = Term::ProgressBar->new({count => $ARGV[0], name => "progress: :"});
$progress->minor(0);
my $next_update=0;

my $column_info;
foreach my $table(@tables){
   my $sth = $dbh->prepare("show columns from $table");
   $sth->execute();
   while(my $result = $sth->fetchrow_hashref){
      $column_info->{$table}->{$result->{'Field'}} = $result;
   }
}

for(my $i=0; $i < $ARGV[0]; $i++){

   foreach my $table(@tables){
      #$sth = $dbh->prepare("SHOW columns FROM $table");
      #$sth->execute();
      my $columns = '';
      my @values;
      my $skip_table = undef;
      while(my($name, $column) = each(%{$column_info->{$table}})){
         if($column->{'Extra'} eq ''){          # if its not auto incremented
            if($column->{'Key'} eq 'MUL' or $column->{'Key'} eq 'UNI'){      # if its a referece to another table (foreign key constraint)
               if($info_schema->{$table}->{$column->{'Field'}}){

                  my ($sql, $sth2, $res);
                  my $refed_column = $column_info->{$table}->{$info_schema->{$table}->{$column->{'Field'}}->{'REFERENCED_COLUMN_NAME'}};
                  if($column_info->{$table}->{$info_schema->{$table}->{$column->{'Field'}}->{'REFERENCED_COLUMN_NAME'}}->{'Extra'} eq 'auto_increment'){
                     $sth2 = $dbh->prepare("select max($column->{'Field'}) from $table");
                     $sth2->execute() or die $!;
                     if(my $max = $sth2->fetchrow_hashref->{"max($column->{'Field'})"}){
                        my $random_id = rand $max;
                        $sql = "select $info_schema->{$table}->{$column->{'Field'}}->{'REFERENCED_COLUMN_NAME'} 
                                   from $info_schema->{$table}->{$column->{'Field'}}->{'REFERENCED_TABLE_NAME'} 
                                   where $info_schema->{$table}->{$column->{'Field'}}->{'REFERENCED_COLUMN_NAME'} = ?";
                        $sth2 = $dbh->prepare($sql);
                        $sth2->execute($random_id) or die $!;
                        $res = $sth2->fetchrow_hashref;
                     }else{
                        $res = undef;
                     }
                  }else{
                     $sql = "select $info_schema->{$table}->{$column->{'Field'}}->{'REFERENCED_COLUMN_NAME'} 
                                from $info_schema->{$table}->{$column->{'Field'}}->{'REFERENCED_TABLE_NAME'} 
                                order by rand() limit 1";
                     $sth2 = $dbh->prepare($sql);
                     $sth2->execute() or die $!;
                     $res  = $sth2->fetchrow_hashref;
                  }

                  if($res){ # if the to referece table is still empty, do nothing
                     $columns .= $column->{'Field'} . ", ";
                     push @values , $res->{$info_schema->{$table}->{$column->{'Field'}}->{'REFERENCED_COLUMN_NAME'}};
                  }else{
                     $skip_table = 'yes';
                  }
               }else{# no reference found, MUL also applies to indexed columns wich do not have a foreign key constraints
                  $columns .= $column->{'Field'} . ", ";
                  &gen_column_value(\@values, $column->{'Type'}, 'yes');
               }

            }else{
               #print Dumper(@values);
               $columns .= $column->{'Field'} . ", ";
               if($column->{'Key'} eq 'PRI'){
                  &gen_column_value(\@values, $column->{'Type'});
               }else{
                  &gen_column_value(\@values, $column->{'Type'}, 'yes');
               }
               #print Dumper(@values);
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
         #print $sql;
         #print join(',', @values) . "\n\n";
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
   #print "$type\n";
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
