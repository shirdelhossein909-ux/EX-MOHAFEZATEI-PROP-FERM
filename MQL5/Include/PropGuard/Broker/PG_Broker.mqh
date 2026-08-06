//+------------------------------------------------------------------+
//|                                                    PG_Broker.mqh |
//|      PropGuard - the only file that talks to MetaTrader          |
//+------------------------------------------------------------------+
//
// Everything platform-specific lives here: reading positions, symbols,
// history and the economic calendar, and sending order operations. The
// Core headers never call a MetaTrader function, which is what lets them
// be compiled and executed by the test harness.
//
// If you find yourself wanting to add a MetaTrader call to a Core header,
// add it here instead and pass the result in through PG_MarketView.
//
#ifndef PG_BROKER_MQH
#define PG_BROKER_MQH

#include <Trade/Trade.mqh>
#include <PropGuard/Core/PG_Types.mqh>
#include <PropGuard/Core/PG_RuleSet.mqh>
#include <PropGuard/Core/PG_Clock.mqh>

//+------------------------------------------------------------------+
//| Broker time offset from UTC, in minutes                          |
//|                                                                  |
//| TimeGMT() needs a live connection. When it is unavailable the     |
//| last known good offset is reused rather than silently assuming    |
//| zero, because a wrong offset moves the daily reset and that is    |
//| precisely the failure this product exists to prevent.             |
//+------------------------------------------------------------------+
class PG_Clock_Broker
  {
private:
   int               m_offset_min;
   bool              m_known;

public:
                     PG_Clock_Broker() { m_offset_min=0; m_known=false; }

   bool              IsKnown() const { return m_known; }
   int               OffsetMin() const { return m_offset_min; }

   bool              Refresh()
     {
      const datetime srv = TimeCurrent();
      const datetime gmt = TimeGMT();
      if(srv<=0 || gmt<=0)
         return m_known;                  // keep the last good value

      //--- brokers sit on whole or half hour offsets; rounding to the
      //--- nearest 15 minutes removes clock jitter without hiding a
      //--- genuine offset
      const long diff = (long)srv-(long)gmt;
      const long q    = (long)MathRound((double)diff/900.0)*900;
      m_offset_min = (int)(q/60);
      m_known      = true;
      return true;
     }
  };

