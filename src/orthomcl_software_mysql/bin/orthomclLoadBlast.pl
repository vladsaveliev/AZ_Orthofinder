#!/usr/bin/env perl

use DBI;
use FindBin;
use lib "$FindBin::Bin/../lib/perl";
use OrthoMCLEngine::Main::Base;
use strict;

usage() unless (@ARGV >= 2);
my $configFile = $ARGV[0];
my $blastFile = $ARGV[1];
my $suffix = $ARGV[2];

my $base = OrthoMCLEngine::Main::Base->new($configFile);
my $dbh = $base->getDbh();

my $dbVendor = $base->getConfig("dbVendor");

if ($dbVendor eq 'mysql') {
  loadBlastMySQL($base, $blastFile);
}
elsif ($dbVendor eq 'oracle') {
  loadBlastOracle($base, $blastFile);
} else {
  die "Config file '$configFile' contains invalid value '$dbVendor' for dbVendor\n";
}

sub loadBlastMySQL {
  my ($base, $blastFile) = @_;
  require DBD::mysql;
  my $dbh = $base->getDbh();
  my $sst = $base->getConfig("similarSequencesTable");

  my $sql = "DELETE FROM $sst$suffix";
  my $stmt = $dbh->prepare($sql) or die DBI::errstr;
  $stmt->execute() or die DBI::errstr;

  my $sql = "
  LOAD DATA
  LOCAL INFILE \"$blastFile\"
  REPLACE INTO TABLE $sst$suffix
  FIELDS TERMINATED BY '\\t'
";
  my $stmt = $dbh->prepare($sql) or die DBI::errstr;
  $stmt->execute() or die DBI::errstr;

  my $sql = "drop table if exists tmp$suffix";
  my $stmt = $dbh->prepare($sql) or die DBI::errstr;
  $stmt->execute() or die DBI::errstr;

  my $sql = "create table tmp$suffix like $sst$suffix";
  my $stmt = $dbh->prepare($sql) or die DBI::errstr;
#  print "$sql";
  $stmt->execute() or die DBI::errstr;

  my $sql = "alter table tmp$suffix add unique (QUERY_ID, SUBJECT_ID)";
  my $stmt = $dbh->prepare($sql) or die DBI::errstr;
#  print "$sql";
  $stmt->execute() or die DBI::errstr;

  my $sql = "insert ignore into tmp$suffix select * from $sst$suffix";
  my $stmt = $dbh->prepare($sql) or die DBI::errstr;
#  print "$sql";
  $stmt->execute() or die DBI::errstr;

  my $sql = "rename table $sst$suffix to deleteme, tmp$suffix to $sst$suffix";
  my $stmt = $dbh->prepare($sql) or die DBI::errstr;
#  print "$sql";
  $stmt->execute() or die DBI::errstr;

  my $sql = "drop table deleteme";
  my $stmt = $dbh->prepare($sql) or die DBI::errstr;
  print "$sql";
  $stmt->execute() or die DBI::errstr;
}


sub loadBlastOracle {
  my ($base, $blastFile) = @_;

  my $dbLogin = $base->getConfig("dbLogin");
  my $dbPassword = $base->getConfig("dbPassword");
  my $dbString = $base->getConfig("dbConnectString");
  my @database = split(/:/, $dbString);
  my $dbInstance = $database[2];

  open (PARFILE, ">orthomclPar.tmp");
  print PARFILE "userid=$dbLogin/$dbPassword\@$dbInstance\n";
  close PARFILE;

  my $sst = $base->getConfig("similarSequencesTable");

  my $sqlHeader = "
LOAD DATA
INFILE '$blastFile' 
INTO TABLE $sst$suffix
FIELDS TERMINATED BY \"\\t\" OPTIONALLY ENCLOSED BY '\"'
TRAILING NULLCOLS
(  query_id,
    subject_id,
    query_taxon_id,
    subject_taxon_id,
    evalue_mant,
    evalue_exp,
    percent_identity,
    percent_match
)
";

  open (CTLFILE, ">orthomclCtl.tmp");
  print CTLFILE $sqlHeader;
  close CTLFILE;

  my $command=`sqlldr parfile=orthomclPar.tmp control=orthomclCtl.tmp`;
  unlink("orthomclCtl.tmp", "orthomclPar.tmp");
}

sub usage {
die "
Load Blast results into an Oracle or Mysql database.

usage: orthomclLoadBlast config_file similar_seqs_file

where:
  config_file :       see below
  similar_seqs_file : output from orthomclParseBlast 

EXAMPLE: orthomclSoftware/bin/orthomclLoadBlast my_orthomcl_dir/orthomcl.config my_orthomcl_dir/similarSequences.txt

NOTE: the database login in the config file must have update/insert/truncate privileges on the tables specified in the config file.

Sample Config File:

dbVendor=oracle  (or mysql)
dbConnectString=dbi:Oracle:orthomcl
dbLogin=my_db_login
dbPassword=my_db_password
similarSequencesTable=SimilarSequences
";
}
