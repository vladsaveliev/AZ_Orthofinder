#!/usr/bin/env perl

use DBI;
use FindBin;
use lib "$FindBin::Bin/../lib/perl";
use OrthoMCLEngine::Main::Base;
use strict;

my $debug=0;

my @args = @ARGV;
my $configFile = shift(@args);
my $logFile = shift(@args);
my $clean = shift(@args);

my %allowedOptArgs = ('startAfter'=>1, 'taxonFilter'=>1, 'suffix'=>1); 
my %optArgs;
map {
    my ($k,$v) = split(/=/);
    die "Argument '$_' not in k=v format\n" unless $k && $v;
    usage() unless $allowedOptArgs{$k};
    $optArgs{$k}=$v;
} @args;

my $suffix = $optArgs{'suffix'};

#die "Error: Suffix '$suffix' is greater than 11 characters." if length($suffix) > 11;

my $base = OrthoMCLEngine::Main::Base->new($configFile, *LOGFILE);
my $inParalogTable = $base->getConfig("inParalogTable");
my $orthologTable = $base->getConfig("orthologTable");
my $coOrthologTable = $base->getConfig("coOrthologTable");


my @steps = ( # Common
             ['updateMinimumEvalueExponent'],
	     ['bestQueryTaxonScore'],
	     ['qtscore_ix'],
             # Ortholog
	     ['bestHit'],
             ['best_hit_ix'],
	     ['ortholog', ["drop table BestHit$suffix"]],
	     ['orthologTaxon'],
	     ['orthologAvg'],
	     ['orthologAvgIndex'],
	     ['orthologsNormalization', ["drop table OrthologAvgScore$suffix", "drop table OrthologTaxon$suffix", "drop table OrthologTemp$suffix"]],
             # InParalog
	     ['bestInterTaxonScore', ["drop table BestQueryTaxonScore$suffix"]],
             ['bis_uids_ix'],
             ['uniqueSimSeqsQueryId'],
             ['ust_qids_ix'],
	     ['betterHit', ["drop table BestInterTaxonScore$suffix", "drop table UniqSimSeqsQueryId$suffix"]],
             ['better_hit_ix'],
	     ['inParalog', ["drop table BetterHit$suffix"]],
 	     ['inParalogTaxonAvg'],
             ['orthologUniqueId'],
             ['orthologUniqueIdIndex'],
             ['inplgOrthTaxonAvg', ["drop table OrthologUniqueId$suffix"]],
	     ['inParalogAvg',["drop table InParalogTaxonAvg$suffix", "drop table InplgOrthTaxonAvg$suffix"]],
	     ['inParalogAvgIndex'],
	     ['inParalogsNormalization', ["drop table InParalogAvgScore$suffix", "drop table InParalogTemp$suffix"]],
             # CoOrtholog
	     ['inParalog2Way'],
	     ['in2a_ix'],
	     ['in2b_ix'],
	     ['ortholog2Way'],
	     ['ortholog2WayIndex'],
             ['inplgOrthoInplg'],
             ['inParalogOrtholog'],
	     ['coOrthologCandidate', ["drop table Ortholog2Way$suffix", "drop table InParalog2Way$suffix", 
                                "drop table InplgOrthoInplg$suffix", "drop table InParalogOrtholog$suffix"]],
	     ['coOrthologNotOrtholog', ["drop table CoOrthologCandidate$suffix"]],
	     ['coOrthologNotOrthologIndex'],
	     ['coOrtholog', ["drop table CoOrthNotOrtholog$suffix"]],
	     ['coOrthologTaxon'],
	     ['coOrthologAvg'],
	     ['coOrthologAvgIndex'],
	     ['coOrthologsNormalization', ["drop table CoOrthologAvgScore$suffix", "drop table CoOrthologTaxon$suffix", "drop table CoOrthologTemp$suffix"]],
	     ['cleanall', ["truncate table $inParalogTable$suffix", "truncate table $orthologTable$suffix", "truncate table $coOrthologTable$suffix"]],
	    );

my $stepsHash;
my $cleanHash;
for (my $i=0; $i<scalar(@steps); $i++) {
    $stepsHash->{$steps[$i]->[0]} = $i+1;
    $cleanHash->{$steps[$i]->[0]} = $steps[$i]->[1] if $steps[$i]->[1];
}

&usage() unless $configFile;
&usage() unless $logFile;
&usage() unless $clean =~ /cleanup=(yes|no|only|all)/;

$clean = $1;

