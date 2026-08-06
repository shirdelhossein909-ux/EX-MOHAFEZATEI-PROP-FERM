//+------------------------------------------------------------------+
//|                                                   PG_Storage.mqh |
//|      PropGuard - persistence for the lock, the day, and the log  |
//+------------------------------------------------------------------+
//
// Files live under MQL5/Files/PropGuard/ in the terminal sandbox:
//
//   state/<login>.state    lock window, limits, strictest-ever, signature
//   state/<login>.day      the day's opening balance and high-water marks
//   logs/<login>-YYYYMMDD.jsonl   the append-only decision record
//
// Writes are atomic where it matters: content goes to a .tmp file which
// then replaces the original, so a terminal killed mid-write leaves the
// previous good state rather than a truncated one.
//
#ifndef PG_STORAGE_MQH
#define PG_STORAGE_MQH

#include <PropGuard/Core/PG_Types.mqh>
#include <PropGuard/Core/PG_RuleSet.mqh>
#include <PropGuard/Core/PG_Lock.mqh>
#include <PropGuard/Core/PG_Log.mqh>
#include <PropGuard/Core/PG_Clock.mqh>

#define PG_DIR_ROOT   "PropGuard"
#define PG_DIR_STATE  "PropGuard\\state"
#define PG_DIR_LOGS   "PropGuard\\logs"

//+------------------------------------------------------------------+
//| Small key=value helpers                                          |
//+------------------------------------------------------------------+
string PG_KV(const string k,const string v)      { return k+"="+v+"\n"; }
string PG_KVd(const string k,const double v)     { return k+"="+DoubleToString(v,6)+"\n"; }
string PG_KVi(const string k,const long v)       { return k+"="+IntegerToString(v)+"\n"; }
string PG_KVb(const string k,const bool v)       { return k+"="+(v ? "1" : "0")+"\n"; }

//--- pull a value out of an already-loaded blob
string PG_GetKV(const string blob,const string key,const string fallback)
  {
   const string needle = "\n"+key+"=";
   string hay = "\n"+blob;
   const int p = StringFind(hay,needle);
   if(p<0)
      return fallback;
   const int start = p+StringLen(needle);
   int end = StringFind(hay,"\n",start);
   if(end<0)
      end = StringLen(hay);
   return StringSubstr(hay,start,end-start);
  }

double PG_GetKVd(const string blob,const string key,const double fallback)
  {
   const string v = PG_GetKV(blob,key,"");
   if(v=="")
      return fallback;
   return StringToDouble(v);
  }

long PG_GetKVi(const string blob,const string key,const long fallback)
  {
   const string v = PG_GetKV(blob,key,"");
   if(v=="")
      return fallback;
   return StringToInteger(v);
  }

bool PG_GetKVb(const string blob,const string key,const bool fallback)
  {
   const string v = PG_GetKV(blob,key,"");
   if(v=="")
      return fallback;
   return (v=="1");
  }

//+------------------------------------------------------------------+
//| Whole-file read and atomic write                                 |
//+------------------------------------------------------------------+
bool PG_ReadTextFile(const string path,string &out)
  {
   out="";
   const int h = FileOpen(path,FILE_READ|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE)
      return false;
   while(!FileIsEnding(h))
      out += FileReadString(h)+"\n";
   FileClose(h);
   return true;
  }

bool PG_WriteTextFileAtomic(const string path,const string content)
  {
   const string tmp = path+".tmp";
   const int h = FileOpen(tmp,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE)
      return false;
   FileWriteString(h,content);
   FileClose(h);

   if(FileIsExist(path))
      FileDelete(path);
   return FileMove(tmp,0,path,FILE_REWRITE);
  }

bool PG_AppendLine(const string path,const string line)
  {
   int h = FileOpen(path,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE)
      h = FileOpen(path,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE)
      return false;
   FileSeek(h,0,SEEK_END);
   FileWriteString(h,line+"\n");
   FileClose(h);
   return true;
  }

//+------------------------------------------------------------------+
//| Paths                                                            |
//+------------------------------------------------------------------+
string PG_StatePath(const long login)
  { return PG_DIR_STATE+"\\"+IntegerToString(login)+".state"; }

