//+------------------------------------------------------------------+
//|                                                     PG_Firms.mqh |
//|                                                                  |
//|   >>> THIS IS THE ONLY FILE YOU EDIT TO ADD OR CHANGE A FIRM <<< |
//|                                                                  |
//+------------------------------------------------------------------+
//
//  HOW TO USE THIS FILE
//  --------------------
//  Every prop firm program is one block below, between a BEGIN and an END
//  marker. To add a firm, copy a whole block, change the numbers, and bump
//  nothing else - the engine, the panel and the logger pick it up
//  automatically.
//
//  THE verified_on FIELD IS THE SAFETY INTERLOCK.
//  Leave it at 0 until a human has opened the firm's own rules page and
//  confirmed every number in the block. While it is 0 the panel shows a red
//  "rules not verified" banner and the log stamps every decision as
//  provisional. Set it with PG_Date(YYYY,MM,DD) once confirmed.
//
//  A NOTE ON THE NUMBERS CURRENTLY IN THIS FILE
//  Every block below is marked DRAFT and carries verified_on = 0. The values
//  came from secondary sources, not from the firms' own rule pages, and they
//  are placeholders so the build has something to run against. Do not ship
//  them. Replace each block with the firm's published numbers, then set
//  verified_on.
//
#ifndef PG_FIRMS_MQH
#define PG_FIRMS_MQH

#include <PropGuard/Core/PG_RuleSet.mqh>
#include <PropGuard/Core/PG_Clock.mqh>

//--- small helper so verification dates read as dates, not epochs
long PG_Date(const int y,const int m,const int d)
  {
   return PG_DaysFromCivil(y,m,d)*PG_SECONDS_PER_DAY;
  }

//+------------------------------------------------------------------+
//| The catalog: every program of every firm, in one flat table      |
//+------------------------------------------------------------------+
struct PG_Catalog
  {
   PG_RuleSet        items[PG_MAX_PROGRAMS];
   int               count;

                     PG_Catalog() { count=0; }

   bool              Add(const PG_RuleSet &r)
     {
      if(count>=PG_MAX_PROGRAMS)
         return false;
      items[count]=r;
      count++;
      return true;
     }
  };

//+------------------------------------------------------------------+
//| ==================  FIRM 1  ====================================  |
//| FundedNext                                              [DRAFT]  |
//| BEGIN FIRM BLOCK                                                 |
//+------------------------------------------------------------------+
void PG_Firm_FundedNext(PG_Catalog &cat)
  {
   PG_RuleSet r;

   //--- fields shared by every program of this firm -----------------
   r.Clear();
   r.firm_id             = "fundednext";
   r.firm_name_en        = "FundedNext";
   r.firm_name_fa        = "فاندد نکست";
   r.source_url          = "https://fundednext.com/package-comparison";
   r.verified_on         = 0;                 // <-- SET AFTER HUMAN CHECK
   r.verified_by         = "";

   r.reset_hour          = 0;                 // firm timezone
   r.reset_minute        = 0;
   r.firm_utc_offset_min = 0;                 // <-- CONFIRM the firm's timezone
   r.firm_uses_dst       = false;
   r.week_reset_dow      = 0;                 // Sunday
   r.week_reset_hour     = 22;

   r.daily_baseline           = PG_BASE_BALANCE_AT_RESET;
   r.daily_include_floating   = true;
   r.maxdd_mode               = PG_DD_STATIC_INITIAL;
   r.maxdd_include_floating   = true;

   r.require_sl          = false;             // firm does not demand one
   r.sl_grace_seconds    = 60;
   r.profit_split_pct    = 80.0;
   r.forbid_hedging      = false;
   r.forbid_ea           = false;
   r.forbid_copy_trading = true;

   //--- program: Stellar 2-Step, phase 1 ----------------------------
   r.program_id       = "stellar-2step";
   r.program_name_en  = "Stellar 2-Step";
   r.program_name_fa  = "استلار دو مرحله‌ای";
   r.phase_label_en   = "Phase 1";
   r.phase_label_fa   = "فاز ۱";
   r.daily_enabled    = true;   r.daily_limit_pct = 5.0;
   r.maxdd_enabled    = true;   r.maxdd_limit_pct = 10.0;
   r.profit_target_pct= 8.0;
   r.min_trading_days = 0;
   r.max_calendar_days= 0;
   cat.Add(r);

   //--- program: Stellar 2-Step, phase 2 ----------------------------
   r.phase_label_en   = "Phase 2";
   r.phase_label_fa   = "فاز ۲";
   r.profit_target_pct= 5.0;
   cat.Add(r);

   //--- program: Stellar 2-Step, funded -----------------------------
   r.phase_label_en   = "Funded";
   r.phase_label_fa   = "فاند";
   r.profit_target_pct= 0.0;
   cat.Add(r);

   //--- program: Stellar 1-Step -------------------------------------
   r.program_id       = "stellar-1step";
   r.program_name_en  = "Stellar 1-Step";
   r.program_name_fa  = "استلار یک مرحله‌ای";
   r.phase_label_en   = "Evaluation";
   r.phase_label_fa   = "ارزیابی";
   r.daily_limit_pct  = 3.0;
   r.maxdd_limit_pct  = 6.0;
   r.profit_target_pct= 10.0;
   cat.Add(r);

   //--- program: Stellar Lite ---------------------------------------
   r.program_id       = "stellar-lite";
   r.program_name_en  = "Stellar Lite";
   r.program_name_fa  = "استلار لایت";
   r.phase_label_en   = "Phase 1";
   r.phase_label_fa   = "فاز ۱";
   r.daily_limit_pct  = 4.0;
   r.maxdd_limit_pct  = 8.0;
   r.profit_target_pct= 8.0;
   cat.Add(r);
  }
