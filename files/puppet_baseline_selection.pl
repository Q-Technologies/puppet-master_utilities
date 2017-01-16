#!/usr/bin/perl

# This script is for moving nodes into and out of Puppet groups that control which
# baseline version the systems should receive.
#
# It makes the following assumptions:
#   * The parent group is 'All Nodes' - do not change this group!
#
# Author: Matthew Mallard
# Website: www.q-technologies.com.au
# Date: 26th August 2016

use strict;
use 5.10.0;
use JSON;
use vars qw/$puppet_config/;
BEGIN { 
  local $/;
  open( my $fh, '<', "/usr/local/etc/puppet_perl_config.json" );
  my $json_text   = <$fh>;
  $puppet_config = decode_json( $json_text )or die $!;    
}
use lib @{$puppet_config->{locallibs}};
use Data::Dumper;
use String::CamelCase qw( camelize );
use Puppet::Classify;
use Puppet::DB;
use Getopt::Std;
use Log::MixedColor;

# Command line argument processing
our( $opt_a, $opt_g, $opt_h, $opt_v, $opt_d, $opt_f );
getopts('a:g:hvdf');
$Getopt::Std::STANDARD_HELP_VERSION = 1;

# Set up logging
my $log = Log::MixedColor->new( verbose => $opt_v, debug => $opt_d );

# Read in baseline config
open( my $fh, '<', "/usr/local/etc/baseline_selection_config.json" );
my $baseline_config = decode_json( <$fh> )or die $!;    

# Globals
my $nodes;
my $parent_id;
my $class = $baseline_config->{repo_class};
my $parent = "All Nodes";
my $baseline_group_prefix = $baseline_config->{baseline_group_prefix}." : ";
my $baseline_group_parent = $baseline_group_prefix."Default";
my $def_baseline_date = $baseline_config->{def_baseline_date};
my $environment = $baseline_config->{environment};
my @actions = qw(init_baseline empty_group add_to_group list_group list_groups add_group purge_old_nodes remove_from_group remove_group );

my $classify = Puppet::Classify->new( 
                                      cert_name   => $puppet_config->{puppet_classify_cert},
                                      api_server  => $puppet_config->{puppet_classify_host},
                                      api_port    => $puppet_config->{puppet_classify_port},
                                    );

my $puppetdb = Puppet::DB->new(       
                                      server_name => $puppet_config->{puppetdb_host},
                                      server_port => $puppet_config->{puppetdb_port},
                                    );
$puppetdb->refresh("nodes", {});
my $puppetdb_nodes = $puppetdb->results;

# Preliminary input checks
if( $opt_h ){
    say "\n$0 -a action -g group [-f] [-v] [-d] node1 [node2] [node3]";
    say "\nThe following actions are supported:";
    for( @actions ){
        say "\t".$_;
    }
    say;
    say "'group' is the unique baseline identifier, usually the date, e.g. 2017-01-13";
    say;
    say "-f is force. Sometimes required as a layer of safety";
    say "-v is to show verbose messages";
    say "-d is to show debug messages";
    say;
    exit;
}
my $action_re = join("|", @actions);
$action_re = qr/$action_re/;
$log->fatal_err( "You need to specify the script action: -a ".join(" | ", @actions ) ) if not $opt_a =~ $action_re;
$log->fatal_err( "You need to specify the group to act upon (-g)" ) if not $opt_g and $opt_a !~ /init_baseline|list_groups|purge_old_nodes/;

# Mainline
my $groups = $classify->get_groups();
#say Dumper( $groups );

my $baseline_parent_id = $classify->get_group_id( $baseline_group_parent );
$log->fatal_err( "Could not find the ID of the '$baseline_group_parent' group which is required.\n  Perhaps you need to run the 'init_baseline' action." ) if not $baseline_group_parent and $opt_a ne "init_baseline";

# See if we need to add the prefix to the group
$opt_g = $baseline_group_prefix.$opt_g if( $opt_g !~ /^$baseline_group_prefix/ );

