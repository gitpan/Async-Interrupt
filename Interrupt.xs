#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

typedef volatile sig_atomic_t atomic_t;

static int *sig_pending, *psig_pend; /* make local copies because of missing THX */
static Sighandler_t old_sighandler;
static atomic_t async_pending;

#define PERL_VERSION_ATLEAST(a,b,c)                             \
  (PERL_REVISION > (a)                                          \
   || (PERL_REVISION == (a)                                     \
       && (PERL_VERSION > (b)                                   \
           || (PERL_VERSION == (b) && PERL_SUBVERSION >= (c)))))

#if defined(HAS_SIGACTION) && defined(SA_SIGINFO)
# define HAS_SA_SIGINFO 1
#endif

#if !PERL_VERSION_ATLEAST(5,10,0)
# undef HAS_SA_SIGINFO
#endif

/*****************************************************************************/
/* support stuff, copied from EV.xs mostly */

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

#ifndef SIG_SIZE
/* kudos to Slaven Rezic for the idea */
static char sig_size [] = { SIG_NUM };
# define SIG_SIZE (sizeof (sig_size) + 1)
#endif

static int
sv_signum (SV *sig)
{
  int signum;

  SvGETMAGIC (sig);

  for (signum = 1; signum < SIG_SIZE; ++signum)
    if (strEQ (SvPV_nolen (sig), PL_sig_name [signum]))
      return signum;

  signum = SvIV (sig);

  if (signum > 0 && signum < SIG_SIZE)
    return signum;

  return -1;
}

/*****************************************************************************/

typedef struct {
  SV *cb;
  void (*c_cb)(pTHX_ void *c_arg, int value);
  void *c_arg;
  SV *fh_r, *fh_w;
  int blocked;
  int signum;

  int fd_r, fd_w;
  int fd_wlen;
  atomic_t fd_enable;
  atomic_t value;
  atomic_t pending;
} async_t;

static AV *asyncs;
static async_t *sig_async [SIG_SIZE];

#define SvASYNC_nrv(sv) INT2PTR (async_t *, SvIVX (sv))
#define SvASYNC(rv)     SvASYNC_nrv (SvRV (rv))

/* the main workhorse to signal */
static void
async_signal (void *signal_arg, int value)
{
  static char pipedata [8];

  async_t *async = (async_t *)signal_arg;
  int pending = async->pending;

  async->value   = value;
  async->pending = 1;
  async_pending  = 1;
  psig_pend [9]  = 1;
  *sig_pending   = 1;

  if (!pending && async->fd_w >= 0 && async->fd_enable)
    if (write (async->fd_w, pipedata, async->fd_wlen) < 0 && errno == EINVAL)
      /* on EINVAL we assume it's an eventfd */
      write (async->fd_w, pipedata, (async->fd_wlen = 8));
}

static void
handle_async (async_t *async)
{
  int old_errno = errno;
  int value = async->value;

  async->pending = 0;

  /* drain pipe */
  if (async->fd_r >= 0 && async->fd_enable)
    {
      char dummy [9]; /* 9 is enough for eventfd and normal pipes */

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
      async_t *async = SvASYNC_nrv (AvARRAY (asyncs)[i]);

      if (async->pending && !async->blocked)
        handle_async (async);
    }
}

#if HAS_SA_SIGINFO
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
async_sigsend (int signum)
{
  async_signal (sig_async [signum], 0);
}

static void
scope_block_cb (pTHX_ void *async_sv)
{
  async_t *async = SvASYNC_nrv ((SV *)async_sv);

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

void
_alloc (SV *cb, void *c_cb, void *c_arg, SV *fh_r, SV *fh_w, SV *signl)
	PPCODE:
{
        SV *cv   = SvOK (cb) ? SvREFCNT_inc (get_cb (cb)) : 0;
        int fd_r = SvOK (fh_r) ? extract_fd (fh_r, 0) : -1;
        int fd_w = SvOK (fh_w) ? extract_fd (fh_w, 1) : -1;
  	async_t *async;

        Newz (0, async, 1, async_t);

        XPUSHs (sv_2mortal (newSViv (PTR2IV (async))));
        av_push (asyncs, TOPs);

        async->fh_r      = fd_r >= 0 ? newSVsv (fh_r) : 0; async->fd_r = fd_r;
        async->fh_w      = fd_w >= 0 ? newSVsv (fh_w) : 0; async->fd_w = fd_w;
        async->fd_wlen   = 1;
        async->fd_enable = 1;
        async->cb        = cv;
        async->c_cb      = c_cb;
        async->c_arg     = c_arg;
        SvGETMAGIC (signl);
        async->signum    = SvOK (signl) ? sv_signum (signl) : 0;

        if (async->signum)
          {
            if (async->signum < 0)
              croak ("Async::Interrupt::new got passed illegal signal name or number: %s", SvPV_nolen (signl));

            sig_async [async->signum] = async;
#if _WIN32
            signal (async->signum, async_sigsend);
#else
            {
              struct sigaction sa = { };
              sa.sa_handler = async_sigsend;
              sigfillset (&sa.sa_mask);
              sigaction (async->signum, &sa, 0);
            }
#endif
          }
}

void
signal_func (async_t *async)
	PPCODE:
        EXTEND (SP, 2);
        PUSHs (sv_2mortal (newSViv (PTR2IV (async_signal))));
        PUSHs (sv_2mortal (newSViv (PTR2IV (async))));

void
signal (async_t *async, int value = 0)
	CODE:
        async_signal (async, value);

void
block (async_t *async)
	CODE:
        ++async->blocked;

void
unblock (async_t *async)
	CODE:
        --async->blocked;
        if (async->pending && !async->blocked)
          handle_async (async);

void
scope_block (SV *self)
	CODE:
{
	SV *async_sv = SvRV (self);
        async_t *async = SvASYNC_nrv (async_sv);
        ++async->blocked;

        LEAVE; /* unfortunately, perl sandwiches XS calls into ENTER/LEAVE */
        SAVEDESTRUCTOR_X (scope_block_cb, (void *)SvREFCNT_inc (async_sv));
        ENTER; /* unfortunately, perl sandwiches XS calls into ENTER/LEAVE */
}

void
pipe_enable (async_t *async)
	ALIAS:
        pipe_enable = 1
        pipe_disable = 0
	CODE:
        async->fd_enable = ix;

void
DESTROY (SV *self)
	CODE:
{
  	int i;
  	SV *async_sv = SvRV (self);
  	async_t *async = SvASYNC_nrv (async_sv);

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

        if (async->signum)
          {
#if _WIN32
            signal (async->signum, SIG_DFL);
#else
            {
              struct sigaction sa = { };
              sa.sa_handler = SIG_DFL;
              sigaction (async->signum, &sa, 0);
            }
#endif
          }

        SvREFCNT_dec (async->fh_r);
        SvREFCNT_dec (async->fh_w);
        SvREFCNT_dec (async->cb);

        Safefree (async);
}

