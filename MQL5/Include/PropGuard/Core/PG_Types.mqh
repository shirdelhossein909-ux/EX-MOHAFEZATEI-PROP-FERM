//+------------------------------------------------------------------+
//|                                                     PG_Types.mqh |
//|                       PropGuard - shared enums and data records  |
//+------------------------------------------------------------------+
//
// This header is PURE DATA. It must never call a MetaTrader API function.
// Everything the engine reasons about is passed in through these records,
// which is what lets the same source files be compiled and executed by the
// test harness in tests/ under a normal C++ compiler.
//
// Fixed-size arrays are used on purpose: identical semantics in MQL5 and
// C++, no heap allocation on the tick path, and a hard ceiling that fails
// loudly instead of silently growing.
//
#ifndef PG_TYPES_MQH
#define PG_TYPES_MQH

#define PG_VERSION            "1.0.0"
#define PG_SCHEMA_VERSION     1

#define PG_MAX_POSITIONS      256
#define PG_MAX_PENDINGS       128
#define PG_MAX_VIOLATIONS      48
#define PG_MAX_FIRMS           16
#define PG_MAX_PROGRAMS        64
#define PG_MAX_NEWS           128
#define PG_MAX_DAYS           120

//--- how a firm derives the baseline that the daily loss is measured from
enum ENUM_PG_BASELINE
  {
   PG_BASE_BALANCE_AT_RESET = 0,   // balance at the daily reset moment
   PG_BASE_EQUITY_AT_RESET  = 1,   // equity at the daily reset moment
   PG_BASE_MAX_OF_BOTH      = 2,   // max(balance, equity) at reset - FTMO style
   PG_BASE_STATIC_INITIAL   = 3    // always the initial deposit
  };

//--- the four genuinely different max-drawdown algorithms
enum ENUM_PG_DD_MODE
  {
   PG_DD_STATIC_INITIAL       = 0, // floor fixed at initial balance - limit
   PG_DD_TRAILING_EQUITY      = 1, // floor trails the equity high-water mark forever
   PG_DD_TRAILING_LOCK        = 2, // trails, then locks once it reaches initial balance
   PG_DD_TRAILING_EOD_BALANCE = 3  // trails the highest end-of-day balance
  };

//--- what the engine wants done about a violation
enum ENUM_PG_ACTION
  {
   PG_ACT_NONE            = 0,
   PG_ACT_WARN            = 1, // surface it, touch nothing
   PG_ACT_BLOCK_NEW       = 2, // refuse new exposure, leave open trades alone
   PG_ACT_DELETE_PENDING  = 3, // remove the offending pending order
   PG_ACT_ATTACH_SL       = 4, // position has no stop - give it the widest legal one
   PG_ACT_REDUCE          = 5, // close worst offenders until compliant again
   PG_ACT_CLOSE_POSITION  = 6, // close one specific position
   PG_ACT_CLOSE_ALL       = 7, // flatten everything
   PG_ACT_LOCKOUT         = 8  // flatten and refuse trading until the next boundary
  };

enum ENUM_PG_SEVERITY
  {
   PG_SEV_INFO     = 0,
   PG_SEV_NOTICE   = 1,
   PG_SEV_WARN     = 2,
   PG_SEV_CRITICAL = 3,
   PG_SEV_BREACH   = 4
  };

//--- every rule the engine can evaluate. Adding one means adding a case in
//--- PG_RuleEngine plus a field in PG_RuleSet - nothing else changes.
enum ENUM_PG_RULE
  {
   PG_RULE_NONE               = 0,
   PG_RULE_DAILY_LOSS         = 1,
   PG_RULE_MAX_DRAWDOWN       = 2,
   PG_RULE_WORST_CASE         = 3, // aggregate loss if every stop is hit
   PG_RULE_MAX_RISK_PER_TRADE = 4,
   PG_RULE_MAX_LOT_PER_TRADE  = 5,
   PG_RULE_MAX_TOTAL_LOTS     = 6,
   PG_RULE_MAX_POSITIONS      = 7,
   PG_RULE_MAX_POS_PER_SYMBOL = 8,
   PG_RULE_STOP_LOSS_REQUIRED = 9,
   PG_RULE_MIN_HOLD_TIME      = 10,
   PG_RULE_NEWS_BLACKOUT      = 11,
   PG_RULE_WEEKEND_HOLDING    = 12,
   PG_RULE_CONSISTENCY        = 13,
   PG_RULE_MAX_CALENDAR_DAYS  = 14,
   PG_RULE_SYMBOL_NOT_ALLOWED = 15,
   PG_RULE_HEDGING            = 16
  };

