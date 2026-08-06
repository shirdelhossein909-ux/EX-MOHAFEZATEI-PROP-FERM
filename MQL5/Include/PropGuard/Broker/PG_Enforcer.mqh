//+------------------------------------------------------------------+
//|                                                  PG_Enforcer.mqh |
//|      PropGuard - carries out what the rule engine decided        |
//+------------------------------------------------------------------+
//
// The engine decides; this executes. Keeping them apart is what lets
// monitor mode and guard mode produce byte-identical verdicts, with the
// only difference being whether this file is allowed to act on them.
//
// Three things here are easy to get wrong and expensive to get wrong:
//
//   * MINIMUM HOLD TIME. Some firms void an account for closing a trade
//     within N seconds of opening it. A guard that "rescues" a 10-second
//     old position would itself commit the breach. Positions younger than
//     the rule are never closed; the enforcer waits and says so.
//
//   * FAILED CLOSES. Market shut, trading disabled, requote, no connection.
//     Retrying blindly floods the journal and the broker. Failures are
//     tracked per ticket with a backoff, and a position that will not close
//     is escalated loudly rather than quietly dropped.
//
//   * REDUCE vs CLOSE_ALL. Flattening an account that is 200 dollars over
//     the line is a good way to lose a customer. Reduce mode closes the
//     single worst contributor, re-measures, and stops the moment the book
//     is compliant again.
//
#ifndef PG_ENFORCER_MQH
#define PG_ENFORCER_MQH

#include <PropGuard/Core/PG_Types.mqh>
#include <PropGuard/Core/PG_RuleSet.mqh>
#include <PropGuard/Core/PG_RiskCalc.mqh>
#include <PropGuard/Core/PG_RuleEngine.mqh>
#include <PropGuard/Core/PG_Clock.mqh>
#include <PropGuard/Broker/PG_Broker.mqh>

#define PG_MAX_ACTIONS        64
#define PG_MAX_CLOSE_ATTEMPTS  5
#define PG_RETRY_BACKOFF_SEC   3

//+------------------------------------------------------------------+
//| One thing the enforcer actually did                              |
//+------------------------------------------------------------------+
struct PG_EnforceAction
  {
   ENUM_PG_ACTION    action;
   ENUM_PG_SEVERITY  severity;
   long              ticket;
   bool              succeeded;
   string            reason;
   string            detail;

                     PG_EnforceAction()
     {
      action=PG_ACT_NONE; severity=PG_SEV_INFO; ticket=0;
      succeeded=false; reason=""; detail="";
     }
  };

struct PG_EnforceResult
  {
   PG_EnforceAction  items[PG_MAX_ACTIONS];
   int               count;
   bool              lockout_engaged;
   int               failures;
   int               deferred;            // skipped for minimum hold time

                     PG_EnforceResult() { Reset(); }

   void              Reset()
     { count=0; lockout_engaged=false; failures=0; deferred=0; }

   void              Add(const ENUM_PG_ACTION a,const ENUM_PG_SEVERITY sev,
                         const long ticket,const bool ok,const string reason,
                         const string detail)
     {
      if(count>=PG_MAX_ACTIONS)
         return;
      items[count].action    = a;
      items[count].severity  = sev;
      items[count].ticket    = ticket;
      items[count].succeeded = ok;
      items[count].reason    = reason;
      items[count].detail    = detail;
      count++;
      if(!ok)
         failures++;
     }
  };

