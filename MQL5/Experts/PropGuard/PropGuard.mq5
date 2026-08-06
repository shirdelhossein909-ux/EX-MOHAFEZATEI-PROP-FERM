//+------------------------------------------------------------------+
//|                                                    PropGuard.mq5 |
//|                                                                  |
//|   It will not let you fail your prop.                            |
//|                                                                  |
//|   This will not make you profitable. It makes sure the account   |
//|   is never lost to a rule violation.                             |
//+------------------------------------------------------------------+
#property copyright "PropGuard"
#property version   "1.00"
#property strict
#property description "Prop firm rule guard: worst-case risk, daily and overall drawdown, weekly tighten-only lock, full audit log."

#include <PropGuard/Core/PG_Types.mqh>
#include <PropGuard/Core/PG_RuleSet.mqh>
#include <PropGuard/Core/PG_Clock.mqh>
#include <PropGuard/Core/PG_RiskCalc.mqh>
#include <PropGuard/Core/PG_RuleEngine.mqh>
#include <PropGuard/Core/PG_Hash.mqh>
#include <PropGuard/Core/PG_Log.mqh>
#include <PropGuard/Core/PG_Lock.mqh>
#include <PropGuard/Firms/PG_Firms.mqh>
#include <PropGuard/Broker/PG_Broker.mqh>
#include <PropGuard/Broker/PG_Storage.mqh>
#include <PropGuard/Broker/PG_Enforcer.mqh>
#include <PropGuard/UI/PG_Theme.mqh>
#include <PropGuard/UI/PG_Lang.mqh>
#include <PropGuard/UI/PG_Panel.mqh>

//--- inputs -------------------------------------------------------
input group                "Prop firm"
input int                  InpFirmIndex        = 0;      // Firm (0-based, see Rules tab)
input int                  InpProgramIndex     = 0;      // Program and phase (0-based)
input double               InpInitialBalance   = 0.0;    // Challenge starting balance (0 = detect)

input group                "Safety"
input ENUM_PG_ENFORCE_MODE InpEnforceMode      = PG_ENFORCE_REDUCE; // When a limit is reached
input double               InpDailyLimitPct    = 0.0;    // Your daily limit % (0 = same as firm)
input double               InpMaxDdPct         = 0.0;    // Your drawdown limit % (0 = same as firm)
input double               InpGapBufferPct     = 15.0;   // Gap buffer %
input double               InpSlippagePoints   = 20.0;   // Slippage allowance (points)
input double               InpWarnAtPct        = 60.0;   // Warn at % of allowance
input double               InpBlockAtPct       = 80.0;   // Block new trades at % of allowance
input bool                 InpRequireStopLoss  = true;   // Require a stop loss on every position

input group                "Panel"
input ENUM_PG_THEME        InpTheme            = PG_THEME_MIDNIGHT; // Theme
input ENUM_PG_LANG         InpLanguage         = PG_LANG_FA;        // Language
input int                  InpPanelX           = 12;     // Panel X
input int                  InpPanelY           = 24;     // Panel Y

input group                "Advanced"
input long                 InpMagic            = 990101; // Magic number for guard actions
input int                  InpTimerMs          = 250;    // Evaluation interval (ms)
input string               InpStateKey         = "propguard-v1"; // State signing key

//--- state --------------------------------------------------------
PG_Catalog       g_catalog;
PG_RuleSet       g_firm;        // as the firm publishes it
PG_RuleSet       g_eff;         // after the trader's tightening
PG_UserConfig    g_cfg;
PG_LockState     g_lock;
PG_DayState      g_day;
PG_MarketView    g_view;
PG_RiskResult    g_risk;
PG_EngineState   g_state;
PG_VerdictSet    g_verdicts;

PG_Clock_Broker  g_clock;
PG_LogWriter     g_logger;
PG_Enforcer      g_enforcer;
PG_Panel         g_panel;

bool             g_owner        = false;
bool             g_have_calendar= false;
long             g_last_eval    = 0;
long             g_seq_startup  = 0;

