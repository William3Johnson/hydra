package Setup;

use strict;
use Exporter;
use Test::PostgreSQL;
use File::Temp;
use File::Path qw(make_path);
use Cwd;

our @ISA = qw(Exporter);
our @EXPORT = qw(test_init hydra_setup nrBuildsForJobset queuedBuildsForJobset nrQueuedBuildsForJobset createBaseJobset createJobsetWithOneInput evalSucceeds runBuild updateRepository);

sub test_init() {
    my $dir = File::Temp->newdir();

    $ENV{'HYDRA_DATA'} = "$dir/hydra-data";
    mkdir $ENV{'HYDRA_DATA'};
    $ENV{'NIX_CONF_DIR'} = "$dir/nix/etc/nix";
    make_path($ENV{'NIX_CONF_DIR'});
    my $nixconf = "$ENV{'NIX_CONF_DIR'}/nix.conf";
    open(my $fh, '>', $nixconf) or die "Could not open file '$nixconf' $!";
    print $fh "sandbox = false\n";
    close $fh;

    $ENV{'NIX_STATE_DIR'} = "$dir/nix/var/nix";

    $ENV{'NIX_MANIFESTS_DIR'} = "$dir/nix/var/nix/manifests";
    $ENV{'NIX_STORE_DIR'} = "$dir/nix/store";
    $ENV{'NIX_LOG_DIR'} = "$dir/nix/var/log/nix";

    my $pgsql = Test::PostgreSQL->new(
        extra_initdb_args => "--locale C.UTF-8"
    );
    $ENV{'HYDRA_DBI'} = $pgsql->dsn;
    system("hydra-init") == 0 or die;
    return ($dir, $pgsql);
}

sub captureStdoutStderr {
    # "Lazy"-load Hydra::Helper::Nix to avoid the compile-time
    # import of Hydra::Model::DB. Early loading of the DB class
    # causes fixation of the DSN, and we need to fixate it after
    # the temporary DB is setup.
    require Hydra::Helper::Nix;
    return Hydra::Helper::Nix::captureStdoutStderr(@_)
}

sub hydra_setup {
    my ($db) = @_;
    $db->resultset('Users')->create({ username => "root", emailaddress => 'root@invalid.org', password => '' });
}

sub nrBuildsForJobset {
    my ($jobset) = @_;
    return $jobset->builds->search({},{})->count ;
}

sub queuedBuildsForJobset {
    my ($jobset) = @_;
    return $jobset->builds->search({finished => 0});
}

sub nrQueuedBuildsForJobset {
    my ($jobset) = @_;
    return queuedBuildsForJobset($jobset)->count ;
}

sub createBaseJobset {
    my ($jobsetName, $nixexprpath) = @_;

    my $db = Hydra::Model::DB->new;
    my $project = $db->resultset('Projects')->update_or_create({name => "tests", displayname => "", owner => "root"});
    my $jobset = $project->jobsets->create({name => $jobsetName, nixexprinput => "jobs", nixexprpath => $nixexprpath, emailoverride => ""});

    my $jobsetinput;
    my $jobsetinputals;

    $jobsetinput = $jobset->jobsetinputs->create({name => "jobs", type => "path"});
    $jobsetinputals = $jobsetinput->jobsetinputalts->create({altnr => 0, value => getcwd."/jobs"});

    return $jobset;
}

sub createJobsetWithOneInput {
    my ($jobsetName, $nixexprpath, $name, $type, $uri) = @_;
    my $jobset = createBaseJobset($jobsetName, $nixexprpath);

    my $jobsetinput;
    my $jobsetinputals;

    $jobsetinput = $jobset->jobsetinputs->create({name => $name, type => $type});
    $jobsetinputals = $jobsetinput->jobsetinputalts->create({altnr => 0, value => $uri});

    return $jobset;
}

sub evalSucceeds {
    my ($jobset) = @_;
    my ($res, $stdout, $stderr) = captureStdoutStderr(60, ("hydra-eval-jobset", $jobset->project->name, $jobset->name));
    chomp $stdout; chomp $stderr;
    print STDERR "Evaluation errors for jobset ".$jobset->project->name.":".$jobset->name.": \n".$jobset->errormsg."\n" if $jobset->errormsg;
    print STDERR "STDOUT: $stdout\n" if $stdout ne "";
    print STDERR "STDERR: $stderr\n" if $stderr ne "";
    return !$res;
}

sub runBuild {
    my ($build) = @_;
    my ($res, $stdout, $stderr) = captureStdoutStderr(60, ("hydra-queue-runner", "-vvvv", "--build-one", $build->id));
    if ($res) {
        print STDERR "Queue runner stdout: $stdout\n" if $stdout ne "";
        print STDERR "Queue runner stderr: $stderr\n" if $stderr ne "";
    }
    return !$res;
}

sub updateRepository {
    my ($scm, $update, $scratchdir) = @_;
    my $curdir = getcwd;
    chdir "$scratchdir";
    my ($res, $stdout, $stderr) = captureStdoutStderr(60, ($update, $scm));
    chdir "$curdir";
    die "unexpected update error with $scm: $stderr\n" if $res;
    my ($message, $loop, $status) = $stdout =~ m/::(.*) -- (.*) -- (.*)::/;
    print STDOUT "Update $scm repository: $message\n";
    return ($loop eq "continue", $status eq "updated");
}

1;