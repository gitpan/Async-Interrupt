unless (exists $SIG{USR1}) {
   print "1..0 # SKIP no SIGUSR1 - broken platform, skipping tests\n";
   exit;
}

print "1..4\n"; $|=1;

use Async::Interrupt;

my $ai = new Async::Interrupt
   cb     => sub { print "ok 3\n" },
   signal => "CHLD";

print "ok 1\n";

{
   $ai->scope_block;
   kill CHLD => $$;
   print "ok 2\n";
}

print "ok 4\n";