if( $opt_a eq "empty_group" ){
    empty_group( $opt_g );
} elsif( $opt_a eq "add_to_group" ){
    $log->fatal_err( "You need to specify the nodes to add to the group" ) if not @ARGV;
    add_to_group( $opt_g, \@ARGV );
} elsif( $opt_a eq "remove_from_group" ){
    $log->fatal_err( "You need to specify the nodes to remove from the group" ) if not @ARGV;
    remove_from_group( $opt_g, \@ARGV );
} elsif( $opt_a eq "add_group" ){
    add_group( $baseline_parent_id, $opt_g, \@ARGV);
} elsif( $opt_a eq "purge_old_nodes" ){
    purge_old_nodes( $baseline_parent_id );
} elsif( $opt_a eq "remove_group" ){
    try_remove_group( $opt_g );
} elsif( $opt_a eq "list_group" ){
    list_group( $opt_g );
} elsif( $opt_a eq "list_groups" ){
    list_groups();
} elsif( $opt_a eq "init_baseline" ){
    my $parent_id = $classify->get_group_id( $parent );
    $log->fatal_err( "Could not find the ID of the '$parent' group which is required.\n  Did someone delete this group accidently?." ) if not $parent_id;
    init_baseline( $parent_id, $baseline_group_parent );
} else {
    $log->fatal_err( "The action: '$opt_a' is not known to the script" );
    exit 1;
}

sub init_baseline {
    my $parent_id = shift;
    my $name = shift;

    my $rule = $baseline_config->{baseline_match_nodes};
    my $classes = { $class => {} };
    my $group_def = { name => $name,
                      environment => $environment,
                      description => "Parent and default group for nodes being assigned to an OS Baseline (SOE release)",
                      parent => $parent_id,
                      rule => $rule,
                      classes => $classes,
                      variables => { baseline_date => $def_baseline_date },
                    };
    add_group_safe( $name, $group_def );

}

sub purge_old_nodes {
    my $parent_id = shift;

    my $child_groups;
    # this step will die if no children exist
    eval { $child_groups = $classify->get_child_groups( $parent_id ) };
    #say $@ if $@;
    if( not $child_groups ){
        $log->debug_msg( "There are no children groups" );
        return;
    }
    my $children = $child_groups->[0]{children};
    for my $child ( @$children ){
        my $rule = $child->{rule};
        next if not $rule;
        my $pinned = hosts_from_pinned_rule( $rule );
        my @not_found;
        for my $pn ( @$pinned ){
            push @not_found, $pn if not in_puppetdb( $pn);
        }
        remove_from_group( $child, \@not_found );
    }
}

sub empty_group {
    # Remove pinned nodes only - leave other rules in place
    my $group = shift;
    my $rule = $classify->get_group_rule( $group );
    my $pinned = hosts_from_pinned_rule( $rule );
    remove_from_group( $group, $pinned );
}

sub in_puppetdb {
    my $name = shift;
    my $found = 0;

    for my $node ( @$puppetdb_nodes ){
        if( $name eq $node->{certname} ) { $found = 1; last }
    }
    return $found;
}

sub remove_from_group {
    my $group = shift;
    my $nodes = shift;
    my $gid;
    # Detect whether we were passed the group name or the assoc array of the group
    if( ref($group) eq "HASH" ){
        $gid = $group->{id};
        $group = $group->{name};
    } else {
        $log->debug_msg( "Checking whether ".$log->quote($group)." exists" );
        $gid = $classify->get_group_id( $group );
        $log->fatal_err( "Could not find the specified group (".$log->quote($group).") are you sure it's an OS Baseline (SOE) group?" ) if not $gid;
    }

    my @deleted;
    $log->debug_msg( "Fetching the existing rule for ".$log->quote($group) );
    my $rule = $classify->get_group_rule( $group );
    if( $rule ){
        if( $rule->[0] eq 'or' ){
            my $max = @$rule;
            for( my $i = 1; $i < $max; $i++){
                next if $rule->[$i][0] ne '=' and $rule->[$i][1] ne 'name';
                for my $node ( @$nodes ){
                    if( $node eq $rule->[$i][2] ){
                        splice @$rule, $i, 1;
                        $i--; $max--;
                        $log->debug_msg( $log->quote($node)." was deleted from the rule" );
                        push @deleted, $node;
                        next;
                    }
                }
            }
            $rule = undef if @$rule == 1;
        } else {
            $log->debug_msg( "The specified rule does not seem to have pinned nodes" );
        }
    } else {
        $log->info_msg( "The specified rule for ".$log->quote($group)." does not exist - nothing to do" );
        return;
    }

    if( @deleted > 0 ){
        $log->info_msg( "Updating the group: ".$log->quote($group) );
        $classify->update_group_rule( $gid, $rule );
    } else {
        $log->info_msg( "None of the specified nodes were found in ".$log->quote($group) );
    }
}

sub hosts_from_pinned_rule {
    my $rule = shift;
    return if not $rule;
    my @rule = @$rule;
    my @nodes;
    if( shift( @rule ) eq 'or' ){
        for my $rule ( @rule ) {
            push @nodes, $rule->[2] if( $rule->[0] eq '=' and $rule->[1] eq 'name' );
        }
    } else {
        $log->debug_msg( "The specified rule does not seem to have pinned nodes" );
    }
    return \@nodes;
}