my $skipPast = getSkipPast($optArgs{startAfter}, $logFile);

my $andTaxonFilter = "";
my $whereTaxonFilter = "";
my $taxonFilterTaxon;
if ($optArgs{taxonFilter}) {
    $taxonFilterTaxon = $optArgs{taxonFilter};
    my $subjFilter = "and s.subject_taxon_id != '$taxonFilterTaxon'";
    $andTaxonFilter = "and s.query_taxon_id != '$taxonFilterTaxon' $subjFilter";
    $whereTaxonFilter = "where s.query_taxon_id != '$taxonFilterTaxon' $subjFilter";
} 
 

open (LOGFILE, ">>$logFile") || die "Can't open log file '$logFile'\n";
my $oldfh = select(LOGFILE); $| = 1; select($oldfh);  # flush print buffer

print LOGFILE "\n\n============================================================================================\n";
print LOGFILE localtime(). " orthomclPairs " . join(' ', @ARGV) . "\n";
print LOGFILE "=============================================================================================\n\n";

my $dbh = $base->getDbh();

my $sst = $base->getConfig("similarSequencesTable");

my $oracleNoLogging = $base->getConfig("dbVendor") eq 'oracle'? " NOLOGGING" : "";
my $straightJoin = $base->getConfig("dbVendor") eq 'oracle'? "" : "STRAIGHT_JOIN";

commonTempTables();

orthologs();

inparalogs();

coorthologs();

clean('cleanall') if $clean eq 'all';

print LOGFILE "\nDone\n";



################################################################################
############################### Common tables  #################################
################################################################################
sub commonTempTables {
  print LOGFILE localtime() . " Constructing common temp tables\n"
    unless $clean eq 'only' || $clean eq 'all';

  my $interTaxonMatch = $base->getConfig("interTaxonMatchView");

  # a little bit of a hack here.  mysql can't tolerate finding the
  # minEvalueExp in the sql that updates the table
  # so, we do it as a preprocess.
  # must explicitly avoid the preprocess if just cleaning or if skipping
  my $sql = "
select min(evalue_exp)
from $sst$suffix
where evalue_mant != 0
";
  my $minEvalueExp;
  if ($clean ne 'only' && $clean ne 'all' && !$skipPast) {
      print LOGFILE localtime() . "   Find min evalue exp  (OrthoMCL-DB V2 took ??? for this step)\n";
      my $stmt = $dbh->prepare("$sql");
      $stmt->execute();
      ($minEvalueExp) = $stmt->fetchrow_array();
      print LOGFILE localtime() . "   done\n";
  }

  $sql = "
update $sst$suffix
set evalue_exp = ${minEvalueExp}-1
where evalue_exp = 0 and evalue_mant = 0
";
  runSql($sql, "updating $sst$suffix, setting 0 evalue_exp to underflow value (${minEvalueExp} - 1)",
	 'updateMinimumEvalueExponent', '25 min', undef);

  ##########################################################################

  $sql = "
create table BestQueryTaxonScore$suffix $oracleNoLogging as
select im.query_id, im.subject_taxon_id, low_exp.evalue_exp, min(im.evalue_mant) as evalue_mant
from $interTaxonMatch$suffix im,
     (select query_id, subject_taxon_id, min(evalue_exp) as evalue_exp
      from $interTaxonMatch$suffix
      group by query_id, subject_taxon_id) low_exp
where im.query_id = low_exp.query_id
  and im.subject_taxon_id = low_exp.subject_taxon_id
  and im.evalue_exp = low_exp.evalue_exp
group by im.query_id, im.subject_taxon_id, low_exp.evalue_exp
";

  if ($base->getConfig("dbVendor") eq 'oracle') {
      $sql = "
create table BestQueryTaxonScore$suffix $oracleNoLogging as
select query_id, subject_taxon_id,
       max(evalue_exp) keep (dense_rank first order by evalue_exp, evalue_mant) as evalue_exp,
       max(evalue_mant) keep (dense_rank first order by evalue_exp, evalue_mant) as evalue_mant
from $sst$suffix
where query_taxon_id != subject_taxon_id
group by query_id, subject_taxon_id
"
  }
  
  runSql($sql, "create BestQueryTaxonScore", 'bestQueryTaxonScore', '1.5 hours', undef);

  ################################################################################

  $sql = "
create unique index qtscore_ix$suffix on BestQueryTaxonScore$suffix(query_id, subject_taxon_id, evalue_exp, evalue_mant)
";
  
  runSql($sql, "create qtscore_ix index on BestQueryTaxonScore", 'qtscore_ix', '15 min', "BestQueryTaxonScore$suffix");
}


