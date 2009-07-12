=head1 NAME

Async::Interrupt - allow C/XS libraries to interrupt perl asynchronously

=head1 SYNOPSIS

 use Async::Interrupt;

=head1 DESCRIPTION

This module implements a single feature only of interest to advanced perl
modules, namely asynchronous interruptions (think "UNIX signals", which
are very similar).

Sometimes, modules wish to run code asynchronously (in another thread,
or from a signal handler), and then signal the perl interpreter on
certain events. One common way is to write some data to a pipe and use an
event handling toolkit to watch for I/O events. Another way is to send
a signal. Those methods are slow, and in the case of a pipe, also not
asynchronous - it won't interrupt a running perl interpreter.

This module implements asynchronous notifications that enable you to
signal running perl code from another thread, asynchronously, and
sometimes even without using a single syscall.

=head2 USAGE SCENARIOS

=over 4

=item Race-free signal handling

There seems to be no way to do race-free signal handling in perl: to
catch a signal, you have to execute Perl code, and between entering the
interpreter C<select> function (or other blocking functions) and executing
the select syscall is a small but relevant timespan during which signals
will be queued, but perl signal handlers will not be executed and the
blocking syscall will not be interrupted.

You can use this module to bind a signal to a callback while at the same
time activating an event pipe that you can C<select> on, fixing the race
completely.

This can be used to implement the signal hadling in event loops,
e.g. L<AnyEvent>, L<POE>, L<IO::Async::Loop> and so on.

=item Background threads want speedy reporting

Assume you want very exact timing, and you can spare an extra cpu core
for that. Then you can run an extra thread that signals your perl
interpreter. This means you can get a very exact timing source while your
perl code is number crunching, without even using a syscall to communicate
between your threads.

For example the deliantra game server uses a variant of this technique
to interrupt background processes regularly to send map updates to game
clients.

L<IO::AIO> and L<BDB> could also use this to speed up result reporting.

=item Speedy event loop invocation

One could use this module e.g. in L<Coro> to interrupt a running coro-thread
and cause it to enter the event loop.

Or one could bind to C<SIGIO> and tell some important sockets to send this
signal, causing the event loop to be entered to reduce network latency.

=back

=head2 HOW TO USE

You can use this module by creating an C<Async::Interrupt> object for each
such event source. This object stores a perl and/or a C-level callback
that is invoked when the C<Async::Interrupt> object gets signalled. It is
executed at the next time the perl interpreter is running (i.e. it will
interrupt a computation, but not an XS function or a syscall).

You can signal the C<Async::Interrupt> object either by calling it's C<<
->signal >> method, or, more commonly, by calling a C function. There is
also the built-in (POSIX) signal source.

The C<< ->signal_func >> returns the address of the C function that is to
be called (plus an argument to be used during the call). The signalling
function also takes an integer argument in the range SIG_ATOMIC_MIN to
SIG_ATOMIC_MAX (guaranteed to allow at least 0..127).

Since this kind of interruption is fast, but can only interrupt a
I<running> interpreter, there is optional support for signalling a pipe
- that means you can also wait for the pipe to become readable (e.g. via
L<EV> or L<AnyEvent>). This, of course, incurs the overhead of a C<read>
and C<write> syscall.

=over 4

=cut

package Async::Interrupt;

no warnings;

BEGIN {
   $VERSION = '0.041';

   require XSLoader;
   XSLoader::load Async::Interrupt::, $VERSION;
}

our $DIED = sub { warn "$@" };

=item $async = new Async::Interrupt key => value...

Creates a new Async::Interrupt object. You may only use async
notifications on this object while it exists, so you need to keep a
reference to it at all times while it is used.

Optional constructor arguments include (normally you would specify at
least one of C<cb> or C<c_cb>).

=over 4

=item cb => $coderef->($value)

Registers a perl callback to be invoked whenever the async interrupt is
signalled.

Note that, since this callback can be invoked at basically any time, it
must not modify any well-known global variables such as C<$/> without
restoring them again before returning.

The exceptions are C<$!> and C<$@>, which are saved and restored by
Async::Interrupt.

If the callback should throw an exception, then it will be caught,
and C<$Async::Interrupt::DIED> will be called with C<$@> containing
the exception.  The default will simply C<warn> about the message and
continue.

=item c_cb => [$c_func, $c_arg]

Registers a C callback the be invoked whenever the async interrupt is
signalled.

The C callback must have the following prototype:

   void c_func (pTHX_ void *c_arg, int value);

Both C<$c_func> and C<$c_arg> must be specified as integers/IVs, and
C<$value> is the C<value> passed to some earlier call to either C<$signal>
or the C<signal_func> function.