//+------------------------------------------------------------------+
//| Logging helper: one place that stamps every record with the      |
//| account state, so no call site can forget to.                    |
//+------------------------------------------------------------------+
void PG_Emit(const string event,const ENUM_PG_SEVERITY sev,
             const ENUM_PG_RULE rule,const ENUM_PG_ACTION action,
             const long ticket,const string reason,const string detail,
             const double current=0.0,const double lim_user=0.0,
             const double lim_firm=0.0)
  {
   PG_LogRecord r;
   r.ts             = g_view.now>0 ? g_view.now : (long)TimeCurrent();
   r.severity       = sev;
   r.event          = event;
   r.rule           = rule;
   r.action         = action;
   r.ticket         = ticket;
   r.current        = current;
   r.limit_user     = lim_user;
   r.limit_firm     = lim_firm;
   r.reason         = reason;
   r.detail         = detail;
   r.account        = g_view.account_login;
   r.firm_id        = g_firm.firm_id;
   r.program_id     = g_firm.program_id;
   r.phase          = g_firm.phase_label_en;
   r.rules_verified = g_firm.IsVerified();
   r.mode           = g_cfg.enforce_mode;
   r.tier           = g_state.tier;
   r.balance        = g_view.balance;
   r.equity         = g_view.equity;
   r.daily_used     = g_state.daily_used_money;
   r.daily_limit    = g_state.daily_limit_money;
   r.dd_used        = g_state.dd_used_money;
   r.dd_limit       = g_state.dd_amount;
   r.worst_equity   = g_risk.worst_equity;
   r.headroom       = g_state.headroom_money;
   r.positions      = g_view.position_count;
   r.lots           = g_risk.total_lots;

   g_logger.Write(r);
   g_panel.PushLog(PG_FormatPanelLine(r),sev);
  }