sub add_to_group {
    my $group = shift;
    my $nodes = shift;

    $log->debug_msg( "Checking whether ".$log->quote($group)." exists" );
    my $gid = $classify->get_group_id( $group );
    $log->fatal_err( "Could not find the specified group (".$log->quote($group).") are you sure it's an OS Baseline (SOE) group?" ) if not $gid;

    $log->debug_msg( "Fetching the existing rule for ".$log->quote($group) );
    my $old_rule = $classify->get_group_rule( $group );

    my @host_matches;
    for my $node( @$nodes ){
        if( in_puppetdb( $node ) ){
            $log->debug_msg( $log->quote($node)." will be added to the rule unless it is already present" );
            push @host_matches, [ '=', "name", $node ];
        } else {
            $log->debug_msg( $log->quote($node)." will not be added to the rule as it is not found in the PuppetDB" );
        }
    }
    # no point continuing if there are no valid hosts to add
    return if @host_matches == 0;

    my $rule;
    if( $old_rule ){
        if( $old_rule->[0] eq 'or' ){
            for my $nhost ( @host_matches ){
                my $found = 0;
                for my $ohost ( @$old_rule ){
                    next if ref($ohost) ne 'ARRAY';
                    if( $nhost->[2] eq $ohost->[2] ){
                        $found = 1;
                    }
                }
                $log->debug_msg( $log->quote($nhost->[2])." was already present, ignoring" ) if $found;
                push @$old_rule, $nhost if not $found;
            }
            $rule = $old_rule;
        } else {
            $rule = [ 'or', $old_rule, @host_matches ];
        }
    } else {
        $rule = [ 'or', @host_matches ];
    }

    $log->info_msg( "Updating the group: ".$log->quote($group) );
    $classify->update_group_rule( $gid, $rule );
}

sub add_group {
    my $parent_id = shift;
    my $name = shift;
    my $nodes = shift;

    $log->fatal_err( "The group name (".$log->quote($name).") must match YYYY-MM-DD" ) if $name !~ /^$baseline_group_prefix(\d{4}-\d\d-\d\d)$/;
    my $date = $1;

    my $rule = [];
    my $classes = { $class => {} };
    my $group_def = { name => $name,
                      environment => $environment,
                      description => "Group to assign nodes to the OS Baseline (SOE release): $date",
                      parent => $parent_id,
                      #rule => $rule,
                      classes => $classes,
                      variables => { baseline_date => $date },
                    };
    add_group_safe( $name, $group_def );
    add_to_group( $name, $nodes ) if @$nodes > 0;

}
sub add_group_safe {
    my $name = shift;
    my $group_def = shift;
    
    my $gid = $classify->get_group_id( $name );
    if( ( $gid and $opt_f and try_remove_group( $name )) or not $gid ){
        $log->info_msg( "Creating the group: ".$log->quote($name) );
        $classify->create_group( $group_def );
    } elsif( $gid ){
        $log->fatal_err( "The group ".$log->quote($name)." already exists - it will only be redefined if you specify '-f'" );
    }

}

sub try_remove_group {
    my $name = shift;
    my $gid = $classify->get_group_id( $name );
    if( not $gid ) { 
        $log->info_msg( $log->quote($name)." doesn't exist - nothing to delete" );
        return;
    }
    my $child_groups;
    # this step will die if no children exist
    eval { $child_groups = $classify->get_child_groups( $gid ) };
    #say $@ if $@;
    my $children = $child_groups->[0]{children};
    if( $children ){
        $log->fatal_err( "The group ".$log->quote($name)." has children - it will not be removed even if you specify '-f'" );
    } else {
        $log->info_msg( "Deleting ".$log->quote($name)." as 'force' was specified" ) if $opt_f;
        $log->info_msg( "Deleting ".$log->quote($name)." as 'remove_group' was invocated directly" ) if not $opt_f;
        $classify->delete_group( $gid );
        return 1;
    }
}

sub list_group {
    my $group = shift;
    my $rule = $classify->get_group_rule( $group );
    my $pinned = hosts_from_pinned_rule( $rule );
    for( @$pinned ){
        say $_;
    }
}

sub list_groups {
    my $baseline_groups = $classify->get_groups_match( qr/^$baseline_group_prefix\d{4}-\d\d-\d\d/ );
    for my $group ( @$baseline_groups ){
        say $group->{name};
    }
}