//--- what the guard does once a threshold is actually reached
enum ENUM_PG_ENFORCE_MODE
  {
   PG_ENFORCE_MONITOR = 0, // log only, never touch an order
   PG_ENFORCE_REDUCE  = 1, // close worst offenders until compliant (default)
   PG_ENFORCE_CLOSE   = 2  // flatten everything at once
  };

enum ENUM_PG_TIER
  {
   PG_TIER_NORMAL = 0,
   PG_TIER_WARN   = 1, // past warn_at_pct of the effective limit
   PG_TIER_BLOCK  = 2, // past block_at_pct - no new exposure
   PG_TIER_ENFORCE= 3  // at or past the limit - act now
  };

//+------------------------------------------------------------------+
//| Symbol facts, snapshotted by the broker adapter                  |
//+------------------------------------------------------------------+
struct PG_SymbolSpec
  {
   string            name;
   double            point;              // e.g. 0.00001
   int               digits;
   double            contract_size;      // units per 1.00 lot
   double            tick_size;
   double            tick_value;         // profit per tick per lot, in ACCOUNT currency
   double            volume_min;
   double            volume_max;
   double            volume_step;
   double            bid;
   double            ask;
   double            commission_per_lot; // round turn, account currency
   double            swap_long_per_lot;  // per night, account currency
   double            swap_short_per_lot;
   bool              tradable;

                     PG_SymbolSpec()
     {
      name="";       point=0.00001;  digits=5;   contract_size=100000.0;
      tick_size=0.00001;             tick_value=1.0;
      volume_min=0.01;               volume_max=100.0;  volume_step=0.01;
      bid=0.0;       ask=0.0;        commission_per_lot=0.0;
      swap_long_per_lot=0.0;         swap_short_per_lot=0.0;
      tradable=true;
     }
  };

//+------------------------------------------------------------------+
//| One open position, as the engine sees it                         |
//+------------------------------------------------------------------+
struct PG_Position
  {
   long              ticket;
   string            symbol;
   int               dir;            // +1 long, -1 short
   double            volume;         // lots
   double            open_price;
   double            sl;             // 0.0 means no stop loss set
   double            tp;
   long              open_time;      // epoch seconds
   double            profit;         // current floating P/L, account currency
   double            swap_accrued;   // already-charged swap, account currency
   long              magic;
   int               spec_index;     // index into the PG_MarketView symbol table

                     PG_Position()
     {
      ticket=0; symbol=""; dir=0; volume=0.0; open_price=0.0; sl=0.0; tp=0.0;
      open_time=0; profit=0.0; swap_accrued=0.0; magic=0; spec_index=-1;
     }
  };

//+------------------------------------------------------------------+
//| One pending order                                                |
//+------------------------------------------------------------------+
struct PG_Pending
  {
   long              ticket;
   string            symbol;
   int               dir;            // +1 buy-side, -1 sell-side
   double            volume;
   double            price;          // trigger price
   double            sl;
   double            tp;
   long              setup_time;
   int               spec_index;

                     PG_Pending()
     {
      ticket=0; symbol=""; dir=0; volume=0.0; price=0.0; sl=0.0; tp=0.0;
      setup_time=0; spec_index=-1;
     }
  };

//+------------------------------------------------------------------+
//| A high-impact news window the account must stay out of           |
//+------------------------------------------------------------------+
struct PG_NewsWindow
  {
   long              event_time;     // epoch seconds
   string            currency;
   string            title;
   int               impact;         // 0 none .. 3 high

                     PG_NewsWindow() { event_time=0; currency=""; title=""; impact=0; }
  };

