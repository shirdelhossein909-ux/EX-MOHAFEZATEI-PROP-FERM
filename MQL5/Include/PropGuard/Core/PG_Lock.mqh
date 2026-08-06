//+------------------------------------------------------------------+
//|                                                      PG_Lock.mqh |
//|      PropGuard - the tighten-only lock, and what happens when    |
//|      someone tries to get around it                              |
//+------------------------------------------------------------------+
//
// The failure this addresses is not technical. It is the trader who, at
// 2am after three losing trades, opens the settings and widens their own
// daily limit. Everything here exists to make that specific act difficult
// and slow, while never getting in the way of tightening.
//
// The rules:
//
//   1. Tightening is always allowed, at any time.
//   2. Loosening is refused while the lock window is open. That includes
//      un-tightening: the 2am trader must not be able to undo their 9am
//      self before the window closes.
//   3. The window runs to the next weekly rollover. Once it closes, the
//      settings are fully editable again - this is a weekly commitment,
//      not a life sentence, and a tool that never lets go gets
//      uninstalled instead of obeyed.
//   4. Inside the window there is still a way out, but it costs 24 hours.
//      A wrong firm was chosen, the account changed, a new challenge
//      started - those are real. Request the unlock now, it applies
//      tomorrow.
//   5. Changing accounts resets everything immediately, because the lock
//      is bound to one account login.
//
// And the part that makes tampering pointless:
//
//   6. The strictest configuration ever recorded for the account is kept
//      alongside the current one. If the state file is missing, corrupt,
//      or fails its signature, PropGuard does NOT fall back to defaults -
//      it restores that strictest configuration and opens a fresh lock
//      window. Deleting the file to escape a limit therefore achieves
//      nothing except resetting the clock against yourself.
//
#ifndef PG_LOCK_MQH
#define PG_LOCK_MQH

#include <PropGuard/Core/PG_Types.mqh>
#include <PropGuard/Core/PG_RuleSet.mqh>
#include <PropGuard/Core/PG_Clock.mqh>
#include <PropGuard/Core/PG_Hash.mqh>

#define PG_UNLOCK_DELAY_SECONDS  86400   // 24 hours of friction

//+------------------------------------------------------------------+
//| Persisted state                                                  |
//+------------------------------------------------------------------+
struct PG_LockState
  {
   long              account_login;
   string            firm_id;
   string            program_id;
   string            phase_label;

   long              locked_until;         // server epoch, 0 = not locked
   long              locked_at;
   long              counter;              // monotonic; catches restored backups
   long              unlock_requested_at;  // 0 = no pending request

   PG_UserConfig     current;              // what is in force
   PG_UserConfig     strictest;            // tightest ever recorded, the floor
   bool              has_strictest;

   ulong             signature;

                     PG_LockState() { Clear(); }

   void              Clear()
     {
      account_login=0; firm_id=""; program_id=""; phase_label="";
      locked_until=0; locked_at=0; counter=0; unlock_requested_at=0;
      current.Defaults(); strictest.Defaults();
      has_strictest=false; signature=0;
     }
  };

//+------------------------------------------------------------------+
//| Tightness comparison                                             |
//|                                                                  |
//| For "smaller is stricter" fields a value of 0 means "no limit",   |
//| so it ranks as the loosest possible value rather than the         |
//| tightest. Getting this backwards would let a trader erase every   |
//| limit by typing zeros, which is exactly the move being defended   |
//| against.                                                          |
//+------------------------------------------------------------------+
double PG_AsCeiling(const double v)
  {
   return (v<=0.0 ? 1e18 : v);
  }

double PG_AsCeilingInt(const int v)
  {
   return (v<=0 ? 1e18 : (double)v);
  }

