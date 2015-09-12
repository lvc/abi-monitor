##################################################################
# Module for ABI Monitor with basic functions
#
# Copyright (C) 2015 Andrey Ponomarenko's ABI Laboratory
#
# Written by Andrey Ponomarenko
#
##################################################################
use strict;

sub findFiles(@)
{
    my ($Path, $Type) = @_;
    my $Cmd = "find \"$Path\"";
    
    if($Type) {
        $Cmd .= " -type ".$Type;
    }
    
    my @Res = split(/\n/, `$Cmd`);
    return @Res;
}

sub listDir($)
{
    my $Path = $_[0];
    return () if(not $Path);
    opendir(my $DH, $Path);
    return () if(not $DH);
    my @Contents = grep { $_ ne "." && $_ ne ".." } readdir($DH);
    return @Contents;
}

sub listFiles($)
{
    my $Path = $_[0];
    return () if(not $Path);
    
    my @Files = ();
    
    foreach my $F (listDir($Path))
    {
        if(-f $Path."/".$F) {
            push(@Files, $F);
        }
    }
    
    return @Files;
}

sub getFilename($)
{ # much faster than basename() from File::Basename module
    if($_[0] and $_[0]=~/([^\/\\]+)[\/\\]*\Z/) {
        return $1;
    }
    return "";
}

sub getDirname($)
{ # much faster than dirname() from File::Basename module
    if($_[0] and $_[0]=~/\A(.*?)[\/\\]+[^\/\\]*[\/\\]*\Z/) {
        return $1;
    }
    return "";
}

sub readFile($)
{
    my $Path = $_[0];
    return "" if(not $Path or not -f $Path);
    open(FILE, $Path);
    local $/ = undef;
    my $Content = <FILE>;
    close(FILE);
    return $Content;
}

sub writeFile($$)
{
    my ($Path, $Content) = @_;
    return if(not $Path);
    if(my $Dir = dirname($Path)) {
        mkpath($Dir);
    }
    open(FILE, ">", $Path) || die ("can't open file \'$Path\': $!\n");
    print FILE $Content;
    close(FILE);
}

sub getSiteAddr($)
{
    if($_[0]=~/\A([a-z]+\:\/\/|)([^\/]+\.[a-z]+)(:[0-9]+|)(\/|\Z)/i) {
        return $2;
    }
    
    return $_[0];
}

sub getSiteProtocol($)
{
    if($_[0]=~/\A([a-z]+\:\/\/)/i) {
        return $1;
    }
    return "";
}

sub extractPackage($$)
{
    my ($Path, $OutDir) = @_;
    
    if($Path=~/\.(tar\.\w+|tgz|tbz2)\Z/i) {
        return "tar -xf $Path --directory=$OutDir";
    }
    elsif($Path=~/\.zip\Z/i) {
        return "unzip $Path -d $OutDir";
    }
    
    return undef;
}

sub isHeader($)
{
    my $Path = $_[0];
    return ($Path=~/\.(h|hh|hp|hxx|hpp|h\+\+|tcc)\Z/i);
}

sub check_Cmd($)
{
    my $Cmd = $_[0];
    return "" if(not $Cmd);
    
    foreach my $Path (sort {length($a)<=>length($b)} split(/:/, $ENV{"PATH"}))
    {
        if(-x $Path."/".$Cmd) {
            return 1;
        }
    }
    
    return 0;
}

return 1;