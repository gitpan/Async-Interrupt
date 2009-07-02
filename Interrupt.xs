#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

typedef volatile sig_atomic_t atomic_t;

static int *sig_pending, *psig_pend; /* make local copies because of missing THX */
static Sighandler_t old_sighandler;
static atomic_t async_pending;

static int
extract_fd (SV *fh, int wr)
{
  int fd = PerlIO_fileno (wr ? IoOFP (sv_2io (fh)) : IoIFP (sv_2io (fh)));

  if (fd < 0)
    croak ("illegal fh argument, either not an OS file or read/write mode mismatch");

  return fd;
}

static SV *
get_cb (SV *cb_sv)
{
  HV *st;
  GV *gvp;
  CV *cv;

  if (!SvOK (cb_sv))
    return 0;

  cv = sv_2cv (cb_sv, &st, &gvp, 0);

  if (!cv)
    croak ("Async::Interrupt callback must be undef or a CODE reference");

  return (SV *)cv;
}

static AV *asyncs;

struct async {
  SV *cb;
  void (*c_cb)(pTHX_ void *c_arg, int value);
  void *c_arg;
  SV *fh_r, *fh_w;
  int blocked;

  int fd_r, fd_w;
  atomic_t value;
  atomic_t pending;
};

/* the main workhorse to signal */
static void
async_signal (void *signal_arg, int value)
{
  struct async *async = (struct async *)signal_arg;
  int pending = async->pending;

  async->value   = value;
  async->pending = 1;
  async_pending  = 1;
  psig_pend [9]  = 1;
  *sig_pending   = 1;

  if (!pending && async->fd_w >= 0)
    write (async->fd_w, async, 1);
}

static void
handle_async (struct async *async)
{
  int old_errno = errno;
  int value = async->value;

  async->pending = 0;

  /* drain pipe */
  if (async->fd_r >= 0)
    {
      char dummy [4];

      while (read (async->fd_r, dummy, sizeof (dummy)) == sizeof (dummy))
        ;
    }

  if (async->c_cb)
    {
      dTHX;
      async->c_cb (aTHX_ async->c_arg, value);
    }

  if (async->cb)
    {
      dSP;

      SV *saveerr = SvOK (ERRSV) ? sv_mortalcopy (ERRSV) : 0;
      SV *savedie = PL_diehook;

      PL_diehook = 0;

      PUSHSTACKi (PERLSI_SIGNAL);

      PUSHMARK (SP);
      XPUSHs (sv_2mortal (newSViv (value)));
      PUTBACK;
      call_sv (async->cb, G_VOID | G_DISCARD | G_EVAL);

      if (SvTRUE (ERRSV))
        {
          SPAGAIN;

          PUSHMARK (SP);
          PUTBACK;
          call_sv (get_sv ("Async::Interrupt::DIED", 1), G_VOID | G_DISCARD | G_EVAL | G_KEEPERR);

          sv_setpvn (ERRSV, "", 0);
        }

      if (saveerr)
        sv_setsv (ERRSV, saveerr);

      {
        SV *oldhook = PL_diehook;
        PL_diehook = savedie;
        SvREFCNT_dec (oldhook);
      }

      POPSTACK;
    }

  errno = old_errno;
}

static void
handle_asyncs (void)
{
  int i;

  async_pending = 0;

  for (i = AvFILLp (asyncs); i >= 0; --i)
    {
      struct async *async = INT2PTR (struct async *, SvIVX (AvARRAY (asyncs)[i]));

      if (async->pending && !async->blocked)
        handle_async (async);
    }
}

#if defined(HAS_SIGACTION) && defined(SA_SIGINFO)
static Signal_t async_sighandler (int signum, siginfo_t *si, void *sarg)
{
  if (signum == 9)
    handle_asyncs ();
  else
    old_sighandler (signum, si, sarg);
}
#else
static Signal_t async_sighandler (int signum)
{
  if (signum == 9)
    handle_asyncs ();
  else
    old_sighandler (signum);
}
#endif

