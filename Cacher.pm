package Tie::Cacher;
use 5.006;
use strict;
use warnings;

use AutoLoader qw(AUTOLOAD);

our $VERSION = "0.04";
use Carp;

use base qw(Tie::Hash);
use fields qw(head nodes hit missed count max_count validate load save);

# This should effectively give us inf
use constant INF => 1e50;

# We could get the effect of count by using keys, but it would reset
# first_key/last_key

package Tie::Cacher::Node;
use fields qw(key previous next);

package Tie::Cacher;

# Dirty hacks
use constant KEY       => $Tie::Cacher::Node::FIELDS{"key"};
use constant PREVIOUS  => $Tie::Cacher::Node::FIELDS{"previous"};
use constant NEXT      => $Tie::Cacher::Node::FIELDS{"next"};
use constant NODE_SIZE => 1+NEXT;

my %attributes = map {($_, 1)} qw(validate load save max_count user_data);
sub new {
    defined(my $class = shift) ||
        croak "Too few arguments. Usage: Tie::Cacher->new(key-val-pairs)";
    my __PACKAGE__ $self = bless [], $class;

    my Tie::Cacher::Node $head = [];
    $self->{"head"} = $head;
    $head->{"next"} = $head;
    $head->{"previous"} = $head;
    $self->{"hit"} = $self->{"missed"} = $self->{"count"} = 0;
    $self->{"max_count"} = INF;
    $self->{"nodes"} = {};

    if (@_ % 2) {
        if (@_ == 1) {
            if (ref($_[0])) {
                @_ = %{$_[0]};
            } else {
                @_ = (max_count => $_[0]);
            }
        }
        croak "Odd number of arguments. Usage: $class->new(key-val-pairs)" if
            @_ %2;
    }
    while (@_) {
        my $key = shift;
        $attributes{$key} || croak "Unknown key $key in $class->new, $class";
        $self->$key(shift);
    }
    $self->{"max_count"} ||= INF;	# Infinity really
    return $self;
}

sub DESTROY {
    my __PACKAGE__ $self = shift;

    # Make nodes single connected
    $self->{"nodes"} = {};
    my Tie::Cacher::Node $head = $self->{"head"};
    my Tie::Cacher::Node $ptr = $head->{"previous"};
    undef $ptr->{"next"};
    $ptr = $head->{"next"};
    $head->{"next"} = $head->{"previous"} = $head;
    $self->{"count"} = 0;

    while ($ptr) {
        # We must remove both the forward and backward links, otherwise
        # perl will do a recursive free and might run out of stackspace
        undef $ptr->{"previous"};
        $ptr = delete $ptr->[NEXT];
    }
}

1;

__END__

sub TIEHASH {
    {
        local $^W;
        *TIEHASH = \&new;
    }
    goto &TIEHASH;
}

sub STORE {
    {
        local $^W;
        *STORE = \&store;
    }
    goto &STORE;
}

sub store {
    my __PACKAGE__ $self = $_[0];
    my Tie::Cacher::Node ($next, $prev);
    my Tie::Cacher::Node $node = $self->{"nodes"}{$_[1]};
    if ($node) {
        # Already exists
        $next = $node->{"next"};
        # Detach node
        $prev = $node->{"previous"};
        $prev->{"next"} = $next;
        $next->{"previous"} = $prev;
    } else {
        if ($self->{"count"} >= $self->{"max_count"}) {
            # Drop an old one
            $next = $self->{"head"};
            $node = $next->{"previous"};
            delete $self->{"nodes"}{$node->{"key"}};
            # Already existed
            $prev = $node->{"previous"};
            $prev->{"next"} = $next;
            $next->{"previous"} = $prev;
        } else {
            $self->{"count"}++;
        }
        $self->{"nodes"}{$_[1]} = $node = [];
        $node->{"key"} = $_[1];
    }
    $node->[0] = $_[2];

    # Reattach node in front
    $prev = $self->{"head"};
    $next = $prev->{"next"};
    $prev->{"next"} = $node;
    $node->{"next"} = $next;
    $node->{"previous"} = $prev;
    $next->{"previous"} = $node;

    if ($self->{"save"}) {
        splice(@_, 2, 1, $node);
        eval {
            &{$self->{"save"}};
        };
        if ($@) {
            $self->delete($_[1]);
            die $@;
        }
    }
}

