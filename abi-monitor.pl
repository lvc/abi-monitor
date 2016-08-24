#!/usr/bin/perl
##################################################################
# ABI Monitor 1.9
# A tool to monitor new versions of a software library, build them
# and create profile for ABI Tracker.
#
# Copyright (C) 2016 Andrey Ponomarenko's ABI Laboratory
#
# Written by Andrey Ponomarenko
#
# PLATFORMS
# =========
#  Linux (x86, x86_64)
#
# REQUIREMENTS
# ============
#  Perl 5 (5.8 or newer)
#  cURL
#  wget
#  CMake
#  Automake
#  GCC
#  G++
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License or the GNU Lesser
# General Public License as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# and the GNU Lesser General Public License along with this program.
# If not, see <http://www.gnu.org/licenses/>.
##################################################################
use Getopt::Long;
Getopt::Long::Configure ("posix_default", "no_ignore_case", "permute");
use File::Path qw(mkpath rmtree);
use File::Copy qw(copy move);
use File::Temp qw(tempdir);
use File::Basename qw(dirname basename);
use Cwd qw(abs_path cwd);
use Data::Dumper;

my $TOOL_VERSION = "1.9";
my $DB_PATH = "Monitor.data";
my $REPO = "src";
my $INSTALLED = "installed";
my $BUILD_LOGS = "build_logs";
my $TMP_DIR = tempdir(CLEANUP=>1);
my $TMP_DIR_LOC = "Off";
my $ACCESS_TIMEOUT = 15;
my $CONNECT_TIMEOUT = 5;
my $ACCESS_TRIES = 2;
my $USE_CURL = 1;
my $PKG_EXT = "tar\\.bz2|tar\\.gz|tar\\.xz|tar\\.lzma|tar\\.lz|tar\\.Z|tbz2|tgz|tar|zip";

# Internal modules
my $MODULES_DIR = get_Modules();
push(@INC, dirname($MODULES_DIR));

my $CMAKE = "cmake";
my $GCC = "gcc";

my $C_FLAGS = "-g -Og -w -fpermissive";
my $CXX_FLAGS = $C_FLAGS;

my ($Help, $DumpVersion, $Get, $Build, $Rebuild, $OutputProfile,
$TargetVersion, $LimitOps, $BuildShared, $BuildNew, $Debug);

my $CmdName = basename($0);
my $ORIG_DIR = cwd();

my %ERROR_CODE = (
    "Success"=>0,
    # Undifferentiated error code
    "Error"=>2,
    # System command is not found
    "Not_Found"=>3,
    # Cannot access input files
    "Access_Error"=>4,
    # Cannot find a module
    "Module_Error"=>9
);

my $ShortUsage = "ABI Monitor $TOOL_VERSION
A tool to monitor new versions of a software library
Copyright (C) 2016 Andrey Ponomarenko's ABI Laboratory
License: GPL or LGPL

Usage: $CmdName [options] [profile]
Example:
  $CmdName -get -build profile.json

More info: $CmdName --help\n";