################################################################################
############################### Orthologs  #####################################
################################################################################
sub orthologs {
  print LOGFILE localtime() . " Constructing ortholog tables\n"
    unless $clean eq 'only' || $clean eq 'all';

  my $evalueExpThreshold = $base->getConfig("evalueExponentCutoff");
  my $percentMatchThreshold = $base->getConfig("percentMatchCutoff");

  my $sql = "
create table BestHit$suffix (primary key(query_id, subject_id))
ignore select s.query_id, s.subject_id,
       s.query_taxon_id, s.subject_taxon_id,
       s.evalue_exp, s.evalue_mant
from $sst$suffix s, BestQueryTaxonScore$suffix cutoff
where s.query_id = cutoff.query_id
  and s.subject_taxon_id = cutoff.subject_taxon_id
  and s.query_taxon_id != s.subject_taxon_id
  and s.evalue_exp <= $evalueExpThreshold $andTaxonFilter
  and s.percent_match >= $percentMatchThreshold
  and (s.evalue_mant < 0.01
       or s.evalue_exp = cutoff.evalue_exp
          and s.evalue_mant = cutoff.evalue_mant)
";
  
  runSql($sql, "create BestHit", 'bestHit', '1.5 hours', undef);

  ######################################################################

  $sql = "
create unique index best_hit_ix$suffix on BestHit$suffix(query_id,subject_id)
";

  runSql($sql, "create best_hit_ix index on BestHit", 'best_hit_ix', '15 min', "BestHit$suffix");

  ######################################################################

  $sql = "
create table OrthologTemp$suffix $oracleNoLogging as
select bh1.query_id as sequence_id_a, bh1.subject_id as sequence_id_b,
       bh1.query_taxon_id as taxon_id_a, bh1.subject_taxon_id as taxon_id_b,
       case -- don't try to calculate log(0) -- use rigged exponents of SimSeq
         when bh1.evalue_mant < 0.01 or bh2.evalue_mant < 0.01
           then (bh1.evalue_exp + bh2.evalue_exp) / -2
         else  -- score = ( -log10(evalue1) - log10(evalue2) ) / 2
           (log(10, bh1.evalue_mant * bh2.evalue_mant)
            + bh1.evalue_exp + bh2.evalue_exp) / -2
       end as unnormalized_score
from BestHit$suffix bh1, BestHit$suffix bh2
where bh1.query_id < bh1.subject_id
  and bh1.query_id = bh2.subject_id
  and bh1.subject_id = bh2.query_id
";
    
  runSql($sql, "create OrthologTemp table", 'ortholog', '5 min', "OrthologTemp$suffix");

  ######################################################################

  orthologTaxonSub('');

  ######################################################################

  normalizeOrthologsSub('', $base->getConfig("orthologTable"));
}