//+------------------------------------------------------------------+
//| Fill a PG_SymbolSpec from the terminal                           |
//+------------------------------------------------------------------+
bool PG_LoadSymbolSpec(const string symbol,PG_SymbolSpec &s)
  {
   if(!SymbolSelect(symbol,true))
      return false;

   s.name          = symbol;
   s.point         = SymbolInfoDouble(symbol,SYMBOL_POINT);
   s.digits        = (int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   s.contract_size = SymbolInfoDouble(symbol,SYMBOL_TRADE_CONTRACT_SIZE);
   s.tick_size     = SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
   s.tick_value    = SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
   s.volume_min    = SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   s.volume_max    = SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   s.volume_step   = SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   s.bid           = SymbolInfoDouble(symbol,SYMBOL_BID);
   s.ask           = SymbolInfoDouble(symbol,SYMBOL_ASK);
   s.swap_long_per_lot  = SymbolInfoDouble(symbol,SYMBOL_SWAP_LONG);
   s.swap_short_per_lot = SymbolInfoDouble(symbol,SYMBOL_SWAP_SHORT);

   const ENUM_SYMBOL_TRADE_MODE mode =
      (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(symbol,SYMBOL_TRADE_MODE);
   s.tradable = (mode==SYMBOL_TRADE_MODE_FULL || mode==SYMBOL_TRADE_MODE_LONGONLY
                 || mode==SYMBOL_TRADE_MODE_SHORTONLY);

   //--- guard against a broker reporting nonsense; a zero tick size would
   //--- silently turn every risk calculation into zero risk
   if(s.tick_size<=0.0)
      s.tick_size = (s.point>0.0 ? s.point : 0.00001);
   if(s.volume_step<=0.0)
      s.volume_step = 0.01;
   if(s.point<=0.0)
      s.point = s.tick_size;

   return true;
  }

//+------------------------------------------------------------------+
//| Index of a symbol in the view's spec table, adding it if needed   |
//+------------------------------------------------------------------+
int PG_EnsureSpec(PG_MarketView &mv,const string symbol,
                  const double commission_per_lot)
  {
   for(int i=0;i<mv.spec_count;i++)
      if(mv.specs[i].name==symbol)
         return i;

   if(mv.spec_count>=PG_MAX_POSITIONS)
      return -1;

   PG_SymbolSpec s;
   if(!PG_LoadSymbolSpec(symbol,s))
      return -1;
   s.commission_per_lot = commission_per_lot;

   mv.specs[mv.spec_count] = s;
   mv.spec_count++;
   return mv.spec_count-1;
  }

//+------------------------------------------------------------------+
//| Read every open position, including manual ones and other EAs'.  |
//| Filtering by magic number here would be a hole: a position the   |
//| guard cannot see is a position that can still fail the account.  |
//+------------------------------------------------------------------+
void PG_LoadPositions(PG_MarketView &mv,const double commission_per_lot)
  {
   mv.position_count=0;

   const int total = PositionsTotal();
   for(int i=0;i<total && mv.position_count<PG_MAX_POSITIONS;i++)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;

      PG_Position p;
      p.ticket     = (long)ticket;
      p.symbol     = PositionGetString(POSITION_SYMBOL);
      p.dir        = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1);
      p.volume     = PositionGetDouble(POSITION_VOLUME);
      p.open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      p.sl         = PositionGetDouble(POSITION_SL);
      p.tp         = PositionGetDouble(POSITION_TP);
      p.open_time  = (long)PositionGetInteger(POSITION_TIME);
      p.profit     = PositionGetDouble(POSITION_PROFIT);
      p.swap_accrued = PositionGetDouble(POSITION_SWAP);
      p.magic      = (long)PositionGetInteger(POSITION_MAGIC);
      p.spec_index = PG_EnsureSpec(mv,p.symbol,commission_per_lot);

      if(p.spec_index<0)
         continue;                        // unusable symbol, skip rather than guess

      mv.positions[mv.position_count]=p;
      mv.position_count++;
     }
  }

//+------------------------------------------------------------------+
//| Read resting pending orders                                      |
//+------------------------------------------------------------------+
void PG_LoadPendings(PG_MarketView &mv,const double commission_per_lot)
  {
   mv.pending_count=0;

   const int total = OrdersTotal();
   for(int i=0;i<total && mv.pending_count<PG_MAX_PENDINGS;i++)
     {
      const ulong ticket = OrderGetTicket(i);
      if(ticket==0 || !OrderSelect(ticket))
         continue;

      const ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      int dir=0;
      if(type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_BUY_STOP
         || type==ORDER_TYPE_BUY_STOP_LIMIT)
         dir=1;
      else
         if(type==ORDER_TYPE_SELL_LIMIT || type==ORDER_TYPE_SELL_STOP
            || type==ORDER_TYPE_SELL_STOP_LIMIT)
            dir=-1;
      if(dir==0)
         continue;                        // a market order in flight, not resting

      PG_Pending o;
      o.ticket     = (long)ticket;
      o.symbol     = OrderGetString(ORDER_SYMBOL);
      o.dir        = dir;
      o.volume     = OrderGetDouble(ORDER_VOLUME_CURRENT);
      o.price      = OrderGetDouble(ORDER_PRICE_OPEN);
      o.sl         = OrderGetDouble(ORDER_SL);
      o.tp         = OrderGetDouble(ORDER_TP);
      o.setup_time = (long)OrderGetInteger(ORDER_TIME_SETUP);
      o.spec_index = PG_EnsureSpec(mv,o.symbol,commission_per_lot);
      if(o.spec_index<0)
         continue;

      mv.pendings[mv.pending_count]=o;
      mv.pending_count++;
     }
  }

