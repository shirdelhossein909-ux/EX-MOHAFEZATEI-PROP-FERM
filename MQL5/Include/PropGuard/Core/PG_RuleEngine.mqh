//+------------------------------------------------------------------+
//|                                                PG_RuleEngine.mqh |
//|      PropGuard - evaluates every rule against one snapshot and   |
//|      returns what should happen, and why, in plain language      |
//+------------------------------------------------------------------+
//
// A pure function: (market view, effective rules, firm rules, config)
// -> verdicts. No side effects, no API calls, no closing of anything.
// The enforcer decides what to do with the verdicts; keeping the two
// apart is what makes monitor mode and guard mode produce identical logs.
//
// Every violation carries BOTH limits - the trader's own and the firm's -
// because a trader who is stopped at their own 3.5% while the firm allows
// 5% has not failed anything, and the panel and log must say so.
//
#ifndef PG_RULEENGINE_MQH
#define PG_RULEENGINE_MQH

#include <PropGuard/Core/PG_Types.mqh>
#include <PropGuard/Core/PG_RuleSet.mqh>
#include <PropGuard/Core/PG_Clock.mqh>
#include <PropGuard/Core/PG_RiskCalc.mqh>

//+------------------------------------------------------------------+
//| Baselines and floors                                             |
//+------------------------------------------------------------------+
double PG_DailyBaseline(const PG_MarketView &mv,const PG_RuleSet &r)
  {
   if(r.daily_baseline==PG_BASE_EQUITY_AT_RESET)
      return mv.day_start_equity;
   if(r.daily_baseline==PG_BASE_MAX_OF_BOTH)
      return MathMax(mv.day_start_balance,mv.day_start_equity);
   if(r.daily_baseline==PG_BASE_STATIC_INITIAL)
      return mv.initial_balance;
   return mv.day_start_balance;
  }

double PG_DailyLimitMoney(const PG_MarketView &mv,const PG_RuleSet &r)
  {
   return PG_DailyBaseline(mv,r)*(r.daily_limit_pct/100.0);
  }

double PG_DailyFloor(const PG_MarketView &mv,const PG_RuleSet &r)
  {
   return PG_DailyBaseline(mv,r)-PG_DailyLimitMoney(mv,r);
  }

//--- the money the firm allows to be lost from the drawdown reference
double PG_MaxDdAmount(const PG_MarketView &mv,const PG_RuleSet &r)
  {
   const double ref = (mv.initial_balance>0.0 ? mv.initial_balance : mv.balance);
   return ref*(r.maxdd_limit_pct/100.0);
  }

//--- the equity level that must never be crossed
double PG_MaxDdFloor(const PG_MarketView &mv,const PG_RuleSet &r)
  {
   const double initial = (mv.initial_balance>0.0 ? mv.initial_balance : mv.balance);
   const double amount  = PG_MaxDdAmount(mv,r);

   if(r.maxdd_mode==PG_DD_TRAILING_EQUITY)
      return mv.hwm_equity-amount;

   if(r.maxdd_mode==PG_DD_TRAILING_LOCK)
     {
      //--- trails the high-water mark, but stops climbing once it reaches
      //--- the starting balance - the floor never rises above initial
      const double trailing = mv.hwm_equity-amount;
      return MathMin(trailing,initial);
     }

   if(r.maxdd_mode==PG_DD_TRAILING_EOD_BALANCE)
      return mv.hwm_eod_balance-amount;

   return initial-amount;   // PG_DD_STATIC_INITIAL
  }

//--- measure used against a limit: equity when floating counts, else balance
double PG_Measure(const PG_MarketView &mv,const bool include_floating)
  {
   return (include_floating ? mv.equity : mv.balance);
  }

//+------------------------------------------------------------------+
//| Small counting helpers                                           |
//+------------------------------------------------------------------+
int PG_CountPositionsOnSymbol(const PG_MarketView &mv,const string symbol)
  {
   int n=0;
   for(int i=0;i<mv.position_count;i++)
      if(mv.positions[i].symbol==symbol)
         n++;
   return n;
  }

