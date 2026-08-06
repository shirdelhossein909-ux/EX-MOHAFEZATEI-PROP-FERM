//+------------------------------------------------------------------+
//|                                                     PG_Panel.mqh |
//|      PropGuard - the on-chart panel                              |
//+------------------------------------------------------------------+
//
// Design intent, in one sentence: a trader should be able to answer "am I
// safe right now?" without reading a single number.
//
// Hence the bars. Each one carries TWO markers - the trader's own limit
// and the prop firm's - because being stopped at your own 3.5% while the
// firm allows 5% is not a failure, and a panel that hides that turns a
// protective action into a support ticket.
//
// The third bar, worst case, is the one competitors do not have. It shows
// where equity lands if every open stop is hit at once, which is the only
// number that tells you whether the trade you are about to take is safe.
//
// Below the bars sits a lot calculator. That is what turns this from
// insurance the trader forgets about into a tool they open every session.
//
#ifndef PG_PANEL_MQH
#define PG_PANEL_MQH

#include <PropGuard/Core/PG_Types.mqh>
#include <PropGuard/Core/PG_RuleSet.mqh>
#include <PropGuard/Core/PG_RiskCalc.mqh>
#include <PropGuard/Core/PG_RuleEngine.mqh>
#include <PropGuard/Core/PG_Lock.mqh>
#include <PropGuard/Core/PG_Log.mqh>
#include <PropGuard/UI/PG_Theme.mqh>
#include <PropGuard/UI/PG_Lang.mqh>

#define PG_UI            "PGx_"
#define PG_PANEL_W        360
#define PG_PANEL_H        470
#define PG_ROW            18
#define PG_PAD            10
#define PG_LOG_ROWS       14
#define PG_POS_ROWS       10

