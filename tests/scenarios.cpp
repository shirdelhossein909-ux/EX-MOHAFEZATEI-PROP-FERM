//+------------------------------------------------------------------+
//|                                                    scenarios.cpp |
//|   PropGuard violation scenario suite.                            |
//|                                                                  |
//|   Each scenario is engineered to breach one specific rule, or to |
//|   prove a boundary is NOT breached. The engine under test is the |
//|   real MQL5 source from MQL5/Include/PropGuard/Core - not a port.|
//+------------------------------------------------------------------+
#include "stubs/mql5_shim.h"

#include <PropGuard/Core/PG_Types.mqh>
#include <PropGuard/Core/PG_RuleSet.mqh>
#include <PropGuard/Core/PG_Clock.mqh>
#include <PropGuard/Core/PG_RiskCalc.mqh>
#include <PropGuard/Core/PG_RuleEngine.mqh>
#include <PropGuard/Core/PG_Hash.mqh>
#include <PropGuard/Core/PG_Log.mqh>
#include <PropGuard/Core/PG_Lock.mqh>
#include <PropGuard/Firms/PG_Firms.mqh>

#include <cstdio>
#include <cmath>
#include <vector>

//==================================================================
// Tiny test framework
//==================================================================
static int  g_pass = 0;
static int  g_fail = 0;
static std::vector<std::string> g_failures;

static void report(const char *group,const char *name,bool ok,const std::string &detail)
  {
   if(ok)
     {
      g_pass++;
      std::printf("  \033[32mPASS\033[0m  %-8s %s\n",group,name);
     }
   else
     {
      g_fail++;
      std::printf("  \033[31mFAIL\033[0m  %-8s %s\n              -> %s\n",
                  group,name,detail.c_str());
      g_failures.push_back(std::string(group)+" / "+name+": "+detail);
     }
  }