bool PG_HasOpposingPositions(const PG_MarketView &mv,const string symbol)
  {
   bool up=false,down=false;
   for(int i=0;i<mv.position_count;i++)
     {
      if(mv.positions[i].symbol!=symbol)
         continue;
      if(mv.positions[i].dir>0) up=true;
      if(mv.positions[i].dir<0) down=true;
     }
   return (up && down);
  }

//--- lot ceilings scale with account size, so they are quoted per 100k
double PG_ScaleLots(const double per_100k,const double account_size)
  {
   if(per_100k<=0.0)
      return 0.0;
   const double base = (account_size>0.0 ? account_size : 100000.0);
   return per_100k*(base/100000.0);
  }

//--- is `now` inside a blackout window around a high-impact release?
bool PG_InNewsBlackout(const PG_MarketView &mv,const PG_RuleSet &r,
                       string &out_title)
  {
   out_title="";
   if(!r.news_blackout_enabled)
      return false;
   const long before = (long)r.news_before_min*60;
   const long after  = (long)r.news_after_min*60;
   for(int i=0;i<mv.news_count;i++)
     {
      if(mv.news[i].impact<3)
         continue;
      if(mv.now>=mv.news[i].event_time-before && mv.now<=mv.news[i].event_time+after)
        {
         out_title=mv.news[i].title;
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Percentage helpers used for tiering                              |
//+------------------------------------------------------------------+
double PG_UsagePct(const double used,const double allowance)
  {
   if(allowance<=0.0)
      return 0.0;
   return (used/allowance)*100.0;
  }

ENUM_PG_TIER PG_TierFor(const double usage_pct,const PG_UserConfig &cfg)
  {
   if(usage_pct>=100.0)          return PG_TIER_ENFORCE;
   if(usage_pct>=cfg.block_at_pct)return PG_TIER_BLOCK;
   if(usage_pct>=cfg.warn_at_pct) return PG_TIER_WARN;
   return PG_TIER_NORMAL;
  }

//+------------------------------------------------------------------+
//| A compact summary the panel reads directly                       |
//+------------------------------------------------------------------+
struct PG_EngineState
  {
   double            daily_baseline;
   double            daily_limit_money;
   double            daily_floor;
   double            daily_used_money;
   double            daily_used_pct;      // of the effective allowance
   double            daily_left_money;

   double            dd_amount;
   double            dd_floor;
   double            dd_used_money;
   double            dd_used_pct;
   double            dd_left_money;

   double            worst_equity;
   double            worst_loss;
   double            worst_used_pct;      // worst case against the daily allowance
   bool              worst_unbounded;

   double            headroom_money;      // extra risk that may still be added
   ENUM_PG_TIER      tier;
   long              seconds_to_reset;

                     PG_EngineState()
     {
      daily_baseline=0.0; daily_limit_money=0.0; daily_floor=0.0;
      daily_used_money=0.0; daily_used_pct=0.0; daily_left_money=0.0;
      dd_amount=0.0; dd_floor=0.0; dd_used_money=0.0; dd_used_pct=0.0;
      dd_left_money=0.0;
      worst_equity=0.0; worst_loss=0.0; worst_used_pct=0.0;
      worst_unbounded=false; headroom_money=0.0;
      tier=PG_TIER_NORMAL; seconds_to_reset=0;
     }
  };

//+------------------------------------------------------------------+
//| Build the numeric state (no verdicts yet)                        |
//+------------------------------------------------------------------+
void PG_BuildState(const PG_MarketView &mv,const PG_RuleSet &eff,
                   const PG_UserConfig &cfg,const PG_RiskResult &risk,
                   const int server_utc_offset_min,PG_EngineState &st)
  {
   st.daily_baseline    = PG_DailyBaseline(mv,eff);
   st.daily_limit_money = PG_DailyLimitMoney(mv,eff);
   st.daily_floor       = st.daily_baseline-st.daily_limit_money;

   const double dmeasure = PG_Measure(mv,eff.daily_include_floating);
   st.daily_used_money = MathMax(0.0,st.daily_baseline-dmeasure);
   st.daily_used_pct   = PG_UsagePct(st.daily_used_money,st.daily_limit_money);
   st.daily_left_money = MathMax(0.0,st.daily_limit_money-st.daily_used_money);

   st.dd_amount = PG_MaxDdAmount(mv,eff);
   st.dd_floor  = PG_MaxDdFloor(mv,eff);

   const double mmeasure = PG_Measure(mv,eff.maxdd_include_floating);
   st.dd_used_money = MathMax(0.0,(st.dd_floor+st.dd_amount)-mmeasure);
   st.dd_used_pct   = PG_UsagePct(st.dd_used_money,st.dd_amount);
   st.dd_left_money = MathMax(0.0,mmeasure-st.dd_floor);

   st.worst_equity    = risk.worst_equity;
   st.worst_loss      = risk.worst_loss;
   st.worst_unbounded = risk.unbounded;

   //--- how much of the daily allowance the open book would consume if
   //--- every stop were hit right now
   const double worst_daily_used = MathMax(0.0,st.daily_baseline-risk.worst_equity);
   st.worst_used_pct = PG_UsagePct(worst_daily_used,st.daily_limit_money);

   //--- room left for NEW risk: the tighter of the daily and the overall
   //--- floor, measured from the projected worst case, not from equity
   const double room_daily = risk.worst_equity-st.daily_floor;
   const double room_dd    = risk.worst_equity-st.dd_floor;
   st.headroom_money = MathMax(0.0,MathMin(room_daily,room_dd));

   st.seconds_to_reset = PG_SecondsToNextReset(mv.now,server_utc_offset_min,eff);

   double worst_usage = MathMax(st.daily_used_pct,st.dd_used_pct);
   worst_usage = MathMax(worst_usage,st.worst_used_pct);
   st.tier = PG_TierFor(worst_usage,cfg);
  }

//+------------------------------------------------------------------+
//| Formatting helper for reasons                                    |
//+------------------------------------------------------------------+
string PG_Money(const double v)
  {
   return DoubleToString(v,2);
  }

string PG_Pct(const double v)
  {
   return DoubleToString(v,2)+"%";
  }

//+------------------------------------------------------------------+
//| THE EVALUATION                                                   |
//+------------------------------------------------------------------+
void PG_Evaluate(const PG_MarketView &mv,const PG_RuleSet &eff,
                 const PG_RuleSet &firm,const PG_UserConfig &cfg,
                 const PG_RiskResult &risk,const PG_EngineState &st,
                 PG_VerdictSet &out)
  {
   out.Reset();
   out.tier = st.tier;

   const bool monitor = (cfg.enforce_mode==PG_ENFORCE_MONITOR);
   PG_Violation v;

   //================================================================
   // 1. Daily loss already realised or floating
   //================================================================
   if(eff.daily_enabled)
     {
      if(st.daily_used_pct>=100.0)
        {
         v=PG_Violation();
         v.rule       = PG_RULE_DAILY_LOSS;
         v.severity   = PG_SEV_BREACH;
         v.action     = (monitor ? PG_ACT_WARN : PG_ACT_LOCKOUT);
         v.current    = st.daily_used_money;
         v.limit_user = st.daily_limit_money;
         v.limit_firm = PG_DailyBaseline(mv,firm)*(firm.daily_limit_pct/100.0);
         v.reason     = "Daily loss "+PG_Money(st.daily_used_money)+" reached the "
                        +PG_Money(st.daily_limit_money)+" allowance ("
                        +PG_Pct(eff.daily_limit_pct)+" of "
                        +PG_Money(st.daily_baseline)+"). Firm allows "
                        +PG_Pct(firm.daily_limit_pct)+".";
         out.Add(v);
        }
      else
         if(st.daily_used_pct>=cfg.block_at_pct)
           {
            v=PG_Violation();
            v.rule       = PG_RULE_DAILY_LOSS;
            v.severity   = PG_SEV_CRITICAL;
            v.action     = (monitor ? PG_ACT_WARN : PG_ACT_BLOCK_NEW);
            v.current    = st.daily_used_money;
            v.limit_user = st.daily_limit_money;
            v.limit_firm = PG_DailyBaseline(mv,firm)*(firm.daily_limit_pct/100.0);
            v.reason     = "Daily loss at "+PG_Pct(st.daily_used_pct)
                           +" of the allowance. No new exposure until the reset in "
                           +PG_FormatDuration(st.seconds_to_reset)+".";
            out.Add(v);
           }
         else
            if(st.daily_used_pct>=cfg.warn_at_pct)
              {
               v=PG_Violation();
               v.rule       = PG_RULE_DAILY_LOSS;
               v.severity   = PG_SEV_WARN;
               v.action     = PG_ACT_WARN;
               v.current    = st.daily_used_money;
               v.limit_user = st.daily_limit_money;
               v.reason     = "Daily loss at "+PG_Pct(st.daily_used_pct)
                              +" of the allowance. "+PG_Money(st.daily_left_money)
                              +" left.";
               out.Add(v);
              }
     }

   //================================================================
   // 2. Overall drawdown
   //================================================================
   if(eff.maxdd_enabled)
     {
      const double mmeasure = PG_Measure(mv,eff.maxdd_include_floating);
      if(mmeasure<=st.dd_floor)
        {
         v=PG_Violation();
         v.rule       = PG_RULE_MAX_DRAWDOWN;
         v.severity   = PG_SEV_BREACH;
         v.action     = (monitor ? PG_ACT_WARN : PG_ACT_LOCKOUT);
         v.current    = st.dd_used_money;
         v.limit_user = st.dd_amount;
         v.limit_firm = PG_MaxDdAmount(mv,firm);
         v.reason     = "Equity "+PG_Money(mmeasure)+" is at or below the drawdown floor "
                        +PG_Money(st.dd_floor)+" ("+PG_Pct(eff.maxdd_limit_pct)
                        +", firm allows "+PG_Pct(firm.maxdd_limit_pct)+").";
         out.Add(v);
        }
      else
         if(st.dd_used_pct>=cfg.block_at_pct)
           {
            v=PG_Violation();
            v.rule       = PG_RULE_MAX_DRAWDOWN;
            v.severity   = PG_SEV_CRITICAL;
            v.action     = (monitor ? PG_ACT_WARN : PG_ACT_BLOCK_NEW);
            v.current    = st.dd_used_money;
            v.limit_user = st.dd_amount;
            v.reason     = "Overall drawdown at "+PG_Pct(st.dd_used_pct)
                           +" of the allowance. "+PG_Money(st.dd_left_money)
                           +" above the floor.";
            out.Add(v);
           }
         else
            if(st.dd_used_pct>=cfg.warn_at_pct)
              {
               v=PG_Violation();
               v.rule     = PG_RULE_MAX_DRAWDOWN;
               v.severity = PG_SEV_WARN;
               v.action   = PG_ACT_WARN;
               v.current  = st.dd_used_money;
               v.limit_user=st.dd_amount;
               v.reason   = "Overall drawdown at "+PG_Pct(st.dd_used_pct)
                            +" of the allowance.";
               out.Add(v);
              }
     }

   //================================================================
   // 3. Worst case - the projected book. This is the rule that closes
   //    a trade BEFORE its stop can breach anything.
   //================================================================
     {
      const bool breaks_daily = (eff.daily_enabled &&
                                 risk.worst_equity<st.daily_floor);
      const bool breaks_dd    = (eff.maxdd_enabled &&
                                 risk.worst_equity<st.dd_floor);

      if(breaks_daily || breaks_dd)
        {
         const double floor_hit = (breaks_daily ? st.daily_floor : st.dd_floor);
         const int    offender  = risk.WorstOffender();

         v=PG_Violation();
         v.rule       = PG_RULE_WORST_CASE;
         v.severity   = PG_SEV_CRITICAL;
         v.action     = (monitor ? PG_ACT_WARN
                         : (cfg.enforce_mode==PG_ENFORCE_CLOSE
                            ? PG_ACT_CLOSE_ALL : PG_ACT_REDUCE));
         v.ticket     = (offender>=0 ? risk.per_position[offender].ticket : 0);
         v.current    = risk.worst_loss;
         v.limit_user = (breaks_daily ? st.daily_limit_money : st.dd_amount);
         v.limit_firm = (breaks_daily
                         ? PG_DailyBaseline(mv,firm)*(firm.daily_limit_pct/100.0)
                         : PG_MaxDdAmount(mv,firm));
         v.reason     = "If every stop is hit, equity lands at "
                        +PG_Money(risk.worst_equity)+", below the "
                        +(breaks_daily ? "daily" : "drawdown")+" floor "
                        +PG_Money(floor_hit)+". Projected loss "
                        +PG_Money(risk.worst_loss)+" across "
                        +IntegerToString(risk.per_position_count)+" position(s).";
         out.Add(v);
        }
      else
         if(st.worst_used_pct>=cfg.block_at_pct)
           {
            v=PG_Violation();
            v.rule     = PG_RULE_WORST_CASE;
            v.severity = PG_SEV_WARN;
            v.action   = (monitor ? PG_ACT_WARN : PG_ACT_BLOCK_NEW);
            v.current  = risk.worst_loss;
            v.limit_user=st.daily_limit_money;
            v.reason   = "Open risk would consume "+PG_Pct(st.worst_used_pct)
                         +" of the daily allowance if every stop is hit. "
                         +"No new exposure.";
            out.Add(v);
           }
     }

   //================================================================
   // 4. Missing stop losses
   //================================================================
   if(eff.require_sl)
     {
      for(int i=0;i<mv.position_count;i++)
        {
         if(mv.positions[i].sl>0.0)
            continue;
         const long age = mv.now-mv.positions[i].open_time;

         v=PG_Violation();
         v.rule    = PG_RULE_STOP_LOSS_REQUIRED;
         v.ticket  = mv.positions[i].ticket;
         v.current = (double)age;
         v.limit_user = (double)eff.sl_grace_seconds;
         if(age<(long)eff.sl_grace_seconds)
           {
            v.severity = PG_SEV_NOTICE;
            v.action   = (monitor ? PG_ACT_WARN : PG_ACT_ATTACH_SL);
            v.reason   = "Position "+IntegerToString(mv.positions[i].ticket)
                         +" ("+mv.positions[i].symbol+") has no stop loss. "
                         +IntegerToString((int)((long)eff.sl_grace_seconds-age))
                         +"s of grace left before it is closed.";
           }
         else
           {
            v.severity = PG_SEV_CRITICAL;
            v.action   = (monitor ? PG_ACT_WARN : PG_ACT_CLOSE_POSITION);
            v.reason   = "Position "+IntegerToString(mv.positions[i].ticket)
                         +" ("+mv.positions[i].symbol
                         +") still has no stop loss after "
                         +IntegerToString((int)age)+"s. Risk is unbounded.";
           }
         out.Add(v);
        }
     }

   //================================================================
   // 5. Per-trade risk ceiling
   //================================================================
   if(eff.max_risk_per_trade_pct>0.0)
     {
      const double ref = (mv.initial_balance>0.0 ? mv.initial_balance : mv.balance);
      const double cap = ref*(eff.max_risk_per_trade_pct/100.0);
      for(int i=0;i<risk.per_position_count;i++)
        {
         if(risk.per_position[i].loss_from_now<=cap)
            continue;
         v=PG_Violation();
         v.rule       = PG_RULE_MAX_RISK_PER_TRADE;
         v.severity   = PG_SEV_CRITICAL;
         v.action     = (monitor ? PG_ACT_WARN : PG_ACT_CLOSE_POSITION);
         v.ticket     = risk.per_position[i].ticket;
         v.current    = risk.per_position[i].loss_from_now;
         v.limit_user = cap;
         v.limit_firm = ref*(firm.max_risk_per_trade_pct/100.0);
         v.reason     = "Position "+IntegerToString(risk.per_position[i].ticket)
                        +" risks "+PG_Money(risk.per_position[i].loss_from_now)
                        +" ("+PG_Pct(risk.per_position[i].risk_pct)+"), over the "
                        +PG_Money(cap)+" per-trade cap.";
         out.Add(v);
        }
     }

   //================================================================
   // 6. Lot and position ceilings
   //================================================================
   const double acct = (mv.initial_balance>0.0 ? mv.initial_balance : mv.balance);

   if(eff.max_lot_per_trade_per_100k>0.0)
     {
      const double cap = PG_ScaleLots(eff.max_lot_per_trade_per_100k,acct);
      for(int i=0;i<mv.position_count;i++)
        {
         if(mv.positions[i].volume<=cap)
            continue;
         v=PG_Violation();
         v.rule       = PG_RULE_MAX_LOT_PER_TRADE;
         v.severity   = PG_SEV_CRITICAL;
         v.action     = (monitor ? PG_ACT_WARN : PG_ACT_CLOSE_POSITION);
         v.ticket     = mv.positions[i].ticket;
         v.current    = mv.positions[i].volume;
         v.limit_user = cap;
         v.limit_firm = PG_ScaleLots(firm.max_lot_per_trade_per_100k,acct);
         v.reason     = "Position "+IntegerToString(mv.positions[i].ticket)
                        +" is "+DoubleToString(mv.positions[i].volume,2)
                        +" lots, over the "+DoubleToString(cap,2)+" lot cap.";
         out.Add(v);
        }
     }

   if(eff.max_total_lots_per_100k>0.0)
     {
      const double cap = PG_ScaleLots(eff.max_total_lots_per_100k,acct);
      if(risk.total_lots>cap)
        {
         v=PG_Violation();
         v.rule       = PG_RULE_MAX_TOTAL_LOTS;
         v.severity   = PG_SEV_CRITICAL;
         v.action     = (monitor ? PG_ACT_WARN : PG_ACT_REDUCE);
         v.current    = risk.total_lots;
         v.limit_user = cap;
         v.limit_firm = PG_ScaleLots(firm.max_total_lots_per_100k,acct);
         v.reason     = "Total exposure "+DoubleToString(risk.total_lots,2)
                        +" lots exceeds the "+DoubleToString(cap,2)+" lot cap.";
         out.Add(v);
        }
     }

   if(eff.max_open_positions>0 && mv.position_count>eff.max_open_positions)
     {
      v=PG_Violation();
      v.rule       = PG_RULE_MAX_POSITIONS;
      v.severity   = PG_SEV_CRITICAL;
      v.action     = (monitor ? PG_ACT_WARN : PG_ACT_BLOCK_NEW);
      v.current    = (double)mv.position_count;
      v.limit_user = (double)eff.max_open_positions;
      v.limit_firm = (double)firm.max_open_positions;
      v.reason     = IntegerToString(mv.position_count)+" open positions, over the "
                     +IntegerToString(eff.max_open_positions)+" limit.";
      out.Add(v);
     }

   if(eff.max_positions_per_symbol>0)
     {
      for(int i=0;i<mv.position_count;i++)
        {
         //--- report once per symbol, on its first occurrence
         bool first=true;
         for(int j=0;j<i;j++)
            if(mv.positions[j].symbol==mv.positions[i].symbol)
              { first=false; break; }
         if(!first)
            continue;
         const int n = PG_CountPositionsOnSymbol(mv,mv.positions[i].symbol);
         if(n<=eff.max_positions_per_symbol)
            continue;
         v=PG_Violation();
         v.rule       = PG_RULE_MAX_POS_PER_SYMBOL;
         v.severity   = PG_SEV_WARN;
         v.action     = (monitor ? PG_ACT_WARN : PG_ACT_BLOCK_NEW);
         v.current    = (double)n;
         v.limit_user = (double)eff.max_positions_per_symbol;
         v.reason     = IntegerToString(n)+" positions on "+mv.positions[i].symbol
                        +", over the "+IntegerToString(eff.max_positions_per_symbol)
                        +" per-symbol limit.";
         out.Add(v);
        }
     }

   //================================================================
   // 7. Hedging
   //================================================================
   if(eff.forbid_hedging)
     {
      for(int i=0;i<mv.position_count;i++)
        {
         bool first=true;
         for(int j=0;j<i;j++)
            if(mv.positions[j].symbol==mv.positions[i].symbol)
              { first=false; break; }
         if(!first || !PG_HasOpposingPositions(mv,mv.positions[i].symbol))
            continue;
         v=PG_Violation();
         v.rule     = PG_RULE_HEDGING;
         v.severity = PG_SEV_CRITICAL;
         v.action   = (monitor ? PG_ACT_WARN : PG_ACT_REDUCE);
         v.reason   = "Opposing positions open on "+mv.positions[i].symbol
                      +". This firm forbids hedging.";
         out.Add(v);
        }
     }

   //================================================================
   // 8. News blackout
   //================================================================
     {
      string title="";
      if(PG_InNewsBlackout(mv,eff,title))
        {
         v=PG_Violation();
         v.rule     = PG_RULE_NEWS_BLACKOUT;
         v.severity = PG_SEV_WARN;
         v.action   = (monitor ? PG_ACT_WARN : PG_ACT_BLOCK_NEW);
         v.reason   = "Inside the news blackout window ("+title+"). "
                      +"No new exposure for "+IntegerToString(eff.news_after_min)
                      +" more minute(s).";
         out.Add(v);
        }
     }

   //================================================================
   // 9. Weekend holding
   //================================================================
   if(eff.forbid_weekend_holding && mv.position_count>0)
     {
      if(PG_IsPastWeekendCutoff(mv.now,eff))
        {
         v=PG_Violation();
         v.rule     = PG_RULE_WEEKEND_HOLDING;
         v.severity = PG_SEV_CRITICAL;
         v.action   = (monitor ? PG_ACT_WARN : PG_ACT_CLOSE_ALL);
         v.current  = (double)mv.position_count;
         v.reason   = IntegerToString(mv.position_count)
                      +" position(s) still open past the weekend cutoff. "
                      +"This firm forbids holding over the weekend.";
         out.Add(v);
        }
     }

   //================================================================
   // 10. Consistency - informational, it only bites at payout time
   //================================================================
   if(eff.consistency_enabled && mv.total_profit>0.0)
     {
      const double share = (mv.best_day_profit/mv.total_profit)*100.0;
      if(share>eff.consistency_max_day_share_pct)
        {
         v=PG_Violation();
         v.rule       = PG_RULE_CONSISTENCY;
         v.severity   = PG_SEV_WARN;
         v.action     = PG_ACT_WARN;
         v.current    = share;
         v.limit_user = eff.consistency_max_day_share_pct;
         v.limit_firm = firm.consistency_max_day_share_pct;
         v.reason     = "Best day is "+PG_Pct(share)+" of total profit, over the "
                        +PG_Pct(eff.consistency_max_day_share_pct)
                        +" consistency limit. Payout may be refused.";
         out.Add(v);
        }
     }

   //================================================================
   // 11. Challenge calendar limit
   //================================================================
   if(eff.max_calendar_days>0 && mv.challenge_start_time>0)
     {
      const int used = PG_CalendarDaysSince(mv.challenge_start_time,mv.now);
      if(used>=eff.max_calendar_days)
        {
         v=PG_Violation();
         v.rule       = PG_RULE_MAX_CALENDAR_DAYS;
         v.severity   = PG_SEV_WARN;
         v.action     = PG_ACT_WARN;
         v.current    = (double)used;
         v.limit_user = (double)eff.max_calendar_days;
         v.reason     = "Day "+IntegerToString(used)+" of a "
                        +IntegerToString(eff.max_calendar_days)+" day challenge.";
         out.Add(v);
        }
     }

   //================================================================
   // 12. Minimum hold time. Recorded so the enforcer knows it must not
   //     close a position that is too young - closing it would itself
   //     be the breach.
   //================================================================
   if(eff.min_hold_seconds>0)
     {
      for(int i=0;i<mv.position_count;i++)
        {
         const long age = mv.now-mv.positions[i].open_time;
         if(age>=(long)eff.min_hold_seconds)
            continue;
         v=PG_Violation();
         v.rule       = PG_RULE_MIN_HOLD_TIME;
         v.severity   = PG_SEV_NOTICE;
         v.action     = PG_ACT_WARN;
         v.ticket     = mv.positions[i].ticket;
         v.current    = (double)age;
         v.limit_user = (double)eff.min_hold_seconds;
         v.reason     = "Position "+IntegerToString(mv.positions[i].ticket)
                        +" is "+IntegerToString((int)age)+"s old; this firm "
                        +"requires "+IntegerToString(eff.min_hold_seconds)
                        +"s minimum hold. It must not be closed yet.";
         out.Add(v);
        }
     }

   //--- tier drives the block flag even when no individual rule fired
   if(out.tier==PG_TIER_BLOCK || out.tier==PG_TIER_ENFORCE)
      out.block_new_trades=true;
  }

//+------------------------------------------------------------------+
//| Pre-trade gate: would this order be allowed right now?           |
//| Returns true when the order is acceptable; reason explains a no. |
//+------------------------------------------------------------------+
bool PG_CheckNewOrder(const PG_MarketView &mv,const PG_RuleSet &eff,
                      const PG_UserConfig &cfg,const PG_EngineState &st,
                      const PG_VerdictSet &current,const PG_SymbolSpec &spec,
                      const int dir,const double volume,const double entry,
                      const double sl,string &reason)
  {
   reason="";

   if(current.block_new_trades || current.lockout)
     {
      reason="Trading is blocked: "
             +(current.lockout ? string("lockout active") : string("limit tier reached"));
      return false;
     }

   if(!spec.tradable)
     {
      reason="Symbol "+spec.name+" is not tradable under the current rules.";
      return false;
     }

   if(eff.require_sl && sl<=0.0)
     {
      reason="A stop loss is required before this order can be accepted.";
      return false;
     }

   const double acct = (mv.initial_balance>0.0 ? mv.initial_balance : mv.balance);

   if(eff.max_lot_per_trade_per_100k>0.0)
     {
      const double cap = PG_ScaleLots(eff.max_lot_per_trade_per_100k,acct);
      if(volume>cap)
        {
         reason="Volume "+DoubleToString(volume,2)+" exceeds the "
                +DoubleToString(cap,2)+" lot per-trade cap.";
         return false;
        }
     }

   if(eff.max_open_positions>0 && mv.position_count>=eff.max_open_positions)
     {
      reason="Already at the "+IntegerToString(eff.max_open_positions)
             +" open position limit.";
      return false;
     }

   string title="";
   if(PG_InNewsBlackout(mv,eff,title))
     {
      reason="News blackout window is active ("+title+").";
      return false;
     }

   if(eff.forbid_weekend_holding && PG_IsPastWeekendCutoff(mv.now,eff))
     {
      reason="Past the weekend cutoff; new positions cannot be opened.";
      return false;
     }

   //--- the decisive test: does this order's own worst case still fit?
   const double add = PG_HypotheticalWorstLoss(spec,dir,volume,entry,sl,
                                               cfg.gap_buffer_pct,
                                               cfg.slippage_points);
   if(!PG_FitsBudget(add,st.headroom_money))
     {
      reason="Worst case of this order is "+PG_Money(add)
             +" but only "+PG_Money(st.headroom_money)
             +" of risk headroom remains.";
      return false;
     }

   if(eff.max_risk_per_trade_pct>0.0)
     {
      const double cap = acct*(eff.max_risk_per_trade_pct/100.0);
      if(!PG_FitsBudget(add,cap))
        {
         reason="Worst case of this order is "+PG_Money(add)
                +", over the "+PG_Money(cap)+" per-trade cap.";
         return false;
        }
     }

   return true;
  }

#endif // PG_RULEENGINE_MQH
//+------------------------------------------------------------------+
