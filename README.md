ABI Monitor 1.12
================

ABI Monitor — monitor new versions of a software library, try to build them and create profile for ABI Tracker: https://github.com/lvc/abi-tracker

Contents
--------

1. [ About   ](#about)
2. [ Install ](#install)
3. [ Usage   ](#usage)
4. [ Profile ](#profile)

About
-----

The tool is intended to be used with the ABI Tracker tool to visualize API/ABI changes timeline of a C/C++ library.

The tool is developed by Andrey Ponomarenko: http://abi-laboratory.pro/

Install
-------

    sudo make install prefix=/usr

###### Requires

* Perl 5 (5.8 or newer)
* perl-Data-Dumper
* curl
* wget

###### Recommends
* cmake
* autotools
* meson
* gcc
* g++

Usage
-----

    abi-monitor [options] [profile]

The input profile will be extended after execution. Then it can be passed to the ABI Tracker.

###### Examples

    abi-monitor -get -build libssh.json
    abi-monitor -rebuild -v 0.7.0 libssh.json

Profile
-------

    {
        "Name":       "SHORT LIBRARY NAME",
        "SourceUrl":  "URL TO DOWNLOAD PACKAGES",
        "Git":        "GIT ADDRESS TO CLONE"
    }

###### Profile example

    {
        "Name":       "libssh",
        "SourceUrl":  "https://red.libssh.org/projects/libssh/files",
        "Git":        "https://git.libssh.org/projects/libssh.git"
    }

See more profile examples in this directory: https://github.com/lvc/upstream-tracker/tree/master/profile

###### Adv. options

You can set additional option `BuildScript` to define the path to the shell script that should be used to build packages. It will be executed inside the source tree of a package. The script should install the library to the output directory defined by the `INSTALL_TO` environment variable. The code should be compiled with the `-g -Og` GCC options.

If you just want to add some configure options then you can define the `Configure` option of the profile.

The other option `SourceDir` allows to index packages from a local directory instead of downloading them from `SourceUrl`.

###### Adv. usage

  For advanced usage, see output of `-help` option.