#define CHECK(group,name,cond) \
   report(group,name,(cond),std::string("expression was false: ") + #cond)

static void check_eq(const char *group,const char *name,double got,double want,
                     double tol=1e-6)
  {
   const bool ok = std::fabs(got-want)<=tol;
   char buf[192];
   std::snprintf(buf,sizeof(buf),"got %.6f, want %.6f",got,want);
   report(group,name,ok,buf);
  }

static void check_eq_i(const char *group,const char *name,long got,long want)
  {
   char buf[192];
   std::snprintf(buf,sizeof(buf),"got %ld, want %ld",got,want);
   report(group,name,got==want,buf);
  }

static void check_time(const char *group,const char *name,long got,long want)
  {
   std::string d = "got "+PG_FormatStamp(got)+", want "+PG_FormatStamp(want);
   report(group,name,got==want,d);
  }

//==================================================================
// Fixtures
//==================================================================
static PG_SymbolSpec SpecEurUsd()
  {
   PG_SymbolSpec s;
   s.name="EURUSD";  s.point=0.00001; s.digits=5;
   s.contract_size=100000.0;
   s.tick_size=0.00001; s.tick_value=1.0;     // 1 pip = $10 per lot
   s.volume_min=0.01;   s.volume_max=100.0;  s.volume_step=0.01;
   s.bid=1.10000;       s.ask=1.10002;
   s.commission_per_lot=0.0;
   s.tradable=true;
   return s;
  }

static PG_SymbolSpec SpecXauUsd()
  {
   PG_SymbolSpec s;
   s.name="XAUUSD";  s.point=0.01; s.digits=2;
   s.contract_size=100.0;
   s.tick_size=0.01; s.tick_value=1.0;        // $1 per 0.01 per lot
   s.volume_min=0.01; s.volume_max=50.0; s.volume_step=0.01;
   s.bid=2400.00;     s.ask=2400.30;
   s.commission_per_lot=0.0;
   s.tradable=true;
   return s;
  }

//--- a 100k account, flat, at 2026-08-05 10:00 server time
static void BaseView(PG_MarketView &mv,double balance=100000.0)
  {
   mv = PG_MarketView();
   mv.now               = PG_MakeTime(2026,8,5,10,0,0);
   mv.account_currency  = "USD";
   mv.account_login     = 12345678;
   mv.balance           = balance;
   mv.equity            = balance;
   mv.initial_balance   = 100000.0;
   mv.day_start_balance = balance;
   mv.day_start_equity  = balance;
   mv.day_start_time    = PG_MakeTime(2026,8,5,0,0,0);
   mv.hwm_equity        = MathMax(balance,100000.0);
   mv.hwm_eod_balance   = MathMax(balance,100000.0);
   mv.challenge_start_time = PG_MakeTime(2026,7,1,0,0,0);
   mv.specs[0]  = SpecEurUsd();
   mv.specs[1]  = SpecXauUsd();
   mv.spec_count = 2;
  }

static void AddPos(PG_MarketView &mv,int spec_index,int dir,double volume,
                   double open,double sl,double floating,long age_sec=3600)
  {
   PG_Position p;
   p.ticket     = 1000+mv.position_count;
   p.symbol     = mv.specs[spec_index].name;
   p.dir        = dir;
   p.volume     = volume;
   p.open_price = open;
   p.sl         = sl;
   p.open_time  = mv.now-age_sec;
   p.profit     = floating;
   p.spec_index = spec_index;
   mv.positions[mv.position_count] = p;
   mv.position_count++;
   mv.equity = mv.balance;
   for(int i=0;i<mv.position_count;i++)
      mv.equity += mv.positions[i].profit;
  }

static void AddPending(PG_MarketView &mv,int spec_index,int dir,double volume,
                       double price,double sl)
  {
   PG_Pending o;
   o.ticket     = 5000+mv.pending_count;
   o.symbol     = mv.specs[spec_index].name;
   o.dir        = dir;
   o.volume     = volume;
   o.price      = price;
   o.sl         = sl;
   o.setup_time = mv.now-60;
   o.spec_index = spec_index;
   mv.pendings[mv.pending_count] = o;
   mv.pending_count++;
  }

//--- a permissive firm: 5% daily off day-start balance, 10% static overall
static PG_RuleSet FirmStandard()
  {
   PG_RuleSet r;
   r.firm_id="test"; r.firm_name_en="Test Firm";
   r.program_id="std"; r.phase_label_en="Phase 1";
   r.daily_enabled=true;  r.daily_limit_pct=5.0;
   r.daily_baseline=PG_BASE_BALANCE_AT_RESET;
   r.daily_include_floating=true;
   r.maxdd_enabled=true;  r.maxdd_limit_pct=10.0;
   r.maxdd_mode=PG_DD_STATIC_INITIAL;
   r.maxdd_include_floating=true;
   r.require_sl=false;
   return r;
  }

static PG_UserConfig CfgStandard()
  {
   PG_UserConfig c;
   c.Defaults();
   c.gap_buffer_pct  = 0.0;    // scenarios assert exact money unless stated
   c.slippage_points = 0.0;
   c.require_sl      = false;
   return c;
  }

//--- run the full pipeline
static void Run(const PG_MarketView &mv,const PG_RuleSet &firm,
                const PG_UserConfig &cfg,PG_RiskResult &risk,
                PG_EngineState &st,PG_VerdictSet &vs,bool include_pendings=true)
  {
   PG_RuleSet eff;
   PG_BuildEffective(firm,cfg,eff);
   PG_ComputeRisk(mv,cfg,include_pendings,risk);
   PG_BuildState(mv,eff,cfg,risk,0,st);
   PG_Evaluate(mv,eff,firm,cfg,risk,st,vs);
  }

static bool HasAction(const PG_VerdictSet &vs,ENUM_PG_RULE rule,ENUM_PG_ACTION act)
  {
   for(int i=0;i<vs.count;i++)
      if(vs.items[i].rule==rule && vs.items[i].action==act)
         return true;
   return false;
  }

static bool AnyAction(const PG_VerdictSet &vs,ENUM_PG_ACTION act)
  {
   for(int i=0;i<vs.count;i++)
      if(vs.items[i].action==act)
         return true;
   return false;
  }

//==================================================================
// GROUP: CLOCK
//==================================================================
static void TestClock()
  {
   std::printf("\n\033[1mCLOCK - boundaries, timezones, DST\033[0m\n");

   PG_RuleSet r = FirmStandard();
   r.reset_hour=0; r.reset_minute=0;

   //--- 1. server UTC+3, firm UTC+0 -> reset lands at 03:00 server
   r.firm_utc_offset_min=0; r.firm_uses_dst=false;
   check_time("CLOCK","01 daily reset, server UTC+3 firm UTC+0",
              PG_DayStartServer(PG_MakeTime(2026,8,5,10,0,0),180,r),
              PG_MakeTime(2026,8,5,3,0,0));

   //--- 2. before the reset, the boundary is yesterday's
   check_time("CLOCK","02 before reset falls back a day",
              PG_DayStartServer(PG_MakeTime(2026,8,5,1,0,0),180,r),
              PG_MakeTime(2026,8,4,3,0,0));

   //--- 3. Iranian firm at UTC+3:30
   r.firm_utc_offset_min=210;
   check_time("CLOCK","03 firm UTC+3:30 boundary",
              PG_DayStartServer(PG_MakeTime(2026,8,5,10,0,0),180,r),
              PG_MakeTime(2026,8,4,23,30,0));

   //--- 4/5. EU DST on and off for a CET firm, server on UTC
   r.firm_utc_offset_min=60; r.firm_uses_dst=true;
   check_time("CLOCK","04 CET firm in summer (CEST, UTC+2)",
              PG_DayStartServer(PG_MakeTime(2026,8,5,10,0,0),0,r),
              PG_MakeTime(2026,8,4,22,0,0));
   check_time("CLOCK","05 CET firm in winter (UTC+1)",
              PG_DayStartServer(PG_MakeTime(2026,1,15,10,0,0),0,r),
              PG_MakeTime(2026,1,14,23,0,0));

   //--- 6. EU DST window edges for 2026: Mar 29 .. Oct 25
   CHECK("CLOCK","06 DST starts last Sunday of March",
         !PG_IsEuDst(PG_MakeTime(2026,3,29,0,59,0)) &&
          PG_IsEuDst(PG_MakeTime(2026,3,29,1,1,0)));
   CHECK("CLOCK","07 DST ends last Sunday of October",
          PG_IsEuDst(PG_MakeTime(2026,10,25,0,59,0)) &&
         !PG_IsEuDst(PG_MakeTime(2026,10,25,1,1,0)));

   //--- 8. next reset is a day later when no DST shift intervenes
   r.firm_utc_offset_min=0; r.firm_uses_dst=false;
   check_eq_i("CLOCK","08 next reset is 24h away",
              PG_NextDayStartServer(PG_MakeTime(2026,8,5,10,0,0),180,r)
              -PG_DayStartServer(PG_MakeTime(2026,8,5,10,0,0),180,r),
              86400);

   //--- 9. countdown never goes negative and never exceeds a day
   const long left = PG_SecondsToNextReset(PG_MakeTime(2026,8,5,10,0,0),180,r);
   CHECK("CLOCK","09 countdown within a day",(left>0 && left<=86400));

   //--- 10. weekly rollover: Sunday 22:00
   r.week_reset_dow=0; r.week_reset_hour=22;
   check_time("CLOCK","10 weekly rollover boundary",
              PG_WeekStartServer(PG_MakeTime(2026,8,5,10,0,0),r),
              PG_MakeTime(2026,8,2,22,0,0));

   //--- 11. day-of-week sanity (2026-08-05 is a Wednesday)
   check_eq_i("CLOCK","11 day of week",PG_DayOfWeek(PG_MakeTime(2026,8,5,0,0,0)),3);

   //--- 12/13/14. weekend cutoff: Friday 20:45
   r.weekend_close_dow=5; r.weekend_close_hour=20; r.weekend_close_minute=45;
   CHECK("CLOCK","12 before Friday cutoff is fine",
         !PG_IsPastWeekendCutoff(PG_MakeTime(2026,8,7,20,44,0),r));
   CHECK("CLOCK","13 after Friday cutoff is blocked",
          PG_IsPastWeekendCutoff(PG_MakeTime(2026,8,7,20,46,0),r));
   CHECK("CLOCK","14 Saturday is blocked",
          PG_IsPastWeekendCutoff(PG_MakeTime(2026,8,8,12,0,0),r));
   CHECK("CLOCK","15 Sunday after rollover reopens",
         !PG_IsPastWeekendCutoff(PG_MakeTime(2026,8,9,23,0,0),r));
  }

//==================================================================
// GROUP: RISK
//==================================================================
static void TestRisk()
  {
   std::printf("\n\033[1mRISK - worst case if every stop is hit\033[0m\n");

   PG_MarketView mv;   BaseView(mv);
   PG_UserConfig cfg = CfgStandard();

   //--- 16. long EURUSD, 50 pips of stop on 1 lot = $500
   AddPos(mv,0,+1,1.00,1.10000,1.09500,0.0);
     {
      bool has_sl=false;
      check_eq("RISK","16 long stop loss in money",
               PG_PositionWorstPL(mv.positions[0],mv.specs[0],0.0,0.0,has_sl),
               -500.0);
      CHECK("RISK","17 stop was detected",has_sl);
     }

   //--- 18. short side is symmetric
   PG_MarketView mv2; BaseView(mv2);
   AddPos(mv2,0,-1,1.00,1.10000,1.10500,0.0);
     {
      bool has_sl=false;
      check_eq("RISK","18 short stop loss in money",
               PG_PositionWorstPL(mv2.positions[0],mv2.specs[0],0.0,0.0,has_sl),
               -500.0);
     }

   //--- 19/20/21. pessimism stacks: gap, slippage, commission
     {
      bool has_sl=false;
      check_eq("RISK","19 gap buffer 15% inflates the loss",
               PG_PositionWorstPL(mv.positions[0],mv.specs[0],15.0,0.0,has_sl),
               -575.0);
      check_eq("RISK","20 slippage allowance adds on top",
               PG_PositionWorstPL(mv.positions[0],mv.specs[0],15.0,20.0,has_sl),
               -595.0);
      PG_SymbolSpec commissioned = mv.specs[0];
      commissioned.commission_per_lot = 7.0;
      check_eq("RISK","21 commission is charged as well",
               PG_PositionWorstPL(mv.positions[0],commissioned,15.0,20.0,has_sl),
               -602.0);
     }

   //--- 22/23. a position with no stop is unbounded, never zero risk
   PG_MarketView mv3; BaseView(mv3);
   AddPos(mv3,0,+1,1.00,1.10000,0.0,-120.0);
     {
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      PG_RuleSet firm = FirmStandard();
      Run(mv3,firm,cfg,risk,st,vs);
      CHECK("RISK","22 missing stop flags unbounded",risk.unbounded);
      check_eq_i("RISK","23 missing stop counted",risk.no_sl_positions,1);
     }

   //--- 24/25. aggregation across two positions and the resulting equity
   PG_MarketView mv4; BaseView(mv4);
   AddPos(mv4,0,+1,1.00,1.10000,1.09500,-100.0);   // -500 at stop
   AddPos(mv4,1,-1,0.50,2400.00,2410.00,-50.0);    // 1000 ticks * 1 * 0.5 = -500
     {
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      PG_RuleSet firm = FirmStandard();
      Run(mv4,firm,cfg,risk,st,vs);
      check_eq("RISK","24 aggregate worst P/L",risk.open_worst_pl,-1000.0);
      check_eq("RISK","25 worst equity = balance + worst P/L",
               risk.worst_equity,99000.0);
      check_eq("RISK","26 total lots",risk.total_lots,1.50);
     }

   //--- 27. a resting pending order is future loss and must be counted
   PG_MarketView mv5; BaseView(mv5);
   AddPending(mv5,0,+1,1.00,1.10500,1.10000);      // -500 if it fills and stops
     {
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      PG_RuleSet firm = FirmStandard();
      Run(mv5,firm,cfg,risk,st,vs,true);
      check_eq("RISK","27 pending order counted",risk.pending_worst_pl,-500.0);
      Run(mv5,firm,cfg,risk,st,vs,false);
      check_eq("RISK","28 pending ignored when asked",risk.pending_worst_pl,0.0);
     }

   //--- 29/30/31. the panel lot calculator
     {
      PG_SymbolSpec s = SpecEurUsd();
      check_eq("RISK","29 max lot, no buffers",
               PG_MaxLotForRisk(s,1.10000,1.09500,1000.0,0.0,0.0),2.00);
      s.commission_per_lot=7.0;
      check_eq("RISK","30 max lot with gap+slip+commission",
               PG_MaxLotForRisk(s,1.10000,1.09500,1000.0,15.0,20.0),1.66);
      check_eq("RISK","31 refuses when below broker minimum",
               PG_MaxLotForRisk(s,1.10000,1.09500,1.0,0.0,0.0),0.0);
     }
  }

//==================================================================
// GROUP: DAILY
//==================================================================
static void TestDailyLoss()
  {
   std::printf("\n\033[1mDAILY - daily loss limit and its baselines\033[0m\n");

   PG_RuleSet firm = FirmStandard();
   PG_UserConfig cfg = CfgStandard();     // warn 60, block 80

   //--- 32. quiet account raises nothing
     {
      PG_MarketView mv; BaseView(mv);
      mv.equity = 99000.0;                // -1% of a 5% allowance = 20%
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("DAILY","32 no verdict well inside the limit",
            !vs.Has(PG_RULE_DAILY_LOSS));
      check_eq("DAILY","33 usage percentage",st.daily_used_pct,20.0);
     }

   //--- 34. warn tier at 60% of the allowance (-3%)
     {
      PG_MarketView mv; BaseView(mv);
      mv.equity = 97000.0;
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("DAILY","34 warn tier fires",
            HasAction(vs,PG_RULE_DAILY_LOSS,PG_ACT_WARN));
      CHECK("DAILY","35 warn does not block trading",!vs.block_new_trades);
     }

   //--- 36. block tier at 80% (-4%)
     {
      PG_MarketView mv; BaseView(mv);
      mv.equity = 96000.0;
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("DAILY","36 block tier stops new trades",vs.block_new_trades);
      CHECK("DAILY","37 but does not lock out yet",!vs.lockout);
     }

   //--- 38. full breach locks the account down
     {
      PG_MarketView mv; BaseView(mv);
      mv.equity = 95000.0;
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("DAILY","38 breach triggers lockout",vs.lockout);
      CHECK("DAILY","39 severity is BREACH",vs.Worst()==PG_SEV_BREACH);
     }

   //--- 40. baseline choice changes the answer. Account opened the day at
   //---     balance 100k but equity 102k from an open winner.
     {
      PG_MarketView mv; BaseView(mv);
      mv.day_start_balance = 100000.0;
      mv.day_start_equity  = 102000.0;
      mv.equity            = 97500.0;

      PG_RuleSet balance_based = firm;
      balance_based.daily_baseline = PG_BASE_BALANCE_AT_RESET;
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,balance_based,cfg,risk,st,vs);
      check_eq("DAILY","40 balance baseline: 2500 used",st.daily_used_money,2500.0);

      PG_RuleSet max_based = firm;
      max_based.daily_baseline = PG_BASE_MAX_OF_BOTH;
      Run(mv,max_based,cfg,risk,st,vs);
      check_eq("DAILY","41 max-of-both baseline: 4500 used",
               st.daily_used_money,4500.0);
      CHECK("DAILY","42 stricter baseline reaches the block tier",
            vs.block_new_trades);
     }

   //--- 43. balance-only firms ignore floating loss
     {
      PG_MarketView mv; BaseView(mv);
      mv.equity = 94000.0;               // -6% floating, balance untouched
      PG_RuleSet no_float = firm;
      no_float.daily_include_floating = false;
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,no_float,cfg,risk,st,vs);
      check_eq("DAILY","43 floating ignored when firm says balance",
               st.daily_used_money,0.0);
     }
  }