//--- END FIRM BLOCK ------------------------------------------------

//+------------------------------------------------------------------+
//| ==================  FIRM 2  ====================================  |
//| SLOT - awaiting firm name and rules                     [DRAFT]  |
//| BEGIN FIRM BLOCK                                                 |
//+------------------------------------------------------------------+
void PG_Firm_Slot2(PG_Catalog &cat)
  {
   PG_RuleSet r;
   r.Clear();
   r.firm_id             = "firm2";
   r.firm_name_en        = "Firm 2 (unset)";
   r.firm_name_fa        = "پراپ ۲ (تعیین نشده)";
   r.source_url          = "";
   r.verified_on         = 0;

   r.reset_hour          = 0;
   r.reset_minute        = 0;
   r.firm_utc_offset_min = 210;               // Iran standard time, UTC+3:30
   r.firm_uses_dst       = false;
   r.week_reset_dow      = 0;
   r.week_reset_hour     = 22;

   //--- the pattern most Iranian firms publish: 5% daily off the day's
   //--- opening BALANCE, 12% overall off the INITIAL balance, static.
   r.daily_enabled            = true;
   r.daily_limit_pct          = 5.0;
   r.daily_baseline           = PG_BASE_BALANCE_AT_RESET;
   r.daily_include_floating   = true;

   r.maxdd_enabled            = true;
   r.maxdd_limit_pct          = 12.0;
   r.maxdd_mode               = PG_DD_STATIC_INITIAL;
   r.maxdd_include_floating   = true;

   r.program_id       = "two-step";
   r.program_name_en  = "Two Step";
   r.program_name_fa  = "دو مرحله‌ای";
   r.phase_label_en   = "Phase 1";
   r.phase_label_fa   = "فاز ۱";
   r.profit_target_pct= 8.0;
   r.profit_split_pct = 80.0;
   r.forbid_hedging   = true;
   r.forbid_ea        = true;
   cat.Add(r);

   r.phase_label_en   = "Phase 2";
   r.phase_label_fa   = "فاز ۲";
   r.profit_target_pct= 4.0;
   cat.Add(r);

   r.phase_label_en   = "Funded";
   r.phase_label_fa   = "فاند";
   r.profit_target_pct= 0.0;
   cat.Add(r);
  }
//--- END FIRM BLOCK ------------------------------------------------

//+------------------------------------------------------------------+
//| ==================  FIRM 3  ====================================  |
//| SLOT - awaiting firm name and rules                     [DRAFT]  |
//| BEGIN FIRM BLOCK                                                 |
//+------------------------------------------------------------------+
void PG_Firm_Slot3(PG_Catalog &cat)
  {
   PG_RuleSet r;
   r.Clear();
   r.firm_id             = "firm3";
   r.firm_name_en        = "Firm 3 (unset)";
   r.firm_name_fa        = "پراپ ۳ (تعیین نشده)";
   r.verified_on         = 0;
   r.firm_utc_offset_min = 210;
   r.daily_limit_pct     = 5.0;
   r.maxdd_limit_pct     = 12.0;
   r.maxdd_mode          = PG_DD_STATIC_INITIAL;

   r.program_id       = "two-step";
   r.program_name_en  = "Two Step";
   r.program_name_fa  = "دو مرحله‌ای";
   r.phase_label_en   = "Phase 1";
   r.phase_label_fa   = "فاز ۱";
   r.profit_target_pct= 8.0;
   cat.Add(r);

   r.phase_label_en   = "Phase 2";
   r.phase_label_fa   = "فاز ۲";
   r.profit_target_pct= 4.0;
   cat.Add(r);
  }
//--- END FIRM BLOCK ------------------------------------------------