sub FETCH {
    {
        local $^W;
        *FETCH = \&fetch;
    }
    goto &FETCH;
}

sub fetch {
    my __PACKAGE__ $self = $_[0];
    my Tie::Cacher::Node $node = $self->{"nodes"}{$_[1]};
    if ($node) {
        # Aha, existence is assured
        $self->{"hit"}++;

        # Detach node
        my Tie::Cacher::Node $next = $node->{"next"};
        my Tie::Cacher::Node $prev = $node->{"previous"};
        $prev->{"next"} = $next;
        $next->{"previous"} = $prev;

        # Reattach node in front
        $prev = $self->{"head"};
        $next = $prev->{"next"};
        $prev->{"next"} = $node;
        $node->{"next"} = $next;
        $node->{"previous"} = $prev;
        $next->{"previous"} = $node;

        return $node->[0] unless $self->{"validate"};
        push(@_, $node);
        return $node->[0] if &{$self->{"validate"}};
        unless ($self->{"load"}) {
            $self->delete($_[1]);
            return;
        }
    } else {
        # Nope, new entry
        $self->{"missed"}++;
        return unless $self->{"load"};
        my Tie::Cacher::Node ($next, $prev);
        if ($self->{"count"} >= $self->{"max_count"}) {
            # Drop an old one
            $next = $self->{"head"};
            $node = $next->{"previous"};
            $prev = $node->{"previous"};
            $prev->{"next"} = $next;
            $next->{"previous"} = $prev;
            delete $self->{"nodes"}{$node->{"key"}};
        } else {
            $self->{"count"}++;
            $node = [];
        }
        $self->{"nodes"}{$_[1]} = $node;
        $node->{"key"} = $_[1];

        # Create node in front
        $prev = $self->{"head"};
        $next = $prev->{"next"};
        $prev->{"next"} = $node;
        $node->{"next"} = $next;
        $node->{"previous"} = $prev;
        $next->{"previous"} = $node;
        push(@_, $node);
    }
    eval {
        &{$self->{"load"}};
        &{$self->{"save"}} if $self->{"save"};
    };
    return $node->[0] unless $@;
    $self->delete($_[1]);
    die $@;
}

sub fetch_node {
    my __PACKAGE__ $self = $_[0];
    my Tie::Cacher::Node $node = $self->{"nodes"}{$_[1]};
    if ($node) {
        # Aha, existence is assured
        $self->{"hit"}++;

        # Detach node
        my Tie::Cacher::Node $next = $node->{"next"};
        my Tie::Cacher::Node $prev = $node->{"previous"};
        $prev->{"next"} = $next;
        $next->{"previous"} = $prev;

        # Reattach node in front
        $prev = $self->{"head"};
        $next = $prev->{"next"};
        $prev->{"next"} = $node;
        $node->{"next"} = $next;
        $node->{"previous"} = $prev;
        $next->{"previous"} = $node;

        return $node unless $self->{"validate"};
        push(@_, $node);
        return $node if &{$self->{"validate"}};
        unless ($self->{"load"}) {
            $self->delete($_[1]);
            return;
        }
    } else {
        # Nope, new entry
        $self->{"missed"}++;
        return unless $self->{"load"};
        my Tie::Cacher::Node ($next, $prev);
        if ($self->{"count"} >= $self->{"max_count"}) {
            # Drop an old one
            $next = $self->{"head"};
            $node = $next->{"previous"};
            $prev = $node->{"previous"};
            $prev->{"next"} = $next;
            $next->{"previous"} = $prev;
            delete $self->{"nodes"}{$node->{"key"}};
        } else {
            $self->{"count"}++;
            $node = [];
        }
        $self->{"nodes"}{$_[1]} = $node;
        $node->{"key"} = $_[1];

        # Create node in front
        $prev = $self->{"head"};
        $next = $prev->{"next"};
        $prev->{"next"} = $node;
        $node->{"next"} = $next;
        $node->{"previous"} = $prev;
        $next->{"previous"} = $node;
        push(@_, $node);
    }
    eval {
        &{$self->{"load"}};
        &{$self->{"save"}} if $self->{"save"};
    };
    return $node unless $@;
    $self->delete($_[1]);
    die $@;
}

sub keys : method {
    my __PACKAGE__ $self = shift;
    return CORE::keys %{$self->{"nodes"}};
}