//==================================================================
// GROUP: MAXDD
//==================================================================
static void TestMaxDrawdown()
  {
   std::printf("\n\033[1mMAXDD - the four drawdown algorithms\033[0m\n");

   PG_RuleSet firm = FirmStandard();     // 10% of 100k = 10k
   PG_UserConfig cfg = CfgStandard();

   //--- 44. static floor sits at initial - amount and never moves
     {
      PG_MarketView mv; BaseView(mv,110000.0);
      mv.hwm_equity = 110000.0;
      PG_RuleSet r = firm; r.maxdd_mode = PG_DD_STATIC_INITIAL;
      check_eq("MAXDD","44 static floor",PG_MaxDdFloor(mv,r),90000.0);
     }

   //--- 45. trailing-on-equity keeps climbing with the high-water mark
     {
      PG_MarketView mv; BaseView(mv,110000.0);
      mv.hwm_equity = 112000.0;
      PG_RuleSet r = firm; r.maxdd_mode = PG_DD_TRAILING_EQUITY;
      check_eq("MAXDD","45 trailing floor follows the HWM",
               PG_MaxDdFloor(mv,r),102000.0);
     }

   //--- 46/47. trailing-then-lock stops at the initial balance
     {
      PG_MarketView mv; BaseView(mv,105000.0);
      PG_RuleSet r = firm; r.maxdd_mode = PG_DD_TRAILING_LOCK;
      mv.hwm_equity = 105000.0;
      check_eq("MAXDD","46 lock mode trails while below the trigger",
               PG_MaxDdFloor(mv,r),95000.0);
      mv.hwm_equity = 118000.0;          // profit now exceeds the 10k allowance
      check_eq("MAXDD","47 lock mode stops at initial balance",
               PG_MaxDdFloor(mv,r),100000.0);
     }

   //--- 48. end-of-day-balance trailing uses the balance HWM, not equity
     {
      PG_MarketView mv; BaseView(mv,108000.0);
      mv.hwm_equity      = 120000.0;
      mv.hwm_eod_balance = 108000.0;
      PG_RuleSet r = firm; r.maxdd_mode = PG_DD_TRAILING_EOD_BALANCE;
      check_eq("MAXDD","48 EOD balance trailing floor",
               PG_MaxDdFloor(mv,r),98000.0);
     }

   //--- 49. crossing the floor is a breach and a lockout
     {
      PG_MarketView mv; BaseView(mv);
      mv.balance = 91000.0; mv.equity = 89500.0;
      mv.day_start_balance = 91000.0; mv.day_start_equity = 91000.0;
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("MAXDD","49 breach detected",vs.Has(PG_RULE_MAX_DRAWDOWN));
      CHECK("MAXDD","50 lockout raised",vs.lockout);
     }
  }