//+------------------------------------------------------------------+
//| Everything about the market and the account at one instant.      |
//| The engine is a pure function of this record plus the rule set.  |
//+------------------------------------------------------------------+
struct PG_MarketView
  {
   long              now;                    // epoch seconds, broker server time
   //--- account
   string            account_currency;
   long              account_login;
   double            balance;
   double            equity;
   double            margin_free;
   double            initial_balance;        // deposit that started the challenge
   //--- daily accounting
   double            day_start_balance;
   double            day_start_equity;
   long              day_start_time;         // epoch of the current daily reset
   //--- drawdown accounting
   double            hwm_equity;             // highest equity ever seen
   double            hwm_eod_balance;        // highest end-of-day balance
   //--- challenge progress
   int               trading_days_done;
   long              challenge_start_time;
   double            best_day_profit;        // largest single-day realised profit
   double            total_profit;           // realised profit since challenge start
   //--- open state
   PG_Position       positions[PG_MAX_POSITIONS];
   int               position_count;
   PG_Pending        pendings[PG_MAX_PENDINGS];
   int               pending_count;
   PG_SymbolSpec     specs[PG_MAX_POSITIONS];
   int               spec_count;
   PG_NewsWindow     news[PG_MAX_NEWS];
   int               news_count;

                     PG_MarketView()
     {
      now=0; account_currency="USD"; account_login=0;
      balance=0.0; equity=0.0; margin_free=0.0; initial_balance=0.0;
      day_start_balance=0.0; day_start_equity=0.0; day_start_time=0;
      hwm_equity=0.0; hwm_eod_balance=0.0;
      trading_days_done=0; challenge_start_time=0;
      best_day_profit=0.0; total_profit=0.0;
      position_count=0; pending_count=0; spec_count=0; news_count=0;
     }
  };

//+------------------------------------------------------------------+
//| A single violation the engine found                              |
//+------------------------------------------------------------------+
struct PG_Violation
  {
   ENUM_PG_RULE      rule;
   ENUM_PG_SEVERITY  severity;
   ENUM_PG_ACTION    action;
   long              ticket;         // 0 when the violation is account-wide
   double            current;        // the measured value
   double            limit_user;     // the trader's own (tighter) limit
   double            limit_firm;     // what the prop firm actually allows
   string            reason;         // plain-language, goes straight into the log

                     PG_Violation()
     {
      rule=PG_RULE_NONE; severity=PG_SEV_INFO; action=PG_ACT_NONE;
      ticket=0; current=0.0; limit_user=0.0; limit_firm=0.0; reason="";
     }
  };

struct PG_VerdictSet
  {
   PG_Violation      items[PG_MAX_VIOLATIONS];
   int               count;
   ENUM_PG_TIER      tier;
   bool              block_new_trades;
   bool              lockout;

                     PG_VerdictSet()
     { count=0; tier=PG_TIER_NORMAL; block_new_trades=false; lockout=false; }

   void              Reset()
     { count=0; tier=PG_TIER_NORMAL; block_new_trades=false; lockout=false; }

   bool              Add(const PG_Violation &v)
     {
      if(count>=PG_MAX_VIOLATIONS)
         return false;
      items[count]=v;
      count++;
      if(v.action==PG_ACT_BLOCK_NEW)
         block_new_trades=true;
      if(v.action==PG_ACT_LOCKOUT || v.action==PG_ACT_CLOSE_ALL)
        {
         lockout=true;
         block_new_trades=true;
        }
      return true;
     }

   //--- worst severity present, used to drive the panel status pill
   ENUM_PG_SEVERITY  Worst() const
     {
      ENUM_PG_SEVERITY w=PG_SEV_INFO;
      for(int i=0;i<count;i++)
         if(items[i].severity>w)
            w=items[i].severity;
      return w;
     }

   bool              Has(ENUM_PG_RULE r) const
     {
      for(int i=0;i<count;i++)
         if(items[i].rule==r)
            return true;
      return false;
     }
  };

#endif // PG_TYPES_MQH
//+------------------------------------------------------------------+
