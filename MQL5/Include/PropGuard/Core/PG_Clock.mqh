//+------------------------------------------------------------------+
//|                                                     PG_Clock.mqh |
//|      PropGuard - server time, firm time, DST, and the daily and  |
//|      weekly boundaries every other module depends on             |
//+------------------------------------------------------------------+
//
// This is the module that quietly kills accounts when it is wrong.
//
// A firm publishes "daily reset at 00:00 CET". The terminal reports broker
// server time, which is some other offset entirely, and both sides may or
// may not observe DST. If the boundary is computed in the wrong frame the
// trader believes the day has rolled over when it has not, keeps trading,
// and breaches a limit that was never actually reset.
//
// Everything here is a pure function of epoch seconds plus explicit
// offsets. No MetaTrader API call. The caller supplies:
//   server_utc_offset_min = (TimeCurrent() - TimeGMT()) / 60
//
#ifndef PG_CLOCK_MQH
#define PG_CLOCK_MQH

#include <PropGuard/Core/PG_RuleSet.mqh>

#define PG_SECONDS_PER_DAY  86400

//+------------------------------------------------------------------+
//| Floor division that behaves for negative numerators              |
//+------------------------------------------------------------------+
long PG_FloorDiv(const long a,const long b)
  {
   long q=a/b;
   if((a%b!=0) && ((a<0)!=(b<0)))
      q--;
   return q;
  }

//+------------------------------------------------------------------+
//| Civil date <-> days since epoch (Howard Hinnant's algorithms)    |
//+------------------------------------------------------------------+
long PG_DaysFromCivil(const int y,const int m,const int d)
  {
   int yy = y - (m<=2 ? 1 : 0);
   const long era = (long)(yy>=0 ? yy : yy-399)/400;
   const long yoe = (long)yy - era*400;                       // [0,399]
   const long doy = (153*(long)(m+(m>2 ? -3 : 9))+2)/5+(long)d-1;
   const long doe = yoe*365+yoe/4-yoe/100+doy;                // [0,146096]
   return era*146097+doe-719468;
  }

void PG_CivilFromDays(const long z_in,int &y,int &m,int &d)
  {
   long z = z_in+719468;
   const long era = (z>=0 ? z : z-146096)/146097;
   const long doe = z-era*146097;                             // [0,146096]
   const long yoe = (doe-doe/1460+doe/36524-doe/146096)/365;  // [0,399]
   const long yy  = yoe+era*400;
   const long doy = doe-(365*yoe+yoe/4-yoe/100);              // [0,365]
   const long mp  = (5*doy+2)/153;                            // [0,11]
   const long dd  = doy-(153*mp+2)/5+1;                       // [1,31]
   const long mm  = mp+(mp<10 ? 3 : -9);                      // [1,12]
   y = (int)(yy+(mm<=2 ? 1 : 0));
   m = (int)mm;
   d = (int)dd;
  }

//+------------------------------------------------------------------+
//| Break an epoch into calendar parts. dow: 0=Sunday .. 6=Saturday  |
//+------------------------------------------------------------------+
void PG_Split(const long epoch,int &y,int &m,int &d,int &hh,int &mi,int &ss,int &dow)
  {
   const long days = PG_FloorDiv(epoch,PG_SECONDS_PER_DAY);
   long rem = epoch-days*PG_SECONDS_PER_DAY;
   PG_CivilFromDays(days,y,m,d);
   hh = (int)(rem/3600);   rem -= (long)hh*3600;
   mi = (int)(rem/60);
   ss = (int)(rem-(long)mi*60);
   //--- 1970-01-01 was a Thursday (4)
   long w = (days+4)%7;
   if(w<0)
      w += 7;
   dow = (int)w;
  }

long PG_MakeTime(const int y,const int m,const int d,
                 const int hh,const int mi,const int ss)
  {
   return PG_DaysFromCivil(y,m,d)*PG_SECONDS_PER_DAY
          +(long)hh*3600+(long)mi*60+(long)ss;
  }

//--- midnight of the calendar day containing `epoch`
long PG_MidnightOf(const long epoch)
  {
   return PG_FloorDiv(epoch,PG_SECONDS_PER_DAY)*PG_SECONDS_PER_DAY;
  }