//==================================================================
// GROUP: WORST - the pre-emptive rule
//==================================================================
static void TestWorstCase()
  {
   std::printf("\n\033[1mWORST - closing a trade before its stop can breach\033[0m\n");

   PG_RuleSet firm = FirmStandard();     // daily 5% = 5000
   PG_UserConfig cfg = CfgStandard();

   //--- 51. book that survives its own stops raises nothing
     {
      PG_MarketView mv; BaseView(mv);
      AddPos(mv,0,+1,2.00,1.10000,1.09500,-200.0);      // -1000 at stop
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("WORST","51 safe book raises nothing",!vs.Has(PG_RULE_WORST_CASE));
      check_eq("WORST","52 worst equity",risk.worst_equity,99000.0);
     }

   //--- 53. book whose stops would blow the daily floor must be reduced
     {
      PG_MarketView mv; BaseView(mv);
      AddPos(mv,0,+1,12.00,1.10000,1.09500,-500.0);     // -6000 at stop
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("WORST","53 projected breach detected",vs.Has(PG_RULE_WORST_CASE));
      CHECK("WORST","54 action is REDUCE by default",
            HasAction(vs,PG_RULE_WORST_CASE,PG_ACT_REDUCE));
      CHECK("WORST","55 the worst offender is named",
            vs.items[vs.count-1].ticket!=0 || vs.count>0);
     }

   //--- 56. same book, CLOSE_ALL enforcement mode
     {
      PG_MarketView mv; BaseView(mv);
      AddPos(mv,0,+1,12.00,1.10000,1.09500,-500.0);
      PG_UserConfig hard = cfg; hard.enforce_mode = PG_ENFORCE_CLOSE;
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,hard,risk,st,vs);
      CHECK("WORST","56 close-all mode flattens instead",
            HasAction(vs,PG_RULE_WORST_CASE,PG_ACT_CLOSE_ALL));
     }

   //--- 57. monitor mode never proposes a destructive action
     {
      PG_MarketView mv; BaseView(mv);
      AddPos(mv,0,+1,12.00,1.10000,1.09500,-500.0);
      mv.equity = 94000.0;                              // also past the daily limit
      PG_UserConfig watch = cfg; watch.enforce_mode = PG_ENFORCE_MONITOR;
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,watch,risk,st,vs);
      CHECK("WORST","57 monitor never closes",
            !AnyAction(vs,PG_ACT_CLOSE_ALL) &&
            !AnyAction(vs,PG_ACT_CLOSE_POSITION) &&
            !AnyAction(vs,PG_ACT_REDUCE) &&
            !AnyAction(vs,PG_ACT_LOCKOUT));
      CHECK("WORST","58 but it still reports the breach",vs.count>0);
     }

   //--- 59. projected breach of the overall floor, not the daily one
     {
      PG_MarketView mv; BaseView(mv,92000.0);
      mv.day_start_balance = 92000.0; mv.day_start_equity = 92000.0;
      AddPos(mv,0,+1,5.00,1.10000,1.09500,-100.0);      // -2500 at stop -> 89.5k
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("WORST","59 overall floor breach projected",
            vs.Has(PG_RULE_WORST_CASE));
     }

   //--- 60. headroom shrinks as risk is added and never goes negative
     {
      PG_MarketView mv; BaseView(mv);
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      const double empty_book = st.headroom_money;
      AddPos(mv,0,+1,4.00,1.10000,1.09500,0.0);         // -2000 at stop
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("WORST","60 headroom shrinks with open risk",
            st.headroom_money<empty_book);
      check_eq("WORST","61 headroom is exact",st.headroom_money,3000.0);
      CHECK("WORST","62 headroom never negative",st.headroom_money>=0.0);
     }
  }

