# Declare our package
package Filesys::Virtual::Async::inMemory;
use strict; use warnings;

# Initialize our version
use vars qw( $VERSION );
$VERSION = '0.01';

# Set our parent
use base 'Filesys::Virtual::Async';

# get some system constants
use Errno qw( :POSIX );		# ENOENT EISDIR etc
use Fcntl qw( :DEFAULT :mode :seek );	# S_IFREG S_IFDIR, O_SYNC O_LARGEFILE etc

# get some handy stuff
use File::Spec;

# create in-memory FHs
use IO::Scalar;

# Set some constants
BEGIN {
	if ( ! defined &DEBUG ) { *DEBUG = sub () { 0 } }
}

# creates a new instance
sub new {
	my $class = shift;

	# The options hash
	my %opt;

	# Support passing in a hash ref or a regular hash
	if ( ( @_ & 1 ) and ref $_[0] and ref( $_[0] ) eq 'HASH' ) {
		%opt = %{ $_[0] };
	} else {
		# Sanity checking
		if ( @_ & 1 ) {
			warn __PACKAGE__ . ' requires an even number of options passed to new()';
			return;
		}

		%opt = @_;
	}

	# lowercase keys
	%opt = map { lc($_) => $opt{$_} } keys %opt;

	# set the readonly mode
	if ( exists $opt{'readonly'} and defined $opt{'readonly'} ) {
		$opt{'readonly'} = $opt{'readonly'} ? 1 : 0;
	} else {
		if ( DEBUG ) {
			warn 'using default READONLY = false';
		}

		$opt{'readonly'} = 0;
	}

	# get our filesystem :)
	if ( exists $opt{'filesystem'} and defined $opt{'filesystem'} ) {
		# validate it
		if ( ! _validate_fs( $opt{'filesystem'} ) ) {
			warn 'invalid filesystem passed to new()';
			return;
		}
	} else {
		if ( DEBUG ) {
			warn 'using default FILESYSTEM = empty';
		}

		$opt{'filesystem'} = {};
	}

	# set the cwd
	if ( exists $opt{'cwd'} and defined $opt{'cwd'} ) {
		# FIXME validate it
	} else {
		if ( DEBUG ) {
			warn 'using default CWD = ' . File::Spec->rootdir();
		}

		$opt{'cwd'} = File::Spec->rootdir();
	}

	# create our instance
	my $self = {
		'fs'		=> $opt{'filesystem'},
		'readonly'	=> $opt{'readonly'},
		'cwd'		=> $opt{'cwd'},
	};
	bless $self, $class;

	return $self;
}

#my %files = (
#	'/' => {
#		type => 0040,
#		mode => 0755,
#		ctime => time()-1000,
#	},
#	'/a' => {
#		data => "File 'a'.\n",
#		type => 0100,
#		mode => 0755,
#		ctime => time()-2000,
#	},
#	'/b' => {
#		data => "This is file 'b'.\n",
#		type => 0100,
#		mode => 0644,
#		ctime => time()-1000,
#	},
#	'/foo' => {
#		type => 0040,
#		mode => 0755,
#		ctime => time()-3000,
#	},
#	'/foo/bar' => {
#		data => "APOCAL is the best!\nJust kidding :)",
#		type => 0100,
#		mode => 0755,
#		ctime => time()-5000,
#	},
#);

# validates a filesystem struct
sub _validate_fs {
	my $fs = shift;

	# FIXME add validation
	return 1;
}

# simple accessor
sub _fs {
	return shift->{'fs'};
}
sub readonly {
	my $self = shift;
	my $ro = shift;
	if ( defined $ro ) {
		$self->{'readonly'} = $ro ? 1 : 0;
	}
	return $self->{'readonly'};
}