################################################################################
############################### InParalogs  ####################################
################################################################################
sub inparalogs {
  print LOGFILE localtime() . " Constructing inParalog tables\n"
    unless $clean eq 'only' || $clean eq 'all';

  my $inParalogTable = $base->getConfig("inParalogTable");
  my $orthologTable = $base->getConfig("orthologTable");
  my $evalueExpThreshold = $base->getConfig("evalueExponentCutoff");
  my $percentMatchThreshold = $base->getConfig("percentMatchCutoff");

  my $sql = "
create table BestInterTaxonScore$suffix $oracleNoLogging as
select im.query_id, low_exp.evalue_exp, min(im.evalue_mant) as evalue_mant
from BestQueryTaxonScore$suffix im,
     (select query_id, min(evalue_exp) as evalue_exp
      from BestQueryTaxonScore$suffix
      group by query_id) low_exp
where im.query_id = low_exp.query_id
  and im.evalue_exp = low_exp.evalue_exp
group by im.query_id, low_exp.evalue_exp
";

  runSql($sql, "create BestInterTaxonScore", 'bestInterTaxonScore', '5 min', undef);

  ###########################################################################

  $sql = "
create unique index bis_uids_ix$suffix on BestInterTaxonScore$suffix (query_id)
";

  runSql($sql, "create bis_uids_ix index on BestQueryTaxonScore", 'bis_uids_ix', '1 min', "BestQueryTaxonScore$suffix");

  ###########################################################################

   $sql = "
create table UniqSimSeqsQueryId$suffix $oracleNoLogging as
select distinct s.query_id from $sst$suffix s $whereTaxonFilter
";

  runSql($sql, "create UniqSimSeqsQueryId", 'uniqueSimSeqsQueryId', '25 min', undef);

  ###########################################################################

  $sql = "
create unique index ust_qids_ix$suffix on UniqSimSeqsQueryId$suffix (query_id)
";

  runSql($sql, "create ust_qids_ix index on UniqSimSeqsQueryId", 'ust_qids_ix', '1 min', "UniqSimSeqsQueryId$suffix");


  ###########################################################################

  $sql = "
create table BetterHit$suffix $oracleNoLogging as
select s.query_id, s.subject_id,
       s.query_taxon_id as taxon_id,
       s.evalue_exp, s.evalue_mant
from $sst$suffix s, BestInterTaxonScore$suffix bis
where s.query_id != s.subject_id $andTaxonFilter
  and s.query_taxon_id = s.subject_taxon_id
  and s.query_id = bis.query_id
  and s.evalue_exp <= $evalueExpThreshold
  and s.percent_match >= $percentMatchThreshold
  and (s.evalue_mant < 0.001
       or s.evalue_exp < bis.evalue_exp
       or (s.evalue_exp = bis.evalue_exp and s.evalue_mant <= bis.evalue_mant))
-- . . . or Similarity for a protein with no BestInterTaxonScore
--       (i.e. an intrataxon match for a protein with no intertaxon
--        match in the database)
union
select s.query_id, s.subject_id, s.query_taxon_id as taxon_id, s.evalue_exp, s.evalue_mant
from $sst$suffix s
where s.query_taxon_id = s.subject_taxon_id $andTaxonFilter
  and s.evalue_exp <= $evalueExpThreshold
  and s.percent_match >= $percentMatchThreshold
  and s.query_id in 
     (SELECT distinct ust.query_id
      from UniqSimSeqsQueryId$suffix ust
      LEFT OUTER JOIN BestInterTaxonScore$suffix bis ON bis.query_id = ust.query_id
      WHERE bis.query_id IS NULL)
";
  
  runSql($sql, "create BetterHit table", 'betterHit', '3 hours', undef);

  ###########################################################################
  
  $sql = "
create unique index better_hit_ix$suffix on BetterHit$suffix (query_id,subject_id)
";

  runSql($sql, "create better_hit_ix index on BetterHit", 'better_hit_ix', '25 min', "BetterHit$suffix");

  ###########################################################################

  $sql = "
create table InParalogTemp$suffix $oracleNoLogging as
select bh1.query_id as sequence_id_a, bh1.subject_id as sequence_id_b,
       bh1.taxon_id,
       case -- don't try to calculate log(0) -- use rigged exponents of SimSeq
         when bh1.evalue_mant < 0.01 or bh2.evalue_mant < 0.01
           then (bh1.evalue_exp + bh2.evalue_exp) / -2
         else  -- score = ( -log10(evalue1) - log10(evalue2) ) / 2
           (log(10, bh1.evalue_mant * bh2.evalue_mant)
            + bh1.evalue_exp + bh2.evalue_exp) / -2
       end as unnormalized_score
from BetterHit$suffix bh1, BetterHit$suffix bh2
where bh1.query_id < bh1.subject_id
  and bh1.query_id = bh2.subject_id
  and bh1.subject_id = bh2.query_id
";

   runSql($sql, "create InParalogTemp table", 'inParalog', '15 min', undef);

  ################################################################

  $sql = "
create table InParalogTaxonAvg$suffix $oracleNoLogging as
select avg(i.unnormalized_score) average, i.taxon_id
from InParalogTemp$suffix i
group by i.taxon_id
";

  runSql($sql, "create InParalogTaxonAvg table", 'inParalogTaxonAvg', '1 min', undef);

  ################################################################

  $sql = "
create table OrthologUniqueId$suffix $oracleNoLogging as
select distinct(sequence_id) from (
select sequence_id_a as sequence_id from $orthologTable$suffix
union
select sequence_id_b as sequence_id from $orthologTable$suffix) i
";

  runSql($sql, "create OrthologUniqueId table", 'orthologUniqueId', '5 min', undef);

  ################################################################

  $sql = "create unique index ortho_uniq_id_ix$suffix on OrthologUniqueId$suffix (sequence_id)";


  runSql($sql, "create unique ortho_uniq_id_ix index", 'orthologUniqueIdIndex', '1 min', "OrthologUniqueId$suffix");

  ################################################################

  $sql = "
 create table InplgOrthTaxonAvg$suffix $oracleNoLogging as
 select avg(i.unnormalized_score) average, i.taxon_id
         from InParalogTemp$suffix i
         where i.sequence_id_a in
                 (select sequence_id from OrthologUniqueId$suffix)
            or i.sequence_id_b in
                 (select sequence_id from OrthologUniqueId$suffix)
         group by i.taxon_id
";

  runSql($sql, "create InplgOrthTaxonAvg table", 'inplgOrthTaxonAvg', '10 min', undef);

  ################################################################

  $sql = "
create table InParalogAvgScore$suffix $oracleNoLogging as
     select case
            when orth_i.average is NULL
              then all_i.average
              else orth_i.average
            end as avg_score,
            all_i.taxon_id
       from InParalogTaxonAvg$suffix all_i LEFT OUTER JOIN InplgOrthTaxonAvg$suffix orth_i
       ON all_i.taxon_id = orth_i.taxon_id
";

   runSql($sql, "create InParalogAvgScore table", 'inParalogAvg', '1 min', undef);

  ################################################################

  $sql = "create unique index inparalog_avg_ix$suffix on InParalogAvgScore$suffix(taxon_id,avg_score)";


  runSql($sql, "create InParalogAvgScore index", 'inParalogAvgIndex', '1 min', "InParalogAvgScore$suffix");

  ################################################################

  $sql = "
  insert into $inParalogTable$suffix (sequence_id_a, sequence_id_b, taxon_id, unnormalized_score, normalized_score)
  select it.sequence_id_a, it.sequence_id_b, it.taxon_id, it.unnormalized_score, it.unnormalized_score/a.avg_score
  from InParalogTemp$suffix it, InParalogAvgScore$suffix a
  where it.taxon_id = a.taxon_id
";

  runSql($sql, "populate $inParalogTable table, including normalized_score", 'inParalogsNormalization', '3 min', "$inParalogTable$suffix");

  ################################################################
}