//+------------------------------------------------------------------+
//| Choose the firm program from the inputs                          |
//+------------------------------------------------------------------+
bool PG_SelectProgram()
  {
   PG_LoadCatalog(g_catalog);
   if(g_catalog.count<=0)
     {
      Print("PropGuard: the firm catalog is empty. Fill in MQL5/Include/PropGuard/Firms/PG_Firms.mqh.");
      return false;
     }

   const int firm_first = PG_FirmFirstIndex(g_catalog,InpFirmIndex);
   if(firm_first<0)
     {
      Print("PropGuard: firm index ",InpFirmIndex," does not exist (",
            PG_FirmCount(g_catalog)," firms available).");
      return false;
     }

   const string firm_id = g_catalog.items[firm_first].firm_id;
   const int idx = PG_ProgramIndexOfFirm(g_catalog,firm_id,InpProgramIndex);
   if(idx<0)
     {
      Print("PropGuard: program index ",InpProgramIndex," does not exist for ",
            firm_id," (",PG_ProgramCountOfFirm(g_catalog,firm_id)," available).");
      return false;
     }

   g_firm = g_catalog.items[idx];

   const string problem = PG_ValidateRuleSet(g_firm);
   if(problem!="")
     {
      Print("PropGuard: refusing to run, the rule record is invalid - ",problem);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Config from inputs, before the stored lock has its say           |
//+------------------------------------------------------------------+
void PG_ConfigFromInputs(PG_UserConfig &c)
  {
   c.Defaults();
   c.use_overrides            = true;
   c.daily_limit_pct          = InpDailyLimitPct;
   c.maxdd_limit_pct          = InpMaxDdPct;
   c.gap_buffer_pct           = InpGapBufferPct;
   c.slippage_points          = InpSlippagePoints;
   c.warn_at_pct              = InpWarnAtPct;
   c.block_at_pct             = InpBlockAtPct;
   c.require_sl               = InpRequireStopLoss;
   c.enforce_mode             = InpEnforceMode;
  }

//+------------------------------------------------------------------+
//| Establish the day's baselines, rebuilding from history so a      |
//| restart cannot hand out a second daily allowance                 |
//+------------------------------------------------------------------+
void PG_EstablishDay(const bool first_run)
  {
   const long day_start = PG_DayStartServer(g_view.now,g_clock.OffsetMin(),g_firm);

   const bool rolled = (g_day.day_start_time!=day_start);

   if(first_run || rolled)
     {
      PG_DayRebuild rb;
      const bool ok = PG_RebuildFromHistory(day_start,g_day.challenge_start_time,
                                            g_view.balance,g_clock.OffsetMin(),
                                            g_firm,rb);

      if(rolled && !first_run)
        {
         //--- the previous day's closing balance feeds EOD-trailing firms
         g_day.hwm_eod_balance = MathMax(g_day.hwm_eod_balance,g_view.balance);
         PG_Emit("day_roll",PG_SEV_INFO,PG_RULE_NONE,PG_ACT_NONE,0,
                 "Trading day rolled over. Daily allowance reset.",
                 "new day starts "+PG_FormatStamp(day_start));
        }

      g_day.day_start_time = day_start;

      if(ok && rb.ok)
        {
         g_day.day_start_balance = rb.day_start_balance;
         g_view.trading_days_done = rb.trading_days;
         g_view.best_day_profit   = rb.best_day_profit;
         g_view.total_profit      = rb.total_profit;
         if(g_day.challenge_start_time<=0 && rb.first_deal_time>0)
            g_day.challenge_start_time = rb.first_deal_time;
        }
      else
        {
         //--- history unavailable: assume the day opened where we are now,
         //--- and say so loudly rather than pretending the number is solid
         g_day.day_start_balance = g_view.balance;
         PG_Emit("day_rebuild",PG_SEV_WARN,PG_RULE_NONE,PG_ACT_NONE,0,
                 "Deal history could not be read; the day's opening balance "
                 "is assumed to be the current balance. If the terminal "
                 "restarted mid-session this may understate today's loss.",
                 "");
        }

      g_day.day_start_equity = g_view.equity;

      if(g_day.initial_balance<=0.0)
         g_day.initial_balance = (InpInitialBalance>0.0
                                  ? InpInitialBalance
                                  : g_day.day_start_balance);
     }

   g_view.day_start_time    = g_day.day_start_time;
   g_view.day_start_balance = g_day.day_start_balance;
   g_view.day_start_equity  = g_day.day_start_equity;
   g_view.initial_balance   = g_day.initial_balance;

   //--- high-water marks
   if(g_view.equity>g_day.hwm_equity)
      g_day.hwm_equity = g_view.equity;
   if(g_day.hwm_eod_balance<=0.0)
      g_day.hwm_eod_balance = g_day.initial_balance;

   g_view.hwm_equity      = MathMax(g_day.hwm_equity,g_day.initial_balance);
   g_view.hwm_eod_balance = g_day.hwm_eod_balance;
   g_view.challenge_start_time = g_day.challenge_start_time;
  }

//+------------------------------------------------------------------+
//| Collect everything, evaluate, act, log, draw                     |
//+------------------------------------------------------------------+
void PG_Cycle(const bool force_log)
  {
   g_clock.Refresh();

   PG_LoadAccount(g_view);
   g_view.spec_count = 0;
   PG_LoadPositions(g_view,0.0);
   PG_LoadPendings(g_view,0.0);
   if(g_have_calendar && g_eff.news_blackout_enabled)
      PG_LoadNews(g_view,3600);
   else
      g_view.news_count = 0;

   PG_EstablishDay(false);

   PG_BuildEffective(g_firm,g_cfg,g_eff);
   PG_ComputeRisk(g_view,g_cfg,true,g_risk);
   PG_BuildState(g_view,g_eff,g_cfg,g_risk,g_clock.OffsetMin(),g_state);
   PG_Evaluate(g_view,g_eff,g_firm,g_cfg,g_risk,g_state,g_verdicts);

   //--- a lockout persists across restarts until the next daily reset
   if(g_day.locked_out && g_view.now<g_day.lockout_until)
     {
      g_verdicts.lockout = true;
      g_verdicts.block_new_trades = true;
     }

   if(g_owner)
     {
      PG_EnforceResult res;
      g_enforcer.Execute(g_view,g_eff,g_cfg,g_risk,g_state,g_verdicts,res);

      for(int i=0;i<res.count;i++)
         PG_Emit("enforce",res.items[i].severity,PG_RULE_NONE,
                 res.items[i].action,res.items[i].ticket,
                 res.items[i].reason,
                 (res.items[i].succeeded ? res.items[i].detail
                                         : "FAILED. "+res.items[i].detail));

      if(res.lockout_engaged && !g_day.locked_out)
        {
         g_day.locked_out    = true;
         g_day.lockout_until = PG_NextDayStartServer(g_view.now,
                                                     g_clock.OffsetMin(),g_firm);
         PG_SaveDayState(g_view.account_login,g_day);
         PG_Emit("lockout",PG_SEV_BREACH,PG_RULE_NONE,PG_ACT_LOCKOUT,0,
                 "Trading is locked until the next daily reset.",
                 "until "+PG_FormatStamp(g_day.lockout_until));
        }
     }

   //--- log verdicts that are new or important enough to repeat
   static ENUM_PG_TIER last_tier = PG_TIER_NORMAL;
   static int          last_count= -1;
   if(force_log || g_state.tier!=last_tier || g_verdicts.count!=last_count)
     {
      for(int i=0;i<g_verdicts.count;i++)
         if(g_verdicts.items[i].severity>=PG_SEV_WARN)
           {
            PG_LogRecord r;
            PG_FillRecordFromViolation(g_verdicts.items[i],r);
            PG_Emit("verdict",g_verdicts.items[i].severity,
                    g_verdicts.items[i].rule,g_verdicts.items[i].action,
                    g_verdicts.items[i].ticket,g_verdicts.items[i].reason,"",
                    g_verdicts.items[i].current,
                    g_verdicts.items[i].limit_user,
                    g_verdicts.items[i].limit_firm);
           }
      last_tier  = g_state.tier;
      last_count = g_verdicts.count;
     }

   g_logger.EnsureDay(g_day.day_start_time);
   PG_SaveDayState(g_view.account_login,g_day);

   g_panel.Render(g_view,g_firm,g_eff,g_cfg,g_state,g_risk,g_verdicts,g_lock);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   PG_EnsureFolders();

   if(!PG_SelectProgram())
      return INIT_PARAMETERS_INCORRECT;

   g_clock.Refresh();
   if(!g_clock.IsKnown())
      Print("PropGuard: broker UTC offset unknown yet; it resolves once the "
            "terminal is connected. Boundaries may be off until then.");

   PG_LoadAccount(g_view);

   g_owner = PG_ClaimSingleton(g_view.account_login,ChartID());
   g_panel.SetReadOnly(!g_owner);
   if(!g_owner)
      Print("PropGuard: another instance already guards account ",
            g_view.account_login,". This chart is display-only.");

   //--- the day, then the lock
   PG_LoadDayState(g_view.account_login,g_day);
   if(InpInitialBalance>0.0)
      g_day.initial_balance = InpInitialBalance;
   PG_EstablishDay(true);

   PG_ConfigFromInputs(g_cfg);

   string problem="";
   const bool loaded = PG_LoadLockState(g_view.account_login,InpStateKey,
                                        g_lock,problem);

   if(!loaded)
     {
      //--- never fall back to defaults. Restore the strictest configuration
      //--- we still have a record of, and close a fresh lock window.
      const bool recoverable = g_lock.has_strictest;
      PG_FallbackToStrictest(g_lock,g_view.account_login,g_view.now,
                             g_firm,recoverable);
      g_lock.firm_id     = g_firm.firm_id;
      g_lock.program_id  = g_firm.program_id;
      g_lock.phase_label = g_firm.phase_label_en;
      g_cfg = g_lock.current;
      PG_SaveLockState(g_lock,InpStateKey);
     }
   else
     {
      if(PG_BindingChanged(g_lock,g_view.account_login,g_firm.firm_id,
                           g_firm.program_id,g_firm.phase_label_en))
        {
         PG_Rebind(g_lock,g_view.account_login,g_firm.firm_id,
                   g_firm.program_id,g_firm.phase_label_en,g_view.now);
         PG_ApplyConfig(g_lock,g_cfg,g_view.now,g_firm);
         PG_SaveLockState(g_lock,InpStateKey);
        }
      else
        {
         //--- inputs may tighten a locked configuration but never loosen it
         string why="";
         if(PG_CanApplyConfig(g_lock,g_cfg,g_view.now,why))
           {
            PG_ApplyConfig(g_lock,g_cfg,g_view.now,g_firm);
            PG_SaveLockState(g_lock,InpStateKey);
           }
         else
            g_cfg = g_lock.current;
        }
     }

   //--- is there a calendar to enforce the news rule with?
     {
      MqlCalendarValue probe[];
      g_have_calendar = (CalendarValueHistory(probe,
                                              (datetime)(g_view.now-86400),
                                              (datetime)(g_view.now+86400),
                                              NULL,NULL)>=0);
     }

   g_enforcer.SetMagic(InpMagic);
   g_enforcer.SetSlippage((int)InpSlippagePoints);

   g_logger.Open(g_view.account_login,g_day.day_start_time);
   g_panel.Configure(InpTheme,InpLanguage,InpPanelX,InpPanelY);

   PG_BuildEffective(g_firm,g_cfg,g_eff);
   PG_ComputeRisk(g_view,g_cfg,true,g_risk);
   PG_BuildState(g_view,g_eff,g_cfg,g_risk,g_clock.OffsetMin(),g_state);

   PG_Emit("startup",PG_SEV_INFO,PG_RULE_NONE,PG_ACT_NONE,0,
           "PropGuard "+PG_VERSION+" started on "+g_firm.firm_name_en+" / "
           +g_firm.program_name_en+" / "+g_firm.phase_label_en+".",
           (g_firm.IsVerified()
            ? "rules verified "+PG_FormatStamp(g_firm.verified_on)
            : "RULES NOT VERIFIED - confirm every number against the firm's "
              "own rules page before relying on this"));

   if(!loaded && problem!="no state file")
      PG_Emit("state",PG_SEV_CRITICAL,PG_RULE_NONE,PG_ACT_NONE,0,
              "Stored settings could not be trusted ("+problem
              +"). Restored the strictest configuration on record and "
              "closed a new lock window.","");

   if(!g_have_calendar)
      PG_Emit("calendar",PG_SEV_WARN,PG_RULE_NONE,PG_ACT_NONE,0,
              "This broker provides no economic calendar; the news blackout "
              "rule cannot be enforced.","");

   EventSetMillisecondTimer((uint)MathMax(100,InpTimerMs));
   PG_Cycle(true);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();

   if(g_owner)
     {
      PG_Emit("shutdown",PG_SEV_INFO,PG_RULE_NONE,PG_ACT_NONE,0,
              "PropGuard stopped. The account is no longer guarded.",
              "reason="+IntegerToString(reason));
      PG_SaveDayState(g_view.account_login,g_day);
      PG_SaveLockState(g_lock,InpStateKey);
      if(reason!=REASON_CHARTCHANGE && reason!=REASON_PARAMETERS)
         PG_ReleaseSingleton(g_view.account_login);
     }

   g_panel.Destroy();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   if(g_owner)
      PG_TouchSingleton(g_view.account_login,ChartID());
   PG_Cycle(false);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   //--- the timer does the work; ticks only matter when they arrive
   //--- faster than the timer and the account is already under pressure
   if(g_state.tier>=PG_TIER_BLOCK)
      PG_Cycle(false);
  }

//+------------------------------------------------------------------+
//| A position appearing is the one moment where milliseconds count. |
//|                                                                  |
//| MetaTrader has no hook that fires BEFORE a market order executes, |
//| so a manual trade or a third-party EA cannot be prevented - only  |
//| reversed. That is enough for the rule this product cares about:   |
//| the breach would happen when the stop is hit, not when the trade  |
//| opens, so closing it within a few hundred milliseconds leaves     |
//| nothing breached. It does cost the spread, and the log says so.   |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(!g_owner)
      return;
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD
      && trans.type!=TRADE_TRANSACTION_ORDER_ADD)
      return;

   PG_Cycle(false);
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &lparam,const double &dparam,
                  const string &sparam)
  {
   if(id!=CHARTEVENT_OBJECT_CLICK)
      return;

   PG_UserConfig proposed = g_cfg;
   const int action = g_panel.OnClick(sparam,proposed);

   if(action==0)
      return;

   if(action==3)
     {
      PG_RequestUnlock(g_lock,g_view.now);
      PG_SaveLockState(g_lock,InpStateKey);
      PG_Emit("lock",PG_SEV_NOTICE,PG_RULE_NONE,PG_ACT_NONE,0,
              "Unlock requested. It takes effect in 24 hours.",
              "effective "+PG_FormatStamp(PG_UnlockEffectiveAt(g_lock)));
     }

   if(action==2)
     {
      string why="";
      if(PG_CanApplyConfig(g_lock,proposed,g_view.now,why))
        {
         g_cfg = proposed;
         PG_ApplyConfig(g_lock,g_cfg,g_view.now,g_firm);
         PG_SaveLockState(g_lock,InpStateKey);
         PG_Emit("config",PG_SEV_NOTICE,PG_RULE_NONE,PG_ACT_NONE,0,
                 "Settings changed. Locked until "
                 +PG_FormatStamp(g_lock.locked_until)+".","");
        }
      else
         PG_Emit("config",PG_SEV_WARN,PG_RULE_NONE,PG_ACT_NONE,0,why,
                 "change refused");
     }

   PG_Cycle(false);
  }
//+------------------------------------------------------------------+