int PG_DayOfWeek(const long epoch)
  {
   int y,m,d,hh,mi,ss,dow;
   PG_Split(epoch,y,m,d,hh,mi,ss,dow);
   return dow;
  }

//+------------------------------------------------------------------+
//| Last Sunday of a given month, as a day-of-month                  |
//+------------------------------------------------------------------+
int PG_LastSundayOfMonth(const int y,const int m)
  {
   int dim=31;
   if(m==4 || m==6 || m==9 || m==11)
      dim=30;
   else
      if(m==2)
        {
         const bool leap = ((y%4==0 && y%100!=0) || y%400==0);
         dim = (leap ? 29 : 28);
        }
   const long last = PG_DaysFromCivil(y,m,dim);
   long w = (last+4)%7;               // 0=Sunday
   if(w<0)
      w += 7;
   return dim-(int)w;
  }

//+------------------------------------------------------------------+
//| EU daylight saving: last Sunday of March 01:00 UTC until the     |
//| last Sunday of October 01:00 UTC. Used by every European prop    |
//| firm that quotes CET/CEST.                                       |
//+------------------------------------------------------------------+
bool PG_IsEuDst(const long utc_epoch)
  {
   int y,m,d,hh,mi,ss,dow;
   PG_Split(utc_epoch,y,m,d,hh,mi,ss,dow);
   const long start = PG_MakeTime(y,3,PG_LastSundayOfMonth(y,3),1,0,0);
   const long end   = PG_MakeTime(y,10,PG_LastSundayOfMonth(y,10),1,0,0);
   return (utc_epoch>=start && utc_epoch<end);
  }

//--- the firm's offset from UTC, in minutes, at a given UTC instant
int PG_FirmOffsetMin(const long utc_epoch,const PG_RuleSet &r)
  {
   int off=r.firm_utc_offset_min;
   if(r.firm_uses_dst && PG_IsEuDst(utc_epoch))
      off += 60;
   return off;
  }

//+------------------------------------------------------------------+
//| Frame conversions                                                |
//+------------------------------------------------------------------+
long PG_ServerToUtc(const long server_epoch,const int server_utc_offset_min)
  { return server_epoch-(long)server_utc_offset_min*60; }

long PG_UtcToServer(const long utc_epoch,const int server_utc_offset_min)
  { return utc_epoch+(long)server_utc_offset_min*60; }

//+------------------------------------------------------------------+
//| The most recent daily reset, expressed in SERVER time.           |
//|                                                                  |
//| Two passes: the first uses the offset in force now, the second   |
//| re-resolves using the offset in force at the candidate instant,  |
//| which is what makes the two DST changeover days correct.         |
//+------------------------------------------------------------------+
long PG_DayStartServer(const long server_now,const int server_utc_offset_min,
                       const PG_RuleSet &r)
  {
   const long utc_now = PG_ServerToUtc(server_now,server_utc_offset_min);

   long utc_reset = 0;
   for(int pass=0; pass<2; pass++)
     {
      const long probe = (pass==0 ? utc_now : utc_reset);
      const int  off   = PG_FirmOffsetMin(probe,r);
      const long firm_now  = utc_now+(long)off*60;
      long firm_reset = PG_MidnightOf(firm_now)
                        +(long)r.reset_hour*3600+(long)r.reset_minute*60;
      if(firm_reset>firm_now)
         firm_reset -= PG_SECONDS_PER_DAY;
      utc_reset = firm_reset-(long)off*60;
     }
   return PG_UtcToServer(utc_reset,server_utc_offset_min);
  }

long PG_NextDayStartServer(const long server_now,const int server_utc_offset_min,
                           const PG_RuleSet &r)
  {
   const long cur = PG_DayStartServer(server_now,server_utc_offset_min,r);
   //--- probe from just after the following midnight so a DST shift on the
   //--- boundary day resolves to the real next reset, not cur + 86400
   return PG_DayStartServer(cur+PG_SECONDS_PER_DAY+3600,server_utc_offset_min,r);
  }

long PG_SecondsToNextReset(const long server_now,const int server_utc_offset_min,
                           const PG_RuleSet &r)
  {
   const long nxt = PG_NextDayStartServer(server_now,server_utc_offset_min,r);
   return (nxt>server_now ? nxt-server_now : 0);
  }

