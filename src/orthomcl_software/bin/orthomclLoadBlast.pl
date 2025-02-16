#!/usr/bin/env perl

use DBI;
use FindBin;
use lib "$FindBin::Bin/../lib/perl";
use OrthoMCLEngine::Main::Base;
use strict;

usage() unless (@ARGV >= 2);
my $configFile = $ARGV[0];
my $blastFile = $ARGV[1];

my $base = OrthoMCLEngine::Main::Base->new($configFile);
my $dbh = $base->getDbh();

my $dbVendor = $base->getConfig("dbVendor");

if ($dbVendor eq 'mysql') {
  loadBlastMySQL($base, $blastFile);
}
elsif ($dbVendor =~ 'sqlite') {
  loadBlastSQLite($base, $blastFile);
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
  my $sql = "
 LOAD DATA
 LOCAL INFILE \"$blastFile\"
 REPLACE INTO TABLE $sst
 FIELDS TERMINATED BY '\\t'
";
  my $stmt = $dbh->prepare($sql) or die DBI::errstr;
  $stmt->execute() or die DBI::errstr;
}


sub loadBlastSQLite {
  my ($base, $blastFile) = @_;
  require DBD::SQLite; # not clear why this is required
  my $dbh = $base->getDbh();
  my $sst = $base->getConfig("similarSequencesTable");
  my $dbString = $base->getConfig("dbConnectString");
  my $dbInstance;
  if ($dbString =~ /database=(.+)$/i){
    $dbInstance = $1;
  } elsif  ($dbString =~ /DBI:SQLite:(.+);?/){
    $dbInstance = $1;
  } else {
    die "orthomcl.conf $dbString should be dbConnectString=DBI:SQLite:YOUR_DATABASE_NAME\n";
  }
  $dbh->do("DROP INDEX if exists ss_qtaxexp_ix");
  $dbh->do("DROP INDEX if exists ss_seqs_ix");
  #my @database = split(/:/, $dbString);
  #my $dbInstance = $database[2];
  my $import_stmt = 'PRAGMA synchronous=OFF;\n'.'PRAGMA journal_mode = OFF;\n'.'PRAGMA locking_mode = EXCLUSIVE;\n'.
      '.separator \"\\\t\"\n.import '. "$blastFile $sst\n"; ## this works also
  
  `printf "$import_stmt" | sqlite3 $dbInstance`;
  $dbh->do("CREATE INDEX ss_qtaxexp_ix
ON SimilarSequences(query_id, subject_taxon_id,
evalue_exp, evalue_mant,
query_taxon_id, subject_id)");

  $dbh->do("CREATE INDEX ss_seqs_ix
ON SimilarSequences(query_id, subject_id,
evalue_exp, evalue_mant, percent_match)");
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
INTO TABLE $sst
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