sub cwd {
	my( $self, $cwd, $cb ) = @_;

	# sanitize the path
	$cwd = File::Spec->canonpath( $cwd );

	# Get or set?
	if ( ! defined $cwd ) {
		if ( defined $cb ) {
			$cb->( $self->{'cwd'} );
			return;
		} else {
			return $self->{'cwd'};
		}
	}

	# actually change our cwd!
	$self->{'cwd'} = $cwd;
	if ( defined $cb ) {
		$cb->( $cwd );
		return;
	} else {
		return $cwd;
	}
}

sub open {
	my( $self, $path, $flags, $mode, $callback ) = @_;

	# make sure we're opening a real file
	if ( exists $self->_fs->{ $path } ) {
		unless ( $self->_fs->{ $path }{'type'} & oct( 040 ) ) {
			# return a $fh object
			$callback->( IO::Scalar->new( \${ $self->_fs->{ $path }->{'data'} } ) );
		} else {
			# path is a directory!
			$callback->( -EISDIR() );
		}
	} else {
		# path does not exist
		$callback->( -ENOENT() );
	}

	return;
}

sub close {
	my( $self, $fh, $callback ) = @_;

	# cleanly close the FH
	$fh->close;
	$callback->( 1 );

	return;
}

sub read {
	# aio_read $fh,$offset,$length, $data,$dataoffset, $callback->($retval)
	# have to leave @_ alone so caller will get proper $buffer reference :(
	my $self = shift;
	my $fh = shift;

	# read the data from the fh!
	my $buf = '';
	my $ret = $fh->read( $buf, $_[1], $_[0] );
	if ( ! defined $ret or $ret == 0 ) {
		$_[4]->( -EIO() );
	} else {
		# stuff the read data into the true buffer, determined by dataoffset
		substr( $_[2], $_[3], $_[1], $buf );

		# inform the callback of success
		$_[4]->( $_[1] );
	}

	return;
}

sub write {
	# aio_write $fh,$offset,$length, $data,$dataoffset, $callback->($retval)
	# have to leave @_ alone so caller will get proper $buffer reference :(
	my $self = shift;
	my $fh = shift;

	# write the data!
	my $ret = $fh->write( $_[2], $_[1], $_[0] ); # FIXME does write actually return anything?
	if ( ! $ret ) {
		$_[4]->( -EIO() );
	} else {
		# return length
		$_[4]->( $_[0] );
	}

	return;
}

sub sendfile {
	my( $self, $out_fh, $in_fh, $in_offset, $length, $callback ) = @_;

	# start by reading $length from $in_fh
	my $buf = '';
	my $ret = $in_fh->read( $buf, $length, $in_offset );
	if ( ! defined $ret or $ret == 0 ) {
		$callback->( -EIO() );
	} else {
		# write it to $out_fh ( at the end )
		$out_fh->seek( 0, SEEK_END );
		$ret = $out_fh->write( $buf, $length );	# FIXME does write actually return anything?
		if ( $ret ) {
			$callback->( $length );
		} else {
			$callback->( -EIO() );
		}
	}

	return;
}

sub readahead {
	my( $self, $fh, $offset, $length, $callback ) = @_;

	# not implemented, always return success
	$callback->( 1 );
	return;
}

sub stat {
	my( $self, $path, $callback ) = @_;

	# FIXME we don't support array/fh mode because it would require insane amounts of munging the paths
	if ( ref $path ) {
		if ( DEBUG ) {
			warn 'Passing a REF to stat() is not supported!';
		}
		$callback->( -ENOSYS() );
		return;
	}

	# gather the proper information
	if ( exists $self->_fs->{ $path } ) {
		my $info = $self->_fs->{ $path };

		my $size = exists( $info->{'cont'} ) ? length( $info->{'cont'} ) : 0;
		my $modes = ( $info->{'type'} << 9 ) + $info->{'mode'};

		# FIXME make sure nlink is proper for directories
		# FIXME check this data, I suspect it's causing vi failures?
		my ($dev, $ino, $rdev, $blocks, $gid, $uid, $nlink, $blksize) = ( 0, 0, 0, 1, (split( /\s+/, $) ))[0], $>, 1, 1024 );

		$gid = $info->{'gid'} if exists $info->{'gid'};
		$uid = $info->{'uid'} if exists $info->{'uid'};
		my ($atime, $ctime, $mtime);
		$atime = $ctime = $mtime = $info->{'ctime'};
		$atime = $info->{'atime'} if exists $info->{'atime'};
		$mtime = $info->{'mtime'} if exists $info->{'mtime'};

		# finally, return the darn data!
		$callback->( $dev, $ino, $modes, $nlink, $uid, $gid, $rdev, $size, $atime, $mtime, $ctime, $blksize, $blocks );
	} else {
		# path does not exist
		$callback->( -ENOENT() );
	}

	return;
}

