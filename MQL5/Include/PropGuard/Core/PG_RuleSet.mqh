//+------------------------------------------------------------------+
//|                                                   PG_RuleSet.mqh |
//|        PropGuard - the rule record, the user overlay, and the    |
//|        tighten-only merge that produces the effective limits     |
//+------------------------------------------------------------------+
//
// PG_RuleSet is a flat record on purpose. A prop firm's rulebook is a list
// of numbers, and a flat record means adding a firm is filling in fields in
// one file (Firms/PG_Firms.mqh) with zero engine changes.
//
// PG_UserConfig is the trader's own overlay. The only legal direction is
// stricter. PG_Effective() enforces that at merge time, so no later code
// can accidentally hand the engine a looser limit than the firm allows.
//
#ifndef PG_RULESET_MQH
#define PG_RULESET_MQH

#include <PropGuard/Core/PG_Types.mqh>

//+------------------------------------------------------------------+
//| One prop firm program/phase, exactly as the firm publishes it    |
//+------------------------------------------------------------------+
struct PG_RuleSet
  {
   //--- identity and provenance -------------------------------------
   string            firm_id;
   string            firm_name_en;
   string            firm_name_fa;
   string            program_id;
   string            program_name_en;
   string            program_name_fa;
   string            phase_label_en;      // "Phase 1", "Funded", ...
   string            phase_label_fa;
   string            source_url;
   long              verified_on;         // epoch. 0 => NOT VERIFIED, panel warns
   string            verified_by;

   //--- daily reset clock -------------------------------------------
   int               reset_hour;          // in the FIRM's timezone
   int               reset_minute;
   int               firm_utc_offset_min; // standard-time offset from UTC
   bool              firm_uses_dst;       // true => EU-style DST applies
   int               week_reset_dow;      // 0=Sun .. 6=Sat, broker week rollover
   int               week_reset_hour;

   //--- daily loss ---------------------------------------------------
   bool              daily_enabled;
   double            daily_limit_pct;
   ENUM_PG_BASELINE  daily_baseline;
   bool              daily_include_floating;

   //--- maximum drawdown --------------------------------------------
   bool              maxdd_enabled;
   double            maxdd_limit_pct;
   ENUM_PG_DD_MODE   maxdd_mode;
   bool              maxdd_include_floating;

   //--- targets and duration ----------------------------------------
   double            profit_target_pct;   // 0 => none (funded phase)
   int               min_trading_days;    // 0 => none
   int               max_calendar_days;   // 0 => unlimited

   //--- consistency --------------------------------------------------
   bool              consistency_enabled;
   double            consistency_max_day_share_pct;

   //--- exposure ceilings --------------------------------------------
   double            max_lot_per_trade_per_100k;  // 0 => unlimited
   double            max_total_lots_per_100k;     // 0 => unlimited
   int               max_open_positions;          // 0 => unlimited
   int               max_positions_per_symbol;    // 0 => unlimited

   //--- risk hygiene -------------------------------------------------
   bool              require_sl;
   int               sl_grace_seconds;
   double            max_risk_per_trade_pct;      // 0 => unlimited
   int               min_hold_seconds;            // anti-HFT, 0 => none

   //--- time restrictions --------------------------------------------
   bool              news_blackout_enabled;
   int               news_before_min;
   int               news_after_min;
   bool              forbid_weekend_holding;
   int               weekend_close_dow;           // 5 = Friday
   int               weekend_close_hour;
   int               weekend_close_minute;

   //--- behavioural flags (informational in the panel, not enforced
   //--- mechanically because they cannot be measured from a terminal)
   bool              forbid_hedging;
   bool              forbid_ea;
   bool              forbid_copy_trading;

   double            profit_split_pct;

                     PG_RuleSet() { Clear(); }

   void              Clear()
     {
      firm_id="";            firm_name_en="";       firm_name_fa="";
      program_id="";         program_name_en="";    program_name_fa="";
      phase_label_en="";     phase_label_fa="";     source_url="";
      verified_on=0;         verified_by="";

      reset_hour=0;          reset_minute=0;
      firm_utc_offset_min=0; firm_uses_dst=false;
      week_reset_dow=0;      week_reset_hour=22;

      daily_enabled=true;    daily_limit_pct=5.0;
      daily_baseline=PG_BASE_BALANCE_AT_RESET;
      daily_include_floating=true;

      maxdd_enabled=true;    maxdd_limit_pct=10.0;
      maxdd_mode=PG_DD_STATIC_INITIAL;
      maxdd_include_floating=true;

      profit_target_pct=0.0; min_trading_days=0;    max_calendar_days=0;

      consistency_enabled=false;
      consistency_max_day_share_pct=0.0;

      max_lot_per_trade_per_100k=0.0;
      max_total_lots_per_100k=0.0;
      max_open_positions=0;  max_positions_per_symbol=0;

      require_sl=false;      sl_grace_seconds=60;
      max_risk_per_trade_pct=0.0;
      min_hold_seconds=0;

      news_blackout_enabled=false;
      news_before_min=2;     news_after_min=2;
      forbid_weekend_holding=false;
      weekend_close_dow=5;   weekend_close_hour=20; weekend_close_minute=45;

      forbid_hedging=false;  forbid_ea=false;       forbid_copy_trading=false;
      profit_split_pct=80.0;
     }

   bool              IsVerified() const { return verified_on>0; }
  };