//+------------------------------------------------------------------+
//| ==================  FIRM 4  ====================================  |
//| SLOT - awaiting firm name and rules                     [DRAFT]  |
//| BEGIN FIRM BLOCK                                                 |
//+------------------------------------------------------------------+
void PG_Firm_Slot4(PG_Catalog &cat)
  {
   PG_RuleSet r;
   r.Clear();
   r.firm_id             = "firm4";
   r.firm_name_en        = "Firm 4 (unset)";
   r.firm_name_fa        = "پراپ ۴ (تعیین نشده)";
   r.verified_on         = 0;
   r.firm_utc_offset_min = 210;
   r.daily_limit_pct     = 5.0;
   r.maxdd_limit_pct     = 12.0;
   r.maxdd_mode          = PG_DD_STATIC_INITIAL;

   r.program_id       = "one-step";
   r.program_name_en  = "One Step";
   r.program_name_fa  = "یک مرحله‌ای";
   r.phase_label_en   = "Evaluation";
   r.phase_label_fa   = "ارزیابی";
   r.profit_target_pct= 10.0;
   cat.Add(r);
  }
//--- END FIRM BLOCK ------------------------------------------------

//+------------------------------------------------------------------+
//| ==================  FIRM 5  ====================================  |
//| SLOT - awaiting firm name and rules                     [DRAFT]  |
//| BEGIN FIRM BLOCK                                                 |
//+------------------------------------------------------------------+
void PG_Firm_Slot5(PG_Catalog &cat)
  {
   PG_RuleSet r;
   r.Clear();
   r.firm_id             = "firm5";
   r.firm_name_en        = "Firm 5 (unset)";
   r.firm_name_fa        = "پراپ ۵ (تعیین نشده)";
   r.verified_on         = 0;
   r.firm_utc_offset_min = 210;
   r.daily_limit_pct     = 5.0;
   r.maxdd_limit_pct     = 12.0;
   r.maxdd_mode          = PG_DD_STATIC_INITIAL;

   r.program_id       = "two-step";
   r.program_name_en  = "Two Step";
   r.program_name_fa  = "دو مرحله‌ای";
   r.phase_label_en   = "Phase 1";
   r.phase_label_fa   = "فاز ۱";
   r.profit_target_pct= 8.0;
   cat.Add(r);

   r.phase_label_en   = "Phase 2";
   r.phase_label_fa   = "فاز ۲";
   r.profit_target_pct= 4.0;
   cat.Add(r);
  }
//--- END FIRM BLOCK ------------------------------------------------

//+------------------------------------------------------------------+
//| Registry - add one call per firm block                           |
//+------------------------------------------------------------------+
void PG_LoadCatalog(PG_Catalog &cat)
  {
   cat.count=0;
   PG_Firm_FundedNext(cat);
   PG_Firm_Slot2(cat);
   PG_Firm_Slot3(cat);
   PG_Firm_Slot4(cat);
   PG_Firm_Slot5(cat);
  }

//+------------------------------------------------------------------+
//| Catalog queries used by the panel's firm/program pickers.        |
//|                                                                  |
//| Index-based rather than array-filling on purpose: the catalog    |
//| holds a handful of entries, and this keeps the same source       |
//| compiling under both MQL5 and the C++ test harness.              |
//+------------------------------------------------------------------+
//--- catalog index of the first program of the n-th distinct firm, or -1
int PG_FirmFirstIndex(const PG_Catalog &cat,const int n)
  {
   int seen=0;
   for(int i=0;i<cat.count;i++)
     {
      bool dup=false;
      for(int j=0;j<i;j++)
         if(cat.items[j].firm_id==cat.items[i].firm_id)
           { dup=true; break; }
      if(dup)
         continue;
      if(seen==n)
         return i;
      seen++;
     }
   return -1;
  }

int PG_FirmCount(const PG_Catalog &cat)
  {
   int n=0;
   while(PG_FirmFirstIndex(cat,n)>=0)
      n++;
   return n;
  }

//--- number of programs belonging to one firm
int PG_ProgramCountOfFirm(const PG_Catalog &cat,const string firm_id)
  {
   int n=0;
   for(int i=0;i<cat.count;i++)
      if(cat.items[i].firm_id==firm_id)
         n++;
   return n;
  }

//--- catalog index of the n-th program of one firm, or -1
int PG_ProgramIndexOfFirm(const PG_Catalog &cat,const string firm_id,const int n)
  {
   int seen=0;
   for(int i=0;i<cat.count;i++)
     {
      if(cat.items[i].firm_id!=firm_id)
         continue;
      if(seen==n)
         return i;
      seen++;
     }
   return -1;
  }

int PG_FindProgram(const PG_Catalog &cat,const string firm_id,
                   const string program_id,const string phase_en)
  {
   for(int i=0;i<cat.count;i++)
     {
      if(cat.items[i].firm_id!=firm_id)             continue;
      if(cat.items[i].program_id!=program_id)       continue;
      if(phase_en!="" && cat.items[i].phase_label_en!=phase_en) continue;
      return i;
     }
   return -1;
  }

//--- how many programs in the catalog still carry verified_on == 0
int PG_UnverifiedCount(const PG_Catalog &cat)
  {
   int n=0;
   for(int i=0;i<cat.count;i++)
      if(!cat.items[i].IsVerified())
         n++;
   return n;
  }

#endif // PG_FIRMS_MQH
//+------------------------------------------------------------------+