//--- is `proposed` at least as strict as `reference` in every field?
bool PG_IsAtLeastAsStrict(const PG_UserConfig &proposed,const PG_UserConfig &reference,
                          string &first_loosened)
  {
   first_loosened="";

   if(PG_AsCeiling(proposed.daily_limit_pct)>PG_AsCeiling(reference.daily_limit_pct))
     { first_loosened="daily loss limit"; return false; }

   if(PG_AsCeiling(proposed.maxdd_limit_pct)>PG_AsCeiling(reference.maxdd_limit_pct))
     { first_loosened="max drawdown limit"; return false; }

   if(PG_AsCeiling(proposed.max_risk_per_trade_pct)
      >PG_AsCeiling(reference.max_risk_per_trade_pct))
     { first_loosened="risk per trade"; return false; }

   if(PG_AsCeiling(proposed.max_lot_per_trade_per_100k)
      >PG_AsCeiling(reference.max_lot_per_trade_per_100k))
     { first_loosened="lot size per trade"; return false; }

   if(PG_AsCeiling(proposed.max_total_lots_per_100k)
      >PG_AsCeiling(reference.max_total_lots_per_100k))
     { first_loosened="total lots"; return false; }

   if(PG_AsCeilingInt(proposed.max_open_positions)
      >PG_AsCeilingInt(reference.max_open_positions))
     { first_loosened="open position limit"; return false; }

   //--- buffers: a bigger buffer is stricter, so it may only grow
   if(proposed.gap_buffer_pct<reference.gap_buffer_pct)
     { first_loosened="gap buffer"; return false; }
   if(proposed.slippage_points<reference.slippage_points)
     { first_loosened="slippage allowance"; return false; }

   //--- tiers: acting sooner is stricter, so they may only come down
   if(proposed.warn_at_pct>reference.warn_at_pct)
     { first_loosened="warning threshold"; return false; }
   if(proposed.block_at_pct>reference.block_at_pct)
     { first_loosened="block threshold"; return false; }

   //--- protections may be switched on but never off
   if(reference.require_sl && !proposed.require_sl)
     { first_loosened="mandatory stop loss"; return false; }
   if(reference.forbid_weekend_holding && !proposed.forbid_weekend_holding)
     { first_loosened="weekend holding block"; return false; }
   if(reference.news_blackout_enabled && !proposed.news_blackout_enabled)
     { first_loosened="news blackout"; return false; }

   //--- monitor mode is the least strict enforcement setting
   if(proposed.enforce_mode==PG_ENFORCE_MONITOR
      && reference.enforce_mode!=PG_ENFORCE_MONITOR)
     { first_loosened="enforcement mode"; return false; }

   return true;
  }

//+------------------------------------------------------------------+
//| Field-by-field tightest of two configurations                    |
//+------------------------------------------------------------------+
void PG_MergeStrictest(const PG_UserConfig &a,const PG_UserConfig &b,
                       PG_UserConfig &out)
  {
   out = a;
   out.use_overrides = true;

   out.daily_limit_pct = MathMin(PG_AsCeiling(a.daily_limit_pct),
                                 PG_AsCeiling(b.daily_limit_pct));
   if(out.daily_limit_pct>=1e17) out.daily_limit_pct=0.0;

   out.maxdd_limit_pct = MathMin(PG_AsCeiling(a.maxdd_limit_pct),
                                 PG_AsCeiling(b.maxdd_limit_pct));
   if(out.maxdd_limit_pct>=1e17) out.maxdd_limit_pct=0.0;

   out.max_risk_per_trade_pct = MathMin(PG_AsCeiling(a.max_risk_per_trade_pct),
                                        PG_AsCeiling(b.max_risk_per_trade_pct));
   if(out.max_risk_per_trade_pct>=1e17) out.max_risk_per_trade_pct=0.0;

   out.max_lot_per_trade_per_100k = MathMin(PG_AsCeiling(a.max_lot_per_trade_per_100k),
                                            PG_AsCeiling(b.max_lot_per_trade_per_100k));
   if(out.max_lot_per_trade_per_100k>=1e17) out.max_lot_per_trade_per_100k=0.0;

   out.max_total_lots_per_100k = MathMin(PG_AsCeiling(a.max_total_lots_per_100k),
                                         PG_AsCeiling(b.max_total_lots_per_100k));
   if(out.max_total_lots_per_100k>=1e17) out.max_total_lots_per_100k=0.0;

   const double pos = MathMin(PG_AsCeilingInt(a.max_open_positions),
                              PG_AsCeilingInt(b.max_open_positions));
   out.max_open_positions = (pos>=1e17 ? 0 : (int)pos);

   out.gap_buffer_pct  = MathMax(a.gap_buffer_pct,b.gap_buffer_pct);
   out.slippage_points = MathMax(a.slippage_points,b.slippage_points);
   out.warn_at_pct     = MathMin(a.warn_at_pct,b.warn_at_pct);
   out.block_at_pct    = MathMin(a.block_at_pct,b.block_at_pct);

   out.require_sl             = (a.require_sl             || b.require_sl);
   out.forbid_weekend_holding = (a.forbid_weekend_holding || b.forbid_weekend_holding);
   out.news_blackout_enabled  = (a.news_blackout_enabled  || b.news_blackout_enabled);

   //--- monitor is the weakest; anything else beats it
   if(a.enforce_mode==PG_ENFORCE_MONITOR)
      out.enforce_mode = b.enforce_mode;
   else
      if(b.enforce_mode==PG_ENFORCE_MONITOR)
         out.enforce_mode = a.enforce_mode;
      else
         out.enforce_mode = (a.enforce_mode==PG_ENFORCE_CLOSE
                             || b.enforce_mode==PG_ENFORCE_CLOSE
                             ? PG_ENFORCE_CLOSE : PG_ENFORCE_REDUCE);
  }