enum ENUM_PG_TAB
  {
   PG_TAB_DASHBOARD = 0,
   PG_TAB_RULES     = 1,
   PG_TAB_SETTINGS  = 2,
   PG_TAB_POSITIONS = 3,
   PG_TAB_LOG       = 4
  };

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
class PG_Panel
  {
private:
   PG_Theme          m_th;
   ENUM_PG_LANG      m_lang;
   ENUM_PG_TAB       m_tab;
   int               m_x, m_y;
   bool              m_collapsed;
   bool              m_rtl;
   bool              m_read_only;

   //--- ring buffer of recent log lines for the log tab
   string            m_log[PG_LOG_ROWS];
   color             m_log_col[PG_LOG_ROWS];
   int               m_log_n;

   //--- lot calculator input, in points
   int               m_calc_stop_points;

   //=================== object helpers =============================
   void              Del(const string n) { ObjectDelete(0,n); }

   void              Rect(const string n,const int x,const int y,
                          const int w,const int h,const color bg,
                          const color brd)
     {
      if(ObjectFind(0,n)<0)
         ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
      ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
      ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
      ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,n,OBJPROP_COLOR,brd);
      ObjectSetInteger(0,n,OBJPROP_BACK,false);
      ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
     }

   void              Text(const string n,const int x,const int y,const string s,
                          const color c,const int size,const bool right_align)
     {
      if(ObjectFind(0,n)<0)
         ObjectCreate(0,n,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,n,OBJPROP_ANCHOR,
                       right_align ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
      ObjectSetString(0,n,OBJPROP_TEXT,s);
      ObjectSetString(0,n,OBJPROP_FONT,m_th.font);
      ObjectSetInteger(0,n,OBJPROP_FONTSIZE,size);
      ObjectSetInteger(0,n,OBJPROP_COLOR,c);
      ObjectSetInteger(0,n,OBJPROP_BACK,false);
      ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
     }

   void              Button(const string n,const int x,const int y,const int w,
                            const int h,const string s,const color bg,
                            const color fg,const bool pressed)
     {
      if(ObjectFind(0,n)<0)
         ObjectCreate(0,n,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
      ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
      ObjectSetString(0,n,OBJPROP_TEXT,s);
      ObjectSetString(0,n,OBJPROP_FONT,m_th.font);
      ObjectSetInteger(0,n,OBJPROP_FONTSIZE,m_th.font_size);
      ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
      ObjectSetInteger(0,n,OBJPROP_COLOR,fg);
      ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR,m_th.border);
      ObjectSetInteger(0,n,OBJPROP_STATE,pressed);
      ObjectSetInteger(0,n,OBJPROP_BACK,false);
      ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
     }

   //--- text that lands on the correct edge for the active language
   int               EdgeX(const int inset) const
     {
      return (m_rtl ? m_x+PG_PANEL_W-inset : m_x+inset);
     }

   void              Line(const string n,const int inset,const int y,
                          const string s,const color c,const int size)
     {
      Text(n,EdgeX(inset),y,s,c,size,m_rtl);
     }

   //--- the opposite edge, for a value paired with a label
   void              LineOpp(const string n,const int inset,const int y,
                             const string s,const color c,const int size)
     {
      const int x = (m_rtl ? m_x+inset : m_x+PG_PANEL_W-inset);
      Text(n,x,y,s,c,size,!m_rtl);
     }

   //+---------------------------------------------------------------+
   //| A usage bar with two limit markers.                           |
   //|                                                                |
   //| fill_pct is usage of the TRADER's allowance. The firm marker   |
   //| sits further along the same track, which is what makes the     |
   //| safety buffer visible instead of theoretical.                  |
   //+---------------------------------------------------------------+
   void              Bar(const string n,const int x,const int y,const int w,
                         const int h,const double fill_pct,const color fill,
                         const double user_marker_pct,const double firm_marker_pct)
     {
      Rect(n+"_t",x,y,w,h,m_th.track,m_th.border);

      double f = fill_pct;
      if(f<0.0)   f=0.0;
      if(f>100.0) f=100.0;
      const int fw = (int)MathRound((double)w*f/100.0);
      if(fw>0)
         Rect(n+"_f",x,y,fw,h,fill,fill);
      else
         Del(n+"_f");

      //--- markers
      if(user_marker_pct>0.0 && user_marker_pct<=100.0)
        {
         const int mx = x+(int)MathRound((double)w*user_marker_pct/100.0);
         Rect(n+"_mu",mx-1,y-2,2,h+4,m_th.marker_user,m_th.marker_user);
        }
      else
         Del(n+"_mu");

      if(firm_marker_pct>0.0 && firm_marker_pct<=100.0)
        {
         const int mx = x+(int)MathRound((double)w*firm_marker_pct/100.0);
         Rect(n+"_mf",mx-1,y-2,2,h+4,m_th.marker_firm,m_th.marker_firm);
        }
      else
         Del(n+"_mf");
     }

   void              DelBar(const string n)
     {
      Del(n+"_t"); Del(n+"_f"); Del(n+"_mu"); Del(n+"_mf");
     }

   //=================== tab bodies =================================
   void              ClearBody()
     {
      for(int i=ObjectsTotal(0,-1,-1)-1;i>=0;i--)
        {
         const string nm = ObjectName(0,i,-1,-1);
         if(StringFind(nm,PG_UI+"b_")==0)
            ObjectDelete(0,nm);
        }
     }

   //---------------------------------------------------------------
   void              DrawDashboard(const PG_MarketView &mv,const PG_RuleSet &eff,
                                   const PG_RuleSet &firm,const PG_UserConfig &cfg,
                                   const PG_EngineState &st,const PG_RiskResult &risk,
                                   const PG_VerdictSet &vs)
     {
      const string P = PG_UI+"b_";
      int y = m_y+96;

      //--- account line
      Line(P+"bal",PG_PAD,y,PG_T(m_lang,"balance")+"  "
           +DoubleToString(mv.balance,2),m_th.text_muted,m_th.font_size);
      LineOpp(P+"eq",PG_PAD,y,PG_T(m_lang,"equity")+"  "
              +DoubleToString(mv.equity,2),m_th.text_muted,m_th.font_size);
      y += PG_ROW+4;

      const int bar_x = m_x+PG_PAD;
      const int bar_w = PG_PANEL_W-2*PG_PAD;

      //--- 1. daily loss --------------------------------------------
      const color dcol = PG_UsageColor(m_th,st.daily_used_pct,
                                       cfg.warn_at_pct,cfg.block_at_pct);
      Line(P+"d1",PG_PAD,y,PG_StatusIcon(st.daily_used_pct,cfg.warn_at_pct,
                                         cfg.block_at_pct)+" "
           +PG_T(m_lang,"daily_loss"),m_th.text,m_th.font_size);
      LineOpp(P+"d2",PG_PAD,y,DoubleToString(st.daily_used_money,0)+" / "
              +DoubleToString(st.daily_limit_money,0),dcol,m_th.font_size);
      y += PG_ROW;

      //--- the firm's allowance drawn on the trader's scale
      double firm_daily_marker = 100.0;
      const double firm_daily_money = PG_DailyBaseline(mv,firm)
                                      *(firm.daily_limit_pct/100.0);
      if(firm_daily_money>0.0 && st.daily_limit_money>0.0)
         firm_daily_marker = MathMin(100.0,
                                     (st.daily_limit_money/firm_daily_money)*100.0);

      Bar(P+"dbar",bar_x,y,bar_w,10,
          (firm_daily_money>0.0 ? (st.daily_used_money/firm_daily_money)*100.0 : 0.0),
          dcol,firm_daily_marker,100.0);
      y += 16;
      Line(P+"d3",PG_PAD,y,PG_T(m_lang,"your_limit")+" "
           +PG_FmtPct(m_lang,eff.daily_limit_pct)+"   "
           +PG_T(m_lang,"firm_limit")+" "+PG_FmtPct(m_lang,firm.daily_limit_pct),
           m_th.text_muted,m_th.font_size_small);
      LineOpp(P+"d4",PG_PAD,y,DoubleToString(st.daily_left_money,0)+" "
              +PG_T(m_lang,"remaining"),m_th.text_muted,m_th.font_size_small);
      y += PG_ROW+6;

      //--- 2. overall drawdown --------------------------------------
      const color mcol = PG_UsageColor(m_th,st.dd_used_pct,
                                       cfg.warn_at_pct,cfg.block_at_pct);
      Line(P+"m1",PG_PAD,y,PG_StatusIcon(st.dd_used_pct,cfg.warn_at_pct,
                                         cfg.block_at_pct)+" "
           +PG_T(m_lang,"max_dd"),m_th.text,m_th.font_size);
      LineOpp(P+"m2",PG_PAD,y,DoubleToString(st.dd_used_money,0)+" / "
              +DoubleToString(st.dd_amount,0),mcol,m_th.font_size);
      y += PG_ROW;

      const double firm_dd_money = PG_MaxDdAmount(mv,firm);
      double firm_dd_marker = 100.0;
      if(firm_dd_money>0.0 && st.dd_amount>0.0)
         firm_dd_marker = MathMin(100.0,(st.dd_amount/firm_dd_money)*100.0);

      Bar(P+"mbar",bar_x,y,bar_w,10,
          (firm_dd_money>0.0 ? (st.dd_used_money/firm_dd_money)*100.0 : 0.0),
          mcol,firm_dd_marker,100.0);
      y += 16;
      Line(P+"m3",PG_PAD,y,PG_T(m_lang,"your_limit")+" "
           +PG_FmtPct(m_lang,eff.maxdd_limit_pct)+"   "
           +PG_T(m_lang,"firm_limit")+" "+PG_FmtPct(m_lang,firm.maxdd_limit_pct),
           m_th.text_muted,m_th.font_size_small);
      y += PG_ROW+6;

      //--- 3. worst case, the one that matters ----------------------
      const color wcol = PG_UsageColor(m_th,st.worst_used_pct,
                                       cfg.warn_at_pct,cfg.block_at_pct);
      Line(P+"w1",PG_PAD,y,PG_StatusIcon(st.worst_used_pct,cfg.warn_at_pct,
                                         cfg.block_at_pct)+" "
           +PG_T(m_lang,"worst_case"),m_th.text,m_th.font_size);
      LineOpp(P+"w2",PG_PAD,y,
              (risk.unbounded ? PG_T(m_lang,"unbounded")
                              : DoubleToString(st.worst_loss,0)),
              (risk.unbounded ? m_th.danger : wcol),m_th.font_size);
      y += PG_ROW;
      Bar(P+"wbar",bar_x,y,bar_w,10,st.worst_used_pct,wcol,100.0,0.0);
      y += 16;
      Line(P+"w3",PG_PAD,y,PG_T(m_lang,"worst_case_sub"),
           m_th.text_muted,m_th.font_size_small);
      y += PG_ROW+8;

      //--- 4. clock and progress ------------------------------------
      Line(P+"c1",PG_PAD,y,PG_T(m_lang,"reset_in")+"  "
           +PG_FormatDuration(st.seconds_to_reset),m_th.text,m_th.font_size);
      y += PG_ROW;
      if(eff.min_trading_days>0)
        {
         Line(P+"c2",PG_PAD,y,PG_T(m_lang,"trading_day")+" "
              +IntegerToString(mv.trading_days_done)+" "+PG_T(m_lang,"of_min")+" "
              +IntegerToString(eff.min_trading_days),
              m_th.text_muted,m_th.font_size);
         y += PG_ROW;
        }
      y += 6;

      //--- 5. the lot calculator ------------------------------------
      Rect(P+"calc",m_x+PG_PAD,y,PG_PANEL_W-2*PG_PAD,54,
           m_th.surface_alt,m_th.border);
      Line(P+"h1",PG_PAD+6,y+5,PG_T(m_lang,"headroom"),
           m_th.text,m_th.font_size);
      LineOpp(P+"h2",PG_PAD+6,y+5,DoubleToString(st.headroom_money,0)+" "
              +mv.account_currency,m_th.accent,m_th.font_size_big);

      string lot_text = "-";
      const int si = (mv.spec_count>0 ? 0 : -1);
      if(si>=0)
        {
         const PG_SymbolSpec spec = mv.specs[si];
         const double entry = (spec.ask>0.0 ? spec.ask : spec.bid);
         const double sl    = entry-(double)m_calc_stop_points*spec.point;
         const double lots  = PG_MaxLotForRisk(spec,entry,sl,st.headroom_money,
                                               cfg.gap_buffer_pct,
                                               cfg.slippage_points);
         lot_text = PG_T(m_lang,"max_lot")+" "+DoubleToString(lots,2)
                    +"  "+spec.name;
        }
      Line(P+"h3",PG_PAD+6,y+28,lot_text,m_th.text,m_th.font_size);
      LineOpp(P+"h4",PG_PAD+6,y+30,PG_T(m_lang,"with_sl")+" "
              +IntegerToString(m_calc_stop_points)+" "+PG_T(m_lang,"points"),
              m_th.text_muted,m_th.font_size_small);

      Button(PG_UI+"b_calcminus",m_x+PG_PANEL_W-70,y+26,26,18,"-",
             m_th.surface,m_th.text,false);
      Button(PG_UI+"b_calcplus",m_x+PG_PANEL_W-40,y+26,26,18,"+",
             m_th.surface,m_th.text,false);
     }

   //---------------------------------------------------------------
   void              DrawRules(const PG_RuleSet &firm,const PG_RuleSet &eff)
     {
      const string P = PG_UI+"b_";
      int y = m_y+96;

      if(!firm.IsVerified())
        {
         Rect(P+"unv",m_x+PG_PAD,y,PG_PANEL_W-2*PG_PAD,34,
              m_th.danger,m_th.danger);
         Line(P+"unv1",PG_PAD+6,y+4,PG_T(m_lang,"rules_unverified"),
              clrWhite,m_th.font_size_small);
         y += 42;
        }
      else
        {
         Line(P+"ver",PG_PAD,y,PG_T(m_lang,"rules_verified")+" "
              +PG_FormatStamp(firm.verified_on),m_th.safe,m_th.font_size_small);
         y += PG_ROW+4;
        }

      Line(P+"fn",PG_PAD,y,(m_lang==PG_LANG_FA ? firm.firm_name_fa
                                               : firm.firm_name_en),
           m_th.text,m_th.font_size_big);
      y += PG_ROW+4;
      Line(P+"pn",PG_PAD,y,(m_lang==PG_LANG_FA ? firm.program_name_fa
                                               : firm.program_name_en)
           +"  -  "+(m_lang==PG_LANG_FA ? firm.phase_label_fa
                                        : firm.phase_label_en),
           m_th.text_muted,m_th.font_size);
      y += PG_ROW+8;

      //--- the rulebook, as the firm publishes it
      const bool fa = (m_lang==PG_LANG_FA);
      string rows[14];
      int n=0;

      rows[n++] = (fa ? "ضرر روزانه" : "Daily loss")+":  "
                  +PG_FmtPct(m_lang,firm.daily_limit_pct)+"   "
                  +(firm.daily_baseline==PG_BASE_BALANCE_AT_RESET
                    ? (fa ? "از بالانس ابتدای روز" : "of day-start balance")
                    : firm.daily_baseline==PG_BASE_EQUITY_AT_RESET
                    ? (fa ? "از اکوییتی ابتدای روز" : "of day-start equity")
                    : firm.daily_baseline==PG_BASE_MAX_OF_BOTH
                    ? (fa ? "از بیشترین آن دو" : "of the higher of the two")
                    : (fa ? "از بالانس اولیه" : "of initial balance"));

      rows[n++] = (fa ? "دراوداون کلی" : "Overall drawdown")+":  "
                  +PG_FmtPct(m_lang,firm.maxdd_limit_pct)+"   "
                  +(firm.maxdd_mode==PG_DD_STATIC_INITIAL
                    ? (fa ? "ثابت" : "static")
                    : firm.maxdd_mode==PG_DD_TRAILING_EQUITY
                    ? (fa ? "تریلینگ" : "trailing")
                    : firm.maxdd_mode==PG_DD_TRAILING_LOCK
                    ? (fa ? "تریلینگ با قفل" : "trailing, then locks")
                    : (fa ? "تریلینگ بالانس پایان روز" : "trailing EOD balance"));

      if(firm.profit_target_pct>0.0)
         rows[n++] = (fa ? "هدف سود" : "Profit target")+":  "
                     +PG_FmtPct(m_lang,firm.profit_target_pct);
      if(firm.min_trading_days>0)
         rows[n++] = (fa ? "حداقل روز معاملاتی" : "Minimum trading days")+":  "
                     +IntegerToString(firm.min_trading_days);
      if(firm.max_calendar_days>0)
         rows[n++] = (fa ? "مهلت چالش" : "Challenge window")+":  "
                     +IntegerToString(firm.max_calendar_days)
                     +(fa ? " روز" : " days");
      if(firm.consistency_enabled)
         rows[n++] = (fa ? "قانون ثبات" : "Consistency")+":  "
                     +(fa ? "حداکثر " : "max ")
                     +PG_FmtPct(m_lang,firm.consistency_max_day_share_pct)
                     +(fa ? " از کل سود در یک روز" : " of total profit in one day");
      if(firm.max_lot_per_trade_per_100k>0.0)
         rows[n++] = (fa ? "حداکثر لات هر معامله" : "Max lot per trade")+":  "
                     +DoubleToString(firm.max_lot_per_trade_per_100k,2)
                     +(fa ? " به ازای هر ۱۰۰ هزار" : " per 100k");
      if(firm.max_open_positions>0)
         rows[n++] = (fa ? "حداکثر پوزیشن باز" : "Max open positions")+":  "
                     +IntegerToString(firm.max_open_positions);
      if(firm.require_sl)
         rows[n++] = (fa ? "استاپ‌لاس اجباری است" : "Stop loss is mandatory");
      if(firm.min_hold_seconds>0)
         rows[n++] = (fa ? "حداقل زمان نگهداری" : "Minimum hold")+":  "
                     +IntegerToString(firm.min_hold_seconds)
                     +(fa ? " ثانیه" : " seconds");
      if(firm.news_blackout_enabled)
         rows[n++] = (fa ? "ممنوعیت معامله حول اخبار مهم"
                         : "No trading around high-impact news")+":  "
                     +IntegerToString(firm.news_before_min)+"/"
                     +IntegerToString(firm.news_after_min)
                     +(fa ? " دقیقه" : " min");
      if(firm.forbid_weekend_holding)
         rows[n++] = (fa ? "نگهداری پوزیشن در آخر هفته ممنوع"
                         : "No weekend holding");
      if(firm.forbid_hedging)
         rows[n++] = (fa ? "هجینگ ممنوع" : "Hedging is not allowed");
      if(firm.forbid_ea)
         rows[n++] = (fa ? "ربات بدون تأیید ممنوع" : "EAs require approval");
      rows[n++] = (fa ? "سهم سود تریدر" : "Profit split")+":  "
                  +PG_FmtPct(m_lang,firm.profit_split_pct);

      for(int i=0;i<n && i<14;i++)
        {
         Line(P+"r"+IntegerToString(i),PG_PAD,y,rows[i],
              m_th.text,m_th.font_size_small);
         y += PG_ROW-2;
        }

      if(firm.source_url!="")
        {
         y += 6;
         Line(P+"src",PG_PAD,y,PG_T(m_lang,"source")+": "+firm.source_url,
              m_th.text_muted,m_th.font_size_small);
        }
     }

   //---------------------------------------------------------------
   void              DrawSettings(const PG_RuleSet &firm,const PG_UserConfig &cfg,
                                  const PG_LockState &lock,const long now)
     {
      const string P = PG_UI+"b_";
      int y = m_y+96;

      const bool locked = PG_LockIsActive(lock,now);
      Rect(P+"lk",m_x+PG_PAD,y,PG_PANEL_W-2*PG_PAD,30,
           m_th.surface_alt,locked ? m_th.warn : m_th.border);
      Line(P+"lk1",PG_PAD+6,y+8,
           locked
           ? PG_T(m_lang,"lock_closed")+" "
             +PG_FormatDuration(PG_LockSecondsRemaining(lock,now))
           : PG_T(m_lang,"lock_open"),
           locked ? m_th.warn : m_th.safe,m_th.font_size);

      const long due = PG_UnlockEffectiveAt(lock);
      if(locked)
        {
         if(due>0)
            LineOpp(P+"lk2",PG_PAD+6,y+8,PG_T(m_lang,"unlock_pending")+" "
                    +PG_FormatDuration(due-now),m_th.text_muted,
                    m_th.font_size_small);
         else
            Button(PG_UI+"b_unlock",m_x+PG_PANEL_W-PG_PAD-110,y+6,104,18,
                   PG_T(m_lang,"request_unlock"),m_th.surface,m_th.text,false);
        }
      y += 38;

      Line(P+"st",PG_PAD,y,PG_T(m_lang,"only_stricter"),
           m_th.text_muted,m_th.font_size_small);
      y += PG_ROW+2;

      //--- each editable limit, with the firm's number beside it so the
      //--- trader can see exactly how much buffer they are buying
      const int bar_x = m_x+PG_PAD;
      const int bar_w = PG_PANEL_W-2*PG_PAD-70;

      DrawLimitRow(P+"s1",PG_T(m_lang,"daily_loss"),y,
                   cfg.daily_limit_pct>0.0 ? cfg.daily_limit_pct
                                           : firm.daily_limit_pct,
                   firm.daily_limit_pct,bar_x,bar_w,"daily",locked);
      y += 34;
      DrawLimitRow(P+"s2",PG_T(m_lang,"max_dd"),y,
                   cfg.maxdd_limit_pct>0.0 ? cfg.maxdd_limit_pct
                                           : firm.maxdd_limit_pct,
                   firm.maxdd_limit_pct,bar_x,bar_w,"maxdd",locked);
      y += 34;
      DrawLimitRow(P+"s3",PG_T(m_lang,"gap_buffer"),y,
                   cfg.gap_buffer_pct,50.0,bar_x,bar_w,"gap",locked);
      y += 40;

      Line(P+"em",PG_PAD,y,PG_T(m_lang,"enforce_mode"),
           m_th.text,m_th.font_size);
      y += PG_ROW+2;
      const int bw = (PG_PANEL_W-2*PG_PAD-8)/3;
      Button(PG_UI+"b_mode0",m_x+PG_PAD,y,bw,20,PG_T(m_lang,"mode_monitor"),
             cfg.enforce_mode==PG_ENFORCE_MONITOR ? m_th.accent : m_th.surface,
             cfg.enforce_mode==PG_ENFORCE_MONITOR ? m_th.accent_text : m_th.text,
             false);
      Button(PG_UI+"b_mode1",m_x+PG_PAD+bw+4,y,bw,20,PG_T(m_lang,"mode_reduce"),
             cfg.enforce_mode==PG_ENFORCE_REDUCE ? m_th.accent : m_th.surface,
             cfg.enforce_mode==PG_ENFORCE_REDUCE ? m_th.accent_text : m_th.text,
             false);
      Button(PG_UI+"b_mode2",m_x+PG_PAD+2*(bw+4),y,bw,20,PG_T(m_lang,"mode_close"),
             cfg.enforce_mode==PG_ENFORCE_CLOSE ? m_th.accent : m_th.surface,
             cfg.enforce_mode==PG_ENFORCE_CLOSE ? m_th.accent_text : m_th.text,
             false);
     }

   //--- one settings row: label, value, a track showing the firm's ceiling
   void              DrawLimitRow(const string id,const string label,const int y,
                                  const double user_val,const double firm_val,
                                  const int bar_x,const int bar_w,
                                  const string tag,const bool locked)
     {
      Line(id+"a",PG_PAD,y,label,m_th.text,m_th.font_size);
      LineOpp(id+"b",PG_PAD,y,PG_FmtPct(m_lang,user_val)+"  /  "
              +PG_FmtPct(m_lang,firm_val),m_th.text_muted,m_th.font_size_small);

      const double frac = (firm_val>0.0
                           ? MathMin(100.0,(user_val/firm_val)*100.0) : 0.0);
      Rect(id+"t",bar_x,y+16,bar_w,8,m_th.track,m_th.border);
      const int fw = (int)MathRound((double)bar_w*frac/100.0);
      if(fw>0)
         Rect(id+"f",bar_x,y+16,fw,8,m_th.accent,m_th.accent);
      else
         Del(id+"f");

      //--- the loose half of the track is greyed out and carries the lock,
      //--- so the direction you cannot go is visible, not just refused
      Button(PG_UI+"b_"+tag+"_dn",m_x+PG_PANEL_W-PG_PAD-56,y+14,24,16,"-",
             m_th.surface,m_th.text,false);
      Button(PG_UI+"b_"+tag+"_up",m_x+PG_PANEL_W-PG_PAD-28,y+14,24,16,
             locked ? "L" : "+",
             m_th.surface,locked ? m_th.text_muted : m_th.text,false);
     }

   //---------------------------------------------------------------
   void              DrawPositions(const PG_MarketView &mv,const PG_RiskResult &risk)
     {
      const string P = PG_UI+"b_";
      int y = m_y+96;

      Line(P+"hs",PG_PAD,y,PG_T(m_lang,"col_symbol"),
           m_th.text_muted,m_th.font_size_small);
      LineOpp(P+"hr",PG_PAD,y,PG_T(m_lang,"col_risk"),
              m_th.text_muted,m_th.font_size_small);
      y += PG_ROW;

      if(mv.position_count==0)
        {
         Line(P+"none",PG_PAD,y+10,PG_T(m_lang,"no_positions"),
              m_th.text_muted,m_th.font_size);
         return;
        }

      const double total_risk = MathMax(1.0,risk.worst_loss);

      for(int i=0;i<mv.position_count && i<PG_POS_ROWS;i++)
        {
         const string id = P+"p"+IntegerToString(i);
         const bool stopless = (mv.positions[i].sl<=0.0);

         double contrib = 0.0;
         for(int k=0;k<risk.per_position_count;k++)
            if(risk.per_position[k].ticket==mv.positions[i].ticket)
              { contrib = risk.per_position[k].loss_from_now; break; }

         if(i%2==1)
            Rect(id+"bg",m_x+PG_PAD,y-2,PG_PANEL_W-2*PG_PAD,PG_ROW+12,
                 m_th.surface_alt,m_th.surface_alt);

         Line(id+"a",PG_PAD+4,y,
              mv.positions[i].symbol+"  "
              +(mv.positions[i].dir>0 ? "BUY " : "SELL ")
              +DoubleToString(mv.positions[i].volume,2),
              stopless ? m_th.danger : m_th.text,m_th.font_size_small);

         LineOpp(id+"b",PG_PAD+4,y,
                 stopless ? PG_T(m_lang,"no_sl") : DoubleToString(contrib,0),
                 stopless ? m_th.danger : m_th.text,m_th.font_size_small);

         //--- share of the total projected loss
         const int tw = PG_PANEL_W-2*PG_PAD-8;
         const int fw = (int)MathRound((double)tw*MathMin(1.0,contrib/total_risk));
         Rect(id+"t",m_x+PG_PAD+4,y+13,tw,4,m_th.track,m_th.track);
         if(fw>0)
            Rect(id+"f",m_x+PG_PAD+4,y+13,fw,4,
                 stopless ? m_th.danger : m_th.warn,
                 stopless ? m_th.danger : m_th.warn);
         else
            Del(id+"f");

         y += PG_ROW+12;
        }
     }

   //---------------------------------------------------------------
   void              DrawLog()
     {
      const string P = PG_UI+"b_";
      int y = m_y+96;

      if(m_log_n==0)
        {
         Line(P+"le",PG_PAD,y+10,PG_T(m_lang,"log_empty"),
              m_th.text_muted,m_th.font_size);
         return;
        }

      for(int i=0;i<m_log_n && i<PG_LOG_ROWS;i++)
        {
         Line(P+"l"+IntegerToString(i),PG_PAD,y,m_log[i],
              m_log_col[i],m_th.font_size_small);
         y += PG_ROW-3;
        }
     }

public:
                     PG_Panel()
     {
      m_lang = PG_LANG_FA;
      m_tab  = PG_TAB_DASHBOARD;
      m_x=12; m_y=24;
      m_collapsed=false;
      m_read_only=false;
      m_log_n=0;
      m_calc_stop_points=300;
      PG_LoadTheme(PG_THEME_MIDNIGHT,m_th);
      m_rtl = PG_IsRtl(m_lang);
     }

   void              Configure(const ENUM_PG_THEME theme,const ENUM_PG_LANG lang,
                               const int x,const int y)
     {
      PG_LoadTheme(theme,m_th);
      m_lang = lang;
      m_rtl  = PG_IsRtl(lang);
      m_x = x;
      m_y = y;
     }

   void              SetReadOnly(const bool ro) { m_read_only = ro; }
   ENUM_PG_TAB       Tab() const { return m_tab; }
   ENUM_PG_THEME     ThemeId() const { return m_th.id; }
   ENUM_PG_LANG      Lang() const { return m_lang; }

   void              PushLog(const string line,const ENUM_PG_SEVERITY sev)
     {
      for(int i=PG_LOG_ROWS-1;i>0;i--)
        {
         m_log[i]     = m_log[i-1];
         m_log_col[i] = m_log_col[i-1];
        }
      m_log[0] = line;
      m_log_col[0] = (sev>=PG_SEV_BREACH   ? m_th.danger
                      : sev>=PG_SEV_CRITICAL ? m_th.danger
                      : sev>=PG_SEV_WARN     ? m_th.warn
                      : m_th.text_muted);
      if(m_log_n<PG_LOG_ROWS)
         m_log_n++;
     }

   void              Destroy()
     {
      for(int i=ObjectsTotal(0,-1,-1)-1;i>=0;i--)
        {
         const string nm = ObjectName(0,i,-1,-1);
         if(StringFind(nm,PG_UI)==0)
            ObjectDelete(0,nm);
        }
      ChartRedraw(0);
     }

   //+---------------------------------------------------------------+
   //| Redraw everything                                             |
   //+---------------------------------------------------------------+
   void              Render(const PG_MarketView &mv,const PG_RuleSet &firm,
                            const PG_RuleSet &eff,const PG_UserConfig &cfg,
                            const PG_EngineState &st,const PG_RiskResult &risk,
                            const PG_VerdictSet &vs,const PG_LockState &lock)
     {
      const int h = (m_collapsed ? 34 : PG_PANEL_H);
      Rect(PG_UI+"bg",m_x,m_y,PG_PANEL_W,h,m_th.bg,m_th.border);

      //--- header: product, promise, and the one status word that matters
      Line(PG_UI+"title",PG_PAD,m_y+8,PG_T(m_lang,"product"),
           m_th.text,m_th.font_size_big);

      string status = PG_T(m_lang,"status_safe");
      color  scol   = m_th.safe;
      if(cfg.enforce_mode==PG_ENFORCE_MONITOR)
        {
         status = PG_T(m_lang,"status_monitor");
         scol   = m_th.text_muted;
        }
      else
         if(vs.lockout)
           {
            status = PG_T(m_lang,"status_locked");
            scol   = m_th.danger;
           }
         else
            if(vs.block_new_trades)
              {
               status = PG_T(m_lang,"status_block");
               scol   = m_th.danger;
              }
            else
               if(st.tier==PG_TIER_WARN)
                 {
                  status = PG_T(m_lang,"status_warn");
                  scol   = m_th.warn;
                 }

      LineOpp(PG_UI+"status",PG_PAD,m_y+8,status,scol,m_th.font_size_big);
      Button(PG_UI+"collapse",m_x+PG_PANEL_W-24,m_y+4,18,16,
             m_collapsed ? "+" : "-",m_th.surface,m_th.text,false);

      if(m_collapsed)
        {
         ClearBody();
         ChartRedraw(0);
         return;
        }

      Line(PG_UI+"promise",PG_PAD,m_y+28,PG_T(m_lang,"promise"),
           m_th.text_muted,m_th.font_size_small);

      //--- tab strip
      const int tw = (PG_PANEL_W-2*PG_PAD-16)/5;
      for(int i=0;i<5;i++)
        {
         string key = "tab_dashboard";
         if(i==1) key="tab_rules";
         if(i==2) key="tab_settings";
         if(i==3) key="tab_positions";
         if(i==4) key="tab_log";
         const bool on = ((int)m_tab==i);
         Button(PG_UI+"tab"+IntegerToString(i),
                m_x+PG_PAD+i*(tw+4),m_y+50,tw,20,PG_T(m_lang,key),
                on ? m_th.accent : m_th.surface,
                on ? m_th.accent_text : m_th.text_muted,false);
        }

      //--- unverified-rules banner rides above every tab, not just Rules
      if(!firm.IsVerified() && m_tab!=PG_TAB_RULES)
         Line(PG_UI+"unvtop",PG_PAD,m_y+76,
              (m_lang==PG_LANG_FA ? "! قوانین تأیید نشده"
                                  : "! rules not verified"),
              m_th.danger,m_th.font_size_small);
      else
         Del(PG_UI+"unvtop");

      if(m_read_only)
         Line(PG_UI+"ro",PG_PAD,m_y+76,PG_T(m_lang,"not_owner"),
              m_th.warn,m_th.font_size_small);
      else
         Del(PG_UI+"ro");

      ClearBody();
      if(m_tab==PG_TAB_DASHBOARD) DrawDashboard(mv,eff,firm,cfg,st,risk,vs);
      if(m_tab==PG_TAB_RULES)     DrawRules(firm,eff);
      if(m_tab==PG_TAB_SETTINGS)  DrawSettings(firm,cfg,lock,mv.now);
      if(m_tab==PG_TAB_POSITIONS) DrawPositions(mv,risk);
      if(m_tab==PG_TAB_LOG)       DrawLog();

      ChartRedraw(0);
     }

   //+---------------------------------------------------------------+
   //| Click routing. Returns an action id the EA acts on:            |
   //|   0 nothing   1 redraw   2 config changed   3 unlock requested |
   //+---------------------------------------------------------------+
   int               OnClick(const string obj,PG_UserConfig &cfg)
     {
      if(StringFind(obj,PG_UI)!=0)
         return 0;

      ObjectSetInteger(0,obj,OBJPROP_STATE,false);

      if(obj==PG_UI+"collapse")
        {
         m_collapsed = !m_collapsed;
         return 1;
        }

      for(int i=0;i<5;i++)
         if(obj==PG_UI+"tab"+IntegerToString(i))
           {
            m_tab = (ENUM_PG_TAB)i;
            return 1;
           }

      if(obj==PG_UI+"b_calcminus")
        {
         m_calc_stop_points = (int)MathMax(10,m_calc_stop_points-50);
         return 1;
        }
      if(obj==PG_UI+"b_calcplus")
        {
         m_calc_stop_points = (int)MathMin(20000,m_calc_stop_points+50);
         return 1;
        }

      if(m_read_only)
         return 1;

      if(obj==PG_UI+"b_unlock")
         return 3;

      //--- limit nudges. Tightening is applied here; loosening is only
      //--- proposed, and the EA asks the lock whether it is allowed.
      if(obj==PG_UI+"b_daily_dn")
        {
         cfg.use_overrides=true;
         cfg.daily_limit_pct=MathMax(0.1,cfg.daily_limit_pct-0.5);
         return 2;
        }
      if(obj==PG_UI+"b_daily_up")
        {
         cfg.use_overrides=true;
         cfg.daily_limit_pct=cfg.daily_limit_pct+0.5;
         return 2;
        }
      if(obj==PG_UI+"b_maxdd_dn")
        {
         cfg.use_overrides=true;
         cfg.maxdd_limit_pct=MathMax(0.1,cfg.maxdd_limit_pct-0.5);
         return 2;
        }
      if(obj==PG_UI+"b_maxdd_up")
        {
         cfg.use_overrides=true;
         cfg.maxdd_limit_pct=cfg.maxdd_limit_pct+0.5;
         return 2;
        }
      if(obj==PG_UI+"b_gap_dn")
        {
         cfg.use_overrides=true;
         cfg.gap_buffer_pct=MathMax(0.0,cfg.gap_buffer_pct-5.0);
         return 2;
        }
      if(obj==PG_UI+"b_gap_up")
        {
         cfg.use_overrides=true;
         cfg.gap_buffer_pct=MathMin(100.0,cfg.gap_buffer_pct+5.0);
         return 2;
        }

      if(obj==PG_UI+"b_mode0") { cfg.enforce_mode=PG_ENFORCE_MONITOR; return 2; }
      if(obj==PG_UI+"b_mode1") { cfg.enforce_mode=PG_ENFORCE_REDUCE;  return 2; }
      if(obj==PG_UI+"b_mode2") { cfg.enforce_mode=PG_ENFORCE_CLOSE;   return 2; }

      return 0;
     }
  };

#endif // PG_PANEL_MQH
//+------------------------------------------------------------------+
