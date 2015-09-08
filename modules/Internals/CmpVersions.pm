##################################################################
# Module for ABI Monitor to compare library versions
#
# Copyright (C) 2015 Andrey Ponomarenko's ABI Laboratory
#
# Written by Andrey Ponomarenko
#
##################################################################
use strict;

sub cmpVersions($$)
{
    my ($A, $B) = @_;
    
    if($A eq "" and $B eq "") {
        return 0;
    }
    elsif($A eq ""
    or $B eq "current") {
        return -1;
    }
    elsif($B eq ""
    or $A eq "current") {
        return 1;
    }
    
    # speed up
    if($A=~/\A(\d+)\./)
    {
        my $A1 = $1;
        if($B=~/\A(\d+)\./)
        {
            my $B1 = $1;
            
            if($A1>$B1) {
                return 1;
            }
            elsif($A1<$B1) {
                return -1;
            }
        }
    }
    
    # speed up
    if($A=~/\A[\d\.]+\Z/ and $B=~/\A[\d\.]+\Z/)
    {
        my @N1 = split(/\./, $A);
        my @N2 = split(/\./, $B);
        
        foreach (0 .. $#N1)
        {
            if($_>$#N2) {
                return 1;
            }
            if($N1[$_]>$N2[$_]) {
                return 1;
            }
            elsif($N1[$_]<$N2[$_]) {
                return -1;
            }
        }
    }
    
    $A=~s/(\d)([a-z])/$1.$2/ig;
    $B=~s/(\d)([a-z])/$1.$2/ig;
    
    $A=~s/[_~-]/./g;
    $B=~s/[_~-]/./g;
    
    $A=~s/\A[.]+//g;
    $B=~s/\A[.]+//g;
    
    $A=~s/\A[0]+([1-9]\d*)\Z/$1/g;
    $B=~s/\A[0]+([1-9]\d*)\Z/$1/g;
    
    $A=~s/\A[0]+\Z/0/g;
    $B=~s/\A[0]+\Z/0/g;
    
    my $PS1 = index($A, ".");
    my $PS2 = index($B, ".");
    
    if($PS1==-1 and $PS2==-1) {
        return mixedCmp($_[0], $_[1]);
    }
    elsif($PS1==-1) {
        return cmpVersions($A.".0", $B);
    }
    elsif($PS2==-1) {
        return cmpVersions($A, $B.".0");
    }
    else
    {
        my ($P1, $P2) = ();
        if($A=~s/\A([^\.]+)\.//o) {
            $P1 = $1;
        }
        if($B=~s/\A([^\.]+)\.//o) {
            $P2 = $1;
        }
        
        if(my $CmpPartRes = mixedCmp($P1, $P2))
        { # compare first parts
            return $CmpPartRes;
        }
        else
        { # compare other parts
            return cmpVersions($A, $B);
        }
    }
}

sub mixedCmp($$)
{
    my ($A, $B) = @_;
    if($A eq $B) {
        return 0;
    }
    
    while($A ne ""
    and $B ne "")
    {
        my $A_Token = get_Token($A);
        my $B_Token = get_Token($B);
        
        my $CmpRes = tokensCmp($A_Token, $B_Token);
        if(not defined $CmpRes)
        { # safety lock
            return 0;
        }
        elsif($CmpRes != 0) {
            return $CmpRes;
        }
        else
        {
            $A=~s/\A\Q$A_Token\E//g;
            $B=~s/\A\Q$B_Token\E//g;
        }
    }
    
    if($A ne ""
    or $A eq "0") {
        return 1;
    }
    elsif($B ne ""
    or $B eq "0") {
        return -1;
    }
    
    return 0;
}

sub get_Token($)
{
    if($_[0]=~/\A(\d+)[a-z]/i) {
        return $1;
    }
    elsif($_[0]=~/\A([a-z]+)\d/i) {
        return $1;
    }
    elsif($_[0]=~/\A(\d+)[^a-z0-9]/i) {
        return $1;
    }
    elsif($_[0]=~/\A([a-z]+)[^a-z0-9]/i) {
        return $1;
    }
    elsif($_[0]=~/\A([^a-z0-9]+)/i) {
        return $1;
    }
    
    return $_[0];
}

sub tokensCmp($$)
{
    my ($A, $B) = @_;
    
    if($A eq $B) {
        return 0;
    }
    elsif($A=~/\A[^a-z0-9]+\Z/i
    and $B=~/\A[^a-z0-9]+\Z/i) {
        return 0;
    }
    elsif($A=~/\A[a-z]+\Z/i
    and $B=~/\A[a-z]+\Z/i) {
        return symbolCmp(lc($A), lc($B));
    }
    elsif($A=~/\A\d+\Z/
    and $B=~/\A\d+\Z/) {
        return int($A)<=>int($B);
    }
    elsif($A=~/\A[a-z]+\Z/i
    and $B=~/\A\d+\Z/) {
        return -1;
    }
    elsif($A=~/\A\d+\Z/
    and $B=~/\A[a-z]+\Z/i) {
        return 1;
    }
    elsif($A and $B eq "") {
        return 1;
    }
    elsif($B and $A eq "") {
        return -1;
    }
    
    return undef;
}

sub symbolCmp($$)
{
    my ($A, $B) = @_;
    
    if($A gt $B) {
        return 1;
    }
    elsif($A eq $B) {
        return 0;
    }
    
    return -1;
}

sub naturalSequence(@)
{
    my @Releases = ();
    my @Unstables = ();
    my @Previews = ();
    
    foreach my $Version (sort {cmpVersions($a, $b)} @_)
    {
        my $Type = getVersionType($Version);
        
        if($Type eq "unknown"
        or $Version eq "current") {
            next;
        }
        
        if($Type eq "release") {
            push(@Releases, $Version);
        }
        elsif($Type eq "technology-preview") {
            push(@Previews, $Version);
        }
        else {
            push(@Unstables, $Version);
        }
    }
    
    my ($LastRelease, $LastUnstable, $LastPreview) = ();
    
    if(@Releases) {
        $LastRelease = $Releases[$#Releases];
    }
    
    if(@Unstables) {
        $LastUnstable = $Unstables[$#Unstables];
    }
    
    if(@Previews) {
        $LastPreview = $Previews[$#Previews];
    }
    
    my @NaturalSequence = @Releases;
    
    if(not $LastUnstable and $LastPreview) {
        $LastUnstable = $LastPreview;
    }
    
    if($LastUnstable)
    {
        if($LastRelease)
        {
            if(cmpVersions($LastUnstable, $LastRelease)==1) {
                push(@NaturalSequence, $LastUnstable);
            }
        }
        else {
            push(@NaturalSequence, $LastUnstable);
        }
    }
    
    if(grep {$_ eq "current"} @_) {
        push(@NaturalSequence, "current");
    }
    
    return @NaturalSequence;
}

sub getVersionType($)
{
    my $Version = $_[0];
    
    if($Version!~/[a-z]/i) {
        return "release";
    }
    
    my @Words = ();
    while($Version=~s/(\A|[^a-z])([a-z]+)([^a-z]|\Z)/$1$3/i) {
        push(@Words, $2);
    }
    
    my %Type = ();
    foreach my $W (sort @Words)
    {
        if($W=~/\A(final)\Z/i) {
            $Type{"release"}=1;
        }
        elsif($W=~/\A(r|rel|release)\Z/i
        and $Version=~/\b$W\d/) {
            $Type{"release"}=1;
        }
        elsif($W=~/\A(devel|dev|exp)\Z/i) {
            $Type{"devel"}=1;
        }
        elsif($W=~/\A(snapshot|snap|master)\Z/i) {
            $Type{"snapshot"}=1;
        }
        elsif($W=~/\A(alfa|alpha|a)\Z/i) {
            $Type{"alfa"}=1;
        }
        elsif($W=~/\A(tp|preview)\Z/i) {
            $Type{"technology-preview"}=1;
        }
        elsif($W=~/\A(beta|b)\Z/i) {
            $Type{"beta"}=1;
        }
        elsif($W=~/\A(pre)\Z/i) {
            $Type{"pre-release"}=1;
        }
        elsif($W=~/\A(rc|cr)\Z/i) {
            $Type{"release-candidate"}=1;
        }
        elsif($W=~/\A(current)\Z/) {
            $Type{"current"}=1;
        }
        else {
            return "unknown";
        }
    }
    if(my @Types = keys(%Type))
    {
        if($#Types==0) {
            return $Types[0];
        }
    }
    return "unknown";
}

return 1;