//+------------------------------------------------------------------+
//| Lock status                                                      |
//+------------------------------------------------------------------+
bool PG_LockIsActive(const PG_LockState &st,const long now)
  {
   return (st.locked_until>0 && now<st.locked_until);
  }

long PG_LockSecondsRemaining(const PG_LockState &st,const long now)
  {
   if(!PG_LockIsActive(st,now))
      return 0;
   return st.locked_until-now;
  }

//--- when a pending unlock request becomes effective, 0 if none
long PG_UnlockEffectiveAt(const PG_LockState &st)
  {
   if(st.unlock_requested_at<=0)
      return 0;
   return st.unlock_requested_at+PG_UNLOCK_DELAY_SECONDS;
  }

bool PG_UnlockIsDue(const PG_LockState &st,const long now)
  {
   const long due = PG_UnlockEffectiveAt(st);
   return (due>0 && now>=due);
  }

//+------------------------------------------------------------------+
//| May this configuration change be applied right now?              |
//+------------------------------------------------------------------+
bool PG_CanApplyConfig(const PG_LockState &st,const PG_UserConfig &proposed,
                       const long now,string &reason)
  {
   reason="";

   //--- the window has closed: the week's commitment is served
   if(!PG_LockIsActive(st,now))
      return true;

   //--- tightening always goes through, lock or no lock
   string field="";
   if(PG_IsAtLeastAsStrict(proposed,st.current,field))
      return true;

   //--- a request made 24 hours ago opens the window early
   if(PG_UnlockIsDue(st,now))
      return true;

   const long due = PG_UnlockEffectiveAt(st);
   if(due>0)
      reason="Cannot loosen "+field+" yet. The unlock you requested takes "
             +"effect in "+PG_FormatDuration(due-now)+".";
   else
      reason="Cannot loosen "+field+" while the lock is on. It opens in "
             +PG_FormatDuration(st.locked_until-now)
             +", or request an unlock and it applies 24 hours from now.";
   return false;
  }

//+------------------------------------------------------------------+
//| Apply a configuration change, updating the lock window and the   |
//| strictest-ever floor. Caller must have checked PG_CanApplyConfig.|
//+------------------------------------------------------------------+
void PG_ApplyConfig(PG_LockState &st,const PG_UserConfig &proposed,
                    const long now,const PG_RuleSet &rules)
  {
   PG_UserConfig merged;
   if(st.has_strictest)
      PG_MergeStrictest(st.strictest,proposed,merged);
   else
      merged = proposed;

   st.strictest     = merged;
   st.has_strictest = true;
   st.current       = proposed;
   st.locked_at     = now;
   st.locked_until  = PG_NextWeekStartServer(now,rules);
   st.counter       = st.counter+1;

   //--- a successful change consumes any pending unlock request
   st.unlock_requested_at = 0;
  }

//+------------------------------------------------------------------+
//| Request the 24 hour unlock. Idempotent: asking twice does not    |
//| restart the clock, otherwise impatience would make it shorter.   |
//+------------------------------------------------------------------+
void PG_RequestUnlock(PG_LockState &st,const long now)
  {
   if(st.unlock_requested_at<=0)
      st.unlock_requested_at = now;
  }

void PG_CancelUnlock(PG_LockState &st)
  {
   st.unlock_requested_at = 0;
  }

//+------------------------------------------------------------------+
//| Switching account, firm, program or phase resets the lock. The   |
//| strictest-ever floor is kept only while the account is the same. |
//+------------------------------------------------------------------+
bool PG_BindingChanged(const PG_LockState &st,const long account,
                       const string firm_id,const string program_id,
                       const string phase)
  {
   if(st.account_login==0)
      return false;
   return (st.account_login!=account || st.firm_id!=firm_id
           || st.program_id!=program_id || st.phase_label!=phase);
  }

