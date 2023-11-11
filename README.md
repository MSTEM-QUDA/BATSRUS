Copyright (C) 2002 Regents of the University of Michigan,
portions used with permission.
For more information, see http://csem.engin.umich.edu/tools/swmf

This document outlines how to install the stand-alone BATSRUS code
on your system and how to create and access the documentation.  
Note that BATSRUS is part of the SWMF. If you already have the SWMF,
you can use BATSRUS inside the SWMF to build the stand-alone BATSRUS code.

To learn more about the BATSRUS, including how to compile and run the code, 
please consult the user manual.  To install the BATSRUS and create the 
user manual please follow the instructions below. 

# Obtain BATSRUS

Get the full source code from GitHub/SWMFsoftware or the open-source code from
GitHub/MSTEM-QUDA.

The minimum requirement is the `BATSRUS` repository. 

You may also need the open-source `SWMF_data` repository that contains
large data files for BATSRUS in the `GM/BATSRUS/data/` and `SC/BATSRUS/data/`
subdirectories. The other subdirectories can be removed to save disk space.
The `SWMF_data` should be put into the home directory:

```
cd
git clone https://github.com/SWMFsoftware/SWMF_data --depth=1
```

Some data files used by the Center for Radiative Shock Hydrodynamics (CRASH)
are in the `CRASH_data` repository that is available to registered users.
If needed, it has to be placed into the home directory.

# Getting the open-source MSTEM-QUDA/BATSRUS from GitHub

Clone BATSRUS from GitHub/MSTEM-QUDA

```
cd {where_you_want_to_have_mstem-quda}
git clone https://github.com/MSTEM-QUDA/BATSRUS
```

The rest of the repositories (share, util, srcBATL ...)
will be cloned from GitHub/MSTEM-QUDA during the installation.

# Getting the full BATSRUS from GitHub/SWMFsoftware (requires access)

Read the
[Git instructions](http://herot.engin.umich.edu/~gtoth/SWMF/doc/Git_instructions.pdf)
about registering, passwordless access, mail notifications, and
using the [gitclone](https://github.com/SWMFsoftware/share/blob/master/Scripts/gitclone) script.

## Clone the BATSRUS distribution
```
cd {where_you_want_to_have_batsrus}
gitclone BATSRUS
```

## Clone the CRASH_data repository into the home directory if needed
```
cd
gitclone CRASH_data
```

# Install BATSRUS

Many machines used by UofM are already recognized by the 
`share/Scripts/Config.pl` script, which is called by all other `Config.pl`
scripts in the SWMF.
For these platform/compiler combinations installation is very simple:
```
./Config.pl -install
```
On other platforms the Fortran (and C) compilers should be explicitly given.
To see available choices, type
```
./Config.pl -compiler
```
Then install the code with the selected Fortran (and default C) compiler, e.g.
```
./Config.pl -install -compiler=gfortran
```
A non-default C compiler can be added after a comma, e.g.
```
./Config.pl -install -compiler=mpxlf90,mpxlc
```
For machines with no MPI library, use
```
./Config.pl -install -nompi -compiler=....
```
This will only allow serial execution, of course. Like with most scripts
in the SWMF/BATSRUS, type
```
./Config.pl -help
```
for a comprehensive description of options and examples.

The ifort compiler (and possibly others too) use the stack for temporary
arrays, so the stack size should be large. For csh/tcsh add the following
to `.cshrc`:
```
unlimit stacksize
```
For bash/ksh/zsh add the following to `.bashrc` or equivalent initialization
file:
```
ulimit -s unlimited
```

# Create the manuals

Please note that creating the PDF manuals requires that LaTeX
(available through the command line) is installed on your system.

To create the PDF manuals for BATSRUS and CRASH type
```
make PDF
cd util/CRASH/doc/Tex; make PDF
```
in the BATSRUS directory. The manuals will be in the `Doc/` and
`util/CRASH/doc/` directories, and can be accessed by opening
`Doc/index.html` and `util/CRASH/doc/index.html`. Note that
the CRASH application is only usable in the full SWMFsoftware version.

The input parameters of BATSRUS/CRASH are described in the `PARAM.XML`
in the main directory. This is the best source of information when
constructing the input parameter file and it is used to generate the
"Input Parameters" section of the manual.

## Cleaning the documentation
```
cd Doc/Tex
make clean
```
To remove all the created documentation type
```
cd Doc/Tex
make cleanpdf
```
As for most Makefile-s in the SWMF/BATSRUS, type
```
make help
```
for a comprehensive list of make targets and examples.

# Read the manuals

All manuals can be accessed by opening the top index file 
```
open Doc/index.html
```
You may also read the PDF files directly with a PDF reader. 
The most important document is the user manual in
```
Doc/USERMANUAL.pdf
```

# Running tests

You can try running the standard test suite by typing
```
make -j test
```
in the main directory. The `-j` flag allows parallel compilation.
This requires a machine where `mpiexec` is available.
The tests run with 2 MPI processors and 2 threads by default. 
Successful passing of the test is indicated by empty `*.diff` files.

To run the tests on more (up to 8) cores use
```
make -j test NP=4
```
You can also run an individual test. The list of available SWMF tests
can be listed with
```
make test_help
```
For example, to run `test_shocktube` in a serial mode (without MPI)
but multithreaded with 4 threads (using OpenMP):
```
make -j test_shocktube MPIRUN= NTHREAD=4
```
