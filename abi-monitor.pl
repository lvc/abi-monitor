#!/usr/bin/perl
##################################################################
# ABI Monitor 1.0
# A tool to monitor new versions of a software library, build them
# and create profile for ABI Tracker.
#
# Copyright (C) 2015 Andrey Ponomarenko's ABI Laboratory
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
#  GNU Wget >= 1.12
#  CMake
#  Automake
#  GCC
#  G++
#  Ctags (5.8 or newer)
#
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
Getopt::Long::Configure ("posix_default", "no_ignore_case");
use File::Path qw(mkpath rmtree);
use File::Copy qw(copy move);
use File::Temp qw(tempdir);
use File::Basename qw(dirname basename);
use Cwd qw(abs_path cwd);
use Data::Dumper;

my $TOOL_VERSION = "1.0";
my $DB_PATH = "Monitor.data";
my $REPO = "src";
my $INSTALLED = "installed";
my $PUBLIC_SYMBOLS = "public_symbols";
my $PUBLIC_TYPES = "public_types";
my $BUILD_LOGS = "build_logs";
my $TMP_DIR = tempdir(CLEANUP=>1);
my $ACCESS_TIMEOUT = 15;
my $CONNECT_TIMEOUT = 5;
my $ACCESS_TRIES = 2;
my $PKG_EXT = "tar\\.bz2|tar\\.gz|tar\\.xz|tar\\.lzma|tar\\.lz|tar\\.Z|tbz2|tgz|tar|zip";

# Internal modules
my $MODULES_DIR = get_Modules();
push(@INC, dirname($MODULES_DIR));

my $CTAGS = "ctags";
my $CMAKE = "cmake";

my ($Help, $DumpVersion, $Get, $Build, $Rebuild, $OutputProfile,
$TargetVersion, $LimitOps, $PublicSymbols);

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
Copyright (C) 2015 Andrey Ponomarenko's ABI Laboratory
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
  "public-symbols!" => \$PublicSymbols
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
  
  -public-symbols
      Re-generate lists of public symbols and types.
";

