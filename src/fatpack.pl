#!/usr/bin/env perl

use strict;
use warnings;

use Getopt::Long;
use File::Basename qw/dirname basename/;
use Storable qw/dclone/;
use Data::Compare;
use Data::Dumper;

my $outdir;
my $truncate = '';
my $inputfile;
my $usage='';
my @whitelist=('io');

GetOptions('output=s' => \$outdir, 'truncate' => \$truncate, 'input=s' => \$inputfile, 'help' => \$usage, 'whitelist=s' => \@whitelist);

@whitelist = uniq(split(/,/, join(',', @whitelist)));
my $whitelisted = join '|', map{ "^" . $_ }  map{quotemeta} sort {length($b)<=>length($a)}@whitelist;
my $whitelistre = qr/($whitelisted)/;

if (   $usage
	|| ((!$outdir)    || (! -d $outdir))
	|| ((!$inputfile) || (! -f $inputfile))) {
	print <<"EOF";
$0 --input <file.lua> --output <directory> [--truncate] [--whitelist <module>,<module>]
	--help      Print this help message
	--input     file to fatpack. Expects all libs to reside in basedir(file)
	--output    output directory for fatpacked files
	--truncate  unconditionally override in outdir (default=false)
	--whitelist modules not to fatpack
EOF
	exit -1;
}

sub uniq {
    my %seen;
    grep !$seen{$_}++, @_;
}

sub slurp {
	my $filename = shift;
	return do {
		local $/;
		open my $file, '<:encoding(UTF-8)', $filename or die "Failed to open file $filename";
		<$file>;
	};
}

sub extractIncludes {
	# get all requires from a given modules
	my $filecontent = shift;

	my @requires = ($filecontent =~ m/require\((.*?)\)/g);
	@requires = map {sanitizeRequire($_)} @requires;

	return \@requires;
}

sub sanitizeRequire {
	my $require = shift;
	# remove all quotes and whitespaces from requires
	$require =~ s/^['"\s]+|['"\s]+$//g;
	return $require;
}

sub fix {
	my $op  = shift;
	my $old = shift;
	my $new = $old;

	do {
		$old = $new;
		$new = dclone($old);
		$new = $op->($new);
	} while (!Compare($old, $new));

	return $new;
}

sub getModule {
	my $includedir = shift;
	my $modulename = shift;

	return slurp("$includedir/$modulename.lua");
}

sub fatpack {
	my $mainmodule = shift;
	my $modules    = shift;

	# split the module in shebang+header and the actual code
	$modules->{$mainmodule} =~ /^(?<head>(#!.*\n|--.*\n)+)(?<tail>(.|\n)*)/;

	my $head = $+{head};
	my $tail = $+{tail};

	# Build the fatpacked script
	my $packed =  $head;

	$packed .= <<"EOF";
	
do
	local _ENV = _ENV
EOF

	foreach my $module (sort keys %{$modules}) {
		next if ($module eq $mainmodule);

		my $effcontent = %{$modules}{$module};
		# Strip the shebang
		$effcontent =~ s/^#!.*\n//g;

		$packed .= <<"EOF";
	package.preload["$module"] = function( ... )
		local arg = _G.arg;
		_ENV = _ENV;

		$effcontent
	end
EOF
	}

	$packed .= "\nend\n";

	$packed .= $tail;

	return $packed;
}

sub unslurp {
	my $dst = shift;
	my $content = shift;

	if (-f $dst && !$truncate) {
		print STDERR "$dst already exists and --truncate was not specified\n";
		exit(1);
	}

	open(my $fh, '>', $dst) or die "Could not open file '$dst'";
	print $fh $content;
	close $fh;
}

sub main {
	my $includedir = dirname($inputfile);

	my $inputmodule = basename($inputfile, ".lua");

	my $modules = {
		$inputmodule => getModule($includedir, $inputmodule),
	};

	my $process = sub {
		my $modules = shift;

		my @new = ();

		# gather all includes in all modules
		while(my ($key, $value) = each %{$modules}) {
			my $extracted = extractIncludes($value);
			push @new, @$extracted;
		}

		# Add all new modules and their contents
		foreach my $module (@new) {
			if (! exists $modules->{$module} && $module !~ $whitelistre) {
				$modules->{$module} = getModule($includedir, $module);
			}
		}

		return $modules;
	};

	$modules = fix($process, $modules);

	my $fat = fatpack($inputmodule, $modules);

	unslurp("$outdir/$inputmodule.lua", $fat);
}

main();
