#!/usr/bin/perl -s
#^CFG COPYRIGHT UM
#^CFG FILE TESTING

$DefaultExe = "BATSRUS.exe";
$Help   =$h;
$Verbose=$v+0;
$Norun  =$norun+0;
$Execute=$x; $Execute=$DefaultExe unless $x;
$Run=$r;     $Run="mpirun -np 2" unless $r;
$Flags  =$f;
$Sleep=$s+0;

&print_help if $Help or $#ARGV != 0;

# Figure out directory for TestBatsrus.pl
$Dir = $0; $Dir =~ s/TestSuite\.pl//; $Dir = './' unless $Dir;

$testbatsrus = "$Dir"."TestBatsrus.pl ".
    "-v=$Verbose -norun=$Norun -r='$Run' -x=$Execute -f='$Flags' -s=$Sleep";

$Table  =$ARGV[0];

# first half of Table 1

###########################################################################
if($Table =~ /test/i){
###########################################################################

    &execute($testbatsrus,"-beta");

###########################################################################
}elsif($Table =~ /empty/i){
###########################################################################

    &execute($testbatsrus,
             "-Planet=earth_simple -Grid=earth_211 -Length=tiny_simple",
	     "-B0source=empty -Cfl=empty -Conservative=empty",
	     "-Corotation=empty -Divb=empty",
	     "-Implicit=empty",                           #^CFG IF IMPLICIT
	     "-Inner=empty -Message=empty -Outer=empty",
	     "-Stage=empty -Time=empty -Timestep=empty -Upstream=empty");

###########################################################################
}elsif($Table =~ /func/i){
###########################################################################

    &execute($testbatsrus,"-beta -rusanov -idltecamr");   #^CFG IF RUSANOVFLUX
    &execute($testbatsrus,"-beta -linde");                #^CFG IF LINDEFLUX
    &execute($testbatsrus,"-beta -sokolov -idltecamr");   #^CFG IF AWFLUX
    &execute($testbatsrus,"-beta -roe");                  #^CFG IF ROEFLUX

    &execute($testbatsrus,"-Conservative=r6 -rusanov");   #^CFG IF RUSANOVFLUX
    &execute($testbatsrus,"-Conservative=adapt -linde");  #^CFG IF LINDEFLUX
    &execute($testbatsrus,"-Conservative=r6 -sokolov");   #^CFG IF AWFLUX
    &execute($testbatsrus,"-Conservative=r6 -roe");       #^CFG IF ROEFLUX

                                                    #^CFG IF BORISCORR BEGIN
    &execute($testbatsrus,"-borisfull -rusanov");         #^CFG IF RUSANOVFLUX
    &execute($testbatsrus,"-borisfull -linde");           #^CFG IF LINDEFLUX
    &execute($testbatsrus,"-borisfull -sokolov");         #^CFG IF AWFLUX
                                                    #^CFG END BORISCORR
                                                    #^CFG IF SIMPLEBORIS BEGIN
    &execute($testbatsrus,"-borissimple -rusanov");       #^CFG IF RUSANOVFLUX
    &execute($testbatsrus,"-borissimple -linde");         #^CFG IF LINDEFLUX
                                                    #^CFG END SIMPLEBORIS

    &execute($testbatsrus,"-ta -Conservative=r6 -idltecamr");
    &execute($testbatsrus,"-ta -Conservative=r6",         #^CFG IF BORISCORR 
		 "-borisfull");                           #^CFG IF BORISCORR 
    &execute($testbatsrus,"-ta -Conservative=r6",         #^CFG IF SIMPLEBORIS
		 "-borissimple");                         #^CFG IF SIMPLEBORIS
							    
    &execute($testbatsrus,"-Inner=float,reflect"); 
    &execute($testbatsrus,"-Inner=full_ionosphere");      #^CFG IF IONOSPHERE

    &execute($testbatsrus,"-Message=dir");

    &execute($testbatsrus,"-ta -Stage=2",                 #^CFG IF IONOSPHERE
	     "-full_ionosphere -Logtype=logsatmove");     #^CFG IF IONOSPHERE

    &execute($testbatsrus,"-ta -Stage=2 -constrain");     #^CFG IF CONSTRAINB
    &execute($testbatsrus,"-ta -Stage=2 -project");       #^CFG IF PROJECTION
    &execute($testbatsrus,"-ta -Stage=2 -diffuse");       #^CFG IF DIVBDIFFUSE

    &execute($testbatsrus,"-ta -Stage=2 -partimpl05");    #^CFG IF IMPLICIT

    &execute($testbatsrus,"-Limiter=beta",
		"-Restart=saveone -Length=restartsave");

    &execute($testbatsrus,"-Limiter=beta",
		"-Restart=read -Length=restartread");

    &execute($testbatsrus,"-ta -Conservative=r6",
		"-Restart=save -Length=restartsave");

    &execute($testbatsrus,"-ta -Conservative=r6",
		"-Restart=read -Length=restartread");

    &execute($testbatsrus,"-ta -Corotation=ideal,updateb0");

    &execute($testbatsrus,"-Plottype=ray");               #^CFG IF RAYTRACE

    &execute($testbatsrus,"-Plottype=sph -Logtype=logpntflx");

    &execute($testbatsrus,"-Plottype=los");

    &execute($testbatsrus,
	     "-Planet=earth_simple -Grid=earth_211 -Length=tiny_simple",
	     "-B0source=empty -Cfl=empty -Conservative=empty",
	     "-Corotation=empty -Divb=empty",
	     "-Implicit=empty",                           #^CFG IF IMPLICIT
	     "-Inner=empty -Message=empty -Outer=empty",
	     "-Stage=empty -Time=empty -Timestep=empty -Upstream=empty");

    &execute($testbatsrus,"-Plottype=raynew");

###########################################################################
}elsif($Table =~ /robust/i){
###########################################################################

    &execute($testbatsrus,"-SSSS -N_5nT -Logs=10");

                                               #^CFG IF IONOSPHERE BEGIN
                                                  #^CFG IF BORISCORR BEGIN
                                                     #^CFG IF RUSANOVFLUX BEGIN
    &execute($testbatsrus,
             "-ta -Plots=3minute -Logs=10", 
             "-borisfull_0.005 -full_ionosphere -Length=hour_restart",
             "-Solver=rusanov",
             "-Upstream=nsturning_5nT");
    &execute($testbatsrus,
             "-ta -Plots=3minute -Logs=10", 
             "-borisfull_0.005 -full_ionosphere -Length=20minute_restart",
             "-Solver=rusanov",
             "-Upstream=ppulse_inc20,ppulse_dec10");
                                                     #^CFG END RUSANOVFLUX
                                                     #^CFG IF AWFLUX BEGIN
    &execute($testbatsrus,
             "-ta -Plots=3minute -Logs=10", 
             "-borisfull_0.005 -full_ionosphere -Length=hour_restart",
             "-Solver=sokolov",
             "-Upstream=nsturning_5nT");
    &execute($testbatsrus,
             "-ta -Plots=3minute -Logs=10", 
             "-borisfull_0.005 -full_ionosphere -Length=20minute_restart",
             "-Solver=sokolov",
             "-Upstream=ppulse_inc20,ppulse_dec10");
                                                     #^CFG END AWFLUX
                                                     #^CFG IF LINDEFLUX BEGIN
    &execute($testbatsrus,
             "-ta -Plots=3minute -Logs=10", 
             "-borisfull_0.005 -full_ionosphere -Length=hour_restart",
             "-Solver=linde",
             "-Upstream=nsturning_5nT");
    &execute($testbatsrus,
             "-ta -Plots=3minute -Logs=10", 
             "-borisfull_0.005 -full_ionosphere -Length=20minute_restart",
             "-Solver=linde",
             "-Upstream=ppulse_inc20,ppulse_dec10");
    &execute($testbatsrus,
             "-ta -Plots=minute -Logs=10", 
             "-borisfull_0.005 -full_ionosphere -Length=hour_restart",
             "-Solver=linde",
             "-Upstream=varying");
                                                        #^CFG IF IMPLICIT BEGIN
    &execute($testbatsrus,
             "-ta -Plots=3minute -Logs=10 -partimpl05", 
             "-borisfull -full_ionosphere -Length=20minute_restart",
             "-Solver=linde,",
             "-Upstream=nsturning_5nT");
                                                        #^CFG END IMPLICIT
                                                     #^CFG END LINDEFLUX
                                                  #^CFG END BORISCORR
                                                  #^CFG IF ROEFLUX BEGIN
    &execute($testbatsrus,
             "-ta -Plots=3minute -Logs=10", 
             "-noboris -full_ionosphere -Length=20minute_restart",
             "-Solver=roe",
             "-Upstream=nsturning_5nT");
                                                  #^CFG END ROEFLUX
                                               #^CFG END IONOSPHERE

}elsif($Table=~/^full$/i){

    die "Full test is to be implemented!\n";

}else{
    print "ERROR: unknown option for testsuite!\n";
    print_help;
}