sub FIRSTKEY {
    {
        local $^W;
        *FIRSTKEY = \&first_key;
    }
    goto &FIRSTKEY;
}

sub first_key {
    my __PACKAGE__ $self = shift;
    CORE::keys %{$self->{"nodes"}};
    return each %{$self->{"nodes"}} unless wantarray;
    my @work = each %{$self->{"nodes"}} or return;
    return ($work[0], $work[1][0]);
}

sub NEXTKEY {
    {
        local $^W;
        *NEXTKEY = \&next_key;
    }
    goto &NEXTKEY;
}

sub next_key {
    my __PACKAGE__ $self = shift;
    return each %{$self->{"nodes"}} unless wantarray;
    my @work = each %{$self->{"nodes"}} or return;
    return ($work[0], $work[1][0]);
}

sub EXISTS {
    {
        local $^W;
        *EXISTS = \&exists;
    }
    goto &EXISTS;
}

sub exists : method {
    my __PACKAGE__ $self = shift;
    return exists $self->{"nodes"}{$_[0]};
}

sub DELETE {
    {
        local $^W;
        *DELETE = \&delete;
    }
    goto &DELETE;
}

sub delete : method {
    my __PACKAGE__ $self = shift;
    unless (defined(wantarray)) {
        for (@_) {
            my Tie::Cacher::Node $node = delete $self->{"nodes"}{$_} || next;
            $self->{"count"}--;

            # Detach node
            my Tie::Cacher::Node $next = $node->{"next"};
            my Tie::Cacher::Node $prev = $node->{"previous"};
            $prev->{"next"} = $next;
            $next->{"previous"} = $prev;
        }
        return;
    }
    my @out = map {
        if (my Tie::Cacher::Node $node = delete $self->{"nodes"}{$_}) {
            $self->{"count"}--;

            # Detach node
            my Tie::Cacher::Node $next = $node->{"next"};
            my Tie::Cacher::Node $prev = $node->{"previous"};
            $prev->{"next"} = $next;
            $next->{"previous"} = $prev;
            $node->[0];
        } else {
            undef;
        }
    } @_;
    return wantarray ? @out : $out[-1];
}

sub CLEAR {
    {
        local $^W;
        *CLEAR = \&clear;
    }
    goto &CLEAR;
}

sub clear {
    {
        local $^W;
        *clear = \&DESTROY;
    }
    goto &clear;
}

sub recent_keys {
    my __PACKAGE__ $self = shift;
    my @keys;
    my Tie::Cacher::Node $head = $self->{"head"};
    for (my Tie::Cacher::Node $here = $head->{"next"}; $here != $head; $here = $here->{"next"}) {
        push(@keys, $here->{"key"});
    }
    return @keys;
}

sub old_keys {
    my __PACKAGE__ $self = shift;
    my @keys;
    my Tie::Cacher::Node $head = $self->{"head"};
    for (my Tie::Cacher::Node $here = $head->{"previous"}; $here != $head; $here = $here->{"previous"}) {
        push(@keys, $here->{"key"});
    }
    return @keys;
}

sub most_recent_key {
    my __PACKAGE__ $self = shift;
    my Tie::Cacher::Node $head = $self->{"head"};
    my Tie::Cacher::Node $here = $head->{"next"};
    return if $here == $head;
    return $here->{"key"}
}

sub oldest_key {
    my __PACKAGE__ $self = shift;
    my Tie::Cacher::Node $head = $self->{"head"};
    my Tie::Cacher::Node $here = $head->{"previous"};
    return if $here == $head;
    return $here->{"key"}
}

sub count {
    my __PACKAGE__ $self = shift;
    return $self->{"count"}
}

sub missed {
    my __PACKAGE__ $self = shift;
    if (@_) {
        my $old = $self->{"missed"};
        $self->{"missed"} = shift;
        return $old;
    }
    return $self->{"missed"}
}

sub hit {
    my __PACKAGE__ $self = shift;
    if (@_) {
        my $old = $self->{"hit"};
        $self->{"hit"} = shift;
        return $old;
    }
    return $self->{"hit"}
}