void PG_Rebind(PG_LockState &st,const long account,const string firm_id,
               const string program_id,const string phase,const long now)
  {
   const bool same_account = (st.account_login==account);

   st.account_login = account;
   st.firm_id       = firm_id;
   st.program_id    = program_id;
   st.phase_label   = phase;
   st.locked_until  = 0;
   st.locked_at     = now;
   st.unlock_requested_at = 0;
   st.counter       = st.counter+1;

   if(!same_account)
     {
      //--- a different account is a different challenge; the old floor
      //--- has nothing to say about it
      st.has_strictest = false;
      st.strictest.Defaults();
     }
  }

//+------------------------------------------------------------------+
//| Signature over the fields worth protecting                       |
//+------------------------------------------------------------------+
string PG_LockPayload(const PG_LockState &st)
  {
   return IntegerToString(st.account_login)+"|"
          +st.firm_id+"|"+st.program_id+"|"+st.phase_label+"|"
          +IntegerToString(st.locked_until)+"|"
          +IntegerToString(st.locked_at)+"|"
          +IntegerToString(st.counter)+"|"
          +IntegerToString(st.unlock_requested_at)+"|"
          +DoubleToString(st.current.daily_limit_pct,4)+"|"
          +DoubleToString(st.current.maxdd_limit_pct,4)+"|"
          +DoubleToString(st.current.max_risk_per_trade_pct,4)+"|"
          +DoubleToString(st.current.max_lot_per_trade_per_100k,4)+"|"
          +DoubleToString(st.current.max_total_lots_per_100k,4)+"|"
          +IntegerToString(st.current.max_open_positions)+"|"
          +DoubleToString(st.current.gap_buffer_pct,4)+"|"
          +DoubleToString(st.current.slippage_points,4)+"|"
          +DoubleToString(st.current.warn_at_pct,4)+"|"
          +DoubleToString(st.current.block_at_pct,4)+"|"
          +IntegerToString((int)st.current.enforce_mode)+"|"
          +(st.current.require_sl ? "1" : "0")
          +(st.current.forbid_weekend_holding ? "1" : "0")
          +(st.current.news_blackout_enabled ? "1" : "0")+"|"
          +(st.has_strictest ? "1" : "0")+"|"
          +DoubleToString(st.strictest.daily_limit_pct,4)+"|"
          +DoubleToString(st.strictest.maxdd_limit_pct,4)+"|"
          +DoubleToString(st.strictest.max_risk_per_trade_pct,4)+"|"
          +DoubleToString(st.strictest.max_lot_per_trade_per_100k,4)+"|"
          +DoubleToString(st.strictest.max_total_lots_per_100k,4)+"|"
          +IntegerToString(st.strictest.max_open_positions)+"|"
          +DoubleToString(st.strictest.gap_buffer_pct,4)+"|"
          +DoubleToString(st.strictest.slippage_points,4)+"|"
          +DoubleToString(st.strictest.warn_at_pct,4)+"|"
          +DoubleToString(st.strictest.block_at_pct,4)+"|"
          +IntegerToString((int)st.strictest.enforce_mode)+"|"
          +(st.strictest.require_sl ? "1" : "0")
          +(st.strictest.forbid_weekend_holding ? "1" : "0")
          +(st.strictest.news_blackout_enabled ? "1" : "0");
  }

void PG_SignLockState(PG_LockState &st,const string key)
  {
   st.signature = PG_HashKeyed(PG_LockPayload(st),key);
  }

bool PG_VerifyLockState(const PG_LockState &st,const string key)
  {
   return (st.signature!=0
           && st.signature==PG_HashKeyed(PG_LockPayload(st),key));
  }

//+------------------------------------------------------------------+
//| What to run with when the stored state cannot be trusted.        |
//|                                                                  |
//| Never defaults. Either the strictest configuration we still have  |
//| a record of, or - if there is nothing at all - the built-in       |
//| defaults with the lock already closed, so the trader has to wait  |
//| out a window before they can loosen anything.                    |
//+------------------------------------------------------------------+
void PG_FallbackToStrictest(PG_LockState &st,const long account,
                            const long now,const PG_RuleSet &rules,
                            const bool had_recoverable_floor)
  {
   PG_UserConfig floor_cfg;
   if(had_recoverable_floor && st.has_strictest)
      floor_cfg = st.strictest;
   else
     {
      floor_cfg.Defaults();
      floor_cfg.use_overrides = true;
     }

   st.account_login = account;
   st.current       = floor_cfg;
   st.strictest     = floor_cfg;
   st.has_strictest = true;
   st.locked_at     = now;
   st.locked_until  = PG_NextWeekStartServer(now,rules);
   st.unlock_requested_at = 0;
   st.counter       = st.counter+1;
  }

#endif // PG_LOCK_MQH
//+------------------------------------------------------------------+