sub lstat {
	my( $self, $path, $callback ) = @_;

	# FIXME unimplemented because of complexity
	$callback->( -ENOSYS() );

	return;
}

sub utime {
	my( $self, $path, $atime, $mtime, $callback ) = @_;

	# FIXME we don't support fh mode because it would require insane amounts of munging the paths
	if ( ref $path ) {
		if ( DEBUG ) {
			warn 'Passing a REF to utime() is not supported!';
		}
		$callback->( -ENOSYS() );
		return;
	}

	if ( exists $self->_fs->{ $path } ) {
		# okay, update the time
		if ( ! defined $atime ) { $atime = time() }
		if ( ! defined $mtime ) { $mtime = $atime }
		$self->_fs->{ $path }{'atime'} = $atime;
		$self->_fs->{ $path }{'mtime'} = $mtime;

		# successful update of time!
		$callback->( 1 );
	} else {
		# path does not exist
		$callback->( -ENOENT() );
	}

	return;
}

sub chown {
	my( $self, $path, $uid, $gid, $callback ) = @_;

	# FIXME we don't support fh mode because it would require insane amounts of munging the paths
	if ( ref $path ) {
		if ( DEBUG ) {
			warn 'Passing a REF to chown() is not supported!';
		}
		$callback->( -ENOSYS() );
		return;
	}

	if ( exists $self->_fs->{ $path } ) {
		# okay, update the ownerships!
		if ( defined $uid and $uid > -1 ) {
			$self->_fs->{ $path }{'uid'} = $uid;
		}
		if ( defined $gid and $gid > -1 ) {
			$self->_fs->{ $path }{'gid'} = $gid;
		}

		# successful update of ownership!
		$callback->( 0 );
	} else {
		# path does not exist
		$callback->( -ENOENT() );
	}

	return;
}

sub truncate {
	my( $self, $path, $offset, $callback ) = @_;

	# FIXME we don't support fh mode because it would require insane amounts of munging the paths
	if ( ref $path ) {
		if ( DEBUG ) {
			warn 'Passing a REF to truncate() is not supported!';
		}
		$callback->( -ENOSYS() );
		return;
	}

	if ( exists $self->_fs->{ $path } ) {
		unless ( $self->_fs->{ $path }{'type'} & oct( 040 ) ) {
			# valid file, proceed with the truncate!

			# sanity check, offset cannot be bigger than the length of the file!
			if ( $offset > length( $self->_fs->{ $path }{'data'} ) ) {
				$callback->( -EINVAL() );
			} else {
				# did we reach the end of the file?
				if ( $offset != length( $self->_fs->{ $path }{'data'} ) ) {
					# ok, truncate our copy!
					$self->_fs->{ $path }{'data'} = substr( $self->_fs->{ $path }{'data'}, 0, $offset );
				}

				# successfully truncated
				$callback->( 0 );
			}
		} else {
			# path is a directory!
			$callback->( -EISDIR() );
		}
	} else {
		# path does not exist
		$callback->( -ENOENT() );
	}

	return;
}