sub max_count {
    my __PACKAGE__ $self = shift;
    if (@_) {
        my $old = $self->{"max_count"};
        if (defined(my $val = shift)) {
            croak "max_count must be at least 1" if $val < 1;
            $self->{"max_count"} = $val;
        } else {
            $self->{"max_count"} = INF;
        }
        return if $old == INF;
        return $old;
    }
    return if $self->{max_count} == INF;
    return $self->{max_count}
}

sub validate {
    my __PACKAGE__ $self = shift;
    if (@_) {
        my $old = $self->{"validate"};
        $self->{"validate"} = shift;
        return $old;
    }
    return $self->{"validate"}
}

sub load {
    my __PACKAGE__ $self = shift;
    if (@_) {
        my $old = $self->{"load"};
        $self->{"load"} = shift;
        return $old;
    }
    return $self->{"load"}
}

sub save {
    my __PACKAGE__ $self = shift;
    if (@_) {
        my $old = $self->{"save"};
        $self->{"save"} = shift;
        return $old;
    }
    return $self->{"save"}
}

sub user_data {
    my __PACKAGE__ $self = shift;
    if (@_) {
        my $old = $self->{"head"}[0];
        $self->{"head"}[0] = shift;
        return $old;
    }
    return $self->{"head"}[0];
}

=head1 NAME

Tie::Cacher - Cache a (sub)set of key/value pairs. Tie and OO interface.

=head1 SYNOPSIS

  # The Object Oriented interface:
  use Tie::Cacher;
  $cache   = Tie::Cacher->new($max_count);
  $cache   = Tie::Cacher->new(%options);
  $cache   = Tie::Cacher->new(\%options);

  $cache->store($key, $value);
  $value   = $cache->fetch($key);
  $node    = $cache->fetch_node($key);

  $nr_keys = $cache->keys;
  @keys    = $cache->keys;
  @keys    = $cache->recent_keys;
  @keys    = $cache->old_keys;
  $key     = $cache->most_recent_key;
  $key     = $cache->oldest_key;

  $key      = $cache->first_key;
  ($key, $value) = $cache->first_key;
  $key      = $cache->next_key;
  ($key, $value) = $cache->next_key;

  $exists   = $cache->exists($key);

  $cache->delete(@keys);
  $value    = $cache->delete(@keys);
  @values   = $cache->delete(@keys);
  $cache->clear;

  $nr_keys = $cache->count;

  $hit = $cache->hit;
  $old_hit = $cache->hit($new_hit);
  $missed = $cache->missed;
  $old_missed = $cache->missed($new_missed);

  $max_count     = $cache->max_count;
  $old_max_count = $cache->max_count($new_max_count);
  $validate      = $cache->validate;
  $old_validate  = $cache->validate($new_validate);
  $load          = $cache->load;
  $old_load      = $cache->load($new_load);
  $save          = $cache->save;
  $old_save      = $cache->save($new_save);
  $user_data     = $cache->user_data;
  $old_user_data = $cache->user_data($new_user_data);

  # The Tie interface:
  use Tie::Cacher;
  $tied = tie %cache, 'Tie::Cache', $max_count;
  $tied = tie %cache, 'Tie::Cache', %options;
  $tied = tie %cache, 'Tie::Cache', {%options};

  # cache supports normal tied hash functions
  $cache{1} = 2;       # STORE
  print "$cache{1}\n"; # FETCH

  print "Yes\n" if exists $cache{1};	# EXISTS
  @keys = keys %cache;	# KEYS

  # FIRSTKEY, NEXTKEY
  while(($k, $v) = each %cache) { print "$k: $v\n"; }

  delete $cache{1};    # DELETE
  %cache = ();         # CLEAR

  # Or use the OO methods on the underlying tied object:
  print $tied->max_count, "\n";

=head1 DESCRIPTION

This module implements a least recently used (LRU) cache in memory through
a tie and a OO interface.  Any time a key/value pair is fetched or stored,
an entry time is associated with it, and as the cache fills up, those members
of the cache that are the oldest are removed to make room for new entries.

So, the cache only "remembers" the last written entries, up to the
size of the cache.  This can be especially useful if you access
great amounts of data, but only access a minority of the data a
majority of the time.

The implementation is a hash, for quick lookups, overlaying a doubly linked
list for quick insertion and deletion. Notice that the OO interface will
be faster than the tie interface.

=head2 EXPORT

None

=head2 METHODS