################################################################################
############################### CoOrthologs  ###################################
################################################################################
sub coorthologs {
  print LOGFILE localtime() . " Constructing coOrtholog tables\n"
    unless $clean eq 'only' || $clean eq 'all';

  my $inParalogTable = $base->getConfig("inParalogTable");
  my $orthologTable = $base->getConfig("orthologTable");
  my $coOrthologTable = $base->getConfig("coOrthologTable");
  my $evalueExpThreshold = $base->getConfig("evalueExponentCutoff");
  my $percentMatchThreshold = $base->getConfig("percentMatchCutoff");

  my $sql = "
create table InParalog2Way$suffix $oracleNoLogging as
select sequence_id_a, sequence_id_b from $inParalogTable$suffix
union
select sequence_id_b as sequence_id_a, sequence_id_a as sequence_id_b from $inParalogTable$suffix
";
  
    runSql($sql, "create InParalog2Way", 'inParalog2Way', '1.5 hours', undef);

  ######################################################################

  $sql = "
create unique index in2a_ix$suffix on InParalog2Way$suffix(sequence_id_a, sequence_id_b)
";
  
  runSql($sql, "index in2a_ix", 'in2a_ix', '45 min', undef);

  ######################################################################

  $sql = "
create unique index in2b_ix$suffix on InParalog2Way$suffix(sequence_id_b, sequence_id_a)
";
  
  runSql($sql, "index in2b_ix", 'in2b_ix', '45 min', "InParalog2Way$suffix");

  ######################################################################

  $sql = "
create table Ortholog2Way$suffix $oracleNoLogging as
-- symmetric closure of Ortholog
select sequence_id_a, sequence_id_b from $orthologTable$suffix
union
select sequence_id_b as sequence_id_a, sequence_id_a as sequence_id_b from $orthologTable$suffix
";
  
   runSql($sql, "create Ortholog2Way", 'ortholog2Way', '1 hours', undef);

  ######################################################################

  $sql = "
create unique index ortholog2way_ix$suffix on Ortholog2Way$suffix(sequence_id_a, sequence_id_b)
";

  runSql($sql, "index ortholog2way_ix", 'ortholog2WayIndex', '5 min', "Ortholog2Way$suffix");

  ######################################################################

  $sql = "
create table InplgOrthoInplg$suffix $oracleNoLogging as
      select ip1.sequence_id_a, ip2.sequence_id_b
      from  Ortholog2Way$suffix o, InParalog2Way$suffix ip2, InParalog2Way$suffix ip1
      where ip1.sequence_id_b = o.sequence_id_a
        and o.sequence_id_b = ip2.sequence_id_a
";
  
   runSql($sql, "create InplgOrthoInplg", 'inplgOrthoInplg', '20 min', undef);

  ##################################################################

  $sql = "
create table InParalogOrtholog$suffix $oracleNoLogging as
      select ip.sequence_id_a, o.sequence_id_b
      from InParalog2Way$suffix ip, Ortholog2Way$suffix o
      where ip.sequence_id_b = o.sequence_id_a
";

   runSql($sql, "create InParalogOrtholog", 'inParalogOrtholog', '15 min', undef);

  ##################################################################

  $sql = "
create table CoOrthologCandidate$suffix $oracleNoLogging as
select distinct
       least(sequence_id_a, sequence_id_b) as sequence_id_a,
       greatest(sequence_id_a, sequence_id_b) as sequence_id_b
from (select sequence_id_a, sequence_id_b from InplgOrthoInplg$suffix
      union
      select sequence_id_a, sequence_id_b from InParalogOrtholog$suffix) t
";

   runSql($sql, "create CoOrthologCandidate", 'coOrthologCandidate', '1 hour', undef);

  ######################################################################

  $sql = "
create table CoOrthNotOrtholog$suffix $oracleNoLogging as
SELECT cc.sequence_id_a, cc.sequence_id_b
      FROM CoOrthologCandidate$suffix cc
      LEFT OUTER JOIN $orthologTable$suffix o
      ON cc.sequence_id_a = o.sequence_id_a
      AND cc.sequence_id_b = o.sequence_id_b
      WHERE o.sequence_id_a IS NULL
";

   runSql($sql, "create CoOrthNotOrtholog table", 'coOrthologNotOrtholog', '10 min', undef);


  #####################################################################

  $sql = "
create index cno_ix$suffix on CoOrthNotOrtholog$suffix(sequence_id_a,sequence_id_b)
";

  runSql($sql, "index cno_ix", 'coOrthologNotOrthologIndex', '1 min', "CoOrthNotOrtholog$suffix");


  ######################################################################

  my $tf;
  if ($taxonFilterTaxon) {
    $tf = "and ab.query_taxon_id != '$taxonFilterTaxon' and ab.subject_taxon_id != '$taxonFilterTaxon' and 
           ba.query_taxon_id != '$taxonFilterTaxon' and ba.subject_taxon_id != '$taxonFilterTaxon'";
  }

  $sql = "
create table CoOrthologTemp$suffix $oracleNoLogging as
select candidate.sequence_id_a, candidate.sequence_id_b,
       ab.query_taxon_id as taxon_id_a, ab.subject_taxon_id as taxon_id_b,
       case  -- in case of 0 evalue, use rigged exponent
         when ab.evalue_mant < 0.00001 or ba.evalue_mant < 0.00001
           then (ab.evalue_exp + ba.evalue_exp) / -2
         else -- score = ( -log10(evalue1) - log10(evalue2) ) / 2
           (log(10, ab.evalue_mant * ba.evalue_mant)
            + ab.evalue_exp + ba.evalue_exp) / -2
       end as unnormalized_score
from $sst$suffix ab, $sst$suffix ba, CoOrthNotOrtholog$suffix candidate
where ab.query_id = candidate.sequence_id_a $tf
  and ab.subject_id = candidate.sequence_id_b
  and ab.evalue_exp <= $evalueExpThreshold
  and ab.percent_match >= $percentMatchThreshold
  and ba.query_id = candidate.sequence_id_b
  and ba.subject_id = candidate.sequence_id_a
  and ba.evalue_exp <= $evalueExpThreshold
  and ba.percent_match >= $percentMatchThreshold
";

  runSql($sql, "create CoOrthologTemp table", 'coOrtholog', '2 hours', undef);

  ######################################################################

  orthologTaxonSub('co');

  ######################################################################

  normalizeOrthologsSub("Co", $base->getConfig("coOrthologTable"));
}