# Global
my $Profile;
my $DB;
my $TARGET_LIB;

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
        while($Info=~s/\"(\w+)\"\s*:\s*([^,\[]+?)\s*(\,|\Z)//)
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
    
    if(-d $CurRepo)
    {
        chdir($CurRepo);
        
        if($Git)
        {
            printMsg("INFO", "Updating source code in repository");
            system("git pull");
        }
        elsif($Svn)
        {
            printMsg("INFO", "Updating source code in repository");
            system("svn update");
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
    
    if(not check_Cmd("wget"))
    {
        printMsg("ERROR", "can't find \"wget\"");
        return;
    }
    
    my @Links = getLinks($SourceUrl);
    my @Pages = getPages(@Links);
    
    # One step into directory tree
    foreach my $Page (@Pages)
    {
        foreach my $Link (getLinks($Page))
        {
            push(@Links, $Link);
        }
    }
    
    my $Packages = getPackages(@Links);
    my $Total = 0;
    
    foreach my $V (sort {cmpVersions($b, $a)} keys(%{$Packages}))
    {
        $Total += getPackage($Packages->{$V}{"Url"}, $Packages->{$V}{"Pkg"}, $V);
        
        if(defined $LimitOps)
        {
            if($Total>=$LimitOps)
            {
                last;
            }
        }
    }
    
    if(not $Total) {
        printMsg("INFO", "No new packages found");
    }
}

sub getPackage($$$)
{
    my ($Link, $P, $V) = @_;
    
    if(defined $DB->{"Source"}{$V})
    { # already downloaded
        return 0;
    }
    
    my $Dir = $REPO."/".$TARGET_LIB."/".$V;
    
    if(not -e $Dir) {
        mkpath($Dir);
    }
    
    my $To = $Dir."/".$P;
    if(-f $To) {
        return 0;
    }
    
    printMsg("INFO", "Downloading package \'$P\'");
    
    my $Pid = fork();
    unless($Pid)
    { # child
        my $Cmd = "wget --no-check-certificate \"$Link\" --connect-timeout=5 --tries=1 --output-document=\"$To\" 2>&1"; # -U ''
        
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
    
    if($Log=~/\[text\/html\]/)
    {
        rmtree($Dir);
        return 0;
    }
    elsif($R or not -f $To or not -s $To)
    {
        rmtree($Dir);
        printMsg("ERROR", "can't access \'$Link\'\n");
        return 0;
    }
    
    $DB->{"Source"}{$V} = $To;
    
    return 1;
}

sub readPage($)
{
    my $Page = $_[0];
    
    my $To = $TMP_DIR."/page.html";
    unlink($To);
    
    if($Page=~/\Aftp:.+[^\/]\Z/
    and getFilename($Page)!~/\./)
    { # wget for ftp
      # tail "/" should be added
        $Page .= "/";
    }
    
    my $Cmd = "wget --no-check-certificate \"$Page\"";
    #$Cmd .= " -U ''";
    $Cmd .= " --no-remove-listing";
    $Cmd .= " --quiet";
    $Cmd .= " --connect-timeout=$CONNECT_TIMEOUT";
    $Cmd .= " --tries=$ACCESS_TRIES --output-document=\"$To\"";
    
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
    
    my $Res = readFile($TMP_DIR."/result");
    
    if(not $Res) {
        return $To;
    }
    
    printMsg("ERROR", "can't access page \'$Page\'");
    return "";
}

sub getPackages(@)
{
    my %Res = ();
    
    foreach my $Link (sort @_)
    {
        if($Link=~/(\A|\/)(\Q$TARGET_LIB\E[_\-]*([^\/"'<>+%]+?)\.($PKG_EXT))([\/\?]|\Z)/i)
        {
            my ($P, $V) = ($2, $3);
            
            if(defined $Res{$V}) {
                next;
            }
            
            if($V=~/mingw|msvc/i) {
                next;
            }
            
            if(getVersionType($V) eq "unknown") {
                next;
            }
            
            $Res{$V}{"Url"} = $Link;
            $Res{$V}{"Pkg"} = $P;
        }
        elsif($Link=~/archive\/v?([\d\.\-\_]+([ab]\d*|rc\d*|))\.(tar\.gz)/i)
        { # github
            my $V = $1;
            
            $Res{$V}{"Url"} = $Link;
            $Res{$V}{"Pkg"} = $TARGET_LIB."-".$V.".".$3;
        }
    }
    
    return \%Res;
}

sub getPages(@)
{
    my @Res = ();
    
    foreach my $Link (@_)
    {
        if($Link!~/\/\Z/ and $Link!~/\A\/\d[\d\.\-]*\Z/)
        {
            next;
        }
        
        push(@Res, $Link);
    }
    
    return @Res;
}

sub getLinks($)
{
    my $Page = $_[0];
    my $To = readPage($Page);
    
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
            $Links2{linkSum($Page, $2)} = 1;
        }
        while($Line=~s/((ftp|http|https):\/\/[^"'<>\s]+?)([\s"']|\Z)//i) {
            $Links3{$1} = 1;
        }
        while($Line=~s/["']([^"'<>\s]+\.($PKG_EXT))["']//i) {
            $Links4{linkSum($Page, $1)} = 1;
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
        
        $Link=~s/\?.+\Z//g;
        $Link=~s/\%2D/-/g;
        $Link=~s/[\/]{2,}\Z/\//g;
        
        if($Link=~/\A(\Q$Page\E|\Q$SiteAddr\E)[\/]*\Z/) {
            next;
        }
        
        if(getSiteAddr($Link) ne getSiteAddr($Page)) {
            next;
        }
        
        if(not getSiteProtocol($Link)) {
            $Link = $SiteProtocol.$Link;
        }
        
        if($Link=~/http:\/\/sourceforge.net\/projects\/(\w+)\/files\/(.+)\/download\Z/)
        { # fix for SF
            $Link = "https://sourceforge.net/projects/$1/files/$2/download?use_mirror=autoselect";
        }
        
        $Link=~s/\%2b/\+/g;
        
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
            if($Link=~/\Q$Url\E/) {
                return 1;
            }
        }
    }
    
    return 0;
}

sub linkSum($$)
{
    my ($Page, $Path) = @_;
    
    $Path=~s/\A\.\///g;
    $Page=~s/\?.+?\Z//g;
    
    if(index($Path, "/")==-1 and $Page=~/\/\Z/)
    {
        return $Page.$Path;
    }
    elsif(index($Path, "/")==0)
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
    
    $Page=~s/\/\Z//g;
    return $Page."/".$Path;
}

sub buildVersions()
{
    if(not defined $DB->{"Source"})
    {
        printMsg("INFO", "Nothing to build");
        return;
    }
    
    my @Versions = keys(%{$DB->{"Source"}});
    @Versions = naturalSequence(@Versions);
    
    @Versions = reverse(@Versions);
    
    my $NumOp = 0;
    my $Built = 0;
    
    foreach my $V (@Versions)
    {
        if(defined $TargetVersion)
        {
            if($TargetVersion ne $V) {
                next;
            }
        }
        
        $NumOp += 1;
        $Built += buildPackage($DB->{"Source"}{$V}, $V);
        
        if(defined $LimitOps)
        {
            if($NumOp>=$LimitOps)
            {
                last;
            }
        }
    }
    
    if(not $Built)
    {
        printMsg("INFO", "Nothing to build");
        return;
    }
}

sub detectPublic($)
{
    my $V = $_[0];
    
    printMsg("INFO", "Detecting public symbols and types in $V");
    
    if(not check_Cmd($CTAGS))
    {
        printMsg("ERROR", "can't find \"$CTAGS\"");
        return;
    }
    
    my $Output_S = $PUBLIC_SYMBOLS."/".$TARGET_LIB."/".$V."/list";
    my $Output_T = $PUBLIC_TYPES."/".$TARGET_LIB."/".$V."/list";
    
    my $Installed = $DB->{"Installed"}{$V};
    my %Public_S = ();
    my %Public_T = ();
    
    foreach my $Path (findFiles($Installed, "f"))
    {
        if(isHeader($Path))
        {
            my $RPath = $Path;
            $RPath=~s/\A\Q$Installed\E\/?//g;
            
            my $IgnoreTags = "";
            
            if(-f $MODULES_DIR."/ignore.tags") {
                $IgnoreTags = "-I \@$MODULES_DIR/ignore.tags";
            }
            
            my $List_S = `$CTAGS -x --c-kinds=pfxv $IgnoreTags \"$Path\"`; # NOTE: short names in C++
            foreach my $Line (split(/\n/, $List_S))
            {
                if($Line=~/\A(\w+)/)
                {
                    $Public_S{$RPath}{$1} = 1;
                }
            }
            
            my $List_T = `$CTAGS -x --c-kinds=csugt $IgnoreTags \"$Path\"`;
            foreach my $Line (split(/\n/, $List_T))
            {
                if($Line=~/\A(\w+)/)
                {
                    $Public_T{$RPath}{$1} = 1;
                }
            }
        }
    }
    
    writeFile($Output_S, Dumper(\%Public_S));
    $DB->{"PublicSymbols"}{$V} = $Output_S;
    
    writeFile($Output_T, Dumper(\%Public_T));
    $DB->{"PublicTypes"}{$V} = $Output_T;
}

sub createProfile($)
{
    my $To = $_[0];
    
    if(not defined $DB->{"Installed"})
    {
        printMsg("INFO", "No installed versions of the library to create profile");
        return;
    }
    
    my @ProfileKeys = ("Name", "Title", "SourceUrl", "SkipUrl", "Git", "Svn", "Doc", "SkipSymbols", "Maintainer", "MaintainerUrl", "BuildScript", "Configure", "SkipObjects");
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
    @Versions = naturalSequence(@Versions);
    
    if(defined $Profile->{"Versions"})
    { # save order of versions in the profile if manually edited
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
                    if(cmpVersions($V2, $V1)==-1)
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
                        if(cmpVersions($V2, $V1)==1)
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
        {
            if($V eq "current") {
                $N_Info->{"Changelog"} = "On";
            }
            else {
                $N_Info->{"Changelog"} = "Off";
            }
        }
        $N_Info->{"PkgDiff"} = "Off";
        $N_Info->{"HeadersDiff"} = "On";
        
        # Non-free high detailed analysis
        $N_Info->{"ABIView"} = "Off";
        $N_Info->{"ABIDiff"} = "Off";
        
        $N_Info->{"PublicSymbols"} = $DB->{"PublicSymbols"}{$V};
        $N_Info->{"PublicTypes"} = $DB->{"PublicTypes"}{$V};
        
        if(defined $Profile->{"Versions"} and defined $Profile->{"Versions"}{$V})
        {
            my $O_Info = $Profile->{"Versions"}{$V};
            
            foreach my $K (sort keys(%{$O_Info}))
            {
                if($K ne "Pos")
                {
                    if(defined $O_Info->{$K}) {
                        $N_Info->{$K} = $O_Info->{$K};
                    }
                }
            }
        }
        
        my @VersionKeys = ("Number", "Installed", "Source", "Changelog", "HeadersDiff", "PkgDiff", "ABIView", "ABIDiff", "PublicSymbols", "PublicTypes", "Deleted");
        
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
    
    foreach my $Name ("ChangeLog", "Changelog", "NEWS")
    {
        if(-f $Dir."/".$Name)
        {
            return $Name;
        }
    }
    
    return "None";
}

sub autoBuild($$)
{
    my ($To, $LogDir) = @_;
    
    my $LogDir_R = $LogDir;
    $LogDir_R=~s/\A$ORIG_DIR\///;
    
    my @Files = listDir(".");
    
    my ($CMake, $Autotools, $Scons) = (0, 0, 0);
    
    my ($Configure, $Autogen) = (0, 0);
    
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
        elsif($File eq "SConstruct") {
            $Scons = 1;
        }
    }
    
    if($Autotools)
    {
        if(not $Configure)
        { # try to generate configure script
            if($Autogen)
            {
                my $Cmd_A = "sh autogen.sh";
                $Cmd_A .= " >\"$LogDir/autogen\" 2>&1";
                
                qx/$Cmd_A/;
                
                if(not -f "configure")
                {
                    printMsg("ERROR", "failed to 'autogen'");
                    printMsg("ERROR", "see error log in '$LogDir_R/autogen'");
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
    $ConfigOptions=~s/{INSTALL_TO}/$To/g;
    
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
        $Cmd_C .= " -DCMAKE_C_FLAGS=\"-g -Og -w\" -DCMAKE_CXX_FLAGS=\"-g -Og -w\"";
        
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
        $Cmd_C .= " CXXFLAGS=\"-g -Og -w\" CFLAGS=\"-g -Og -w\"";
        
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
    else
    {
        printMsg("ERROR", "unknown build system, please set \"BuildScript\" in the profile");
        return 0;
    }
    
    if($CMake or $Autotools)
    {
        my $Cmd_M = "make >$LogDir/make 2>&1";
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
    
    if(not listDir($To))
    {
        return 0;
    }
    
    return 1;
}

sub buildPackage($$)
{
    my ($Package, $V) = @_;
    
    if(not $Rebuild)
    {
        if(defined $DB->{"Installed"}{$V})
        {
            return 0;
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
    
    my $LogDir = $BUILD_LOGS."/".$TARGET_LIB."/".$V;
    rmtree($LogDir);
    mkpath($LogDir);
    
    $LogDir = abs_path($LogDir);
    
    my $InstallDir = $INSTALLED."/".$TARGET_LIB."/".$V;
    rmtree($InstallDir);
    mkpath($InstallDir);
    
    my $InstallDir_A = abs_path($InstallDir);
    
    my $BuildDir = $TMP_DIR."/build/";
    mkpath($BuildDir);
    
    if($V eq "current")
    {
        my $Cmd_E = "cp -fr $Package/* $BuildDir";
        qx/$Cmd_E/; # execute
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
    
    if($V ne "current")
    {
        my $Found = findChangelog(".");
        
        if($Found ne "None") {
            $DB->{"Changelog"}{$V} = $Found;
        }
        else {
            $DB->{"Changelog"}{$V} = "Off";
        }
    }
    
    if(defined $BuildScript)
    {
        my $Cmd_I = "INSTALL_TO=\"$InstallDir_A\" sh \"".$BuildScript."\"";
        $Cmd_I .= " >\"$LogDir/build\" 2>&1";
        
        qx/$Cmd_I/; # execute
        
        if($? or not listDir($InstallDir_A))
        {
            delete($DB->{"Installed"}{$V});
        }
        else {
            $DB->{"Installed"}{$V} = $InstallDir;
        }
    }
    else
    {
        if(autoBuild($InstallDir_A, $LogDir)) {
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
        detectPublic($V);
        
        rmtree($InstallDir."/share");
        rmtree($InstallDir."/bin");
    }
    else
    {
        printMsg("ERROR", "failed to build");
        rmtree($InstallDir);
    }
    
    return 1;
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
    
    my $Public_S = $PUBLIC_SYMBOLS."/".$TARGET_LIB;
    foreach my $V (listDir($Public_S))
    {
        if(-f $Public_S."/".$V."/list")
        {
            $DB->{"PublicSymbols"}{$V} = $Public_S."/".$V."/list";
        }
    }
    
    my $Public_T = $PUBLIC_TYPES."/".$TARGET_LIB;
    foreach my $V (listDir($Public_T))
    {
        if(-f $Public_T."/".$V."/list")
        {
            $DB->{"PublicTypes"}{$V} = $Public_T."/".$V."/list";
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
    
    foreach my $V (keys(%{$DB->{"PublicSymbols"}}))
    {
        if(not -f $DB->{"PublicSymbols"}{$V})
        {
            delete($DB->{"PublicSymbols"}{$V});
        }
    }
    
    foreach my $V (keys(%{$DB->{"PublicTypes"}}))
    {
        if(not -f $DB->{"PublicTypes"}{$V})
        {
            delete($DB->{"PublicTypes"}{$V});
        }
    }
}

sub safeExit()
{
    chdir($ORIG_DIR);
    
    printMsg("INFO", "\nReceived SIGINT");
    printMsg("INFO", "Exiting");
    
    writeDB($DB_PATH);
    exit(1);
}

sub scenario()
{
    $Data::Dumper::Sortkeys = 1;
    
    $SIG{INT} = \&safeExit;
    
    if($Rebuild) {
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
    
    if($PublicSymbols)
    {
        foreach my $V (sort {cmpVersions($b, $a)} keys(%{$DB->{"Installed"}}))
        {
            if(defined $TargetVersion)
            {
                if($TargetVersion ne $V) {
                    next;
                }
            }
            detectPublic($V);
        }
    }
    
    writeDB($DB_PATH);
    
    my $Output = $OutputProfile;
    if(not $Output) {
        $Output = $Profile_Path;
    }
    
    createProfile($Output);
}

scenario();