//+------------------------------------------------------------------+
//| The most recent weekly rollover, in SERVER time. This is the     |
//| moment the tighten-only lock is allowed to open.                 |
//+------------------------------------------------------------------+
long PG_WeekStartServer(const long server_now,const PG_RuleSet &r)
  {
   int y,m,d,hh,mi,ss,dow;
   PG_Split(server_now,y,m,d,hh,mi,ss,dow);

   long candidate = PG_MidnightOf(server_now)+(long)r.week_reset_hour*3600;
   int back = dow-r.week_reset_dow;
   if(back<0)
      back += 7;
   candidate -= (long)back*PG_SECONDS_PER_DAY;
   if(candidate>server_now)
      candidate -= 7*PG_SECONDS_PER_DAY;
   return candidate;
  }

long PG_NextWeekStartServer(const long server_now,const PG_RuleSet &r)
  {
   return PG_WeekStartServer(server_now,r)+7*PG_SECONDS_PER_DAY;
  }

//+------------------------------------------------------------------+
//| Weekend-holding deadline for the week containing server_now      |
//+------------------------------------------------------------------+
long PG_WeekendCutoffServer(const long server_now,const PG_RuleSet &r)
  {
   int y,m,d,hh,mi,ss,dow;
   PG_Split(server_now,y,m,d,hh,mi,ss,dow);

   long cutoff = PG_MidnightOf(server_now)
                 +(long)r.weekend_close_hour*3600
                 +(long)r.weekend_close_minute*60;
   int fwd = r.weekend_close_dow-dow;
   if(fwd<0)
      fwd += 7;
   cutoff += (long)fwd*PG_SECONDS_PER_DAY;
   if(cutoff<server_now)
      cutoff += 7*PG_SECONDS_PER_DAY;
   return cutoff;
  }

//--- true once the cutoff has passed and the market has not yet reopened
bool PG_IsPastWeekendCutoff(const long server_now,const PG_RuleSet &r)
  {
   int y,m,d,hh,mi,ss,dow;
   PG_Split(server_now,y,m,d,hh,mi,ss,dow);
   if(dow==6)                    // Saturday
      return true;
   if(dow==0)                    // Sunday, before the week reopens
      return (hh<r.week_reset_hour);
   if(dow!=r.weekend_close_dow)
      return false;
   const long today_cut = PG_MidnightOf(server_now)
                          +(long)r.weekend_close_hour*3600
                          +(long)r.weekend_close_minute*60;
   return (server_now>=today_cut);
  }

//--- calendar days elapsed since the challenge started
int PG_CalendarDaysSince(const long start_epoch,const long now_epoch)
  {
   if(start_epoch<=0 || now_epoch<start_epoch)
      return 0;
   return (int)(PG_FloorDiv(now_epoch,PG_SECONDS_PER_DAY)
                -PG_FloorDiv(start_epoch,PG_SECONDS_PER_DAY));
  }

//+------------------------------------------------------------------+
//| Formatting helpers (panel and log)                               |
//+------------------------------------------------------------------+
string PG_Pad2(const int v)
  {
   if(v<10 && v>=0)
      return "0"+IntegerToString(v);
   return IntegerToString(v);
  }

string PG_FormatStamp(const long epoch)
  {
   int y,m,d,hh,mi,ss,dow;
   PG_Split(epoch,y,m,d,hh,mi,ss,dow);
   return IntegerToString(y)+"-"+PG_Pad2(m)+"-"+PG_Pad2(d)+" "
          +PG_Pad2(hh)+":"+PG_Pad2(mi)+":"+PG_Pad2(ss);
  }

string PG_FormatDuration(const long seconds_in)
  {
   long s = (seconds_in>0 ? seconds_in : 0);
   const int hh=(int)(s/3600);   s-=(long)hh*3600;
   const int mi=(int)(s/60);
   const int ss=(int)(s-(long)mi*60);
   return PG_Pad2(hh)+":"+PG_Pad2(mi)+":"+PG_Pad2(ss);
  }

#endif // PG_CLOCK_MQH
//+------------------------------------------------------------------+