//+------------------------------------------------------------------+
//| High-impact calendar events near now, from MetaTrader's own      |
//| economic calendar. No web request, no external feed.             |
//+------------------------------------------------------------------+
void PG_LoadNews(PG_MarketView &mv,const long window_seconds)
  {
   mv.news_count=0;

   const datetime from = (datetime)(mv.now-window_seconds);
   const datetime to   = (datetime)(mv.now+window_seconds);

   MqlCalendarValue values[];
   const int n = CalendarValueHistory(values,from,to,NULL,NULL);
   if(n<=0)
      return;                             // broker ships no calendar; caller warns

   for(int i=0;i<n && mv.news_count<PG_MAX_NEWS;i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id,ev))
         continue;
      if(ev.importance!=CALENDAR_IMPORTANCE_HIGH)
         continue;

      MqlCalendarCountry country;
      string ccy="";
      if(CalendarCountryById(ev.country_id,country))
         ccy = country.currency;

      PG_NewsWindow w;
      w.event_time = (long)values[i].time;
      w.currency   = ccy;
      w.title      = ev.name;
      w.impact     = 3;
      mv.news[mv.news_count]=w;
      mv.news_count++;
     }
  }

//+------------------------------------------------------------------+
//| Account fields                                                   |
//+------------------------------------------------------------------+
void PG_LoadAccount(PG_MarketView &mv)
  {
   mv.now              = (long)TimeCurrent();
   mv.account_login    = (long)AccountInfoInteger(ACCOUNT_LOGIN);
   mv.account_currency = AccountInfoString(ACCOUNT_CURRENCY);
   mv.balance          = AccountInfoDouble(ACCOUNT_BALANCE);
   mv.equity           = AccountInfoDouble(ACCOUNT_EQUITY);
   mv.margin_free      = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
  }

//+------------------------------------------------------------------+
//| Rebuild the day's accounting from deal history.                  |
//|                                                                  |
//| Called on every start and after any restart. The current balance |
//| is NOT a safe stand-in for the day's opening balance: a terminal |
//| that restarts at noon after three losing trades would otherwise  |
//| hand the trader a fresh daily allowance on top of the losses     |
//| already taken. Working backwards from the deal history is the    |
//| only version of this that survives a VPS reboot.                 |
//+------------------------------------------------------------------+
struct PG_DayRebuild
  {
   double            day_start_balance;
   double            realised_today;
   int               deals_today;
   int               trading_days;
   double            best_day_profit;
   double            total_profit;
   long              first_deal_time;
   bool              ok;

                     PG_DayRebuild()
     {
      day_start_balance=0.0; realised_today=0.0; deals_today=0;
      trading_days=0; best_day_profit=0.0; total_profit=0.0;
      first_deal_time=0; ok=false;
     }
  };

bool PG_RebuildFromHistory(const long day_start,const long challenge_start,
                           const double current_balance,
                           const int server_utc_offset_min,
                           const PG_RuleSet &rules,PG_DayRebuild &out)
  {
   out = PG_DayRebuild();

   const datetime from = (datetime)(challenge_start>0
                                    ? challenge_start
                                    : day_start-PG_SECONDS_PER_DAY*(long)PG_MAX_DAYS);
   if(!HistorySelect(from,(datetime)(TimeCurrent()+3600)))
      return false;

   //--- per-day realised P/L, bucketed by the firm's own daily boundary
   double day_pl[PG_MAX_DAYS];
   long   day_key[PG_MAX_DAYS];
   int    day_n = 0;
   for(int i=0;i<PG_MAX_DAYS;i++)
     {
      day_pl[i]=0.0;
      day_key[i]=0;
     }

   const int total = HistoryDealsTotal();
   for(int i=0;i<total;i++)
     {
      const ulong ticket = HistoryDealGetTicket(i);
      if(ticket==0)
         continue;

      const ENUM_DEAL_ENTRY entry =
         (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket,DEAL_ENTRY);
      const ENUM_DEAL_TYPE dtype =
         (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket,DEAL_TYPE);
      if(dtype!=DEAL_TYPE_BUY && dtype!=DEAL_TYPE_SELL)
         continue;                        // deposits and credits are not trading
      if(entry==DEAL_ENTRY_IN)
         continue;                        // opening deals realise nothing

      const long   t  = (long)HistoryDealGetInteger(ticket,DEAL_TIME);
      const double pl = HistoryDealGetDouble(ticket,DEAL_PROFIT)
                        +HistoryDealGetDouble(ticket,DEAL_SWAP)
                        +HistoryDealGetDouble(ticket,DEAL_COMMISSION);

      if(out.first_deal_time==0 || t<out.first_deal_time)
         out.first_deal_time = t;

      out.total_profit += pl;

      //--- which trading day does this deal belong to?
      const long key = PG_DayStartServer(t,server_utc_offset_min,rules);

      int slot=-1;
      for(int k=0;k<day_n;k++)
         if(day_key[k]==key)
           { slot=k; break; }
      if(slot<0 && day_n<PG_MAX_DAYS)
        {
         slot = day_n;
         day_key[slot] = key;
         day_n++;
        }
      if(slot>=0)
         day_pl[slot] += pl;

      if(t>=day_start)
        {
         out.realised_today += pl;
         out.deals_today++;
        }
     }

   out.trading_days = day_n;
   for(int k=0;k<day_n;k++)
      if(day_pl[k]>out.best_day_profit)
         out.best_day_profit = day_pl[k];

   //--- the day opened at whatever the balance is now, minus everything
   //--- realised since the boundary
   out.day_start_balance = current_balance-out.realised_today;
   out.ok = true;
   return true;
  }