string PG_DayPath(const long login)
  { return PG_DIR_STATE+"\\"+IntegerToString(login)+".day"; }

string PG_LogPath(const long login,const long day_epoch)
  {
   int y,m,d,hh,mi,ss,dow;
   PG_Split(day_epoch,y,m,d,hh,mi,ss,dow);
   return PG_DIR_LOGS+"\\"+IntegerToString(login)+"-"
          +IntegerToString(y)+PG_Pad2(m)+PG_Pad2(d)+".jsonl";
  }

//+------------------------------------------------------------------+
//| Lock state                                                       |
//+------------------------------------------------------------------+
string PG_SerializeConfig(const string prefix,const PG_UserConfig &c)
  {
   return PG_KVb(prefix+"use_overrides",c.use_overrides)
          +PG_KVd(prefix+"daily",c.daily_limit_pct)
          +PG_KVd(prefix+"maxdd",c.maxdd_limit_pct)
          +PG_KVd(prefix+"risk_per_trade",c.max_risk_per_trade_pct)
          +PG_KVd(prefix+"lot_per_trade",c.max_lot_per_trade_per_100k)
          +PG_KVd(prefix+"total_lots",c.max_total_lots_per_100k)
          +PG_KVi(prefix+"max_positions",c.max_open_positions)
          +PG_KVb(prefix+"require_sl",c.require_sl)
          +PG_KVb(prefix+"no_weekend",c.forbid_weekend_holding)
          +PG_KVb(prefix+"news",c.news_blackout_enabled)
          +PG_KVd(prefix+"gap_buffer",c.gap_buffer_pct)
          +PG_KVd(prefix+"slippage",c.slippage_points)
          +PG_KVd(prefix+"warn_at",c.warn_at_pct)
          +PG_KVd(prefix+"block_at",c.block_at_pct)
          +PG_KVi(prefix+"enforce_mode",(long)c.enforce_mode);
  }

void PG_DeserializeConfig(const string blob,const string prefix,PG_UserConfig &c)
  {
   c.Defaults();
   c.use_overrides              = PG_GetKVb(blob,prefix+"use_overrides",false);
   c.daily_limit_pct            = PG_GetKVd(blob,prefix+"daily",0.0);
   c.maxdd_limit_pct            = PG_GetKVd(blob,prefix+"maxdd",0.0);
   c.max_risk_per_trade_pct     = PG_GetKVd(blob,prefix+"risk_per_trade",0.0);
   c.max_lot_per_trade_per_100k = PG_GetKVd(blob,prefix+"lot_per_trade",0.0);
   c.max_total_lots_per_100k    = PG_GetKVd(blob,prefix+"total_lots",0.0);
   c.max_open_positions         = (int)PG_GetKVi(blob,prefix+"max_positions",0);
   c.require_sl                 = PG_GetKVb(blob,prefix+"require_sl",true);
   c.forbid_weekend_holding     = PG_GetKVb(blob,prefix+"no_weekend",false);
   c.news_blackout_enabled      = PG_GetKVb(blob,prefix+"news",false);
   c.gap_buffer_pct             = PG_GetKVd(blob,prefix+"gap_buffer",15.0);
   c.slippage_points            = PG_GetKVd(blob,prefix+"slippage",20.0);
   c.warn_at_pct                = PG_GetKVd(blob,prefix+"warn_at",60.0);
   c.block_at_pct               = PG_GetKVd(blob,prefix+"block_at",80.0);
   c.enforce_mode = (ENUM_PG_ENFORCE_MODE)PG_GetKVi(blob,prefix+"enforce_mode",
                                                    (long)PG_ENFORCE_REDUCE);
  }

bool PG_SaveLockState(PG_LockState &st,const string key)
  {
   PG_SignLockState(st,key);

   string body = PG_KVi("schema",PG_SCHEMA_VERSION)
                 +PG_KV("version",PG_VERSION)
                 +PG_KVi("account",st.account_login)
                 +PG_KV("firm",st.firm_id)
                 +PG_KV("program",st.program_id)
                 +PG_KV("phase",st.phase_label)
                 +PG_KVi("locked_until",st.locked_until)
                 +PG_KVi("locked_at",st.locked_at)
                 +PG_KVi("counter",st.counter)
                 +PG_KVi("unlock_requested_at",st.unlock_requested_at)
                 +PG_KVb("has_strictest",st.has_strictest)
                 +PG_SerializeConfig("cur.",st.current)
                 +PG_SerializeConfig("str.",st.strictest)
                 +PG_KV("sig",PG_HexU64(st.signature));

   return PG_WriteTextFileAtomic(PG_StatePath(st.account_login),body);
  }