Notice that in the methods you will see a number of places where a
node is returned where you might have expected a value or a reference to
a value. This node is an array reference that actually has the value
at index 0, followed by a few internal fields. You are however free to
put extra associated data in this array after them or even do things like
bless the array. This gives you an easy way to decorate values.

=over 4

=item X<new>$cache = Tie::Cacher->new($max_count)

=item $cache = Tie::Cacher->new(%options)

=item $cache = Tie::Cacher->new(\%options)

Creates a new Tie::Cache object. Will throw an exception on failure
(the only possible failures are invalid arguments).

Options are name value pairs, where the following are currently recognized:

=over 8

=item X<option_validate>validate => \&code

If this option is given, whenever a data L<fetch|"fetch"> or
L<fetch_node|"fetch_node"> is done (notice that when using the tied interface,
a list context L<each|perlfunc/"each"> implies a L<fetch|"fetch"> for the
value) and the requested key already exists, the given code is called like:

 $validate->($cache, $key, $node)

where $node is an internal array reference. You can access the current value
corresponding to the key as $node->[0]. The code should either return true,
indicating the value is still valid, or false, meaning it's not valid anymore.

In the invalid case the current entry gets removed and the fetch proceeds
as if the key had not been found (which includes a possible
L<load|"option_load">).

In the valid case, you may in fact change the value through $node->[0] before
returning. (That way you can save a call to L<load|"option_load">, but there
won't be any implied L<save|"option_save"> call, so you'll have to do that
yourself if you want it).

If the code dies, the exception will be passed to the application, but
The L<hit|"hit"> counter will have been increased, the key will still be in
the cache and will have been marked as recently used.

=item X<option_load>load => \&load

If this option is given, whenever a data L<fetch|"fetch"> or
L<fetch_node|"fetch_node"> is done (notice that when using the tied interface,
a list context L<each|perlfunc/"each"> implies a L<fetch|"fetch"> for the
value) and the requested key does not exist (or is declared invalid by a
L<validate|"option_validate"> returning false), the given code is called like:

 $load->($cache, $key, $node)

The $load code reference should now somehow get a value corresponding to $key
(e.g. by looking it up in a database or doing a complex calculation or
whatever) and then store this new value in $node->[0]. If it fails it should
throw an exception (which will B<not> be caught and passed on to the caller of
L<fetch|"fetch"> or L<fetch_node|"fetch_node">. The entry will be removed from
the cache and no L<save callback|"option_save"> will be called for it).

=item X<option_save>save => \&save

If this option is given, it will be called whenever a new value enters the
cache, which means on L<store|"option_store"> or just after a
L<load|"option_load"> (triggered by a L<fetch|"fetch"> or
L<fetch_node|"fetch_node">). It's not called if you store a value in a
L<validate|"option_validate"> callback.

The code is called like:

 $save->($cache, $key, $node)

where the value is in $node->[0].

If this code dies, the exception is passed on to the application, but the
key will be removed from the cache.

=item X<option_max_count>max_count => size

If this option is given, the cache has a maximum number of entries. Whenever
you store a key/value pair and this would cause the cache to grow beyong the
given size, the oldest entry will be dropped from the cache to make place.

=item X<option_user_data>user_data => value

This option allows you to associate one scalar value with the cache object.
You can retrieve it with the L<user_data|"user_data"> method. The user_data
is undef if it has never been set.

=back

=item X<store>$cache->store($key, $value)

Looks up $key in the cache, and replaces its value if it already exists.
If it doesn't exist yet, the cache is checked for size (in case a
L<maximum size|"option_max_count"> was given) and the oldest entry is dropped
if the maximum is reached. A new slot is created for the new key, and the
new value is now stored there.

The node with the new value now gets the newest timestamp.

In either case, the L<save callback|"option_save"> is called if one exists.
If a L<save callback|"option_save"> is called and throws an exception, the
key is removed from the cache.

The L<hit|"hit"> and L<missed|"missed"> counters will remain untouched for
all cases.

=item X<fetch>$value = $cache->fetch($key)

Looks up $key in the cache.

If it does exist, increases the L<hit|"hit"> counter and marks the node as
most recent. Next it will call the L<validate callback|"option_validate"> if
one exists. If that returns true or there is no
L<validate callback|"option_validate">, the value associated with $key is
returned.