//==================================================================
// GROUP: RULES - the remaining mechanical limits
//==================================================================
static void TestOtherRules()
  {
   std::printf("\n\033[1mRULES - stops, lots, positions, hedging, news, weekend\033[0m\n");

   PG_UserConfig cfg = CfgStandard();

   //--- 63/64. missing stop loss: grace, then close
     {
      PG_RuleSet firm = FirmStandard();
      firm.require_sl = true; firm.sl_grace_seconds = 60;

      PG_MarketView mv; BaseView(mv);
      AddPos(mv,0,+1,1.00,1.10000,0.0,-10.0,30);        // 30s old
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("RULES","63 inside grace: attach a stop",
            HasAction(vs,PG_RULE_STOP_LOSS_REQUIRED,PG_ACT_ATTACH_SL));

      PG_MarketView mv2; BaseView(mv2);
      AddPos(mv2,0,+1,1.00,1.10000,0.0,-10.0,300);      // 5 minutes old
      Run(mv2,firm,cfg,risk,st,vs);
      CHECK("RULES","64 past grace: close the position",
            HasAction(vs,PG_RULE_STOP_LOSS_REQUIRED,PG_ACT_CLOSE_POSITION));
     }

   //--- 65. per-trade risk cap
     {
      PG_RuleSet firm = FirmStandard();
      firm.max_risk_per_trade_pct = 1.0;                // 1000 on 100k
      PG_MarketView mv; BaseView(mv);
      AddPos(mv,0,+1,3.00,1.10000,1.09500,0.0);         // -1500 at stop
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("RULES","65 oversized single-trade risk caught",
            vs.Has(PG_RULE_MAX_RISK_PER_TRADE));
     }

   //--- 66. lot ceiling per trade, scaled to account size
     {
      PG_RuleSet firm = FirmStandard();
      firm.max_lot_per_trade_per_100k = 2.0;
      PG_MarketView mv; BaseView(mv);
      AddPos(mv,0,+1,2.50,1.10000,1.09900,0.0);
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("RULES","66 oversized lot caught",vs.Has(PG_RULE_MAX_LOT_PER_TRADE));

      PG_MarketView ok; BaseView(ok);
      AddPos(ok,0,+1,2.00,1.10000,1.09900,0.0);
      Run(ok,firm,cfg,risk,st,vs);
      CHECK("RULES","67 exactly at the cap is allowed",
            !vs.Has(PG_RULE_MAX_LOT_PER_TRADE));
     }

   //--- 68. total exposure ceiling
     {
      PG_RuleSet firm = FirmStandard();
      firm.max_total_lots_per_100k = 3.0;
      PG_MarketView mv; BaseView(mv);
      AddPos(mv,0,+1,2.00,1.10000,1.09900,0.0);
      AddPos(mv,0,+1,2.00,1.10000,1.09900,0.0);
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("RULES","68 total lots ceiling caught",
            vs.Has(PG_RULE_MAX_TOTAL_LOTS));
     }

   //--- 69. open position count
     {
      PG_RuleSet firm = FirmStandard();
      firm.max_open_positions = 2;
      PG_MarketView mv; BaseView(mv);
      for(int i=0;i<3;i++)
         AddPos(mv,0,+1,0.10,1.10000,1.09900,0.0);
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("RULES","69 too many positions caught",
            vs.Has(PG_RULE_MAX_POSITIONS));
     }

   //--- 70. hedging
     {
      PG_RuleSet firm = FirmStandard();
      firm.forbid_hedging = true;
      PG_MarketView mv; BaseView(mv);
      AddPos(mv,0,+1,1.00,1.10000,1.09900,0.0);
      AddPos(mv,0,-1,1.00,1.10000,1.10100,0.0);
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("RULES","70 opposing positions caught",vs.Has(PG_RULE_HEDGING));
     }

   //--- 71/72. news blackout window
     {
      PG_RuleSet firm = FirmStandard();
      firm.news_blackout_enabled = true;
      firm.news_before_min = 2; firm.news_after_min = 2;

      PG_MarketView mv; BaseView(mv);
      mv.news[0].event_time = mv.now+60;      // one minute out
      mv.news[0].impact     = 3;
      mv.news[0].title      = "US CPI";
      mv.news[0].currency   = "USD";
      mv.news_count = 1;
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("RULES","71 inside the blackout window",
            vs.Has(PG_RULE_NEWS_BLACKOUT) && vs.block_new_trades);

      mv.news[0].event_time = mv.now+3600;    // an hour out
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("RULES","72 outside the window is clear",
            !vs.Has(PG_RULE_NEWS_BLACKOUT));
     }

   //--- 73. weekend holding
     {
      PG_RuleSet firm = FirmStandard();
      firm.forbid_weekend_holding = true;
      firm.weekend_close_dow = 5;
      firm.weekend_close_hour = 20; firm.weekend_close_minute = 45;

      PG_MarketView mv; BaseView(mv);
      mv.now = PG_MakeTime(2026,8,7,21,0,0);           // Friday 21:00
      AddPos(mv,0,+1,1.00,1.10000,1.09900,0.0);
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("RULES","73 open over the weekend is closed",
            HasAction(vs,PG_RULE_WEEKEND_HOLDING,PG_ACT_CLOSE_ALL));
     }

   //--- 74. consistency rule
     {
      PG_RuleSet firm = FirmStandard();
      firm.consistency_enabled = true;
      firm.consistency_max_day_share_pct = 40.0;
      PG_MarketView mv; BaseView(mv);
      mv.total_profit    = 10000.0;
      mv.best_day_profit = 5000.0;                     // 50%
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("RULES","74 concentrated profit flagged",
            vs.Has(PG_RULE_CONSISTENCY));
     }

   //--- 75. minimum hold time - the guard must know not to close too early
     {
      PG_RuleSet firm = FirmStandard();
      firm.min_hold_seconds = 60;
      PG_MarketView mv; BaseView(mv);
      AddPos(mv,0,+1,1.00,1.10000,1.09900,0.0,10);     // 10 seconds old
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      CHECK("RULES","75 young position flagged as un-closable",
            vs.Has(PG_RULE_MIN_HOLD_TIME));
     }
  }