//--- returns true only when the file loaded AND its signature checked out
bool PG_LoadLockState(const long login,const string key,PG_LockState &st,
                      string &problem)
  {
   problem="";
   st.Clear();

   string blob="";
   if(!PG_ReadTextFile(PG_StatePath(login),blob))
     {
      problem="no state file";
      return false;
     }

   st.account_login       = PG_GetKVi(blob,"account",0);
   st.firm_id             = PG_GetKV(blob,"firm","");
   st.program_id          = PG_GetKV(blob,"program","");
   st.phase_label         = PG_GetKV(blob,"phase","");
   st.locked_until        = PG_GetKVi(blob,"locked_until",0);
   st.locked_at           = PG_GetKVi(blob,"locked_at",0);
   st.counter             = PG_GetKVi(blob,"counter",0);
   st.unlock_requested_at = PG_GetKVi(blob,"unlock_requested_at",0);
   st.has_strictest       = PG_GetKVb(blob,"has_strictest",false);
   PG_DeserializeConfig(blob,"cur.",st.current);
   PG_DeserializeConfig(blob,"str.",st.strictest);

   const string sig_hex = PG_GetKV(blob,"sig","");
   const string expect  = PG_HexU64(PG_HashKeyed(PG_LockPayload(st),key));

   if(sig_hex!=expect)
     {
      problem="signature mismatch - the state file was edited or replaced";
      return false;
     }
   if(st.account_login!=login)
     {
      problem="state file belongs to a different account";
      return false;
     }

   st.signature = PG_HashKeyed(PG_LockPayload(st),key);
   return true;
  }

//+------------------------------------------------------------------+
//| Daily accounting                                                 |
//+------------------------------------------------------------------+
struct PG_DayState
  {
   long              day_start_time;
   double            day_start_balance;
   double            day_start_equity;
   double            hwm_equity;
   double            hwm_eod_balance;
   double            initial_balance;
   long              challenge_start_time;
   bool              locked_out;          // survives a restart on purpose
   long              lockout_until;

                     PG_DayState()
     {
      day_start_time=0; day_start_balance=0.0; day_start_equity=0.0;
      hwm_equity=0.0; hwm_eod_balance=0.0; initial_balance=0.0;
      challenge_start_time=0; locked_out=false; lockout_until=0;
     }
  };

bool PG_SaveDayState(const long login,const PG_DayState &d)
  {
   const string body = PG_KVi("day_start_time",d.day_start_time)
                       +PG_KVd("day_start_balance",d.day_start_balance)
                       +PG_KVd("day_start_equity",d.day_start_equity)
                       +PG_KVd("hwm_equity",d.hwm_equity)
                       +PG_KVd("hwm_eod_balance",d.hwm_eod_balance)
                       +PG_KVd("initial_balance",d.initial_balance)
                       +PG_KVi("challenge_start_time",d.challenge_start_time)
                       +PG_KVb("locked_out",d.locked_out)
                       +PG_KVi("lockout_until",d.lockout_until);
   return PG_WriteTextFileAtomic(PG_DayPath(login),body);
  }

bool PG_LoadDayState(const long login,PG_DayState &d)
  {
   string blob="";
   if(!PG_ReadTextFile(PG_DayPath(login),blob))
      return false;
   d.day_start_time       = PG_GetKVi(blob,"day_start_time",0);
   d.day_start_balance    = PG_GetKVd(blob,"day_start_balance",0.0);
   d.day_start_equity     = PG_GetKVd(blob,"day_start_equity",0.0);
   d.hwm_equity           = PG_GetKVd(blob,"hwm_equity",0.0);
   d.hwm_eod_balance      = PG_GetKVd(blob,"hwm_eod_balance",0.0);
   d.initial_balance      = PG_GetKVd(blob,"initial_balance",0.0);
   d.challenge_start_time = PG_GetKVi(blob,"challenge_start_time",0);
   d.locked_out           = PG_GetKVb(blob,"locked_out",false);
   d.lockout_until        = PG_GetKVi(blob,"lockout_until",0);
   return true;
  }