If the key is not in the cache yet, or the
L<validate callback|"option_validate"> returns false, it will increase the
L<missed counter|"missed">, and see if there is
a L<load callback|"option_load">. If there isn't one, fetch will return undef.
Otherwise a slot is created for a new value and marked as most recently used,
and the L<load callback|"option_load"> is called which will try to
produce a value (or throw an exception). If there is a
L<save callback|"option_save">, that will now be called to e.g. store the new
value in long term storage. After that, the new value is returned.

If the L<load callback|"option_load"> callback throws an exception, the key is
deleted from the cache (even if it existed before and failed a validate) and no
L<save callback|"option_save"> will be called for this value.

Notice that if fetch returns undef, you don't normally know if this means that
the associated value is "undef" or if the key didn't exist at all. You can
check using L<exists|"exists"> or do the fetch with L<fetch_node|"fetch_node">.

=item X<fetch_node>$node = $cache->fetch_node($key)

Does exactly the same as L<fetch|"fetch">, but where fetch would return a
value, this returns the node array reference where you can find the value
as $node->[0].

One advantage is that you can distinguish a failed fetch (returns undef)
from an undefined value (returns a node where $node->[0] is undef).

You can also use this to access extra data associated with the value.

=item X<keys>$nr_keys = $cache->keys

=item @keys = $cache->keys

In scalar context, returns the number of keys in the cache.

In list context, returns all the keys in the cache.

In either case it resets the position of L<next_key|"next_key">.

Will not do any key L<validation|"option_validate">.

=item X<recent_keys>@keys = $cache->recent_keys

Returns all keys, ordered from most recently used to least recently used.
This is notably slower than using L<keys|"keys">

=item X<old_keys>@keys = $cache->old_keys

Returns all keys, ordered from least recently used to most recently used.
This is notably slower than using L<keys|"keys">

=item X<most_recent_key>$key = $cache->most_recent_key

Returns the most recently used key, or "undef" if the cache is empty.

=item X<oldest_key>$key = $cache->oldest_key

Returns the least recently used key, or "undef" if the cache is empty.

=item $key = $cache->first_key

=item ($key, $value) = $cache->first_key

Resets the position for L<next_key|"next_key"> to the start and does a
L<next_key|"next_key">.

=item $key = $cache->next_key

=item ($key, $value) = $cache->next_key

Returns the next element in the cache, so you can iterate over it.
In scalar context it just returns the key, in list context it returns both
the key and the corresponding value, but it will do no
L<validation|"option_validate"> on the value. If you want validation, use the
scalar version and do the fetch yourself.

Entries are returned in an apparently random order. The actual random order is
subject to change in future versions of perl, but it is guaranteed to be in
the same order as that returned by the L<keys|"keys"> method.

When the cache is entirely read, an empty list is returned in list context
(which when assigned produces a false (0) value), and "undef" in scalar
context. The next call to "next_key" after that will start iterating again.
There is a single iterator for each cache, shared by all "first_key",
"next_key" and "keys" calls in the program; it can be reset by reading all the
elements from the cache or by calling "keys". If you add or delete elements of
a hash while you're iterating over it, you may get entries skipped or
duplicated, so don't. Exception: It is always safe to delete the item most
recently returned by "first_key" or "next_key", which means that the following
code will work:

 while (($key, $value) = $cache->next_key) {
     print $key, "\n";
     $cache->delete($key);   # This is safe
 }

=item X<exists>$exists = $cache->exists($key)

Returns true if $key exists in the cache, even if it has the value undef.
Returns false otherwise. Does no L<validation|"option_validate">.

=item X<delete>$cache->delete(@keys)

=item X<delete>$value  = $cache->delete(@keys)

=item X<delete>@values = $cache->delete(@keys)

deletes all entries in the cache corresponding to the given @keys (quite
often only one key to be deleted will be specified of course). Any keys
that don't exist in the cache will cause no changes in the cache, but will
behave as if they correspond to a value of "undef" for the return value.

In scalar context, returns the last deleted value. In list context, returns
the list of deleted values corresponding to the given keys. No
L<validation|"option_validate"> is done for any of the values.

=item X<clear>$cache->clear

Removes all entries from the cache.

=item X<count>$nr_keys = $cache->count

Returns the number of keys in the cache like L<keys|"keys"> does in scalar
context, but does not reset the position for L<next_key|"next_key">