static void
scope_block_cb (pTHX_ void *async_sv)
{
  struct async *async = INT2PTR (struct async *, SvIVX ((SV *)async_sv));

  --async->blocked;
  if (async->pending && !async->blocked)
    handle_async (async);

  SvREFCNT_dec (async_sv);
}

MODULE = Async::Interrupt		PACKAGE = Async::Interrupt

BOOT:
	old_sighandler = PL_sighandlerp;
        PL_sighandlerp = async_sighandler;
        sig_pending = &PL_sig_pending;
        psig_pend   = PL_psig_pend;
        asyncs      = newAV ();
        CvNODEBUG_on (get_cv ("Async::Interrupt::scope_block", 0)); /* otherwise calling scope can be the debugger */

PROTOTYPES: DISABLE

SV *
_alloc (SV *cb, void *c_cb, void *c_arg, SV *fh_r, SV *fh_w)
	CODE:
{
        SV *cv   = SvOK (cb) ? SvREFCNT_inc_NN (get_cb (cb)) : 0;
        int fd_r = SvOK (fh_r) ? extract_fd (fh_r, 0) : -1;
        int fd_w = SvOK (fh_w) ? extract_fd (fh_w, 1) : -1;
  	struct async *async;

        Newz (0, async, 1, struct async);

        async->fh_r   = fd_r >= 0 ? newSVsv (fh_r) : 0; async->fd_r = fd_r;
        async->fh_w   = fd_w >= 0 ? newSVsv (fh_w) : 0; async->fd_w = fd_w;
        async->cb     = cv;
        async->c_cb   = c_cb;
        async->c_arg  = c_arg;

        printf ("r,w %d,%d\n", fd_r, fd_w);//D

        RETVAL = newSViv (PTR2IV (async));
        av_push (asyncs, RETVAL);
}
	OUTPUT:
        RETVAL

void
signal_func (SV *self)
	PPCODE:
        EXTEND (SP, 2);
        PUSHs (sv_2mortal (newSViv (PTR2IV (async_signal))));
        PUSHs (sv_2mortal (newSViv (SvIVX (SvRV (self)))));

void
signal (SV *self, int value = 0)
	CODE:
        async_signal (INT2PTR (void *, SvIVX (SvRV (self))), value);

void
block (SV *self)
	CODE:
{
        struct async *async = INT2PTR (struct async *, SvIVX (SvRV (self)));
        ++async->blocked;
}

void
unblock (SV *self)
	CODE:
{
        struct async *async = INT2PTR (struct async *, SvIVX (SvRV (self)));
        --async->blocked;
        if (async->pending && !async->blocked)
          handle_async (async);
}

void
scope_block (SV *self)
	CODE:
{
	SV *async_sv = SvRV (self);
        struct async *async = INT2PTR (struct async *, SvIVX (async_sv));
        ++async->blocked;

        LEAVE; /* unfortunately, perl sandwiches XS calls into ENTER/LEAVE */
        SAVEDESTRUCTOR_X (scope_block_cb, (void *)SvREFCNT_inc (async_sv));
        ENTER; /* unfortunately, perl sandwiches XS calls into ENTER/LEAVE */
}

void
DESTROY (SV *self)
	CODE:
{
  	int i;
  	SV *async_sv = SvRV (self);
  	struct async *async = INT2PTR (struct async *, SvIVX (async_sv));

        for (i = AvFILLp (asyncs); i >= 0; --i)
          if (AvARRAY (asyncs)[i] == async_sv)
            {
              if (i < AvFILLp (asyncs))
                AvARRAY (asyncs)[i] = AvARRAY (asyncs)[AvFILLp (asyncs)];

              assert (av_pop (asyncs) == async_sv);
              goto found;
            }

        if (!PL_dirty)
          warn ("Async::Interrupt::DESTROY could not find async object in list of asyncs, please report");

	found:
        SvREFCNT_dec (async->fh_r);
        SvREFCNT_dec (async->fh_w);
        SvREFCNT_dec (async->cb);

        Safefree (async);
}