//+------------------------------------------------------------------+
//| The trader's overlay. Every numeric field here may only make the |
//| corresponding firm field stricter.                               |
//+------------------------------------------------------------------+
struct PG_UserConfig
  {
   bool              use_overrides;

   double            daily_limit_pct;
   double            maxdd_limit_pct;
   double            max_risk_per_trade_pct;
   double            max_lot_per_trade_per_100k;
   double            max_total_lots_per_100k;
   int               max_open_positions;
   bool              require_sl;
   bool              forbid_weekend_holding;
   bool              news_blackout_enabled;

   //--- safety margins the firm never asks for but reality does
   double            gap_buffer_pct;      // inflate worst case: stops gap through
   double            slippage_points;     // per-position execution allowance

   //--- tiering, as a percentage of the EFFECTIVE limit
   double            warn_at_pct;
   double            block_at_pct;

   ENUM_PG_ENFORCE_MODE enforce_mode;

                     PG_UserConfig() { Defaults(); }

   void              Defaults()
     {
      use_overrides=false;
      daily_limit_pct=0.0;   maxdd_limit_pct=0.0;
      max_risk_per_trade_pct=0.0;
      max_lot_per_trade_per_100k=0.0;
      max_total_lots_per_100k=0.0;
      max_open_positions=0;
      require_sl=true;                 // stricter than most firms, on by default
      forbid_weekend_holding=false;
      news_blackout_enabled=false;
      gap_buffer_pct=15.0;
      slippage_points=20.0;
      warn_at_pct=60.0;
      block_at_pct=80.0;
      enforce_mode=PG_ENFORCE_REDUCE;
     }
  };

//+------------------------------------------------------------------+
//| Tighten-only merge helpers                                       |
//+------------------------------------------------------------------+
//
// For "smaller is stricter" fields (loss limits, lot ceilings) a user value
// of 0 means "no opinion, keep the firm value". A non-zero user value is
// accepted only when it is below the firm value.
//
double PG_TightenDown(const double firm_value,const double user_value)
  {
   if(user_value<=0.0)
      return firm_value;                 // no opinion
   if(firm_value<=0.0)
      return user_value;                 // firm has no ceiling, user adds one
   return (user_value<firm_value ? user_value : firm_value);
  }

int PG_TightenDownInt(const int firm_value,const int user_value)
  {
   if(user_value<=0)
      return firm_value;
   if(firm_value<=0)
      return user_value;
   return (user_value<firm_value ? user_value : firm_value);
  }

//--- for booleans, "true" is always the stricter state
bool PG_TightenFlag(const bool firm_value,const bool user_value)
  {
   return (firm_value || user_value);
  }

