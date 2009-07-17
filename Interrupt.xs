#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "schmorp.h"

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

typedef struct {
  SV *cb;
  void (*c_cb)(pTHX_ void *c_arg, int value);
  void *c_arg;
  SV *fh_r, *fh_w;
  SV *value;
  int signum;
  volatile int blocked;

  s_epipe ep;
  int fd_wlen;
  atomic_t fd_enable;
  atomic_t pending;
  volatile IV *valuep;
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

  *async->valuep = value ? value : 1;
  async->pending = 1;
  async_pending  = 1;
  psig_pend [9]  = 1;
  *sig_pending   = 1;

  {
    int fd_enable = async->fd_enable;

    if (!pending && fd_enable && async->ep.fd [1] >= 0)
      s_epipe_signal (&async->ep);
  }
}

static void
handle_async (async_t *async)
{
  int old_errno = errno;
  int value = *async->valuep;

  *async->valuep = 0;
  async->pending = 0;

  /* drain pipe */
  if (async->fd_enable && async->ep.fd [0] >= 0)
    s_epipe_drain (&async->ep);

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

#define block(async) ++(async)->blocked

static void
unblock (async_t *async)
{
  --async->blocked;
  if (async->pending && !async->blocked)
    handle_async (async);
}

static void
scope_block_cb (pTHX_ void *async_sv)
{
  async_t *async = SvASYNC_nrv ((SV *)async_sv);
  unblock (async);
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
_alloc (SV *cb, void *c_cb, void *c_arg, SV *fh_r, SV *fh_w, SV *signl, SV *pvalue)
	PPCODE:
{
        SV *cv   = SvOK (cb) ? SvREFCNT_inc (s_get_cv_croak (cb)) : 0;
  	async_t *async;

        Newz (0, async, 1, async_t);

        XPUSHs (sv_2mortal (newSViv (PTR2IV (async))));
        /* TODO: need to bless right now to ensure deallocation */
        av_push (asyncs, TOPs);

        SvGETMAGIC (fh_r); SvGETMAGIC (fh_w);
        if (SvOK (fh_r) || SvOK (fh_w))
          {
            int fd_r = s_fileno_croak (fh_r, 0);
            int fd_w = s_fileno_croak (fh_w, 1);

            async->fh_r      = newSVsv (fh_r);
            async->fh_w      = newSVsv (fh_w);
            async->ep.fd [0] = fd_r;
            async->ep.fd [1] = fd_w;
            async->ep.len    = 1;
            async->fd_enable = 1;
          }

        async->value     = SvROK (pvalue)
                           ? SvREFCNT_inc_NN (SvRV (pvalue))
                           : NEWSV (0, 0);

        sv_setiv (async->value, 0);
        SvIOK_only (async->value); /* just to be sure */
        SvREADONLY_on (async->value);

        async->valuep    = &(SvIVX (async->value));

        async->cb        = cv;
        async->c_cb      = c_cb;
        async->c_arg     = c_arg;
        async->signum    = SvOK (signl) ? s_signum_croak (signl) : 0;

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

IV
c_var (async_t *async)
	CODE:
        RETVAL = PTR2IV (async->valuep);
	OUTPUT:
        RETVAL

void
signal (async_t *async, int value = 1)
	CODE:
        async_signal (async, value);

void
block (async_t *async)
	CODE:
        block (async);

void
unblock (async_t *async)
	CODE:
        unblock (async);

void
scope_block (SV *self)
	CODE:
{
	SV *async_sv = SvRV (self);
        async_t *async = SvASYNC_nrv (async_sv);
        block (async);

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

int
pipe_fileno (async_t *async)
	CODE:
        if (!async->ep.len)
          {
            int res;

            /*block (async);*//*TODO*/
            res = s_epipe_new (&async->ep);
            async->fd_enable = 1;
            /*unblock (async);*//*TODO*/

            if (res < 0)
              croak ("Async::Interrupt: unable to initialize event pipe");
          }

	RETVAL = async->ep.fd [0];
	OUTPUT:
        RETVAL


void
post_fork (async_t *async)
	CODE:
        if (async->ep.len)
          {
  	    int res;

            /*block (async);*//*TODO*/
            res = s_epipe_renew (&async->ep);
            /*unblock (async);*//*TODO*/

            if (res < 0)
              croak ("Async::Interrupt: unable to initialize event pipe after fork");
          }

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

        if (!async->fh_r && async->ep.len)
          s_epipe_destroy (&async->ep);

        SvREFCNT_dec (async->fh_r);
        SvREFCNT_dec (async->fh_w);
        SvREFCNT_dec (async->cb);
        SvREFCNT_dec (async->value);

        Safefree (async);
}