if($#ARGV==-1)
{
    printMsg("INFO", $ShortUsage);
    exit(0);
}

GetOptions("h|help!" => \$Help,
  "dumpversion!" => \$DumpVersion,
# general options
  "get!" => \$Get,
  "build!" => \$Build,
  "rebuild!" => \$Rebuild,
  "limit=s" => \$LimitOps,
  "v=s" => \$TargetVersion,
  "output=s" => \$OutputProfile,
  "build-shared!" => \$BuildShared,
  "build-new!" => \$BuildNew,
  "debug!" => \$Debug
) or ERR_MESSAGE();

sub ERR_MESSAGE()
{
    printMsg("INFO", "\n".$ShortUsage);
    exit($ERROR_CODE{"Error"});
}

my $HelpMessage="
NAME:
  ABI Monitor ($CmdName)
  Monitor and build new versions of a C/C++ software library

DESCRIPTION:
  ABI Tracker is a tool to monitor new versions of a software
  library, try to build them and create profile for ABI Tracker.
  
  The tool is intended to be used with the ABI Tracker tool for
  visualizing API/ABI changes timeline.

  This tool is free software: you can redistribute it and/or
  modify it under the terms of the GNU LGPL or GNU GPL.

USAGE:
  $CmdName [options] [profile]

EXAMPLES:
  $CmdName -get -build profile.json

INFORMATION OPTIONS:
  -h|-help
      Print this help.

  -dumpversion
      Print the tool version ($TOOL_VERSION) and don't do
      anything else.

GENERAL OPTIONS:
  -get
      Download new library versions.
      
  -build
      Build library versions.
  
  -rebuild
      Re-build library versions.
  
  -limit NUM
      Limit number of operations to NUM. This is usefull if
      you want to download or build only NUM packages.
  
  -v NUM
      Build only one particular version.
      
  -output PATH
      Path to output profile. The tool will overwrite the
      input profile by default.
  
  -build-shared
      Build shared objects from static ones if they cannot
      be build by the library makefile or build script.
  
  -build-new
      Build newly found packages only. This option should
      be used with -get option.
  
  -debug
      Enable debug messages.
";

# Global
my $Profile;
my $DB;
my $TARGET_LIB;

my %NewVer;

sub get_Modules()
{
    my $TOOL_DIR = dirname($0);
    my @SEARCH_DIRS = (
        # tool's directory
        abs_path($TOOL_DIR),
        # relative path to modules
        abs_path($TOOL_DIR)."/../share/abi-monitor",
        # install path
        'MODULES_INSTALL_PATH'
    );
    foreach my $DIR (@SEARCH_DIRS)
    {
        if(not $DIR=~/\A\//)
        { # relative path
            $DIR = abs_path($TOOL_DIR)."/".$DIR;
        }
        if(-d $DIR."/modules") {
            return $DIR."/modules";
        }
    }
    exitStatus("Module_Error", "can't find modules");
}

sub loadModule($)
{
    my $Name = $_[0];
    my $Path = $MODULES_DIR."/Internals/$Name.pm";
    if(not -f $Path) {
        exitStatus("Module_Error", "can't access \'$Path\'");
    }
    require $Path;
}

sub readModule($$)
{
    my ($Module, $Name) = @_;
    my $Path = $MODULES_DIR."/Internals/$Module/".$Name;
    if(not -f $Path) {
        exitStatus("Module_Error", "can't access \'$Path\'");
    }
    return readFile($Path);
}

sub exitStatus($$)
{
    my ($Code, $Msg) = @_;
    printMsg("ERROR", $Msg);
    exit($ERROR_CODE{$Code});
}

sub printMsg($$)
{
    my ($Type, $Msg) = @_;
    if($Type!~/\AINFO/) {
        $Msg = $Type.": ".$Msg;
    }
    if($Type!~/_C\Z/) {
        $Msg .= "\n";
    }
    if($Type eq "ERROR") {
        print STDERR $Msg;
    }
    else {
        print $Msg;
    }
}

sub readProfile($)
{
    my $Content = $_[0];
    
    my %Res = ();
    
    if($Content=~/\A\s*\{\s*((.|\n)+?)\s*\}\s*\Z/)
    {
        my $Info = $1;
        
        if($Info=~/\"Versions\"/)
        {
            my $Pos = 0;
            
            while($Info=~s/(\"Versions\"\s*:\s*\[\s*)(\{\s*(.|\n)+?\s*\})\s*,?\s*/$1/)
            {
                my $VInfo = readProfile($2);
                if(my $VNum = $VInfo->{"Number"})
                {
                    $VInfo->{"Pos"} = $Pos++;
                    $Res{"Versions"}{$VNum} = $VInfo;
                }
                else {
                    printMsg("ERROR", "version number is missed in the profile");
                }
            }
        }
        
        # arrays
        while($Info=~s/\"(\w+)\"\s*:\s*\[\s*(.*?)\s*\]\s*(\,|\Z)//)
        {
            my ($K, $A) = ($1, $2);
            
            if($K eq "Versions") {
                next;
            }
            
            $Res{$K} = [];
            
            foreach my $E (split(/\s*\,\s*/, $A))
            {
                $E=~s/\A[\"\']//;
                $E=~s/[\"\']\Z//;
                
                push(@{$Res{$K}}, $E);
            }
        }
        
        # scalars
        while($Info=~s/\"(\w+)\"\s*:\s*(.+?)\s*\,?\s*$//m)
        {
            my ($K, $V) = ($1, $2);
            
            if($K eq "Versions") {
                next;
            }
            
            $V=~s/\A[\"\']//;
            $V=~s/[\"\']\Z//;
            
            $Res{$K} = $V;
        }
    }
    
    return \%Res;
}

sub getCurrent()
{
    my $CurRepo = $REPO."/".$TARGET_LIB."/current";
    
    my $Git = defined $Profile->{"Git"};
    my $Svn = defined $Profile->{"Svn"};
    
    if($Git)
    {
        if(not check_Cmd("git"))
        {
            printMsg("ERROR", "can't find \"git\"");
            return;
        }
    }
    elsif($Svn)
    {
        if(not check_Cmd("svn"))
        {
            printMsg("ERROR", "can't find \"svn\"");
            return;
        }
    }
    
    my $UpToDate = 0;
    
    if(-d $CurRepo)
    {
        chdir($CurRepo);
        
        if($Git)
        {
            printMsg("INFO", "Updating source code in repository");
            my $Log = qx/git pull/;
            
            if($Log=~/Already up\-to\-date/i) {
                $UpToDate = 1;
            }
        }
        elsif($Svn)
        {
            printMsg("INFO", "Updating source code in repository");
            my $Log = qx/svn update/;
            
            if($Log!~/Updated to revision/i) {
                $UpToDate = 1;
            }
        }
    }
    else
    {
        if($Git)
        {
            printMsg("INFO", "Cloning git repository");
            system("git clone ".$Profile->{"Git"}." ".$CurRepo);
        }
        elsif($Svn)
        {
            printMsg("INFO", "Checkouting svn repository");
            system("svn checkout ".$Profile->{"Svn"}." ".$CurRepo);
        }
    }
    
    chdir($ORIG_DIR);
    
    $DB->{"Source"}{"current"} = $CurRepo;
    
    my $UTime = getScmUpdateTime();
    if(not $UpToDate)
    {
        if($DB->{"ScmUpdateTime"})
        {
            if($DB->{"ScmUpdateTime"} ne $UTime) {
                $NewVer{"current"} = 1;
            }
        }
        else {
            $NewVer{"current"} = 1;
        }
    }
    $DB->{"ScmUpdateTime"} = $UTime;
}

sub getScmUpdateTime()
{
    if(my $Source = $DB->{"Source"}{"current"})
    {
        if(not -d $Source) {
            return undef;
        }
        
        my $Time = undef;
        my $Head = undef;
        
        if(defined $Profile->{"Git"})
        {
            $Head = "$Source/.git/refs/heads/master";
            
            if(not -f $Head)
            { # is not updated yet
                $Head = "$Source/.git/FETCH_HEAD";
            }
            
            if(not -f $Head)
            {
                $Head = undef;
            }
        }
        elsif(defined $Profile->{"Svn"})
        {
            $Head = "$Source/.svn/wc.db";
            
            if(not -f $Head)
            {
                $Head = undef;
            }
        }
        
        if($Head)
        {
            $Time = `stat -c \%Y \"$Head\"`;
            chomp($Time);
        }
        
        if($Time) {
            return $Time;
        }
    }
    
    return undef;
}

sub getVersions_Local()
{
    if(not defined $Profile->{"SourceDir"}) {
        return 0;
    }
    
    my $SourceDir = $Profile->{"SourceDir"};
    
    if(not $SourceDir) {
        return 0;
    }
    
    if(not -d $SourceDir)
    {
        exitStatus("Access_Error", "can't access \'$SourceDir\'");
        return 0;
    }
    
    printMsg("INFO", "Copying packages from \'$SourceDir\' to \'$REPO/$TARGET_LIB\'");
    
    my @Files = findFiles($SourceDir, "f");
    
    foreach my $File (sort {$b cmp $a} @Files)
    {
        if($File=~/\/(\Q$TARGET_LIB\E[\_\-]*([^\/]+?)\.($PKG_EXT))\Z/)
        {
            my ($P, $V) = ($1, $2);
            my $To = $REPO."/".$TARGET_LIB."/".$V;
            
            if(not -d $To or not listDir($To))
            {
                printMsg("INFO", "Found $File");
                
                # copy to local directory
                # mkpath($To);
                # if(copy($File, $To))
                # {
                #     $DB->{"Source"}{$V} = $To."/".$P;
                # }
                
                $DB->{"Source"}{$V} = $File;
            }
        }
    }
}

sub getVersions()
{
    my $SourceUrl = $Profile->{"SourceUrl"};
    
    if(not $SourceUrl)
    {
        if(not defined $Profile->{"SourceDir"})
        {
            printMsg("WARNING", "SourceUrl is not specified in the profile");
        }
        return;
    }
    
    printMsg("INFO", "Searching for new packages");
    
    if($USE_CURL)
    {
        if(not check_Cmd("curl"))
        {
            printMsg("ERROR", "can't find \"curl\"");
            return;
        }
    }
    else
    {
        if(not check_Cmd("wget"))
        {
            printMsg("ERROR", "can't find \"wget\"");
            return;
        }
    }
    
    my @Links = getLinks($SourceUrl);
    
    my $Depth = 2;
    if(defined $Profile->{"SourceUrlDepth"})
    { # More steps into directory tree
        $Depth = $Profile->{"SourceUrlDepth"};
    }
    
    if($Depth>=2)
    {
        my %Checked = ();
        $Checked{$SourceUrl} = 1;
        
        foreach my $D (1 .. $Depth - 1)
        {
            my @Pages = getPages($SourceUrl, \@Links);
            foreach my $Page (@Pages)
            {
                if(not defined $Checked{$Page})
                {
                    $Checked{$Page} = 1;
                    foreach my $Link (getLinks($Page))
                    {
                        push(@Links, $Link);
                    }
                }
            }
        }
    }
    
    my $Packages = getPackages(@Links);
    my $NumOp = 0;
    
    foreach my $V (sort {cmpVersions_P($b, $a, $Profile)} keys(%{$Packages}))
    {
        my $R = getPackage($Packages->{$V}{"Url"}, $Packages->{$V}{"Pkg"}, $V);
        
        if($R>0) {
            $NumOp += 1;
        }
        
        if(defined $LimitOps)
        {
            if($NumOp>=$LimitOps)
            {
                last;
            }
        }
    }
    
    if(not $NumOp) {
        printMsg("INFO", "No new packages found");
    }
}

sub getHighRelease()
{
    my @Vers = keys(%{$DB->{"Source"}});
    @Vers = naturalSequence($Profile, @Vers);
    @Vers = reverse(@Vers);
    
    foreach my $V (@Vers)
    {
        if(getVersionType($V, $Profile) eq "release")
        {
            return $V;
        }
    }
    
    return undef;
}

sub isOldMicro($$)
{
    my ($V, $L) = @_;
    my $M = getMajor($V, $L);
    
    foreach my $Ver (sort keys(%{$DB->{"Source"}}))
    {
        if(getMajor($Ver, $L) eq $M)
        {
            if(cmpVersions_P($Ver, $V, $Profile)>=0)
            {
                return 1;
            }
        }
    }
    
    return 0;
}

sub getPackage($$$)
{
    my ($Link, $P, $V) = @_;
    
    if(defined $DB->{"Source"}{$V})
    { # already downloaded
        return -1;
    }
    
    if(getVersionType($V, $Profile) ne "release")
    {
        if(my $HighRelease = getHighRelease())
        {
            if(cmpVersions_P($V, $HighRelease, $Profile)==-1)
            { # do not download old alfa/beta/pre releases
                return -1;
            }
        }
    }
    
    if(defined $Profile->{"LatestMicro"})
    {
        if(isOldMicro($V, 2))
        { # do not download old micro releases
            return -1;
        }
    }
    
    if(defined $Profile->{"LatestNano"})
    {
        if(isOldMicro($V, 3))
        { # do not download old nano releases
            return -1;
        }
    }
    
    my $Dir = $REPO."/".$TARGET_LIB."/".$V;
    
    if(not -e $Dir) {
        mkpath($Dir);
    }
    
    my $To = $Dir."/".$P;
    if(-f $To) {
        return -1;
    }
    
    printMsg("INFO", "Downloading package \'$P\'");
    
    my $Pid = fork();
    unless($Pid)
    { # child
        my $Cmd = "";
        
        if($USE_CURL) {
            $Cmd = "curl -L \"$Link\" --connect-timeout 5 --retry 1 --output \"$To\"";
        }
        else {
            $Cmd = "wget --no-check-certificate \"$Link\" --connect-timeout=5 --tries=1 --output-document=\"$To\""; # -U ''
        }
        
        system($Cmd." >".$TMP_DIR."/wget_log 2>&1");
        writeFile($TMP_DIR."/wget_res", $?);
        exit(0);
    }
    local $SIG{INT} = sub
    {
        rmtree($Dir);
        safeExit();
    };
    waitpid($Pid, 0);
    
    my $Log = readFile($TMP_DIR."/wget_log");
    my $R = readFile($TMP_DIR."/wget_res");
    
    if($Log=~/\[text\/html\]/ or not -B $To)
    {
        rmtree($Dir);
        printMsg("ERROR", "\'$Link\' is not a package\n");
        return 0;
    }
    elsif($R or not -f $To or not -s $To)
    {
        rmtree($Dir);
        printMsg("ERROR", "can't access \'$Link\'\n");
        return 0;
    }
    
    $DB->{"Source"}{$V} = $To;
    $NewVer{$V} = 1;
    
    return 1;
}

sub readPage($)
{
    my $Page = $_[0];
    
    my $To = $TMP_DIR."/page.html";
    unlink($To);
    my $Url = $Page;
    
    if($Page=~/\Aftp:.+[^\/]\Z/
    and getFilename($Page)!~/\./)
    { # wget for ftp
      # tail "/" should be added
        $Page .= "/";
    }
    
    my $Cmd = "";
    
    if($USE_CURL and index($Page, "ftp:")!=0)
    { # TODO: how to list absolute paths in FTP directory using curl?
        $Cmd = "curl -L \"$Page\"";
        $Cmd .= " --connect-timeout $CONNECT_TIMEOUT";
        $Cmd .= " --retry $ACCESS_TRIES --output \"$To\"";
        $Cmd .= " -w \"\%{url_effective}\\n\"";
    }
    else
    {
        $Cmd = "wget --no-check-certificate \"$Page\"";
        # $Cmd .= " -U ''";
        $Cmd .= " --no-remove-listing";
        # $Cmd .= " --quiet";
        $Cmd .= " --connect-timeout=$CONNECT_TIMEOUT";
        $Cmd .= " --tries=$ACCESS_TRIES --output-document=\"$To\"";
    }
    
    my $Pid = fork();
    unless($Pid)
    { # child
        system($Cmd." >".$TMP_DIR."/output 2>&1");
        writeFile($TMP_DIR."/result", $?);
        exit(0);
    }
    $SIG{ALRM} = sub {
        kill(9, $Pid);
    };
    alarm $ACCESS_TIMEOUT;
    waitpid($Pid, 0);
    alarm 0;
    
    my $Output = readFile($TMP_DIR."/output");
    
    while($Output=~s/((http|https|ftp):\/\/[^\s]+)//)
    { # real URL
        $Url = $1;
    }
    
    my $Res = readFile($TMP_DIR."/result");
    
    if(not $Res) {
        return ($To, $Url);
    }
    
    printMsg("ERROR", "can't access page \'$Page\'");
    return ("", "");
}

sub getPackages(@)
{
    my %Res = ();
    
    my $Pkg = $TARGET_LIB;
    
    if(defined $Profile->{"Package"}) {
        $Pkg = $Profile->{"Package"};
    }
    
    foreach my $Link (sort {$b cmp $a} @_)
    {
        if($Link=~/\/\Z/) {
            next;
        }
        
        my ($P, $V, $E) = ();
        
        if($Link=~/(\A|\/)(\Q$Pkg\E[_\-]*([^\/"'<>+%]+?)\.($PKG_EXT))([\/\?]|\Z)/i)
        {
            ($P, $V, $E) = ($2, $3, $4);
        }
        elsif($Link=~/(archive|get)\/v?([\d\.\-\_]+([ab]\d*|alpha\d*|beta\d*|rc\d*|))\.(tar\.gz)/i)
        { # github
          # bitbucket
            ($V, $E) = ($2, $4);
            $P = $Pkg."-".$V.".".$E;
        }
        
        $V=~s/\Av(\d)/$1/i; # v1.1
        $V=~s/[\-\_](src|source|sources)\Z//i; # pkg-X.Y.Z-Source.tar.gz
        
        if(defined $Res{$V})
        {
            if($Res{$V}{"Ext"} ne "zip" or $E eq "zip")
            {
                next;
            }
        }
        
        if($V=~/mingw|msvc/i) {
            next;
        }
        
        if($V=~/snapshot/i) {
            next;
        }
        
        if(getVersionType($V, $Profile) eq "unknown") {
            next;
        }
        
        if(my $Release = checkReleasePattern($V, $Profile))
        {
            $V = $Release;
        }
        
        if(skipVersion($V, $Profile)) {
            next;
        }
        
        if($P)
        {
            $Res{$V}{"Url"} = $Link;
            $Res{$V}{"Pkg"} = $P;
            $Res{$V}{"Ext"} = $E;
        }
    }
    
    return \%Res;
}

sub getPages($$)
{
    my ($Top, $Links) = @_;
    my @Res = ();
    
    $Top=~s/\?.*\Z//g;
    
    foreach my $Link (@{$Links})
    {
        if($Link!~/\/\Z/ and $Link!~/\/v?\d[\d\.\-]*\Z/i)
        {
            if($Link!~/github\.com\/.+\?after\=/)
            {
                next;
            }
        }
        
        if(index($Link, $Top)==-1)
        {
            next;
        }
        
        if($Link=~/https:\/\/sourceforge\.net\/projects\/[^\/]+\/files\/[^\/]+\/([^\/]+)\/\Z/)
        {
            if(defined $DB->{"Source"}{$1})
            {
                if($Debug) {
                    printMsg("INFO", "Skip: $Link");
                }
                next;
            }
        }
        elsif($Link=~/\/($TARGET_LIB[\-_]*|)v?([\d\.\-\_]+)[\/]*\Z/i)
        {
            my $V = $2;
            if(defined $DB->{"Source"}{$V})
            {
                if($Debug) {
                    printMsg("INFO", "Skip: $Link");
                }
                next;
            }
            elsif(skipVersion($V, $Profile))
            {
                if($Debug) {
                    printMsg("INFO", "Skip: $Link");
                }
                next;
            }
        }
        
        push(@Res, $Link);
    }
    
    return @Res;
}

sub getLinks($)
{
    my $Page = $_[0];
    
    if($Debug) {
        printMsg("INFO", "Reading ".$Page);
    }
    
    my ($To, $Url) = readPage($Page);
    
    if(not $To) {
        return ();
    }
    
    my $Content = readFile($To);
    unlink($To);
    
    my (%Links1, %Links2, %Links3, %Links4) = ();
    
    my @Lines = split(/\n/, $Content);
    
    foreach my $Line (@Lines)
    {
        while($Line=~s/(src|href)\s*\=\s*["']\s*((ftp|http|https):\/\/[^"'<>\s]+?)\s*["']//i) {
            $Links1{$2} = 1;
        }
        while($Line=~s/(src|href)\s*\=\s*["']\s*([^"'<>\s]+?)\s*["']//i) {
            $Links2{linkSum($Url, $2)} = 1;
        }
        while($Line=~s/((ftp|http|https):\/\/[^"'<>\s]+?)([\s"']|\Z)//i) {
            $Links3{$1} = 1;
        }
        while($Line=~s/["']([^"'<>\s]+\.($PKG_EXT))["']//i) {
            $Links4{linkSum($Url, $1)} = 1;
        }
    }
    
    foreach my $U (keys(%Links4))
    {
        my $F = getFilename($U);
        
        if(grep {getFilename($_) eq $F} keys(%Links1)) {
            delete($Links4{$U});
        }
    }
    
    my @Res = ();
    my @AllLinks = (sort {$b cmp $a} keys(%Links1), sort {$b cmp $a} keys(%Links2), sort {$b cmp $a} keys(%Links3), sort {$b cmp $a} keys(%Links4));
    
    foreach (@AllLinks) {
        while($_=~s/\/[^\/]+\/\.\.\//\//g){};
    }
    
    my $SiteAddr = getSiteAddr($Page);
    my $SiteProtocol = getSiteProtocol($Page);
    
    foreach my $Link (@AllLinks)
    {
        if(skipUrl($Link)) {
            next;
        }
        
        if($Link!~/github\.com\/.*\?after\=/) {
            $Link=~s/\?.+\Z//g;
        }
        
        $Link=~s/\%2D/-/g;
        $Link=~s/[\/]{2,}\Z/\//g;
        
        if($Link=~/\A(\Q$Page\E|\Q$Url\E|\Q$SiteAddr\E)[\/]*\Z/) {
            next;
        }
        
        # if(getSiteAddr($Link) ne getSiteAddr($Page)) {
        #     next;
        # }
        
        if(not getSiteProtocol($Link)) {
            $Link = $SiteProtocol.$Link;
        }
        
        if(index($Link, "sourceforge")!=-1)
        {
            if($Link=~/($PKG_EXT)\/(.+)\Z/)
            {
                if($2 ne "download") {
                    next;
                }
            }
            if($Link=~/(http[s]*):\/\/sourceforge.net\/projects\/(\w+)\/files\/(.+)\/download\Z/)
            { # fix for SF
                $Link = "$1://sourceforge.net/projects/$2/files/$3/download?use_mirror=autoselect";
            }
        }
        
        $Link=~s/\%2b/\+/g;
        $Link=~s/\:21\//\//;
        
        push(@Res, $Link);
    }
    
    return @Res;
}

sub skipUrl($$)
{
    my $Link = $_[0];
    
    if(defined $Profile->{"SkipUrl"})
    {
        foreach my $Url (@{$Profile->{"SkipUrl"}})
        {
            if(not $Url) {
                next;
            }
            
            if($Url=~/[\*\+\(\|\\]/)
            { # pattern
                if($Link=~/$Url/) {
                    return 1;
                }
            }
            else
            {
                if($Link=~/\Q$Url\E/) {
                    return 1;
                }
            }
        }
    }
    
    return 0;
}

sub linkSum($$)
{
    my ($Page, $Path) = @_;
    
    $Page=~s/\?.+?\Z//g;
    $Path=~s/\A\.\///g;
    
    if(index($Path, "/")==0)
    {
        if($Path=~/\A\/\/([^\/:]+\.[a-z]+\/.+)\Z/)
        { # //liblouis.googlecode.com/files/liblouis-1.6.2.tar.gz
            return $1;
        }
        
        return getSiteAddr($Page).$Path;
    }
    elsif(index($Path, "://")!=-1) {
        return $Path;
    }
    elsif($Page=~/\/\Z/)
    {
        return $Page.$Path;
    }
    
    return getDirname($Page)."/".$Path;
}

sub buildVersions()
{
    if(not defined $DB->{"Source"})
    {
        printMsg("INFO", "Nothing to build");
        return;
    }
    
    if(check_Cmd($GCC))
    {
        if(my $Machine = qx/$GCC -dumpmachine/)
        {
            if($Machine=~/x86_64/)
            {
                $C_FLAGS .= " -fPIC";
                $CXX_FLAGS .= " -fPIC";
            }
        }
    }
    
    if(defined $BuildNew)
    {
        if(not defined $DB->{"Installed"}{"current"})
        { # NOTE: try to build current again
            $NewVer{"current"} = 1;
        }
    }
    
    my @Versions = keys(%{$DB->{"Source"}});
    @Versions = naturalSequence($Profile, @Versions);
    
    @Versions = reverse(@Versions);
    
    my $NumOp = 0;
    
    foreach my $V (@Versions)
    {
        if(defined $TargetVersion)
        {
            if($TargetVersion ne $V) {
                next;
            }
        }
        
        if(defined $BuildNew)
        {
            if(not defined $NewVer{$V}) {
                next;
            }
        }
        
        my $R = buildPackage($DB->{"Source"}{$V}, $V);
        
        if($R>0) {
            $NumOp += 1;
        }
        
        if(defined $LimitOps)
        {
            if($NumOp>=$LimitOps)
            {
                last;
            }
        }
    }
    
    if(not $NumOp)
    {
        printMsg("INFO", "Nothing to build");
        return;
    }
}

sub createProfile($)
{
    my $To = $_[0];
    
    if(not defined $DB->{"Installed"})
    {
        printMsg("INFO", "No installed versions of the library to create profile");
        return;
    }
    
    my @ProfileKeys = ("Name", "Title", "SourceUrl", "SourceUrlDepth", "SourceDir", "SkipUrl", "Git", "Svn", "Doc",
    "Maintainer", "MaintainerUrl", "BuildSystem", "Configure", "CurrentConfigure", "BuildScript", "PreInstall", "CurrentPreInstall", "PostInstall", "CurrentPostInstall", "SkipObjects", "SkipHeaders", "SkipSymbols", "SkipInternalSymbols", "SkipTypes", "SkipInternalTypes");
    my $MaxLen_P = 13;
    
    my %UnknownKeys = ();
    foreach my $K (keys(%{$Profile}))
    {
        if(not grep {$_ eq $K} @ProfileKeys)
        {
            $UnknownKeys{$K} = 1;
        }
    }
    if(keys(%UnknownKeys)) {
        push(@ProfileKeys, sort keys(%UnknownKeys));
    }
    
    my @Content_L = ();
    
    foreach my $K (@ProfileKeys)
    {
        if(defined $Profile->{$K})
        {
            my $Val = $Profile->{$K};
            my $Ref = ref($Val);
            
            if($Ref eq "HASH") {
                next;
            }
            
            my $St = "";
            foreach (0 .. $MaxLen_P - length($K)) {
                $St .= " ";
            }
            
            if($Ref eq "ARRAY") {
                push(@Content_L, "\"$K\": ".$St."[ \"".join("\", \"", @{$Val})."\" ]");
            }
            else {
                push(@Content_L, "\"$K\": ".$St."\"$Val\"");
            }
        }
    }
    
    my @Content_V = ();
    
    my @Versions = keys(%{$DB->{"Installed"}});
    @Versions = naturalSequence($Profile, @Versions);
    
    if(defined $Profile->{"Versions"})
    { # save order of versions in the profile if manually edited
        foreach my $V (keys(%{$Profile->{"Versions"}}))
        { # clear variable
            if(not defined $Profile->{"Versions"}{$V}{"Pos"}) {
                delete($Profile->{"Versions"}{$V});
            }
        }
        
        my @O_Versions = keys(%{$Profile->{"Versions"}});
        @O_Versions = sort {int($Profile->{"Versions"}{$b}{"Pos"})<=>int($Profile->{"Versions"}{$a}{"Pos"})} @O_Versions;
        my %Added = map {$_=>1} @O_Versions;
        my @Merged = ();
        
        foreach my $P1 (0 .. $#O_Versions)
        {
            my $V1 = $O_Versions[$P1];
            
            foreach my $V2 (@Versions)
            {
                if(not defined $Added{$V2})
                {
                    if(cmpVersions_P($V2, $V1, $Profile)==-1)
                    {
                        push(@Merged, $V2);
                        $Added{$V2} = 1;
                    }
                }
            }
            
            push(@Merged, $V1);
            
            if($P1==$#O_Versions)
            {
                foreach my $V2 (@Versions)
                {
                    if(not defined $Added{$V2})
                    {
                        if(cmpVersions_P($V2, $V1, $Profile)==1)
                        {
                            push(@Merged, $V2);
                            $Added{$V2} = 1;
                        }
                    }
                }
            }
        }
        
        @Versions = @Merged;
    }
    
    # Mark old unstable releases as "deleted"
    if(not defined $Profile->{"KeepOldBeta"})
    {
        my $MaxBeta = undef;
        my $MaxRelease = undef;
        foreach my $V (reverse(@Versions))
        {
            if($V eq "current") {
                next;
            }
            
            if(getVersionType($V, $Profile) eq "release")
            {
                if(not defined $MaxRelease) {
                    $MaxRelease = $V;
                }
            }
            else
            {
                if(defined $MaxBeta or defined $MaxRelease)
                {
                    if(not defined $Profile->{"Versions"}{$V}{"Deleted"})
                    { # One can set Deleted to 0 in order to prevent deleting
                        $Profile->{"Versions"}{$V}{"Deleted"} = 1;
                    }
                }
                
                if(not defined $MaxBeta) {
                    $MaxBeta = $V;
                }
            }
        }
    }
    
    if(defined $Profile->{"LatestMicro"})
    {
        my %MaxMicro = ();
        foreach my $V (reverse(@Versions))
        {
            if($V eq "current") {
                next;
            }
            
            my $M = getMajor($V, 2);
            
            if(defined $MaxMicro{$M})
            {
                if(not defined $Profile->{"Versions"}{$V}{"Deleted"})
                { # One can set Deleted to 0 in order to prevent deleting
                    $Profile->{"Versions"}{$V}{"Deleted"} = 1;
                }
            }
            else {
                $MaxMicro{$M} = $V;
            }
        }
    }
    
    if(defined $Profile->{"LatestNano"})
    {
        my %MaxNano = ();
        foreach my $V (reverse(@Versions))
        {
            if($V eq "current") {
                next;
            }
            
            my $M = getMajor($V, 3);
            
            if(defined $MaxNano{$M})
            {
                if(not defined $Profile->{"Versions"}{$V}{"Deleted"})
                { # One can set Deleted to 0 in order to prevent deleting
                    $Profile->{"Versions"}{$V}{"Deleted"} = 1;
                }
            }
            else {
                $MaxNano{$M} = $V;
            }
        }
    }
    
    foreach my $V (reverse(@Versions))
    {
        my @Info = ();
        my $Sp = "    ";
        my $N_Info = {};
        
        $N_Info->{"Number"} = $V;
        $N_Info->{"Installed"} = $DB->{"Installed"}{$V};
        $N_Info->{"Source"} = $DB->{"Source"}{$V};
        $N_Info->{"Changelog"} = $DB->{"Changelog"}{$V};
        if(not $N_Info->{"Changelog"})
        { # default
            if(defined $Profile->{"Changelog"})
            {
                $N_Info->{"Changelog"} = $Profile->{"Changelog"};
            }
            else
            {
                if($V eq "current") {
                    $N_Info->{"Changelog"} = "On";
                }
                else {
                    $N_Info->{"Changelog"} = "Off";
                }
            }
        }
        if(defined $Profile->{"PkgDiff"}) {
            $N_Info->{"PkgDiff"} = $Profile->{"PkgDiff"};
        }
        else {
            $N_Info->{"PkgDiff"} = "Off";
        }
        
        if(defined $Profile->{"HeadersDiff"}) {
            $N_Info->{"HeadersDiff"} = $Profile->{"HeadersDiff"};
        }
        else {
            $N_Info->{"HeadersDiff"} = "On";
        }
        
        # Non-free high detailed analysis
        $N_Info->{"ABIView"} = "Off";
        $N_Info->{"ABIDiff"} = "Off";
        
        if(defined $Profile->{"Versions"} and defined $Profile->{"Versions"}{$V})
        {
            my $O_Info = $Profile->{"Versions"}{$V};
            
            foreach my $K (sort keys(%{$O_Info}))
            {
                # if($K eq "PublicSymbols"
                # or $K eq "PublicTypes")
                # { # obsolete
                #     next;
                # }
                
                if($K ne "Pos")
                {
                    if(defined $O_Info->{$K}) {
                        $N_Info->{$K} = $O_Info->{$K};
                    }
                }
            }
        }
        
        my @VersionKeys = ("Number", "Installed", "Source", "Changelog", "HeadersDiff", "PkgDiff", "ABIView",
        "ABIDiff", "BuildShared", "Deleted");
        
        my $MaxLen_V = 13;
        
        my %UnknownKeys_V = ();
        foreach my $K (keys(%{$N_Info}))
        {
            if(not grep {$_ eq $K} @VersionKeys)
            {
                $UnknownKeys_V{$K} = 1;
            }
        }
        if(keys(%UnknownKeys_V)) {
            push(@VersionKeys, sort keys(%UnknownKeys_V));
        }
        
        foreach my $K (@VersionKeys)
        {
            if(defined $N_Info->{$K})
            {
                my $St = "";
                foreach (0 .. $MaxLen_V - length($K)) {
                    $St .= " ";
                }
                
                if(int($N_Info->{$K}) eq $N_Info->{$K}) { # integer
                    push(@Info, $Sp."\"$K\": $St".$N_Info->{$K});
                }
                else { # string
                    push(@Info, $Sp."\"$K\": $St\"".$N_Info->{$K}."\"");
                }
            }
        }
        
        push(@Content_V, "{\n".join(",\n", @Info)."\n  }");
    }
    
    writeFile($To, "{\n  ".join(",\n  ", @Content_L).",\n\n  \"Versions\": [\n  ".join(",\n  ", @Content_V)."]\n}\n");
}

sub findChangelog($)
{
    my $Dir = $_[0];
    
    foreach my $Name ("NEWS", "CHANGES", "CHANGES.txt", "RELEASE_NOTES", "ChangeLog", "Changelog",
    "RELEASE_NOTES.md", "RELEASE_NOTES.markdown", "NEWS.md")
    {
        if(-f $Dir."/".$Name
        and -s $Dir."/".$Name)
        {
            return $Name;
        }
    }
    
    return "None";
}

sub autoBuild($$$)
{
    my ($To, $LogDir, $V) = @_;
    
    my $LogDir_R = $LogDir;
    $LogDir_R=~s/\A$ORIG_DIR\///;
    
    my $PreInstall = $Profile->{"PreInstall"};
    
    if($V eq "current")
    {
        if(defined $Profile->{"CurrentPreInstall"}) {
            $PreInstall = $Profile->{"CurrentPreInstall"};
        }
    }
    
    if($PreInstall)
    {
        $PreInstall = addParams($PreInstall, $To, $V);
        my $Cmd_P = $PreInstall." >$LogDir/pre_install 2>&1";
        qx/$Cmd_P/; # execute
        if($?)
        {
            printMsg("ERROR", "pre install has failed");
            printMsg("ERROR", "see error log in '$LogDir_R/pre_install'");
            return 0;
        }
    }
    
    my @Files = listDir(".");
    
    my ($CMake, $Autotools, $Scons, $Waf) = (0, 0, 0, 0);
    
    my ($Configure, $Autogen, $Bootstrap, $Buildconf) = (0, 0, 0, 0);
    
    foreach my $File (sort @Files)
    {
        if($File eq "CMakeLists.txt") {
            $CMake = 1;
        }
        elsif($File eq "configure")
        {
            $Autotools = 1;
            $Configure = 1;
        }
        elsif($File eq "configure.ac") {
            $Autotools = 1;
        }
        elsif($File eq "autogen.sh") {
            $Autogen = 1;
        }
        elsif($File eq "bootstrap") {
            $Bootstrap = 1;
        }
        elsif($File eq "buildconf") {
            $Buildconf = 1;
        }
        elsif($File eq "SConstruct") {
            $Scons = 1;
        }
        elsif($File eq "waf") {
            $Waf = 1;
        }
    }
    
    if(defined $Profile->{"BuildSystem"})
    {
        if($Profile->{"BuildSystem"} eq "CMake") {
            $Autotools = 0;
        }
        elsif($Profile->{"BuildSystem"} eq "Autotools")
        {
            $CMake = 0;
            $Autotools = 1;
        }
    }
    
    if($Autotools and not $CMake)
    {
        if(not $Configure)
        { # try to generate configure script
            if($Autogen)
            {
                my $Cmd_A = "NOCONFIGURE=1 NO_CONFIGURE=1 sh autogen.sh --no-configure";
                $Cmd_A .= " >\"$LogDir/autogen\" 2>&1";
                
                qx/$Cmd_A/;
                
                if(not -f "configure")
                {
                    printMsg("ERROR", "failed to 'autogen'");
                    printMsg("ERROR", "see error log in '$LogDir_R/autogen'");
                    return 0;
                }
            }
            elsif($Bootstrap)
            {
                my $Cmd_B = "sh bootstrap";
                $Cmd_B .= " >\"$LogDir/bootstrap\" 2>&1";
                
                qx/$Cmd_B/;
                
                if(not -f "configure")
                {
                    printMsg("ERROR", "failed to 'bootstrap'");
                    printMsg("ERROR", "see error log in '$LogDir_R/bootstrap'");
                    return 0;
                }
            }
            elsif($Buildconf)
            {
                my $Cmd_B = "sh buildconf";
                $Cmd_B .= " >\"$LogDir/buildconf\" 2>&1";
                
                qx/$Cmd_B/;
                
                if(not -f "configure")
                {
                    printMsg("ERROR", "failed to 'buildconf'");
                    printMsg("ERROR", "see error log in '$LogDir_R/buildconf'");
                    return 0;
                }
            }
            else
            {
                $Autotools = 0;
            }
        }
    }
    
    my $ConfigOptions = $Profile->{"Configure"};
    if($V eq "current")
    {
        if(defined $Profile->{"CurrentConfigure"}) {
            $ConfigOptions = $Profile->{"CurrentConfigure"};
        }
    }
    $ConfigOptions = addParams($ConfigOptions, $To, $V);
    
    if($CMake)
    {
        if(not check_Cmd($CMAKE))
        {
            printMsg("ERROR", "can't find \"$CMAKE\"");
            return;
        }
        
        mkpath("build");
        chdir("build");
        
        my $Cmd_C = $CMAKE." .. -DCMAKE_BUILD_TYPE=Debug -DBUILD_SHARED_LIBS=ON";
        $Cmd_C .= " -DCMAKE_INSTALL_PREFIX=\"$To\"";
        $Cmd_C .= " -DCMAKE_C_FLAGS=\"$C_FLAGS\" -DCMAKE_CXX_FLAGS=\"$CXX_FLAGS\"";
        
        if($ConfigOptions) {
            $Cmd_C .= " ".$ConfigOptions;
        }
        
        $Cmd_C .= " >\"$LogDir/cmake\" 2>&1";
        
        qx/$Cmd_C/; # execute
        if($?)
        {
            printMsg("ERROR", "failed to 'cmake'");
            printMsg("ERROR", "see error log in '$LogDir_R/cmake'");
            return 0;
        }
    }
    elsif($Autotools)
    {
        my $Cmd_C = "./configure --enable-shared";
        $Cmd_C .= " --prefix=\"$To\"";
        $Cmd_C .= " CFLAGS=\"$C_FLAGS\" CXXFLAGS=\"$CXX_FLAGS\"";
        
        if($ConfigOptions) {
            $Cmd_C .= " ".$ConfigOptions;
        }
        
        $Cmd_C .= " >\"$LogDir/configure\" 2>&1";
        
        qx/$Cmd_C/; # execute
        if($?)
        {
            printMsg("ERROR", "failed to 'configure'");
            printMsg("ERROR", "see error log in '$LogDir_R/configure'");
            return 0;
        }
    }
    elsif($Scons)
    {
        my $Cmd_I = "scons prefix=\"$To\" debug=True";
        
        if($ConfigOptions) {
            $Cmd_I .= " ".$ConfigOptions;
        }
        
        $Cmd_I .= " install";
        
        $Cmd_I .= " >\"$LogDir/scons\" 2>&1";
        
        my $SConstruct = readFile("SConstruct");
        $SConstruct=~s/'-O0'/'-Og'/;
        writeFile("SConstruct", $SConstruct);
        
        qx/$Cmd_I/; # execute
        if($?)
        {
            printMsg("ERROR", "failed to 'scons'");
            printMsg("ERROR", "see error log in '$LogDir_R/scons'");
            return 0;
        }
    }
    elsif($Waf)
    {
        my $Cmd_C = "./waf configure --prefix=\"$To\" --debug";
        
        if($ConfigOptions) {
            $Cmd_C .= " ".$ConfigOptions;
        }
        
        $Cmd_C .= " >\"$LogDir/configure\" 2>&1";
        
        qx/$Cmd_C/; # execute
        if($?)
        {
            printMsg("ERROR", "failed to './waf configure'");
            printMsg("ERROR", "see error log in '$LogDir_R/configure'");
            return 0;
        }
    }
    else
    {
        printMsg("ERROR", "unknown build system, please set \"BuildScript\" in the profile");
        return 0;
    }
    
    my $MakeOptions = $Profile->{"Make"};
    
    if($CMake or $Autotools)
    {
        my $Cmd_M = "make";
        if($MakeOptions) {
            $Cmd_M .= " ".$MakeOptions;
        }
        $Cmd_M .= " >$LogDir/make 2>&1";
        
        qx/$Cmd_M/; # execute
        if($?)
        {
            printMsg("ERROR", "failed to 'make'");
            printMsg("ERROR", "see error log in '$LogDir_R/make'");
            return 0;
        }
        
        my $Cmd_I = "make install >$LogDir/install 2>&1";
        qx/$Cmd_I/; # execute
        if($?)
        {
            printMsg("ERROR", "failed to 'make install'");
            printMsg("ERROR", "see error log in '$LogDir_R/install'");
            return 0;
        }
    }
    elsif($Waf)
    {
        my $Cmd_M = "./waf build";
        
        $Cmd_M .= " >$LogDir/build 2>&1";
        
        qx/$Cmd_M/; # execute
        if($?)
        {
            printMsg("ERROR", "failed to './waf build'");
            printMsg("ERROR", "see error log in '$LogDir_R/build'");
            return 0;
        }
        
        my $Cmd_I = "./waf install >$LogDir/install 2>&1";
        qx/$Cmd_I/; # execute
        if($?)
        {
            printMsg("ERROR", "failed to './waf install'");
            printMsg("ERROR", "see error log in '$LogDir_R/install'");
            return 0;
        }
    }
    
    my $PostInstall = $Profile->{"PostInstall"};
    if($V eq "current")
    {
        if(defined $Profile->{"CurrentPostInstall"}) {
            $PostInstall = $Profile->{"CurrentPostInstall"};
        }
    }
    
    if($CMake) {
        chdir("..");
    }
    
    if($PostInstall)
    {
        $PostInstall = addParams($PostInstall, $To, $V);
        my $Cmd_P = $PostInstall." >$LogDir/post_install 2>&1";
        qx/$Cmd_P/; # execute
        if($?)
        {
            printMsg("ERROR", "post install has failed");
            printMsg("ERROR", "see error log in '$LogDir_R/post_install'");
            return 0;
        }
    }
    
    copyFiles($To);
    
    if(not listDir($To))
    {
        return 0;
    }
    
    return 1;
}

sub copyFiles($)
{
    my $To = $_[0];
    
    foreach my $Tag ("CopyHeaders", "CopyObjects")
    {
        if(not defined $Profile->{$Tag}) {
            next;
        }
        
        my $Dir = undef;
        
        if($Tag eq "CopyHeaders") {
            $Dir = "include";
        }
        else {
            $Dir = "lib";
        }
        
        if(my $Elems = $Profile->{$Tag})
        {
            foreach my $D (@{$Elems})
            {
                my @Files = ();
                
                if(-d $D)
                {
                    if($Tag eq "CopyHeaders") {
                        @Files = findHeaders($D);
                    }
                    else {
                        @Files = findObjects($D);
                    }
                }
                elsif(-f $D) {
                    @Files = ($D);
                }
                
                foreach my $F (@Files)
                {
                    my $O_To = $To."/".$Dir."/".$F;
                    my $D_To = getDirname($O_To);
                    mkpath($D_To);
                    copy($F, $D_To);
                }
            }
        }
    }
}

sub addParams($$$)
{
    my ($Cmd, $To, $V) = @_;
    
    $Cmd=~s/{INSTALL_TO}/$To/g;
    $Cmd=~s/{VERSION}/$V/g;
    
    my $InstallRoot_A = $ORIG_DIR."/".$INSTALLED;
    $Cmd=~s/{INSTALL_ROOT}/$InstallRoot_A/g;
    
    return $Cmd;
}

sub findObjects($)
{
    my $Dir = $_[0];
    
    my @Files = ();
    
    if($Profile->{"Mode"} eq "Kernel")
    {
        @Files = findFiles($Dir, "f", ".*\\.ko");
        @Files = (@Files, findFiles($Dir, "f", "", "vmlinux"));
    }
    else
    {
        @Files = findFiles($Dir, "f", ".*\\.so\\..*");
        @Files = (@Files, findFiles($Dir, "f", ".*\\.so"));
    }
    
    my @Res = ();
    
    foreach my $F (@Files)
    {
        if(-B $F) {
            push(@Res, $F);
        }
    }
    
    return @Res;
}

sub findHeaders($)
{
    my $Dir = $_[0];
    
    my @Files = findFiles($Dir, "f");
    my @Headers = ();
    
    foreach my $File (sort {lc($a) cmp lc($b)} @Files)
    {
        if(isHeader($File)) {
            push(@Headers, $File);
        }
    }
    
    return @Headers;
}

sub buildPackage($$)
{
    my ($Package, $V) = @_;
    
    if(not $Rebuild)
    {
        if(defined $DB->{"Installed"}{$V})
        {
            if($V ne "current" or not defined $NewVer{$V})
            {
                return -1;
            }
        }
    }
    
    printMsg("INFO", "Building \'".getFilename($Package)."\'");
    
    my $BuildScript = undef;
    if(defined $Profile->{"BuildScript"})
    {
        $BuildScript = $Profile->{"BuildScript"};
        
        if(not -f $BuildScript) {
            exitStatus("Access_Error", "can't access build script \'$BuildScript\'");
        }
        
        $BuildScript = abs_path($BuildScript);
    }
    
    my $LogDir_R = $BUILD_LOGS."/".$TARGET_LIB."/".$V;
    rmtree($LogDir_R);
    mkpath($LogDir_R);
    
    my $LogDir = abs_path($LogDir_R);
    
    my $InstallDir = $INSTALLED."/".$TARGET_LIB."/".$V;
    rmtree($InstallDir);
    mkpath($InstallDir);
    
    my $InstallDir_A = abs_path($InstallDir);
    my $InstallRoot_A = abs_path($INSTALLED);
    
    my $BuildDir = $TMP_DIR."/build/";
    mkpath($BuildDir);
    
    if($V eq "current")
    {
        my $Cmd_E = "cp -fr $Package $BuildDir";
        qx/$Cmd_E/; # execute
        
        $BuildDir .= "/current";
    }
    else
    {
        if(my $Cmd_E = extractPackage($Package, $BuildDir))
        {
            qx/$Cmd_E/; # execute
            if($?)
            {
                printMsg("ERROR", "Failed to extract package \'".getFilename($Package)."\'");
                return 0;
            }
        }
        else
        {
            printMsg("ERROR", "Unknown package format \'".getFilename($Package)."\'");
            return 0;
        }
    }
    
    chdir($BuildDir);
    my @Files = listDir(".");
    if($#Files==0 and -d $Files[0])
    { # one step deeper
        chdir($Files[0]);
    }
    
    if($V ne "current" and not defined $Profile->{"Changelog"})
    {
        my $Found = findChangelog(".");
        
        if($Found ne "None") {
            $DB->{"Changelog"}{$V} = $Found;
        }
        else {
            $DB->{"Changelog"}{$V} = "Off";
        }
    }
    
    if(my $CustomDir = $Profile->{"BuildDir"}) {
        chdir($CustomDir);
    }
    
    if(defined $BuildScript)
    {
        my $Cmd_I = "INSTALL_TO=\"$InstallDir_A\" INSTALL_ROOT=\"$InstallRoot_A\" sh \"".$BuildScript."\"";
        $Cmd_I .= " >\"$LogDir/build\" 2>&1";
        
        qx/$Cmd_I/; # execute
        
        my $Err = $?;
        
        copyFiles($InstallDir_A);
        
        if($Err or not listDir($InstallDir_A))
        {
            delete($DB->{"Installed"}{$V});
            
            printMsg("ERROR", "custom build has failed");
            printMsg("ERROR", "see error log in '$LogDir_R/build'");
        }
        else {
            $DB->{"Installed"}{$V} = $InstallDir;
        }
    }
    else
    {
        if(autoBuild($InstallDir_A, $LogDir, $V)) {
            $DB->{"Installed"}{$V} = $InstallDir;
        }
        else {
            delete($DB->{"Installed"}{$V});
        }
    }
    
    chdir($ORIG_DIR);
    rmtree($BuildDir);
    
    if($DB->{"Installed"}{$V})
    {
        if((defined $Profile->{"Versions"} and defined $Profile->{"Versions"}{$V}
        and $Profile->{"Versions"}{$V}{"BuildShared"} and $Profile->{"Versions"}{$V}{"BuildShared"} ne "Off")
        or ($Profile->{"BuildShared"} and $Profile->{"BuildShared"} ne "Off"))
        {
            buildShared($V);
        }
        
        if(not defined $Profile->{"ClearInstalled"}
        or $Profile->{"ClearInstalled"} ne "Off")
        {
            foreach my $D ("share", "bin", "sbin",
            "etc", "var", "opt", "libexec", "doc",
            "manual", "man", "logs", "icons",
            "conf", "cgi-bin", "docs", "lib/systemd",
            "lib/udev", "lib/cmake", "systemd", "udev",
            "lib/girepository-1.0", "lib/python2.7",
            "tmp", "info", "lib/sysctl.d", "lib64/cmake")
            {
                if(-d $InstallDir."/".$D) {
                    rmtree($InstallDir."/".$D);
                }
            }
            
            my @Fs = listPaths($InstallDir."/lib");
            my @Fs64 = listPaths($InstallDir."/lib64");
            my $Shared = undef;
            
            foreach my $F (@Fs, @Fs64)
            {
                if($F=~/\.so(\.|\Z)/)
                {
                    $Shared = 1;
                    last;
                }
            }
            
            foreach my $F (@Fs, @Fs64)
            {
                if(-f $F)
                {
                    if($F=~/\.(la|jar|o)\Z/) {
                        unlink($F)
                    }
                    
                    if(defined $Shared)
                    {
                        if($F=~/\.a\Z/) {
                            unlink($F)
                        }
                    }
                }
            }
        }
    }
    else
    {
        printMsg("ERROR", "failed to build");
        rmtree($InstallDir);
    }
    
    return 1;
}

sub buildShared($)
{
    my $V = $_[0];
    
    my $Installed = $DB->{"Installed"}{$V};
    
    if(not -d $Installed) {
        return 0;
    }
    
    if(not check_Cmd($GCC)) {
        return 0;
    }
    
    my @Objects = findStatic($Installed);
    
    foreach my $Object (@Objects)
    {
        my $Object_A = abs_path($Object);
        my $To = getDirname($Object);
        
        my $Object_S = getFilename($Object);
        $Object_S=~s/\.a\Z/.so/g;
        
        if(-e $To."/".$Object_S)
        {
            printMsg("INFO", "shared object already exists");
            return 1;
        }
        
        chdir($To);
        my $Cmd_B = $GCC." -nostdlib -shared -o \"$Object_S\" -Wl,--whole-archive \"$Object_A\"";
        qx/$Cmd_B/;
        
        if($?)
        {
            print STDERR "ERROR: failed to build shared object(s)\n";
            chdir($ORIG_DIR);
            return 0;
        }
        
        chdir($ORIG_DIR);
        print "Created \'$To/$Object_S\'\n";
    }
}

sub findStatic($)
{
    my $Dir = $_[0];
    
    return findFiles($Dir, "f", ".*\\.a");
}

sub readDB($)
{
    my $Path = $_[0];
    
    if(-f $Path)
    {
        my $P = eval(readFile($Path));
        
        if(not $P) {
            exitStatus("Error", "please remove 'use strict' from code and retry");
        }
        
        return $P;
    }
    
    return {};
}

sub writeDB($)
{
    my $Path = $_[0];
    
    if($Path and $DB and keys(%{$DB})) {
        writeFile($Path, Dumper($DB));
    }
}

sub checkFiles()
{
    my $Repo = $REPO."/".$TARGET_LIB;
    foreach my $V (listDir($Repo))
    {
        if($V eq "current") {
            $DB->{"Source"}{$V} = $Repo."/".$V;
        }
        else
        {
            if(my @Files = listFiles($Repo."/".$V))
            {
                $DB->{"Source"}{$V} = $Repo."/".$V."/".$Files[0];
            }
        }
    }
    
    my $Installed = $INSTALLED."/".$TARGET_LIB;
    foreach my $V (listDir($Installed))
    {
        if(my @Files = listDir($Installed."/".$V))
        {
            $DB->{"Installed"}{$V} = $Installed."/".$V;
        }
        else
        {
            rmtree($Installed."/".$V);
        }
    }
}

sub checkDB()
{
    foreach my $V (keys(%{$DB->{"Source"}}))
    {
        if(not -f $DB->{"Source"}{$V})
        {
            delete($DB->{"Source"}{$V});
        }
    }
    
    foreach my $V (keys(%{$DB->{"Installed"}}))
    {
        if(not -d $DB->{"Installed"}{$V})
        {
            delete($DB->{"Installed"}{$V});
        }
    }
}

sub safeExit()
{
    chdir($ORIG_DIR);
    
    printMsg("INFO", "\nReceived SIGINT");
    printMsg("INFO", "Exiting");
    
    if($TMP_DIR_LOC eq "On") {
        rmtree($TMP_DIR);
    }
    
    writeDB($DB_PATH);
    exit(1);
}

sub scenario()
{
    $Data::Dumper::Sortkeys = 1;
    
    $SIG{INT} = \&safeExit;
    
    if($Rebuild or $BuildNew) {
        $Build = 1;
    }
    
    if(defined $LimitOps)
    {
        if($LimitOps<=0) {
            exitStatus("Error", "the value of -limit option should be a positive integer");
        }
    }
    
    if($DumpVersion)
    {
        printMsg("INFO", $TOOL_VERSION);
        exit(0);
    }
    
    if($Help)
    {
        printMsg("INFO", $HelpMessage);
        exit(0);
    }
    
    if(-d "archives_report") {
        exitStatus("Error", "Can't execute inside the Java API tracker home directory");
    }
    
    my $Profile_Path = $ARGV[0];
    
    if(not $Profile_Path) {
        exitStatus("Error", "profile path is not specified");
    }
    
    if(not -e $Profile_Path) {
        exitStatus("Access_Error", "can't access \'$Profile_Path\'");
    }
    
    loadModule("Basic");
    loadModule("CmpVersions");
    
    $Profile = readProfile(readFile($Profile_Path));
    
    if(not $Profile->{"Name"}) {
        exitStatus("Error", "name of the library is not specified in profile");
    }
    
    if(defined $Profile->{"LocalBuild"}
    and $Profile->{"LocalBuild"} eq "On")
    {
        $TMP_DIR_LOC = "On";
        $TMP_DIR = ".tmp";
        mkpath($TMP_DIR);
        $TMP_DIR = abs_path($TMP_DIR);
    }
    
    $TARGET_LIB = $Profile->{"Name"};
    $DB_PATH = "db/".$TARGET_LIB."/".$DB_PATH;
    
    $DB = readDB($DB_PATH);
    
    checkDB();
    checkFiles();
    
    if($Get)
    {
        getVersions_Local();
        getVersions();
        
        if(defined $Profile->{"Git"}
        or defined $Profile->{"Svn"})
        {
            getCurrent();
        }
    }
    
    if($Build) {
        buildVersions();
    }
    
    if($BuildShared)
    {
        if(defined $TargetVersion)
        {
            buildShared($TargetVersion);
        }
        else {
            print STDERR "ERROR: target version should be specified to build shared objects from static ones\n";
        }
    }
    
    writeDB($DB_PATH);
    
    my $Output = $OutputProfile;
    if(not $Output) {
        $Output = $Profile_Path;
    }
    
    createProfile($Output);
    
    if($TMP_DIR_LOC eq "On") {
        rmtree($TMP_DIR);
    }
}

scenario();