sub orthologTaxonSub {
  my ($co) = @_;

  my $coCaps = $co? "Co" : "";
  $co = $co? "coO" : "o";

my $sql = "create table ${coCaps}OrthologTaxon$suffix $oracleNoLogging as
select case
         when taxon_id_a < taxon_id_b
         then taxon_id_a
         else taxon_id_b
        end as smaller_tax_id,
        case
          when taxon_id_a < taxon_id_b
          then taxon_id_b
          else taxon_id_a
        end as bigger_tax_id,
        unnormalized_score
      from ${coCaps}OrthologTemp$suffix";

  runSql($sql, "create ${coCaps}OrthologTaxon table", "${co}rthologTaxon", '1 min', undef);
}

sub normalizeOrthologsSub {
  my ($co, $orthologTable) = @_;

  my $coCaps = $co? "Co" : "";
  $co = $co? "coO" : "o";

  my $sql = "
create table ${coCaps}OrthologAvgScore$suffix $oracleNoLogging as
select smaller_tax_id, bigger_tax_id, avg(unnormalized_score) avg_score
from ${coCaps}OrthologTaxon$suffix
group by smaller_tax_id, bigger_tax_id
"; 

  runSql($sql, "create ${coCaps}OrthologAvgScore table", "${co}rthologAvg", '1 min', undef);

  ################################################################
  
  $sql = "create unique index ${co}orthoAvg_ix$suffix on ${coCaps}OrthologAvgScore$suffix(smaller_tax_id,bigger_tax_id,avg_score)";
  
  runSql($sql, "create ${coCaps}OrthologAvgScore index", "${co}rthologAvgIndex", '1 min', "${coCaps}OrthologAvgScore$suffix");

  ################################################################

  $sql = "
  insert into $orthologTable$suffix (sequence_id_a, sequence_id_b, taxon_id_a, taxon_id_b, unnormalized_score, normalized_score)
  select ot.sequence_id_a, ot.sequence_id_b, ot.taxon_id_a, ot.taxon_id_b, ot.unnormalized_score, ot.unnormalized_score/a.avg_score
  from ${coCaps}OrthologTemp$suffix ot, ${coCaps}OrthologAvgScore$suffix a
where least(ot.taxon_id_a, ot.taxon_id_b) = a.smaller_tax_id
    and greatest(ot.taxon_id_a, ot.taxon_id_b) = a.bigger_tax_id
";
  
  runSql($sql, "populate $orthologTable table, including normalized_score", "${co}rthologsNormalization", '2 min', "$orthologTable$suffix");
}