sub chmod {
	my( $self, $path, $mode, $callback ) = @_;

	# FIXME we don't support fh mode because it would require insane amounts of munging the paths
	if ( ref $path ) {
		if ( DEBUG ) {
			warn 'Passing a REF to chmod() is not supported!';
		}
		$callback->( -ENOSYS() );
		return;
	}

	if ( exists $self->_fs->{ $path } ) {
		# okay, update the mode!
		$self->_fs->{ $path }{'mode'} = $mode;

		# successful update of mode!
		$callback->( 0 );
	} else {
		# path does not exist
		$callback->( -ENOENT() );
	}

	return;
}

sub unlink {
	my( $self, $path, $callback ) = @_;

	if ( exists $self->_fs->{ $path } ) {
		unless ( $self->_fs->{ $path }{'type'} & oct( 040 ) ) {
			# valid file, proceed with the deletion!
			delete $self->_fs->{ $path };

			# successful deletion!
			$callback->( 0 );
		} else {
			# path is a directory!
			$callback->( -EISDIR() );
		}
	} else {
		# path does not exist
		$callback->( -ENOENT() );
	}

	return;
}

sub mknod {
	my( $self, $path, $mode, $dev, $callback ) = @_;

	# cleanup the mode ( for some reason we get '100644' instead of '0644' )
	# FIXME this seems to also screw up the S_ISREG() stuff, have to investigate more...
	$mode = $mode & oct( 00777 );

	if ( exists $self->_fs->{ $path } or $path eq '.' or $path eq '..' ) {
		# already exists!
		$callback->( -EEXIST() );
	} else {
		# should we add validation to make sure all parents already exist
		# seems like touch() and friends check themselves, so we don't have to do it...

		# we only allow regular files to be created
		if ( $dev == 0 ) {
			$self->_fs->{ $path } = {
				type => oct( 100 ),
				mode => $mode,
				ctime => time(),
				data => "",
			};

			# successful creation!
			$callback->( 0 );
		} else {
			# unsupported mode
			$callback->( -EINVAL() );
		}
	}

	return;
}

sub link {
	my( $self, $srcpath, $dstpath, $callback ) = @_;

	# FIXME unimplemented because of complexity
	$callback->( -ENOSYS() );

	return;
}

sub symlink {
	my( $self, $srcpath, $dstpath, $callback ) = @_;

	# FIXME unimplemented because of complexity
	$callback->( -ENOSYS() );

	return;
}

sub readlink {
	my( $self, $path, $callback ) = @_;

	# FIXME unimplemented because of complexity
	$callback->( -ENOSYS() );

	return;
}

sub rename {
	my( $self, $srcpath, $dstpath, $callback ) = @_;

	if ( exists $self->_fs->{ $srcpath } ) {
		if ( ! exists $self->_fs->{ $dstpath } ) {
			# should we add validation to make sure all parents already exist
			# seems like mv() and friends check themselves, so we don't have to do it...

			# proceed with the rename!
			$self->_fs->{ $dstpath } = delete $self->_fs->{ $srcpath };

			$callback->( 0 );
		} else {
			# destination already exists!
			$callback->( -EEXIST() );
		}
	} else {
		# path does not exist
		$callback->( -ENOENT() );
	}

	return;
}

sub mkdir {
	my( $self, $path, $mode, $callback ) = @_;

	if ( exists $self->_fs->{ $path } ) {
		# already exists!
		$callback->( -EEXIST() );
	} else {
		# should we add validation to make sure all parents already exist
		# seems like mkdir() and friends check themselves, so we don't have to do it...

		# create the directory!
		$self->_fs->{ $path } = {
			type => oct( 040 ),
			mode => $mode,
			ctime => time(),
		};

		# successful creation!
		$callback->( 0 );
	}

	return;
}