//==================================================================
// GROUP: GATE - the pre-trade check
//==================================================================
static void TestPreTradeGate()
  {
   std::printf("\n\033[1mGATE - would this order be allowed?\033[0m\n");

   PG_RuleSet firm = FirmStandard();
   PG_UserConfig cfg = CfgStandard();
   PG_SymbolSpec spec = SpecEurUsd();

   //--- 76. a modest order is accepted
     {
      PG_MarketView mv; BaseView(mv);
      PG_RuleSet eff; PG_BuildEffective(firm,cfg,eff);
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      string why;
      CHECK("GATE","76 order inside headroom accepted",
            PG_CheckNewOrder(mv,eff,cfg,st,vs,spec,+1,1.00,1.10000,1.09500,why));
     }

   //--- 77. an order whose own stop would blow the day is refused
     {
      PG_MarketView mv; BaseView(mv);
      PG_RuleSet eff; PG_BuildEffective(firm,cfg,eff);
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      string why;
      const bool ok = PG_CheckNewOrder(mv,eff,cfg,st,vs,spec,+1,20.00,
                                       1.10000,1.09500,why);
      CHECK("GATE","77 oversized order refused",!ok);
      CHECK("GATE","78 refusal explains itself",StringLen(why)>0);
     }

   //--- 79. no stop loss, and the config demands one
     {
      PG_MarketView mv; BaseView(mv);
      PG_UserConfig strict = cfg; strict.require_sl = true;
      PG_RuleSet eff; PG_BuildEffective(firm,strict,eff);
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,strict,risk,st,vs);
      string why;
      CHECK("GATE","79 stopless order refused",
            !PG_CheckNewOrder(mv,eff,strict,st,vs,spec,+1,0.10,1.10000,0.0,why));
     }

   //--- 80. nothing gets through during a lockout
     {
      PG_MarketView mv; BaseView(mv);
      mv.equity = 95000.0;                        // daily limit breached
      PG_RuleSet eff; PG_BuildEffective(firm,cfg,eff);
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);
      string why;
      CHECK("GATE","80 lockout refuses everything",
            !PG_CheckNewOrder(mv,eff,cfg,st,vs,spec,+1,0.01,1.10000,1.09990,why));
     }

   //--- 81. the calculator and the gate agree: the lot the panel offers
   //---     is the largest lot the gate will actually accept
     {
      PG_MarketView mv; BaseView(mv);
      PG_RuleSet eff; PG_BuildEffective(firm,cfg,eff);
      PG_RiskResult risk; PG_EngineState st; PG_VerdictSet vs;
      Run(mv,firm,cfg,risk,st,vs);

      const double offered = PG_MaxLotForRisk(spec,1.10000,1.09500,
                                              st.headroom_money,
                                              cfg.gap_buffer_pct,
                                              cfg.slippage_points);
      string why;
      const bool accepted = PG_CheckNewOrder(mv,eff,cfg,st,vs,spec,+1,offered,
                                             1.10000,1.09500,why);
      const bool next_refused = !PG_CheckNewOrder(mv,eff,cfg,st,vs,spec,+1,
                                                  offered+spec.volume_step,
                                                  1.10000,1.09500,why);
      CHECK("GATE","81 the offered lot is accepted",accepted);
      CHECK("GATE","82 one step larger is refused",next_refused);
     }
  }

//==================================================================
// GROUP: LOCK - tighten-only merge and rule validation
//==================================================================
static void TestTightenOnly()
  {
   std::printf("\n\033[1mLOCK - the trader may only make it stricter\033[0m\n");

   PG_RuleSet firm = FirmStandard();     // daily 5, dd 10

   //--- 83. a stricter user value wins
     {
      PG_UserConfig c; c.Defaults();
      c.use_overrides=true; c.daily_limit_pct=3.5; c.maxdd_limit_pct=7.0;
      PG_RuleSet eff; PG_BuildEffective(firm,c,eff);
      check_eq("LOCK","83 stricter daily accepted",eff.daily_limit_pct,3.5);
      check_eq("LOCK","84 stricter drawdown accepted",eff.maxdd_limit_pct,7.0);
     }

   //--- 85. a looser user value is discarded, silently and always
     {
      PG_UserConfig c; c.Defaults();
      c.use_overrides=true; c.daily_limit_pct=9.0; c.maxdd_limit_pct=25.0;
      PG_RuleSet eff; PG_BuildEffective(firm,c,eff);
      check_eq("LOCK","85 looser daily rejected",eff.daily_limit_pct,5.0);
      check_eq("LOCK","86 looser drawdown rejected",eff.maxdd_limit_pct,10.0);
     }

   //--- 87. zero means "no opinion", not "no limit"
     {
      PG_UserConfig c; c.Defaults();
      c.use_overrides=true; c.daily_limit_pct=0.0;
      PG_RuleSet eff; PG_BuildEffective(firm,c,eff);
      check_eq("LOCK","87 zero keeps the firm value",eff.daily_limit_pct,5.0);
     }

   //--- 88. a user ceiling on a field the firm leaves open is adopted
     {
      PG_UserConfig c; c.Defaults();
      c.use_overrides=true; c.max_lot_per_trade_per_100k=1.5;
      PG_RuleSet eff; PG_BuildEffective(firm,c,eff);
      check_eq("LOCK","88 user adds a ceiling the firm lacks",
               eff.max_lot_per_trade_per_100k,1.5);
     }

   //--- 89. boolean tightening only ever goes on
     {
      PG_UserConfig c; c.Defaults();
      c.use_overrides=true; c.require_sl=true; c.forbid_weekend_holding=true;
      PG_RuleSet permissive = firm;
      permissive.require_sl=false; permissive.forbid_weekend_holding=false;
      PG_RuleSet eff; PG_BuildEffective(permissive,c,eff);
      CHECK("LOCK","89 user can switch a protection on",
            eff.require_sl && eff.forbid_weekend_holding);

      PG_UserConfig lax; lax.Defaults();
      lax.use_overrides=true; lax.require_sl=false;
      PG_RuleSet demanding = firm; demanding.require_sl=true;
      PG_RuleSet eff2; PG_BuildEffective(demanding,lax,eff2);
      CHECK("LOCK","90 user cannot switch a firm protection off",eff2.require_sl);
     }
  }