sub runSql {
  my ($sql, $msg, $tag, $sampleTime, $tableToAnalyze) = @_;

  print LOGFILE "$sql\n\n" if $debug;

  my $stepNumber = $stepsHash->{$tag};
  die "invalid tag '$tag'" unless $stepNumber;

  if ($skipPast >= $stepNumber) {
    print LOGFILE "... skipping '$tag'...\n\n";
    return;
  }

  if ($clean ne 'only' && $clean ne 'all') {
      my $t = time();

      print LOGFILE localtime() . "   $msg  (Benchmark dataset took $sampleTime for this step)\n";

      my $stmt = $dbh->prepare($sql);
      $stmt->execute();
      if ($@) {
        # you might want to use state instead of err but you did not show us the state
        if ($dbh->err =~ /Duplicate entry/) {
          print $dbh->err;
          print 'Ignoring.';
          # already registered
        } else {
          die $dbh->err;
          # report what is in $@ - it is a different error
        }
      }

      &analyzeStats($tableToAnalyze) if ($tableToAnalyze);

      my $tt = time() - $t;
      my $hours = int($tt / 3600);
      my $mins = int($tt / 60) % 60;
      if ($hours == 0 && $mins == 0) {$mins = 1};
      my $hoursStr = $hours? "$hours hours and " : "";
      print LOGFILE localtime() . "   step '$tag' done ($hoursStr$mins mins)\n\n";
  }

  clean($tag) unless ($clean eq 'no');
}

# optional skipPast (for smart restart) may be provided:
#  - as an explicit argument on the command line
#  - or by looking at the last 'done' line of log
#      - looks for log file lines of the form (as printed in runSql()):
#      - ... step '$tag' done ...
sub getSkipPast {
    my ($startAfter, $logFile) = @_;   # argument from command line

    my $skipPast;
    if ($startAfter eq 'useLog') {
      if (-e $logFile) {
	my $lastDone;
	my $lastDoneLine;
	open(LOG, "$logFile") || die "Can't open logfile '$logFile' to read startAfter\n";
	while (<LOG>) {
	    if (/step '(.+)' done/) {
		$lastDone = $1;
		$lastDoneLine = $_;
	    }
	}
	close(LOG);
	if ($lastDone) {
	    $skipPast = $stepsHash->{$lastDone};
	    die "Error: could not find valid startAfter value in log '$logFile' on line $_\n" unless $skipPast;
	}
      }
    } elsif ($startAfter) {
	$skipPast = $stepsHash->{$startAfter};
	die "invalid startAfter arg '$startAfter'\n" unless $skipPast;
    }
    return $skipPast;
}