//+------------------------------------------------------------------+
//| Produce the limits the engine actually enforces.                 |
//| The firm record is left untouched so the panel can always show   |
//| both numbers side by side.                                       |
//+------------------------------------------------------------------+
void PG_BuildEffective(const PG_RuleSet &firm,const PG_UserConfig &user,PG_RuleSet &out)
  {
   out=firm;
   if(!user.use_overrides)
     {
      //--- even with overrides off, the always-on hygiene defaults apply
      out.require_sl=PG_TightenFlag(firm.require_sl,user.require_sl);
      return;
     }

   out.daily_limit_pct            = PG_TightenDown(firm.daily_limit_pct,
                                                   user.daily_limit_pct);
   out.maxdd_limit_pct            = PG_TightenDown(firm.maxdd_limit_pct,
                                                   user.maxdd_limit_pct);
   out.max_risk_per_trade_pct     = PG_TightenDown(firm.max_risk_per_trade_pct,
                                                   user.max_risk_per_trade_pct);
   out.max_lot_per_trade_per_100k = PG_TightenDown(firm.max_lot_per_trade_per_100k,
                                                   user.max_lot_per_trade_per_100k);
   out.max_total_lots_per_100k    = PG_TightenDown(firm.max_total_lots_per_100k,
                                                   user.max_total_lots_per_100k);
   out.max_open_positions         = PG_TightenDownInt(firm.max_open_positions,
                                                      user.max_open_positions);

   out.require_sl             = PG_TightenFlag(firm.require_sl,user.require_sl);
   out.forbid_weekend_holding = PG_TightenFlag(firm.forbid_weekend_holding,
                                               user.forbid_weekend_holding);
   out.news_blackout_enabled  = PG_TightenFlag(firm.news_blackout_enabled,
                                               user.news_blackout_enabled);
  }

//+------------------------------------------------------------------+
//| Validate a rule record before it is ever allowed to guard money. |
//| Returns "" when the record is usable, otherwise the first fault. |
//+------------------------------------------------------------------+
string PG_ValidateRuleSet(const PG_RuleSet &r)
  {
   if(r.firm_id=="")
      return "firm_id is empty";
   if(r.program_id=="")
      return "program_id is empty";

   if(r.daily_enabled && (r.daily_limit_pct<=0.0 || r.daily_limit_pct>100.0))
      return "daily_limit_pct out of range (0,100]";
   if(r.maxdd_enabled && (r.maxdd_limit_pct<=0.0 || r.maxdd_limit_pct>100.0))
      return "maxdd_limit_pct out of range (0,100]";
   if(r.daily_enabled && r.maxdd_enabled && r.daily_limit_pct>r.maxdd_limit_pct)
      return "daily_limit_pct exceeds maxdd_limit_pct";

   if(r.reset_hour<0   || r.reset_hour>23)   return "reset_hour out of range";
   if(r.reset_minute<0 || r.reset_minute>59) return "reset_minute out of range";
   if(r.firm_utc_offset_min<-780 || r.firm_utc_offset_min>840)
      return "firm_utc_offset_min out of range";
   if(r.week_reset_dow<0 || r.week_reset_dow>6) return "week_reset_dow out of range";

   if(r.consistency_enabled &&
      (r.consistency_max_day_share_pct<=0.0 || r.consistency_max_day_share_pct>100.0))
      return "consistency_max_day_share_pct out of range (0,100]";

   if(r.profit_target_pct<0.0)  return "profit_target_pct is negative";
   if(r.min_trading_days<0)     return "min_trading_days is negative";
   if(r.max_calendar_days<0)    return "max_calendar_days is negative";
   if(r.profit_split_pct<0.0 || r.profit_split_pct>100.0)
      return "profit_split_pct out of range [0,100]";

   if(r.forbid_weekend_holding)
     {
      if(r.weekend_close_dow<0   || r.weekend_close_dow>6)   return "weekend_close_dow out of range";
      if(r.weekend_close_hour<0  || r.weekend_close_hour>23) return "weekend_close_hour out of range";
      if(r.weekend_close_minute<0|| r.weekend_close_minute>59)return "weekend_close_minute out of range";
     }
   return "";
  }

#endif // PG_RULESET_MQH
//+------------------------------------------------------------------+