sub rmdir {
	my( $self, $path, $callback ) = @_;

	if ( exists $self->_fs->{ $path } ) {
		if ( $self->_fs->{ $path }{'type'} & oct( 040 ) ) {
			# valid directory, does this directory have any children ( files, subdirs ) ??
			my $children = grep { $_ =~ /^$path/ } ( keys %{ $self->_fs } );
			if ( $children == 1 ) {
				delete $self->_fs->{ $path };

				# successful deletion!
				$callback->( 0 );
			} else {
				# need to delete children first!
				$callback->( -ENOTEMPTY() );
			}
		} else {
			# path is not a directory!
			$callback->( -ENOTDIR() );
		}
	} else {
		# path does not exist
		$callback->( -ENOENT() );
	}

	return;
}

sub readdir {
	my( $self, $path, $callback ) = @_;

	if ( exists $self->_fs->{ $path } ) {
		if ( $self->_fs->{ $path }{'type'} & oct( 040 ) ) {
			# construct all the data in this directory
			my @list = map { $_ =~ s/^$path\/?//; $_ }
				grep { $_ =~ /^$path\/?[^\/]+$/ } ( keys %{ $self->_fs } );

			# no need to add "." and ".."

			# return the list!
			$callback->( @list );
		} else {
			# path is not a directory!
			$callback->( -ENOTDIR() );
		}
	} else {
		# path does not exist!
		$callback->( -ENOENT() );
	}

	return;
}

sub load {
	# have to leave @_ alone so caller will get proper $data reference :(
	my $self = shift;
	my $path = shift;

	if ( exists $self->_fs->{ $path } ) {
		unless ( $self->_fs->{ $path }{'type'} & oct( 040 ) ) {
			# simply read it all into the buf
			$_[0] = $self->_fs->{ $path }{'data'};

			# successful load!
			$_[1]->( length( self->_fs->{ $path }{'data'} ) );
		} else {
			# path is a directory!
			$_[1]->( -EISDIR() );
		}
	} else {
		# path does not exist
		$_[1]->( -ENOENT() );
	}

	return;
}

sub copy {
	my( $self, $srcpath, $dstpath, $callback ) = @_;

	if ( exists $self->_fs->{ $srcpath } ) {
		if ( ! exists $self->_fs->{ $dstpath } ) {
			# should we add validation to make sure all parents already exist
			# seems like cp() and friends check themselves, so we don't have to do it...

			# proceed with the copy!
			$self->_fs->{ $dstpath } = { %{ $self->_fs->{ $srcpath } } };

			$callback->( -1 );
		} else {
			# destination already exists!
			$callback->( 0 );
		}
	} else {
		# path does not exist
		$callback->( 0 );
	}

	return;
}

sub move {
	my( $self, $srcpath, $dstpath, $callback ) = @_;

	# to us, move is equivalent to rename
	$self->rename( $srcpath, $dstpath, $callback );

	return;
}

sub scandir {
	my( $self, $path, $maxreq, $callback ) = @_;

	# this is a glorified version of readdir...

	if ( exists $self->_fs->{ $path } ) {
		if ( $self->_fs->{ $path }{'type'} & oct( 040 ) ) {
			# construct all the data in this directory
			my @files = map { $_ if $self->_fs->{ $_ }{'type'} & oct( 100 ) }
				map { $_ =~ s/^$path\/?//; $_ }
				grep { $_ =~ /^$path\/?[^\/]+$/ } ( keys %{ $self->_fs } );

			my @dirs = map { $_ if $self->_fs->{ $_ }{'type'} & oct( 040 ) }
				map { $_ =~ s/^$path\/?//; $_ }
				grep { $_ =~ /^$path\/?[^\/]+$/ } ( keys %{ $self->_fs } );

			# no need to add "." and ".."

			# return the list!
			$callback->( \@files, \@dirs );
		} else {
			# path is not a directory!
			$callback->();
		}
	} else {
		# path does not exist!
		$callback->();
	}

	return;
}

sub rmtree {
	my( $self, $path, $callback ) = @_;

	if ( exists $self->_fs->{ $path } ) {
		if ( $self->_fs->{ $path }{'type'} & oct( 040 ) ) {
			# delete all stuff under this path
			my @entries = grep { $_ =~ /^$path\/?.+$/ } ( keys %{ $self->_fs } );
			foreach my $e ( @entries ) {
				delete $self->_fs->{ $e };
			}
		} else {
			# path is not a directory!
			$callback->( -ENOTDIR() );
		}
	} else {
		# path does not exist
		$callback->( -ENOENT() );
	}

	return;
}

sub fsync {
	my( $self, $fh, $callback ) = @_;

	# not implemented, always return success
	$callback->( 1 );

	return;
}

sub fdatasync {
	my( $self, $fh, $callback ) = @_;

	# not implemented, always return success
	$callback->( 1 );

	return;
}

1;
__END__
=head1 NAME

POE::Component::Fuse - Using FUSE in POE asynchronously

=head1 SYNOPSIS

	#!/usr/bin/perl
	# a simple example to illustrate directory listings
	use strict; use warnings;

	use POE qw( Component::Fuse );
	use base 'POE::Session::AttributeBased';

	# constants we need to interact with FUSE
	use Errno qw( :POSIX );		# ENOENT EISDIR etc

	my %files = (
		'/' => {	# a directory
			type => 0040,
			mode => 0755,
			ctime => time()-1000,
		},
		'/a' => {	# a file
			type => 0100,
			mode => 0644,
			ctime => time()-2000,
		},
		'/foo' => {	# a directory
			type => 0040,
			mode => 0755,
			ctime => time()-3000,
		},
		'/foo/bar' => {	# a file
			type => 0100,
			mode => 0755,
			ctime => time()-4000,
		},
	);

	POE::Session->create(
		__PACKAGE__->inline_states(),
	);

	POE::Kernel->run();
	exit;

	sub _start : State {
		# create the fuse session
		POE::Component::Fuse->spawn;
		print "Check us out at the default place: /tmp/poefuse\n";
		print "You can navigate the directory, but no I/O operations are supported!\n";
	}
	sub _child : State {
		return;
	}
	sub _stop : State {
		return;
	}

	# return unimplemented for the rest of the FUSE api
	sub _default : State {
		if ( $_[ARG0] =~ /^fuse/ ) {
			$_[ARG1]->[0]->( -ENOSYS() );
		}
		return;
	}

	sub fuse_CLOSED : State {
		print "shutdown: $_[ARG0]\n";
		return;
	}

	sub fuse_getattr : State {
		my( $postback, $context, $path ) = @_[ ARG0 .. ARG2 ];

		if ( exists $files{ $path } ) {
			my $size = exists( $files{ $path }{'cont'} ) ? length( $files{ $path }{'cont'} ) : 0;
			$size = $files{ $path }{'size'} if exists $files{ $path }{'size'};
			my $modes = ( $files{ $path }{'type'} << 9 ) + $files{ $path }{'mode'};
			my ($dev, $ino, $rdev, $blocks, $gid, $uid, $nlink, $blksize) = ( 0, 0, 0, 1, (split( /\s+/, $) ))[0], $>, 1, 1024 );
			my ($atime, $ctime, $mtime);
			$atime = $ctime = $mtime = $files{ $path }{'ctime'};

			# finally, return the darn data!
			$postback->( $dev, $ino, $modes, $nlink, $uid, $gid, $rdev, $size, $atime, $mtime, $ctime, $blksize, $blocks );
		} else {
			# path does not exist
			$postback->( -ENOENT() );
		}

		return;
	}

	sub fuse_getdir : State {
		my( $postback, $context, $path ) = @_[ ARG0 .. ARG2 ];

		if ( exists $files{ $path } ) {
			if ( $files{ $path }{'type'} & 0040 ) {
				# construct all the data in this directory
				my @list = map { $_ =~ s/^$path\/?//; $_ }
					grep { $_ =~ /^$path\/?[^\/]+$/ } ( keys %files );

				# no need to add "." and ".." - FUSE handles it automatically!

				# return the list with a success code on the end
				$postback->( @list, 0 );
			} else {
				# path is not a directory!
				$postback->( -ENOTDIR() );
			}
		} else {
			# path does not exist!
			$postback->( -ENOENT() );
		}

		return;
	}

	sub fuse_getxattr : State {
		my( $postback, $context, $path, $attr ) = @_[ ARG0 .. ARG3 ];

		# we don't have any extended attribute support
		$postback->( 0 );

		return;
	}

=head1 ABSTRACT

Using this module will enable you to asynchronously process FUSE requests from the kernel in POE. Think of
this module as a simple wrapper around L<Fuse> to POEify it.

=head1 DESCRIPTION

This module allows you to use FUSE filesystems in POE. Basically, it is a wrapper around L<Fuse> and exposes
it's API via events. Furthermore, you can use L<Filesys::Virtual> to handle the filesystem.

The standard way to use this module is to do this:

	use POE;
	use POE::Component::Fuse;

	POE::Component::Fuse->spawn( ... );

	POE::Session->create( ... );

	POE::Kernel->run();

Naturally, the best way to quickly get up to speed is to study other implementations of FUSE to see what
they have done. Furthermore, please look at the scripts in the examples/ directory in the tarball!

=head2 Starting Fuse

To start Fuse, just call it's spawn method:

	POE::Component::Fuse->spawn( ... );

This method will return failure on errors or return success.

NOTE: The act of starting/stopping PoCo-Fuse fires off _child events, read the POE documentation on
what to do with them :)

This constructor accepts either a hashref or a hash, valid options are:

=head3 alias

This sets the session alias in POE.

The default is: "fuse"

=head3 mount

This sets the mountpoint for FUSE.

If this mountpoint doesn't exist ( and the "mkdir" option isn't set ) spawn() will return failure.

The default is: "/tmp/poefuse"

=head3 mountoptions

This passes the options to FUSE for mounting.

NOTE: this is a comma-separated string!

The default is: undef

=head3 mkdir

If true, PoCo-Fuse will attempt to mkdir the mountpoint if it doesn't exist.

If the mkdir attempt fails, spawn() will return failure.

The default is: false

=head3 umount

If true, PoCo-Fuse will attempt to umount the filesystem on exit/shutdown.

This basically calls "fusermount -u -z $mountpoint"

WARNING: This is not exactly portable and is in the testing stage. Feedback would be much appreciated!

The default is: false

=head3 prefix

The prefix for all events generated by this module when using the "session" method.

The default is: "fuse_"

=head3 session

The session to send all FUSE events to. Used in conjunction with the "prefix" option, you can control
where the events arrive.

If this option is missing ( or POE is not running ) and "vfilesys" isn't enabled spawn() will return failure.

NOTE: You cannot use this and "vfilesys" at the same time! PoCo-Fuse will pick vfilesys over this!

The default is: calling session ( if POE is running )

=head3 vfilesys

The L<Filesys::Virtual> object to use as our filesystem. PoCo-Fuse will proceed to use L<Fuse::Filesys::Virtual>
to wrap around it and process the events internally.

Furthermore, you can also use L<Filesys::Virtual::Async> subclasses, this module understands their callback API
and will process it properly!

If this option is missing and "session" isn't enabled spawn() will return failure.

NOTE: You cannot use this and "session" at the same time! PoCo-Fuse will pick this over session!

Compatibility has not been tested with all Filesys::Virtual::XYZ subclasses, so please let me know if some isn't
working properly!

The default is: not used

=head2 Commands

There is only one command you can use, because this module does nothing except process FUSE events.

=head3 shutdown

Tells this module to kill the FUSE mount and terminates the session. Due to the semantics of FUSE, this
will often result in a wedged filesystem. You would need to either umount it manually ( via "fusermount -u $mount" )
or by enabling the "umount" option.

=head2 Events

If you aren't using the Filesys::Virtual interface, the FUSE api will be exposed to you in it's glory via
events to your session. You can process them, and send the data back via the supplied postback. All the arguments
are identical to the one in L<Fuse> so please take a good look at that module for more information!

The only place where this differs is the additional arguments. All events will receive 2 extra arguments in front
of the standard FUSE args. They are the postback and context info. The postback is self-explanatory, you
supply the return data to it and it'll fire an event back to PoCo-Fuse for processing. The context is the
calling context received from FUSE. It is a hashref with the 3 keys in it: uid, gid, pid. It is received via
the fuse_get_context() sub from L<Fuse>.

Remember that the events are the fuse methods with the prefix tacked on to them. A typical FUSE handler would
look something like the example below. ( it is sugared via POE::Session::AttributeBased hah )

	sub fuse_getdir : State {
		my( $postback, $context, $path ) = @_[ ARG0 .. ARG2 ];

		# somehow get our data, we fake it here for instructional reasons
		$postback->( 'foo', 'bar', 0 );
		return;
	}

Again, pretty please read the L<Fuse> documentation for all the events you can receive. Here's the list
as of Fuse v0.09: getattr readlink getdir mknod mkdir unlink rmdir symlink rename link chmod chown truncate
utime open read write statfs flush release fsync setxattr getxattr listxattr removexattr.

=head3 CLOSED

This is a special event sent to the session notifying it of component shutdown. As usual, it will be prefixed by the
prefix set in the options. If you are using the vfilesys option, this will not be sent anywhere.

The event handler will get one argument, the error string. If you shut down the component, it will be "shutdown",
otherwise it will contain some error string. A sample handler is below.

	sub fuse_CLOSED : State {
		my $error = $_[ARG0];
		if ( $error ne 'shutdown' ) {
			print "AIEE: $error\n";

			# do some actions like emailing the sysadmin, restarting the component, etc...
		} else {
			# we told it to shutdown, so what do we want to do next?
		}

		return;
	}

=head2 Internals

=head3 XSification

This module does it's magic by spawning a subprocess via Wheel::Run and passing events back and forth to
the L<Fuse> module loaded in it. This isn't exactly optimal which is obvious, but it works perfectly!

I'm working on improving this by using XS but it will take me some time seeing how I'm a n00b :( Furthermore,
FUSE doesn't really help because I have to figure out how to get at the filehandle buried deep in it and expose
it to POE...

If anybody have the time and knowledge, please help me out and we can have fun converting this to XS!

=head3 Debugging

You can enable debug mode which prints out some information ( and especially error messages ) by doing this:

	sub Filesys::Virtual::Async::Dispatcher::DEBUG () { 1 }
	use Filesys::Virtual::Async::Dispatcher;


=head1 EXPORT

None.

=head1 SEE ALSO

L<POE>

L<Fuse>

L<Filesys::Virtual>

L<Fuse::Filesys::Virtual>

L<Filesys::Virtual::Async>

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc POE::Component::Fuse

=head2 Websites

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/POE-Component-Fuse>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/POE-Component-Fuse>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=POE-Component-Fuse>

=item * Search CPAN

L<http://search.cpan.org/dist/POE-Component-Fuse>

=back

=head2 Bugs

Please report any bugs or feature requests to C<bug-poe-component-fuse at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=POE-Component-Fuse>.  I will be
notified, and then you'll automatically be notified of progress on your bug as I make changes.

=head1 AUTHOR

Apocalypse E<lt>apocal@cpan.orgE<gt>

Props goes to xantus who got me motivated to write this :)

Also, this module couldn't have gotten off the ground if not for L<Fuse> which did the heavy XS lifting!

=head1 COPYRIGHT AND LICENSE

Copyright 2009 by Apocalypse

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