//+------------------------------------------------------------------+
//| Order operations                                                 |
//+------------------------------------------------------------------+
class PG_Trader
  {
private:
   CTrade            m_trade;
   int               m_slippage;

public:
                     PG_Trader()
     {
      m_slippage=30;
      m_trade.SetDeviationInPoints(m_slippage);
      m_trade.SetAsyncMode(false);
      m_trade.LogLevel(LOG_LEVEL_ERRORS);
     }

   void              SetMagic(const long magic) { m_trade.SetExpertMagicNumber((ulong)magic); }
   void              SetSlippage(const int pts)
     {
      m_slippage=pts;
      m_trade.SetDeviationInPoints(pts);
     }

   string            LastError()
     {
      return "retcode="+IntegerToString((int)m_trade.ResultRetcode())
             +" "+m_trade.ResultRetcodeDescription();
     }

   bool              ClosePosition(const long ticket)
     {
      return m_trade.PositionClose((ulong)ticket,m_slippage);
     }

   bool              DeletePending(const long ticket)
     {
      return m_trade.OrderDelete((ulong)ticket);
     }

   bool              SetStopLoss(const long ticket,const double sl,const double tp)
     {
      return m_trade.PositionModify((ulong)ticket,sl,tp);
     }
  };

//+------------------------------------------------------------------+
//| Is the symbol's session open right now? Used before reporting a  |
//| close failure as an emergency rather than as "market is shut".   |
//+------------------------------------------------------------------+
bool PG_MarketIsOpen(const string symbol)
  {
   datetime from,to;
   MqlDateTime st;
   TimeToStruct(TimeCurrent(),st);
   const ENUM_DAY_OF_WEEK dow = (ENUM_DAY_OF_WEEK)st.day_of_week;

   const long secs = (long)st.hour*3600+(long)st.min*60+(long)st.sec;
   for(uint session=0; session<8; session++)
     {
      if(!SymbolInfoSessionTrade(symbol,dow,session,from,to))
         break;
      if(secs>=(long)from && secs<=(long)to)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Only one PropGuard per account. Two instances would each see the |
//| other's closes as somebody else trading and fight over them.     |
//+------------------------------------------------------------------+
bool PG_ClaimSingleton(const long account,const long chart_id)
  {
   const string key = "PropGuard.owner."+IntegerToString(account);
   if(GlobalVariableCheck(key))
     {
      const double owner = GlobalVariableGet(key);
      if((long)owner!=chart_id)
        {
         //--- a stale claim from a crashed instance expires after 5 minutes
         const datetime touched = GlobalVariableTime(key);
         if(TimeCurrent()-touched<300)
            return false;
        }
     }
   GlobalVariableSet(key,(double)chart_id);
   return true;
  }

void PG_TouchSingleton(const long account,const long chart_id)
  {
   GlobalVariableSet("PropGuard.owner."+IntegerToString(account),(double)chart_id);
  }

void PG_ReleaseSingleton(const long account)
  {
   GlobalVariableDel("PropGuard.owner."+IntegerToString(account));
  }

#endif // PG_BROKER_MQH
//+------------------------------------------------------------------+