##############################################################################

sub execute{

    $command = join(' ',@_);

    print "$command\n" if $Verbose;

    $result = `$command`;

    print $result;
}


##############################################################################
#BOP
#!ROUTINE: TestSuite.pl - test BATSRUS with a suite of tests
#!DESCRIPTION:
# This script can run a set of tests using TestBatsrus.pl.
#
#!REVISION HISTORY:
# 01/28/02 G.Toth and A.Ridley - initial version developed for BATSRUS
# 07/10/03 G.Toth              - adapted to SWMF
# 03/11/04 G.Toth              - moved back into BATSRUS but 
#                                it can be used in SWMF as well
#EOP

sub print_help{

    print 
#BOC
"

TestSuite.pl [-h] [-v] [-norun] [-s=SLEEP]              \\
             [-r=RUNCOMMAND] [-x=EXECUTABLE] [-f=FLAGS] \\
             test | func | robust | full

-h     print this help message

-v     verbose

-norun do not run $DefaultExe, just create test directories and parameter files

-s=SLEEP
       sleep SLEEP seconds between tests, e.g. use -s=10 for 10 seconds.

-r=RUNCOMMAND
       define the runcommand to be executed. The default runcommand is 
       -r='mpirun -np 2'. You can specify a machinefile,
       or run on a different number of processors.

-x=COMMAND    
       executable. The default is $DefaultExe

-f=FLAGS
       command line flags for the executable. The default is no flags.


test   just do a single run

empty  test the default settings (almost empty PARAM.in file)

func   test the functionality (after syntactic change)

robust test robustness (of new algorithm)

full   test everything (before release)"
#EOC
,"\n\n";

    exit;
}