//+------------------------------------------------------------------+
//| The log sink                                                     |
//+------------------------------------------------------------------+
class PG_LogWriter
  {
private:
   long              m_login;
   long              m_day;
   long              m_seq;
   ulong             m_prev;
   string            m_path;

   //--- resume the chain from the tail of today's file so a restart does
   //--- not silently begin a second, unlinked chain
   void              Resume()
     {
      m_seq  = 0;
      m_prev = 0;

      string blob="";
      if(!PG_ReadTextFile(m_path,blob))
         return;

      int pos = 0;
      string last = "";
      while(true)
        {
         const int nl = StringFind(blob,"\n",pos);
         if(nl<0)
            break;
         const string line = StringSubstr(blob,pos,nl-pos);
         if(StringLen(line)>2)
            last = line;
         pos = nl+1;
        }
      if(last=="")
         return;

      const int hp = StringFind(last,"\"hash\":\"");
      if(hp>=0)
        {
         const string hex = StringSubstr(last,hp+8,16);
         ulong v=0;
         for(int i=0;i<StringLen(hex);i++)
           {
            const ushort c = StringGetCharacter(hex,i);
            int nib = 0;
            if(c>='0' && c<='9') nib = (int)(c-'0');
            else if(c>='a' && c<='f') nib = 10+(int)(c-'a');
            v = (v<<4)|(ulong)nib;
           }
         m_prev = v;
        }
      const int sp = StringFind(last,"\"seq\":");
      if(sp>=0)
         m_seq = StringToInteger(StringSubstr(last,sp+6,20));
     }

public:
                     PG_LogWriter() { m_login=0; m_day=0; m_seq=0; m_prev=0; m_path=""; }

   void              Open(const long login,const long day_epoch)
     {
      m_login = login;
      m_day   = day_epoch;
      m_path  = PG_LogPath(login,day_epoch);
      Resume();
     }

   //--- roll to a new file when the trading day turns over
   void              EnsureDay(const long day_epoch)
     {
      if(day_epoch!=m_day)
         Open(m_login,day_epoch);
     }

   long              Sequence() const { return m_seq; }
   string            Path()     const { return m_path; }

   bool              Write(PG_LogRecord &r)
     {
      m_seq++;
      r.seq = m_seq;
      ulong digest = 0;
      const string line = PG_FormatLogLine(r,m_prev,digest);
      if(!PG_AppendLine(m_path,line))
        {
         m_seq--;
         return false;
        }
      m_prev = digest;
      return true;
     }
  };

//+------------------------------------------------------------------+
//| Verify a stored log file end to end                              |
//+------------------------------------------------------------------+
bool PG_VerifyLogFile(const string path,int &lines_checked,int &first_bad_line)
  {
   lines_checked=0;
   first_bad_line=-1;

   string blob="";
   if(!PG_ReadTextFile(path,blob))
      return false;

   ulong prev=0;
   int pos=0,n=0;
   while(true)
     {
      const int nl = StringFind(blob,"\n",pos);
      if(nl<0)
         break;
      const string line = StringSubstr(blob,pos,nl-pos);
      pos = nl+1;
      if(StringLen(line)<4)
         continue;
      n++;
      ulong digest=0;
      if(!PG_VerifyLogLine(line,prev,digest))
        {
         first_bad_line=n;
         lines_checked=n;
         return false;
        }
      prev = digest;
     }
   lines_checked=n;
   return true;
  }

//+------------------------------------------------------------------+
//| Create the folder tree on first run                              |
//+------------------------------------------------------------------+
void PG_EnsureFolders()
  {
   FolderCreate(PG_DIR_ROOT);
   FolderCreate(PG_DIR_STATE);
   FolderCreate(PG_DIR_LOGS);
  }

#endif // PG_STORAGE_MQH
//+------------------------------------------------------------------+