Note that, because the callback can be invoked at almost any time, you
have to be careful at saving and restoring global variables that Perl
might use (the exception is C<errno>, which is saved and restored by
Async::Interrupt). The callback itself runs as part of the perl context,
so you can call any perl functions and modify any perl data structures (in
which case the requirements set out for C<cb> apply as well).

=item signal => $signame_or_value

When this parameter is specified, then the Async::Interrupt will hook the
given signal, that is, it will effectively call C<< ->signal (0) >> each time
the given signal is caught by the process.

Only one async can hook a given signal, and the signal will be restored to
defaults when the Async::Interrupt object gets destroyed.

=item pipe => [$fileno_or_fh_for_reading, $fileno_or_fh_for_writing]

Specifies two file descriptors (or file handles) that should be signalled
whenever the async interrupt is signalled. This means a single octet will
be written to it, and before the callback is being invoked, it will be
read again. Due to races, it is unlikely but possible that multiple octets
are written. It is required that the file handles are both in nonblocking
mode.

You can get a portable pipe and set non-blocking mode portably by using
e.g. L<AnyEvent::Util> from the L<AnyEvent> distribution.

It is also possible to pass in a linux eventfd as both read and write
handle (which is faster than a pipe).

The object will keep a reference to the file handles.

This can be used to ensure that async notifications will interrupt event
frameworks as well.

=back

=cut

sub new {
   my ($class, %arg) = @_;

   bless \(_alloc $arg{cb}, @{$arg{c_cb}}[0,1], @{$arg{pipe}}[0,1], $arg{signal}), $class
}

=item ($signal_func, $signal_arg) = $async->signal_func

Returns the address of a function to call asynchronously. The function has
the following prototype and needs to be passed the specified C<$c_arg>,
which is a C<void *> cast to C<IV>:

   void (*signal_func) (void *signal_arg, int value)

An example call would look like:

   signal_func (signal_arg, 0);

The function is safe to call from within signal and thread contexts, at
any time. The specified C<value> is passed to both C and Perl callback.

C<$value> must be in the valid range for a C<sig_atomic_t> (0..127 is
portable).

If the function is called while the Async::Interrupt object is already
signaled but before the callbacks are being executed, then the stored
C<value> is either the old or the new one. Due to the asynchronous
nature of the code, the C<value> can even be passed to two consecutive
invocations of the callback.

=item $async->signal ($value=0)

This signals the given async object from Perl code. Semi-obviously, this
will instantly trigger the callback invocation.

C<$value> must be in the valid range for a C<sig_atomic_t> (0..127 is
portable).

=item $async->block

=item $async->unblock

Sometimes you need a "critical section" of code that will not be
interrupted by an Async::Interrupt. This can be implemented by calling C<<
$async->block >> before the critical section, and C<< $async->unblock >>
afterwards.

Note that there must be exactly one call of C<unblock> for every previous
call to C<block> (i.e. calls can nest).

Since ensuring this in the presence of exceptions and threads is
usually more difficult than you imagine, I recommend using C<<
$async->scoped_block >> instead.

=item $async->scope_block

This call C<< $async->block >> and installs a handler that is called when
the current scope is exited (via an exception, by canceling the Coro
thread, by calling last/goto etc.).

This is the recommended (and fastest) way to implement critical sections.

=item $async->pipe_enable

=item $async->pipe_disable

Enable/disable signalling the pipe when the interrupt occurs (default is
enabled). Writing to a pipe is relatively expensive, so it can be disabled
when you know you are not waiting for it (for example, with L<EV> you
could disable the pipe in a check watcher, and enable it in a prepare
watcher).

Note that when C<fd_disable> is in effect, no attempt to read from the
pipe will be done.

=cut

1;

=back

=head1 EXAMPLE

There really should be a complete C/XS example. Bug me about it. Better
yet, create one.

=head1 IMPLEMENTATION DETAILS AND LIMITATIONS

This module works by "hijacking" SIGKILL, which is guaranteed to always
exist, but also cannot be caught, so is always available.

Basically, this module fakes the occurance of a SIGKILL signal and
then intercepts the interpreter handling it. This makes normal signal
handling slower (probably unmeasurably, though), but has the advantage
of not requiring a special runops function, nor slowing down normal perl
execution a bit.

It assumes that C<sig_atomic_t> and C<int> are both async-safe to modify
(C<sig_atomic_> is used by this module, and perl itself uses C<int>, so we
can assume that this is quite portable, at least w.r.t. signals).

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