=item X<hit>$hit = $cache->hit

Return the number of times a L<fetch|"fetch"> or L<fetch_node|"fetch_node">
on a key found that key to already exist.

=item $old_hit = $cache->hit($new_hit)

Sets the number of hits to $new_hit (typically 0 will be used here).
Returns the old value

=item X<missed>$missed = $cache->missed

Return the number of times a L<fetch|"fetch"> or L<fetch_node|"fetch_node">
on a key found that key to not exist yet.

=item $old_missed = $cache->hit($new_missed)

Sets the number of misses to $new_missed (typically 0 will be used here).
Returns the old value

=item X<max_count>$max_count = $cache->max_count

Returns the maximum number of entries allowed in the cache, or "undef" if
there is no maximum.

=item $old_max_count = $cache->max_count($new_max_count)

Sets a new maximum for the number of allowed entries in the cache.
"undef" means there is no maximum. Returns the old value.

=item X<validate>$validate = $cache->validate

Returns a code reference to the L<validate callback|"option_validate"> or 
"undef" if there is none.

=item $old_validate  = $cache->validate($new_validate)

Sets a new L<validate callback|"option_validate">. "undef" means no more 
L<validate callback|"option_validate">. Returns the old value.

=item X<load>$load = $cache->load

Returns a code reference to the L<load callback|"option_load"> or undef
if there is none.

=item $old_load = $cache->load($new_load)

Sets a new L<load callback|"option_load">. "undef" means no more 
L<load callback|"option_load">. Returns the old value.

=item X<save>$save = $cache->save

Returns a code reference to the L<save callback|"option_save"> or undef
if there is none.

=item $old_save = $cache->save($new_save)

Sets a new L<save callback|"option_save">. "undef" means no more 
L<save callback|"option_save">. Returns the old value.

=item X<user>$user_data = $cache->user_data

Returns the L<user_data|"option_user_data"> associated with the cache.

=item $old_user_data = $cache->user_data($new_user_data)

Sets a new value as the L<user data|"option_user_data">. Returns the old value.

=item $tied = tie %cache, 'Tie::Cache', $max_count

=item $tied = tie %cache, 'Tie::Cacher', %options

=item $tied = tie %cache, 'Tie::Cacher', {%options}

These are like L<new|"new"> (with all the same options), with the object
returned in $tied. It also ties the object to the hash %cache and fakes the
normal hash operations to the corresponding operations on the underlying
object as described in L<Tie::Hash> (see also the L<SYNOPSIS|"SYNOPSIS">).

If you don't need to do any Object Oriented calls, you can just get rid of the
$tied assignment. In fact, you can always drop it and just use
L<tied|perlfunc/"tied"> if you ever need the underlying object. So e.g. a
basic size restricted hash is as simple as:

    tie %hash, 'Tie::Cacher', max_count => 1000;

There is one gotcha you have to be aware off:

    ($key, $value) = each %hash;

will use scalar context L<first_key|"first_key"> or L<next_key|"next_key">
and then get the value using a L<fetch|"fetch">, unlike the list context
variants of L<first_key|"first_key"> and L<next_key|"next_key"> that just
directly get the value without any L<validation|"option_validate">,
L<loading|"option_load"> or L<saving|"option_save">.

=back

=head1 EXAMPLE

Here's a simple memoized fibonacci:

  use Tie::Cacher;
  my $fibo = Tie::Cacher->new(load => sub {
                                  my ($self, $key, $node) = @_;
                                  $node->[0] = $self->fetch($key-1) +
                                               $self->fetch($key-2);
                              });
  $fibo->store(0 => 0);
  $fibo->store(1 => 1);
  print $fibo->fetch(20), "\n";

or as a tie:

  use Tie::Cacher;
  tie my %fibo, "Tie::Cacher", load => sub {
                                  my ($self, $key, $node) = @_;
                                  $node->[0] = $self->fetch($key-1) +
                                               $self->fetch($key-2);
                              };
  $fibo{0} = 0;
  $fibo{1} = 1;
  print "$fibo{20}\n";

=head1 SEE ALSO

L<Tie::Cache>,
L<Tie::Cache::LRU>

=head1 AUTHOR

Ton Hospel, E<lt>Tie::Cacher@ton.iguana.beE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2003 by Ton Hospel

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
