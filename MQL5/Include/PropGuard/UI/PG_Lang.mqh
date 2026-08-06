//+------------------------------------------------------------------+
//|                                                      PG_Lang.mqh |
//|      PropGuard - Persian and English strings                     |
//+------------------------------------------------------------------+
//
// SAVE THIS FILE AS UTF-8. MetaEditor will keep the Persian intact; a
// save as ANSI silently turns it into question marks.
//
// Layout mirrors with the language rather than only the words changing:
// PG_IsRtl() drives which edge labels anchor to and which way the bars
// fill. A Persian panel with left-aligned English geometry looks like a
// translation, not a product.
//
// The promise below is deliberately narrow and appears verbatim in the
// panel header. It never claims profit, an edge, or better performance,
// because the product does not provide any of those and the market it
// sells into is full of tools that pretend otherwise.
//
#ifndef PG_LANG_MQH
#define PG_LANG_MQH

enum ENUM_PG_LANG
  {
   PG_LANG_FA = 0,
   PG_LANG_EN = 1
  };

bool PG_IsRtl(const ENUM_PG_LANG lang) { return (lang==PG_LANG_FA); }

//+------------------------------------------------------------------+
//| String table                                                     |
//+------------------------------------------------------------------+
string PG_T(const ENUM_PG_LANG lang,const string key)
  {
   const bool fa = (lang==PG_LANG_FA);

   //--- product and promise
   if(key=="product")        return fa ? "پراپ‌گارد"                    : "PropGuard";
   if(key=="promise")        return fa ? "نمی‌ذاره پراپت رو فیل کنی"
                                       : "It will not let you fail your prop";
   if(key=="promise_long")   return fa ? "سودآورت نمی‌کنه. فقط نمی‌ذاره حسابت با نقض قانون از دست بره."
                                       : "This will not make you profitable. It makes sure the account is never lost to a rule violation.";

   //--- tabs
   if(key=="tab_dashboard")  return fa ? "داشبورد"      : "Dashboard";
   if(key=="tab_rules")      return fa ? "قوانین پراپ"  : "Prop rules";
   if(key=="tab_settings")   return fa ? "تنظیمات من"   : "My settings";
   if(key=="tab_positions")  return fa ? "پوزیشن‌ها"     : "Positions";
   if(key=="tab_log")        return fa ? "لاگ"          : "Log";

   //--- dashboard
   if(key=="daily_loss")     return fa ? "ضرر روزانه"           : "Daily loss";
   if(key=="max_dd")         return fa ? "دراوداون کلی"         : "Overall drawdown";
   if(key=="worst_case")     return fa ? "بدترین حالت"          : "Worst case";
   if(key=="worst_case_sub") return fa ? "اگر همه‌ی استاپ‌ها بخورن"
                                       : "if every stop is hit";
   if(key=="reset_in")       return fa ? "ریست روزانه تا"       : "Daily reset in";
   if(key=="trading_day")    return fa ? "روز معاملاتی"          : "Trading day";
   if(key=="of_min")         return fa ? "از حداقل"             : "of minimum";
   if(key=="headroom")       return fa ? "الان چقدر می‌تونی ریسک کنی؟"
                                       : "How much can you risk right now?";
   if(key=="max_lot")        return fa ? "حداکثر لات"           : "Max lot";
   if(key=="with_sl")        return fa ? "با استاپ"             : "with a stop of";
   if(key=="points")         return fa ? "پوینت"                : "points";
   if(key=="balance")        return fa ? "بالانس"               : "Balance";
   if(key=="equity")         return fa ? "اکوییتی"              : "Equity";
   if(key=="remaining")      return fa ? "باقی‌مانده"            : "remaining";
   if(key=="your_limit")     return fa ? "حد تو"                : "your limit";
   if(key=="firm_limit")     return fa ? "حد پراپ"              : "firm limit";

   //--- status
   if(key=="status_safe")    return fa ? "امن"       : "Safe";
   if(key=="status_warn")    return fa ? "هشدار"     : "Warning";
   if(key=="status_block")   return fa ? "توقف ورود" : "No new trades";
   if(key=="status_locked")  return fa ? "قفل"       : "Locked out";
   if(key=="status_monitor") return fa ? "فقط رصد"   : "Monitor only";

   //--- settings and lock
   if(key=="lock_open")      return fa ? "تنظیمات باز است"      : "Settings unlocked";
   if(key=="lock_closed")    return fa ? "قفل تا"               : "Locked for";
   if(key=="only_stricter")  return fa ? "فقط می‌تونی سخت‌گیرانه‌ترش کنی"
                                       : "You can only make this stricter";
   if(key=="request_unlock") return fa ? "درخواست باز کردن قفل" : "Request unlock";
   if(key=="unlock_pending") return fa ? "باز شدن قفل تا"       : "Unlock in";
   if(key=="cancel_unlock")  return fa ? "لغو درخواست"          : "Cancel request";
   if(key=="preset_conserv") return fa ? "محافظه‌کار"            : "Conservative";
   if(key=="preset_balanced")return fa ? "متعادل"               : "Balanced";
   if(key=="preset_firm")    return fa ? "نزدیک حد پراپ"        : "Near firm limit";
   if(key=="gap_buffer")     return fa ? "بافر گپ"              : "Gap buffer";
   if(key=="enforce_mode")   return fa ? "رفتار موقع رسیدن به حد"
                                       : "When the limit is reached";
   if(key=="mode_monitor")   return fa ? "فقط هشدار"            : "Warn only";
   if(key=="mode_reduce")    return fa ? "کاهش تا حد مجاز"      : "Reduce to compliant";
   if(key=="mode_close")     return fa ? "بستن همه"             : "Close everything";

   //--- rules tab
   if(key=="rules_verified") return fa ? "قوانین تأیید شده در"  : "Rules verified on";
   if(key=="rules_unverified")
      return fa ? "قوانین این پراپ هنوز تأیید نشده. قبل از اتکا به آن، با داشبورد پراپ خودت تطبیق بده."
                : "These rules are not verified yet. Check them against your own prop dashboard before relying on them.";
   if(key=="source")         return fa ? "منبع"                 : "Source";
   if(key=="select_firm")    return fa ? "پراپ خودت رو انتخاب کن"
                                       : "Choose your prop firm";
   if(key=="select_program") return fa ? "پلن و فاز"            : "Program and phase";

   //--- positions tab
   if(key=="col_symbol")     return fa ? "نماد"        : "Symbol";
   if(key=="col_lots")       return fa ? "لات"         : "Lots";
   if(key=="col_entry")      return fa ? "ورود"        : "Entry";
   if(key=="col_sl")         return fa ? "استاپ"       : "Stop";
   if(key=="col_risk")       return fa ? "ریسک"        : "Risk";
   if(key=="col_share")      return fa ? "سهم"         : "Share";
   if(key=="no_sl")          return fa ? "بدون استاپ"  : "NO STOP";
   if(key=="no_positions")   return fa ? "پوزیشن بازی نیست" : "No open positions";
   if(key=="close_position") return fa ? "بستن"        : "Close";

   //--- log tab
   if(key=="log_all")        return fa ? "همه"      : "All";
   if(key=="log_warn")       return fa ? "هشدار+"   : "Warn+";
   if(key=="log_critical")   return fa ? "بحرانی+"  : "Critical+";
   if(key=="export")         return fa ? "خروجی گزارش" : "Export report";
   if(key=="log_empty")      return fa ? "هنوز رویدادی ثبت نشده" : "Nothing logged yet";

   //--- misc
   if(key=="theme")          return fa ? "تم"     : "Theme";
   if(key=="language")       return fa ? "زبان"   : "Language";
   if(key=="collapse")       return fa ? "بستن"   : "Collapse";
   if(key=="expand")         return fa ? "باز کردن" : "Expand";
   if(key=="unbounded")      return fa ? "نامحدود" : "unbounded";
   if(key=="no_calendar")    return fa ? "تقویم اقتصادی این بروکر در دسترس نیست؛ قانون اخبار غیرفعال شد."
                                       : "This broker provides no economic calendar; the news rule is off.";
   if(key=="not_owner")      return fa ? "یک نسخه‌ی دیگر پراپ‌گارد روی این حساب فعال است. این نسخه فقط نمایش می‌دهد."
                                       : "Another PropGuard instance owns this account. This one is display-only.";

   return key;
  }

//+------------------------------------------------------------------+
//| Percent and money, formatted the way each language reads them    |
//+------------------------------------------------------------------+
string PG_FmtPct(const ENUM_PG_LANG lang,const double v)
  {
   return DoubleToString(v,2)+"%";
  }

string PG_FmtMoney(const ENUM_PG_LANG lang,const double v,const string ccy)
  {
   const string n = DoubleToString(v,2);
   return (PG_IsRtl(lang) ? n+" "+ccy : ccy+" "+n);
  }

#endif // PG_LANG_MQH
//+------------------------------------------------------------------+