//+------------------------------------------------------------------+
//| Enforcer                                                         |
//+------------------------------------------------------------------+
class PG_Enforcer
  {
private:
   PG_Trader         m_trader;

   //--- per-ticket failure bookkeeping so a stuck close backs off
   long              m_fail_ticket[PG_MAX_ACTIONS];
   int               m_fail_count[PG_MAX_ACTIONS];
   long              m_next_try[PG_MAX_ACTIONS];
   int               m_fail_n;

   int               FailSlot(const long ticket)
     {
      for(int i=0;i<m_fail_n;i++)
         if(m_fail_ticket[i]==ticket)
            return i;
      if(m_fail_n>=PG_MAX_ACTIONS)
         return -1;
      m_fail_ticket[m_fail_n]=ticket;
      m_fail_count[m_fail_n]=0;
      m_next_try[m_fail_n]=0;
      m_fail_n++;
      return m_fail_n-1;
     }

   void              ClearFail(const long ticket)
     {
      for(int i=0;i<m_fail_n;i++)
         if(m_fail_ticket[i]==ticket)
           {
            m_fail_ticket[i]=m_fail_ticket[m_fail_n-1];
            m_fail_count[i] =m_fail_count[m_fail_n-1];
            m_next_try[i]   =m_next_try[m_fail_n-1];
            m_fail_n--;
            return;
           }
     }

   bool              MayRetry(const long ticket,const long now)
     {
      const int s = FailSlot(ticket);
      if(s<0)
         return true;
      return (now>=m_next_try[s]);
     }

   int               NoteFailure(const long ticket,const long now)
     {
      const int s = FailSlot(ticket);
      if(s<0)
         return PG_MAX_CLOSE_ATTEMPTS;
      m_fail_count[s]++;
      //--- exponential-ish backoff, capped
      long wait = (long)PG_RETRY_BACKOFF_SEC;
      for(int i=1;i<m_fail_count[s] && wait<60;i++)
         wait *= 2;
      m_next_try[s] = now+wait;
      return m_fail_count[s];
     }

   //--- index of a position in the view, or -1
   int               FindPos(const PG_MarketView &mv,const long ticket) const
     {
      for(int i=0;i<mv.position_count;i++)
         if(mv.positions[i].ticket==ticket)
            return i;
      return -1;
     }

   //--- a position this firm forbids us to close yet
   bool              TooYoungToClose(const PG_MarketView &mv,const PG_RuleSet &eff,
                                     const int idx) const
     {
      if(eff.min_hold_seconds<=0 || idx<0)
         return false;
      return ((mv.now-mv.positions[idx].open_time)<(long)eff.min_hold_seconds);
     }

   //--- close one position, with all the excuses accounted for
   bool              TryClose(const PG_MarketView &mv,const PG_RuleSet &eff,
                              const long ticket,const string why,
                              PG_EnforceResult &res)
     {
      const int idx = FindPos(mv,ticket);
      if(idx<0)
        {
         ClearFail(ticket);
         return true;                     // already gone
        }

      if(TooYoungToClose(mv,eff,idx))
        {
         res.deferred++;
         res.Add(PG_ACT_NONE,PG_SEV_WARN,ticket,false,why,
                 "Deferred: position is "
                 +IntegerToString((int)(mv.now-mv.positions[idx].open_time))
                 +"s old and this firm requires "
                 +IntegerToString(eff.min_hold_seconds)
                 +"s minimum hold. Closing it now would be the breach.");
         return false;
        }

      if(!MayRetry(ticket,mv.now))
         return false;                    // backing off, stay quiet

      if(m_trader.ClosePosition(ticket))
        {
         ClearFail(ticket);
         res.Add(PG_ACT_CLOSE_POSITION,PG_SEV_CRITICAL,ticket,true,why,
                 mv.positions[idx].symbol+" "
                 +DoubleToString(mv.positions[idx].volume,2)+" lots");
         return true;
        }

      const int attempts = NoteFailure(ticket,mv.now);
      const bool open    = PG_MarketIsOpen(mv.positions[idx].symbol);
      const string err   = m_trader.LastError();

      res.Add(PG_ACT_CLOSE_POSITION,
              (attempts>=PG_MAX_CLOSE_ATTEMPTS ? PG_SEV_BREACH : PG_SEV_CRITICAL),
              ticket,false,why,
              (open
               ? "Close FAILED ("+IntegerToString(attempts)+"/"
                 +IntegerToString(PG_MAX_CLOSE_ATTEMPTS)+"): "+err
               : "Cannot close: "+mv.positions[idx].symbol
                 +" session is closed. Will retry when it opens. "+err));
      return false;
     }

public:
                     PG_Enforcer() { m_fail_n=0; }

   void              SetMagic(const long magic) { m_trader.SetMagic(magic); }
   void              SetSlippage(const int pts) { m_trader.SetSlippage(pts); }

   //+---------------------------------------------------------------+
   //| Reduce the book until its worst case fits again.              |
   //|                                                                |
   //| Greedy on purpose: the position whose stop would cost the most |
   //| goes first, then the book is re-measured. Closing the smallest |
   //| offenders first would close more trades than necessary.        |
   //+---------------------------------------------------------------+
   void              Reduce(const PG_MarketView &mv,const PG_RuleSet &eff,
                            const PG_RiskResult &risk,const PG_EngineState &st,
                            const string why,PG_EnforceResult &res)
     {
      double projected = risk.worst_equity;
      const double floor_needed = MathMax(st.daily_floor,st.dd_floor);

      bool closed[PG_MAX_POSITIONS];
      for(int i=0;i<PG_MAX_POSITIONS;i++)
         closed[i]=false;

      for(int round=0; round<mv.position_count; round++)
        {
         if(projected>=floor_needed)
            break;

         //--- pick the largest remaining contributor we are allowed to touch
         int    pick=-1;
         double worst=0.0;
         for(int i=0;i<risk.per_position_count;i++)
           {
            if(closed[i])
               continue;
            const int idx = FindPos(mv,risk.per_position[i].ticket);
            if(idx<0 || TooYoungToClose(mv,eff,idx))
               continue;
            if(risk.per_position[i].loss_from_now>worst)
              {
               worst = risk.per_position[i].loss_from_now;
               pick  = i;
              }
           }

         if(pick<0)
           {
            //--- nothing left that may legally be closed
            bool any_young=false;
            for(int i=0;i<risk.per_position_count;i++)
              {
               if(closed[i])
                  continue;
               const int idx = FindPos(mv,risk.per_position[i].ticket);
               if(idx>=0 && TooYoungToClose(mv,eff,idx))
                 { any_young=true; break; }
              }
            if(any_young)
               res.Add(PG_ACT_NONE,PG_SEV_BREACH,0,false,why,
                       "Cannot reduce further: every remaining position is "
                       "inside this firm's minimum hold time. Waiting.");
            break;
           }

         const long ticket = risk.per_position[pick].ticket;
         const string detail = "Reducing: worst case "+PG_Money(projected)
                               +" is below the floor "+PG_Money(floor_needed)
                               +"; this position contributes "
                               +PG_Money(risk.per_position[pick].loss_from_now)+".";

         if(TryClose(mv,eff,ticket,why+" "+detail,res))
           {
            projected += risk.per_position[pick].loss_from_now;
            closed[pick]=true;
           }
         else
           {
            closed[pick]=true;            // do not spin on an un-closable ticket
           }
        }
     }

   //+---------------------------------------------------------------+
   //| Flatten everything, positions and resting orders alike        |
   //+---------------------------------------------------------------+
   void              CloseAll(const PG_MarketView &mv,const PG_RuleSet &eff,
                              const string why,PG_EnforceResult &res)
     {
      for(int i=mv.pending_count-1;i>=0;i--)
        {
         const long t = mv.pendings[i].ticket;
         if(m_trader.DeletePending(t))
            res.Add(PG_ACT_DELETE_PENDING,PG_SEV_CRITICAL,t,true,why,
                    mv.pendings[i].symbol);
         else
            res.Add(PG_ACT_DELETE_PENDING,PG_SEV_CRITICAL,t,false,why,
                    "Delete FAILED: "+m_trader.LastError());
        }

      for(int i=mv.position_count-1;i>=0;i--)
         TryClose(mv,eff,mv.positions[i].ticket,why,res);
     }

   //+---------------------------------------------------------------+
   //| Give a stopless position the widest stop its remaining risk    |
   //| budget allows, so it stops being unbounded.                    |
   //+---------------------------------------------------------------+
   bool              AttachStop(const PG_MarketView &mv,const PG_EngineState &st,
                                const PG_UserConfig &cfg,const long ticket,
                                const string why,PG_EnforceResult &res)
     {
      const int idx = FindPos(mv,ticket);
      if(idx<0)
         return false;
      const int si = mv.positions[idx].spec_index;
      if(si<0 || si>=mv.spec_count)
         return false;

      const PG_SymbolSpec spec = mv.specs[si];
      const PG_Position   p    = mv.positions[idx];

      //--- budget for this one position: whatever headroom is left
      const double budget = st.headroom_money;
      if(budget<=0.0)
        {
         res.Add(PG_ACT_ATTACH_SL,PG_SEV_CRITICAL,ticket,false,why,
                 "No risk headroom left to place a stop within; closing instead.");
         return false;
        }

      //--- distance whose worst case equals the budget at this volume
      const double per_lot_per_tick = MathAbs(spec.tick_value)*p.volume;
      if(per_lot_per_tick<=0.0)
         return false;

      double ticks = budget/per_lot_per_tick;
      ticks /= (1.0+cfg.gap_buffer_pct/100.0);          // undo the pessimism
      const double distance = ticks*spec.tick_size;
      if(distance<=0.0)
         return false;

      const double price = (p.dir>0 ? spec.bid : spec.ask);
      double sl = (p.dir>0 ? price-distance : price+distance);
      sl = NormalizeDouble(sl,spec.digits);

      //--- respect the broker's stop level
      const long stop_level = SymbolInfoInteger(spec.name,SYMBOL_TRADE_STOPS_LEVEL);
      const double min_dist = (double)stop_level*spec.point;
      if(MathAbs(price-sl)<min_dist)
         sl = (p.dir>0 ? price-min_dist*1.5 : price+min_dist*1.5);
      sl = NormalizeDouble(sl,spec.digits);

      if(m_trader.SetStopLoss(ticket,sl,p.tp))
        {
         res.Add(PG_ACT_ATTACH_SL,PG_SEV_NOTICE,ticket,true,why,
                 "Stop placed at "+DoubleToString(sl,spec.digits)
                 +" ("+PG_Money(budget)+" of remaining headroom).");
         return true;
        }

      res.Add(PG_ACT_ATTACH_SL,PG_SEV_CRITICAL,ticket,false,why,
              "Could not place a stop: "+m_trader.LastError());
      return false;
     }

   //+---------------------------------------------------------------+
   //| Delete pending orders whose own worst case no longer fits      |
   //+---------------------------------------------------------------+
   void              PrunePendings(const PG_MarketView &mv,const PG_RuleSet &eff,
                                   const PG_UserConfig &cfg,const PG_EngineState &st,
                                   PG_EnforceResult &res)
     {
      double budget = st.headroom_money;

      for(int i=0;i<mv.pending_count;i++)
        {
         const int si = mv.pendings[i].spec_index;
         if(si<0 || si>=mv.spec_count)
            continue;

         const bool stopless = (mv.pendings[i].sl<=0.0);
         const double add = (stopless
                             ? 0.0
                             : PG_WorstLossMagnitude(mv.specs[si],
                                                     mv.pendings[i].price,
                                                     mv.pendings[i].sl,
                                                     mv.pendings[i].volume,
                                                     cfg.gap_buffer_pct,
                                                     cfg.slippage_points));

         string why="";
         if(stopless && eff.require_sl)
            why = "Pending order has no stop loss and this configuration "
                  "requires one.";
         else
            if(!stopless && !PG_FitsBudget(add,budget))
               why = "Pending order would risk "+PG_Money(add)
                     +" but only "+PG_Money(budget)+" of headroom remains. "
                     +"Removing it before it can trigger.";

         if(why=="")
           {
            budget -= add;                // it fits; reserve its share
            continue;
           }

         const long t = mv.pendings[i].ticket;
         if(m_trader.DeletePending(t))
            res.Add(PG_ACT_DELETE_PENDING,PG_SEV_WARN,t,true,why,
                    mv.pendings[i].symbol+" "
                    +DoubleToString(mv.pendings[i].volume,2)+" lots");
         else
            res.Add(PG_ACT_DELETE_PENDING,PG_SEV_CRITICAL,t,false,why,
                    "Delete FAILED: "+m_trader.LastError());
        }
     }

   //+---------------------------------------------------------------+
   //| Act on a verdict set. Highest-consequence action wins: there   |
   //| is no point trimming one position when the whole account is    |
   //| already being locked out.                                      |
   //+---------------------------------------------------------------+
   void              Execute(const PG_MarketView &mv,const PG_RuleSet &eff,
                             const PG_UserConfig &cfg,const PG_RiskResult &risk,
                             const PG_EngineState &st,const PG_VerdictSet &vs,
                             PG_EnforceResult &res)
     {
      res.Reset();

      if(cfg.enforce_mode==PG_ENFORCE_MONITOR)
         return;                          // observed, logged, untouched

      //--- 1. lockout or flatten
      for(int i=0;i<vs.count;i++)
         if(vs.items[i].action==PG_ACT_LOCKOUT || vs.items[i].action==PG_ACT_CLOSE_ALL)
           {
            res.lockout_engaged = (vs.items[i].action==PG_ACT_LOCKOUT);
            CloseAll(mv,eff,vs.items[i].reason,res);
            return;
           }

      //--- 2. individual closes
      for(int i=0;i<vs.count;i++)
         if(vs.items[i].action==PG_ACT_CLOSE_POSITION && vs.items[i].ticket!=0)
            TryClose(mv,eff,vs.items[i].ticket,vs.items[i].reason,res);

      //--- 3. missing stops
      for(int i=0;i<vs.count;i++)
         if(vs.items[i].action==PG_ACT_ATTACH_SL && vs.items[i].ticket!=0)
            if(!AttachStop(mv,st,cfg,vs.items[i].ticket,vs.items[i].reason,res))
               TryClose(mv,eff,vs.items[i].ticket,
                        vs.items[i].reason+" A stop could not be placed.",res);

      //--- 4. trim the book back inside its limits
      for(int i=0;i<vs.count;i++)
         if(vs.items[i].action==PG_ACT_REDUCE)
           {
            Reduce(mv,eff,risk,st,vs.items[i].reason,res);
            break;
           }

      //--- 5. resting orders that no longer fit
      if(vs.block_new_trades || st.tier>=PG_TIER_BLOCK)
         PrunePendings(mv,eff,cfg,st,res);
     }
  };

#endif // PG_ENFORCER_MQH
//+------------------------------------------------------------------+