//==================================================================
// GROUP: VALID - rule file sanity
//==================================================================
static void TestValidation()
  {
   std::printf("\n\033[1mVALID - rule records are checked before they guard money\033[0m\n");

   //--- 91. a sane record passes
     {
      PG_RuleSet r = FirmStandard();
      report("VALID","91 sane record accepted",PG_ValidateRuleSet(r)=="",
             PG_ValidateRuleSet(r));
     }

   //--- 92..96 rejections
     {
      PG_RuleSet r = FirmStandard(); r.daily_limit_pct = 0.0;
      CHECK("VALID","92 zero daily limit rejected",PG_ValidateRuleSet(r)!="");
     }
     {
      PG_RuleSet r = FirmStandard(); r.daily_limit_pct = 12.0;  // > maxdd 10
      CHECK("VALID","93 daily above overall rejected",PG_ValidateRuleSet(r)!="");
     }
     {
      PG_RuleSet r = FirmStandard(); r.reset_hour = 24;
      CHECK("VALID","94 impossible reset hour rejected",PG_ValidateRuleSet(r)!="");
     }
     {
      PG_RuleSet r = FirmStandard(); r.firm_id = "";
      CHECK("VALID","95 missing firm id rejected",PG_ValidateRuleSet(r)!="");
     }
     {
      PG_RuleSet r = FirmStandard();
      r.consistency_enabled=true; r.consistency_max_day_share_pct=0.0;
      CHECK("VALID","96 impossible consistency share rejected",
            PG_ValidateRuleSet(r)!="");
     }

   //--- 97/98. the shipped catalog must be structurally valid, and every
   //---        entry must still be flagged unverified until a human checks it
     {
      PG_Catalog cat; PG_LoadCatalog(cat);
      bool all_valid=true; string first_error="";
      for(int i=0;i<cat.count;i++)
        {
         const string e = PG_ValidateRuleSet(cat.items[i]);
         if(e!="")
           { all_valid=false; first_error=cat.items[i].firm_id+": "+e; break; }
        }
      report("VALID","97 shipped catalog is structurally valid",all_valid,
             first_error);
      check_eq_i("VALID","98 every shipped program is unverified",
                 PG_UnverifiedCount(cat),cat.count);
     }
  }

//==================================================================
// GROUP: WINDOW - the weekly lock and its escape hatch
//==================================================================
static void TestLockWindow()
  {
   std::printf("\n\033[1mWINDOW - the weekly lock, and getting around it\033[0m\n");

   PG_RuleSet rules = FirmStandard();
   rules.week_reset_dow = 0; rules.week_reset_hour = 22;
   const long monday = PG_MakeTime(2026,8,3,12,0,0);

   //--- a locked state at 3.5% daily
   PG_LockState st;
   st.account_login = 12345678;
   st.firm_id="test"; st.program_id="std"; st.phase_label="Phase 1";
     {
      PG_UserConfig c; c.Defaults();
      c.use_overrides=true; c.daily_limit_pct=3.5; c.maxdd_limit_pct=7.0;
      PG_ApplyConfig(st,c,monday,rules);
     }

   CHECK("WINDOW","99 lock is active after applying",PG_LockIsActive(st,monday));

   //--- 100. tightening is always allowed
     {
      PG_UserConfig tighter = st.current; tighter.daily_limit_pct=2.0;
      string why;
      CHECK("WINDOW","100 tightening allowed inside the window",
            PG_CanApplyConfig(st,tighter,monday,why));
     }

   //--- 101. loosening is refused, with an explanation
     {
      PG_UserConfig looser = st.current; looser.daily_limit_pct=4.5;
      string why;
      const bool ok = PG_CanApplyConfig(st,looser,monday,why);
      CHECK("WINDOW","101 loosening refused inside the window",!ok);
      CHECK("WINDOW","102 refusal names the field",
            StringFind(why,"daily loss limit")>=0);
     }

   //--- 103. typing a zero must not read as "no limit, therefore fine"
     {
      PG_UserConfig zeroed = st.current; zeroed.daily_limit_pct=0.0;
      string why;
      CHECK("WINDOW","103 zeroing a limit is treated as loosening",
            !PG_CanApplyConfig(st,zeroed,monday,why));
     }

   //--- 104. switching to monitor mode is loosening too
     {
      PG_UserConfig watch = st.current; watch.enforce_mode=PG_ENFORCE_MONITOR;
      string why;
      CHECK("WINDOW","104 dropping to monitor mode is refused",
            !PG_CanApplyConfig(st,watch,monday,why));
     }

   //--- 105/106. the 24 hour unlock, and impatience not shortening it
     {
      PG_LockState s2 = st;
      PG_RequestUnlock(s2,monday);
      check_eq_i("WINDOW","105 unlock lands 24h later",
                 PG_UnlockEffectiveAt(s2)-monday,PG_UNLOCK_DELAY_SECONDS);
      PG_RequestUnlock(s2,monday+3600);
      check_eq_i("WINDOW","106 asking again does not restart the clock",
                 PG_UnlockEffectiveAt(s2)-monday,PG_UNLOCK_DELAY_SECONDS);

      PG_UserConfig looser = s2.current; looser.daily_limit_pct=4.5;
      string why;
      CHECK("WINDOW","107 still refused before the delay elapses",
            !PG_CanApplyConfig(s2,looser,monday+3600,why));
      CHECK("WINDOW","108 allowed once the delay has elapsed",
            PG_CanApplyConfig(s2,looser,monday+PG_UNLOCK_DELAY_SECONDS+60,why));
     }

   //--- 109. once the week is served the settings open up again. This is a
   //---      weekly commitment, not a permanent ratchet.
     {
      PG_LockState s3 = st;
      const long after_window = s3.locked_until+3600;
      PG_UserConfig looser = s3.current; looser.daily_limit_pct=4.5;
      string why;
      CHECK("WINDOW","109 loosening allowed once the window closes",
            PG_CanApplyConfig(s3,looser,after_window,why));
     }

   //--- 110/111. tightening twice keeps the tighter of the two forever
     {
      PG_LockState s4 = st;
      PG_UserConfig t1 = s4.current; t1.daily_limit_pct=2.0;
      PG_ApplyConfig(s4,t1,monday+60,rules);
      check_eq("WINDOW","110 floor records the tighter value",
               s4.strictest.daily_limit_pct,2.0);

      PG_UserConfig back = s4.current; back.daily_limit_pct=3.0;
      string why;
      CHECK("WINDOW","111 cannot walk a tightening back",
            !PG_CanApplyConfig(s4,back,monday+120,why));
     }

   //--- 112/113. rebinding
     {
      PG_LockState s5 = st;
      PG_Rebind(s5,12345678,"test","std","Phase 2",monday);
      CHECK("WINDOW","112 same account keeps the floor",s5.has_strictest);

      PG_LockState s6 = st;
      PG_Rebind(s6,99999999,"test","std","Phase 1",monday);
      CHECK("WINDOW","113 a different account clears the floor",!s6.has_strictest);
     }

   //--- 114. binding change detection
     {
      CHECK("WINDOW","114 binding change detected",
            PG_BindingChanged(st,12345678,"other","std","Phase 1"));
      CHECK("WINDOW","115 identical binding is not a change",
            !PG_BindingChanged(st,12345678,"test","std","Phase 1"));
     }

   //--- 116/117. signature
     {
      PG_LockState s7 = st;
      PG_SignLockState(s7,"propguard-key");
      CHECK("WINDOW","116 signature verifies",
            PG_VerifyLockState(s7,"propguard-key"));
      s7.current.daily_limit_pct = 9.0;      // hand-edited state file
      CHECK("WINDOW","117 tampering breaks the signature",
            !PG_VerifyLockState(s7,"propguard-key"));
     }

   //--- 118/119. the payoff: a broken state file falls back to the
   //---           strictest known configuration, never to defaults
     {
      PG_LockState s8 = st;                  // strictest = 3.5 daily
      PG_FallbackToStrictest(s8,12345678,monday,rules,true);
      check_eq("WINDOW","118 fallback restores the strictest value",
               s8.current.daily_limit_pct,3.5);
      CHECK("WINDOW","119 fallback closes the lock window",
            PG_LockIsActive(s8,monday));
     }

   //--- 120. with nothing recoverable it still locks rather than opening up
     {
      PG_LockState s9;
      PG_FallbackToStrictest(s9,12345678,monday,rules,false);
      CHECK("WINDOW","120 empty history still starts locked",
            PG_LockIsActive(s9,monday));
     }

   //--- 121. the counter only ever goes up, so a restored backup is visible
     {
      PG_LockState s10 = st;
      const long before = s10.counter;
      PG_UserConfig t = s10.current; t.daily_limit_pct=1.0;
      PG_ApplyConfig(s10,t,monday+60,rules);
      CHECK("WINDOW","121 counter is monotonic",s10.counter>before);
     }
  }