sub analyzeStats {
    my ($tableToAnalyze) = @_;

    if ($base->getConfig("dbVendor") eq 'oracle') {
	my $sql = "analyze table $tableToAnalyze compute statistics";
	my $stmt = $dbh->prepare($sql);
	$stmt->execute();
	$stmt = $dbh->prepare("$sql for all indexes");
	$stmt->execute();
    } else {
	my $sql = "analyze table $tableToAnalyze";
	my $stmt = $dbh->prepare($sql);
	$stmt->execute();
    }
}

sub clean {
  my ($tag) = @_;

  my $cleanSqls = $cleanHash->{$tag};
  foreach my $cleanSql (@$cleanSqls) {
    if ($cleanSql) {
      $cleanSql =~ /(\w+) table (\w+)/i || die "invalid clean sql '$cleanSql'";
      my $action = $1;
      my $table = $2;
      next if ($action eq 'drop' && &tableAlreadyDropped($table));
      my $stmt = $dbh->prepare($cleanSql);
      print LOGFILE localtime() . "   cleaning: $cleanSql\n";
      $stmt->execute();
      print LOGFILE localtime() . "   done\n";
    }
  }
}

sub tableAlreadyDropped {
  my ($table) = @_;

  my $orthologTable = $base->getConfig("orthologTable");
  my $coOrthologTable = $base->getConfig("coOrthologTable");
  my $inParalogTable = $base->getConfig("inParalogTable");

  $table = $orthologTable if $table eq 'Ortholog';
  $table = $coOrthologTable if $table eq 'CoOrtholog';
  $table = $inParalogTable if $table eq 'InParalog';
  my $sql;
  if ($base->getConfig("dbVendor") eq 'oracle') {
    $table = uc($table);
    $sql = "select table_name from all_tables where table_name = '$table$suffix'";
  } else {
    $sql = "show tables like '$table$suffix'";
  }
  my $stmt = $dbh->prepare($sql);
  $stmt->execute();
  while ($stmt->fetchrow()) { return 0};
  return 1;
}


sub cleanall {
    foreach my $tag (keys (%$cleanHash)) {
	clean($tag);
    }
}

sub usage {
  my $stepsString;
  map { $stepsString .= "  $_->[0]\n" } @steps;

  print STDERR "
Find pairs for OrthoMCL.

usage: orthomclPairs config_file log_file cleanup=[yes|no|only|all] <startAfter=TAG>

where:
  config_file : see below
  log_file    : where to write the log
  cleanup     : clean up temp tables? 
                   yes=clean as we go; 
                   no=don't clean as we go; 
                   only=just clean, do nothing else; 
                   all=just clean, plus clean InParalog, Ortholog and CoOrtholog tables.
  startAfter  : optionally start after a previously completed step. see below for TAGs.
                If startAfter=useLog then start after the last 'done' step in the log.

Database Input:
  - SimilarSequences table containing all-v-all BLAST hits
  - InParalog, Ortholog, CoOrtholog tables - created but empty

Database Output:
  - Populated InParalog, Ortholog and CoOrtholog tables

NOTE: the database login in the config file must have update/insert/truncate privileges on the tables specified in the config file.

EXAMPLE: orthomclSoftware/bin/orthomclPairs my_orthomcl_dir/orthomcl.config my_orthomcl_dir/orthomcl_pairs.log cleanup=no

WARNING: if using startAfter=useLog, be sure to delete the log if you have run cleanup=all to reset this run of orthomclPairs.
         Otherwise when you start running again orthomclPairs will attempt to startAfter an invalid last step.

Sample Config File:

dbVendor=oracle  (or mysql)
dbConnectString=dbi:Oracle:orthomcl
dbLogin=my_db_login
dbPassword=my_db_password
similarSequencesTable=SimilarSequences
orthologTable=Ortholog
inParalogTable=InParalog
coOrthologTable=CoOrtholog
interTaxonMatchView=InterTaxonMatch
percentMatchCutoff=50
evalueExponentCutoff=-5

Names of TAGs to use in startAfter (look in log file to see last one run)
$stepsString
";
  exit(1);
}