//==================================================================
// GROUP: LOG - the audit chain
//==================================================================
static void TestLogChain()
  {
   std::printf("\n\033[1mLOG - append-only, tamper-evident decision records\033[0m\n");

   PG_LogRecord r;
   r.ts = PG_MakeTime(2026,8,5,14,30,15);
   r.seq = 1;
   r.severity = PG_SEV_CRITICAL;
   r.event = "enforce";
   r.rule = PG_RULE_WORST_CASE;
   r.action = PG_ACT_REDUCE;
   r.ticket = 1000;
   r.current = 5820.0;
   r.limit_user = 3500.0;
   r.limit_firm = 5000.0;
   r.account = 12345678;
   r.firm_id = "fundednext";
   r.program_id = "stellar-2step";
   r.phase = "Phase 1";
   r.rules_verified = false;
   r.mode = PG_ENFORCE_REDUCE;
   r.tier = PG_TIER_ENFORCE;
   r.balance = 100000.0;
   r.equity = 99400.0;
   r.reason = "If every stop is hit, equity lands at 94180.00, below the daily floor 96500.00.";

   ulong h1=0, h2=0, h3=0;
   const string l1 = PG_FormatLogLine(r,0,h1);

   //--- 122. a line verifies against the chain position it was written at
     {
      ulong got=0;
      CHECK("LOG","122 line verifies",PG_VerifyLogLine(l1,0,got));
     }

   //--- 123. and fails against a different one
     {
      ulong got=0;
      CHECK("LOG","123 wrong chain position is rejected",
            !PG_VerifyLogLine(l1,12345,got));
     }

   //--- 124. consecutive lines chain
     {
      r.seq=2; r.reason="Closed position #1000.";
      const string l2 = PG_FormatLogLine(r,h1,h2);
      ulong got=0;
      CHECK("LOG","124 second line chains to the first",
            PG_VerifyLogLine(l2,h1,got));
      r.seq=3;
      const string l3 = PG_FormatLogLine(r,h2,h3);
      CHECK("LOG","125 third line chains to the second",
            PG_VerifyLogLine(l3,h2,got));
      CHECK("LOG","126 digests differ between lines",h1!=h2 && h2!=h3);
     }

   //--- 127. an edited reason breaks its own digest
     {
      string edited = l1;
      CHECK("LOG","127 reason is present to edit",
            StringReplace(edited,"94180.00","99180.00"));
      ulong got=0;
      CHECK("LOG","128 edited line fails verification",
            !PG_VerifyLogLine(edited,0,got));
     }

   //--- 129. the record carries both limits, which is the whole point
     {
      CHECK("LOG","129 line records the trader limit",
            StringFind(l1,"\"limit_user\":3500.00")>=0);
      CHECK("LOG","130 line records the firm limit",
            StringFind(l1,"\"limit_firm\":5000.00")>=0);
      CHECK("LOG","131 unverified rules are stamped on every line",
            StringFind(l1,"\"rules_verified\":false")>=0);
     }

   //--- 132. quotes and newlines in a reason cannot break the format
     {
      PG_LogRecord q;
      q.ts = r.ts;
      q.reason = "symbol \"EUR/USD\"\nline two\ttabbed";
      ulong h=0;
      const string line = PG_FormatLogLine(q,0,h);
      ulong got=0;
      CHECK("LOG","132 escaped payload still verifies",
            PG_VerifyLogLine(line,0,got));
      CHECK("LOG","133 raw newline never reaches the file",
            StringFind(line,"\n")<0);
     }

   //--- 134. the panel rendering is short and human
     {
      const string p = PG_FormatPanelLine(r);
      CHECK("LOG","134 panel line starts with the time",
            StringFind(p,"14:30:15")==0);
      CHECK("LOG","135 panel line names the rule",
            StringFind(p,"WORST_CASE")>0);
     }
  }

//==================================================================
int main()
  {
   std::printf("\n\033[1m================ PropGuard scenario suite ================\033[0m\n");

   TestClock();
   TestRisk();
   TestDailyLoss();
   TestMaxDrawdown();
   TestWorstCase();
   TestOtherRules();
   TestPreTradeGate();
   TestTightenOnly();
   TestValidation();
   TestLockWindow();
   TestLogChain();

   std::printf("\n\033[1m==========================================================\033[0m\n");
   std::printf("  total %d   \033[32mpassed %d\033[0m   \033[31mfailed %d\033[0m\n",
               g_pass+g_fail,g_pass,g_fail);
   if(!g_failures.empty())
     {
      std::printf("\n  failures:\n");
      for(size_t i=0;i<g_failures.size();i++)
         std::printf("   - %s\n",g_failures[i].c_str());
     }
   std::printf("\n");
   return (g_fail==0 ? 0 : 1);
  }
