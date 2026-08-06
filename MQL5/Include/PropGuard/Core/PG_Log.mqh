//+------------------------------------------------------------------+
//|                                                       PG_Log.mqh |
//|      PropGuard - append-only, hash-chained decision records      |
//+------------------------------------------------------------------+
//
// Logging is a first-class feature here, for two reasons that pull in the
// same direction:
//
//   * the trader has handed a program the power to close their trades and
//     is owed a complete account of every decision it made, and
//   * that same account, exported, is the only honest proof the product
//     works. It has to be clean enough to publish.
//
// Each line carries the account state AT THE MOMENT OF THE DECISION, the
// rule that fired, both limits, and the reason in plain language. Each
// line also carries the digest of the line before it, so a deleted or
// edited line breaks the chain and PG_VerifyChain finds it.
//
// Monitor mode and guard mode emit identical records. That is what lets a
// trader run monitor mode for a week and read exactly what guard mode
// would have done.
//
#ifndef PG_LOG_MQH
#define PG_LOG_MQH

#include <PropGuard/Core/PG_Types.mqh>
#include <PropGuard/Core/PG_Clock.mqh>
#include <PropGuard/Core/PG_Hash.mqh>

//+------------------------------------------------------------------+
//| Names, kept stable because they end up in exported files          |
//+------------------------------------------------------------------+
string PG_SeverityName(const ENUM_PG_SEVERITY s)
  {
   if(s==PG_SEV_BREACH)   return "BREACH";
   if(s==PG_SEV_CRITICAL) return "CRITICAL";
   if(s==PG_SEV_WARN)     return "WARN";
   if(s==PG_SEV_NOTICE)   return "NOTICE";
   return "INFO";
  }

string PG_RuleName(const ENUM_PG_RULE r)
  {
   if(r==PG_RULE_DAILY_LOSS)         return "DAILY_LOSS";
   if(r==PG_RULE_MAX_DRAWDOWN)       return "MAX_DRAWDOWN";
   if(r==PG_RULE_WORST_CASE)         return "WORST_CASE";
   if(r==PG_RULE_MAX_RISK_PER_TRADE) return "MAX_RISK_PER_TRADE";
   if(r==PG_RULE_MAX_LOT_PER_TRADE)  return "MAX_LOT_PER_TRADE";
   if(r==PG_RULE_MAX_TOTAL_LOTS)     return "MAX_TOTAL_LOTS";
   if(r==PG_RULE_MAX_POSITIONS)      return "MAX_POSITIONS";
   if(r==PG_RULE_MAX_POS_PER_SYMBOL) return "MAX_POS_PER_SYMBOL";
   if(r==PG_RULE_STOP_LOSS_REQUIRED) return "STOP_LOSS_REQUIRED";
   if(r==PG_RULE_MIN_HOLD_TIME)      return "MIN_HOLD_TIME";
   if(r==PG_RULE_NEWS_BLACKOUT)      return "NEWS_BLACKOUT";
   if(r==PG_RULE_WEEKEND_HOLDING)    return "WEEKEND_HOLDING";
   if(r==PG_RULE_CONSISTENCY)        return "CONSISTENCY";
   if(r==PG_RULE_MAX_CALENDAR_DAYS)  return "MAX_CALENDAR_DAYS";
   if(r==PG_RULE_SYMBOL_NOT_ALLOWED) return "SYMBOL_NOT_ALLOWED";
   if(r==PG_RULE_HEDGING)            return "HEDGING";
   return "NONE";
  }

string PG_ActionName(const ENUM_PG_ACTION a)
  {
   if(a==PG_ACT_WARN)           return "WARN";
   if(a==PG_ACT_BLOCK_NEW)      return "BLOCK_NEW";
   if(a==PG_ACT_DELETE_PENDING) return "DELETE_PENDING";
   if(a==PG_ACT_ATTACH_SL)      return "ATTACH_SL";
   if(a==PG_ACT_REDUCE)         return "REDUCE";
   if(a==PG_ACT_CLOSE_POSITION) return "CLOSE_POSITION";
   if(a==PG_ACT_CLOSE_ALL)      return "CLOSE_ALL";
   if(a==PG_ACT_LOCKOUT)        return "LOCKOUT";
   return "NONE";
  }

string PG_TierName(const ENUM_PG_TIER t)
  {
   if(t==PG_TIER_ENFORCE) return "ENFORCE";
   if(t==PG_TIER_BLOCK)   return "BLOCK";
   if(t==PG_TIER_WARN)    return "WARN";
   return "NORMAL";
  }

string PG_ModeName(const ENUM_PG_ENFORCE_MODE m)
  {
   if(m==PG_ENFORCE_MONITOR) return "MONITOR";
   if(m==PG_ENFORCE_CLOSE)   return "CLOSE_ALL";
   return "REDUCE";
  }

//+------------------------------------------------------------------+
//| JSON string escaping                                             |
//+------------------------------------------------------------------+
string PG_JsonEscape(const string s)
  {
   string out = "";
   const int n = StringLen(s);
   for(int i=0;i<n;i++)
     {
      const ushort c = StringGetCharacter(s,i);
      if(c=='"')
         out += "\\\"";
      else
         if(c=='\\')
            out += "\\\\";
         else
            if(c=='\n')
               out += "\\n";
            else
               if(c=='\r')
                  out += "\\r";
               else
                  if(c=='\t')
                     out += "\\t";
                  else
                     if(c<0x20)
                        out += " ";
                     else
                        out += StringSubstr(s,i,1);
     }
   return out;
  }

string PG_JsonStr(const string key,const string value)
  {
   return "\""+key+"\":\""+PG_JsonEscape(value)+"\"";
  }

string PG_JsonNum(const string key,const double value,const int digits)
  {
   return "\""+key+"\":"+DoubleToString(value,digits);
  }

string PG_JsonInt(const string key,const long value)
  {
   return "\""+key+"\":"+IntegerToString(value);
  }

string PG_JsonBool(const string key,const bool value)
  {
   return "\""+key+"\":"+(value ? "true" : "false");
  }

//+------------------------------------------------------------------+
//| One decision, with the account state that produced it            |
//+------------------------------------------------------------------+
struct PG_LogRecord
  {
   long              ts;
   long              seq;
   ENUM_PG_SEVERITY  severity;
   string            event;          // startup, verdict, enforce, config, lock
   ENUM_PG_RULE      rule;
   ENUM_PG_ACTION    action;
   long              ticket;
   double            current;
   double            limit_user;
   double            limit_firm;
   string            reason;
   string            detail;         // free field: broker error text, symbol, ...

   //--- snapshot
   long              account;
   string            firm_id;
   string            program_id;
   string            phase;
   bool              rules_verified;
   ENUM_PG_ENFORCE_MODE mode;
   ENUM_PG_TIER      tier;
   double            balance;
   double            equity;
   double            daily_used;
   double            daily_limit;
   double            dd_used;
   double            dd_limit;
   double            worst_equity;
   double            headroom;
   int               positions;
   double            lots;

                     PG_LogRecord()
     {
      ts=0; seq=0; severity=PG_SEV_INFO; event="";
      rule=PG_RULE_NONE; action=PG_ACT_NONE; ticket=0;
      current=0.0; limit_user=0.0; limit_firm=0.0; reason=""; detail="";
      account=0; firm_id=""; program_id=""; phase="";
      rules_verified=false; mode=PG_ENFORCE_REDUCE; tier=PG_TIER_NORMAL;
      balance=0.0; equity=0.0; daily_used=0.0; daily_limit=0.0;
      dd_used=0.0; dd_limit=0.0; worst_equity=0.0; headroom=0.0;
      positions=0; lots=0.0;
     }
  };

//+------------------------------------------------------------------+
//| Render one record as a JSONL line and advance the chain.         |
//| `prev` is the digest of the previous line; 0 starts a new file.  |
//+------------------------------------------------------------------+
string PG_FormatLogLine(const PG_LogRecord &r,const ulong prev,ulong &out_digest)
  {
   //--- the payload is everything except the digest itself, so verification
   //--- can recompute it from the line as written
   string body =
      PG_JsonInt("seq",r.seq)+","
      +PG_JsonInt("ts",r.ts)+","
      +PG_JsonStr("time",PG_FormatStamp(r.ts))+","
      +PG_JsonStr("level",PG_SeverityName(r.severity))+","
      +PG_JsonStr("event",r.event)+","
      +PG_JsonStr("rule",PG_RuleName(r.rule))+","
      +PG_JsonStr("action",PG_ActionName(r.action))+","
      +PG_JsonInt("ticket",r.ticket)+","
      +PG_JsonNum("current",r.current,2)+","
      +PG_JsonNum("limit_user",r.limit_user,2)+","
      +PG_JsonNum("limit_firm",r.limit_firm,2)+","
      +PG_JsonInt("account",r.account)+","
      +PG_JsonStr("firm",r.firm_id)+","
      +PG_JsonStr("program",r.program_id)+","
      +PG_JsonStr("phase",r.phase)+","
      +PG_JsonBool("rules_verified",r.rules_verified)+","
      +PG_JsonStr("mode",PG_ModeName(r.mode))+","
      +PG_JsonStr("tier",PG_TierName(r.tier))+","
      +PG_JsonNum("balance",r.balance,2)+","
      +PG_JsonNum("equity",r.equity,2)+","
      +PG_JsonNum("daily_used",r.daily_used,2)+","
      +PG_JsonNum("daily_limit",r.daily_limit,2)+","
      +PG_JsonNum("dd_used",r.dd_used,2)+","
      +PG_JsonNum("dd_limit",r.dd_limit,2)+","
      +PG_JsonNum("worst_equity",r.worst_equity,2)+","
      +PG_JsonNum("headroom",r.headroom,2)+","
      +PG_JsonInt("positions",r.positions)+","
      +PG_JsonNum("lots",r.lots,2)+","
      +PG_JsonStr("reason",r.reason)+","
      +PG_JsonStr("detail",r.detail);

   out_digest = PG_HashChain(prev,body);

   return "{"+body+","
          +PG_JsonStr("prev",PG_HexU64(prev))+","
          +PG_JsonStr("hash",PG_HexU64(out_digest))+"}";
  }

//+------------------------------------------------------------------+
//| Recompute the digest of a line as written, for chain verification |
//+------------------------------------------------------------------+
bool PG_VerifyLogLine(const string line,const ulong prev,ulong &out_digest)
  {
   out_digest = 0;
   if(StringLen(line)<4 || StringSubstr(line,0,1)!="{")
      return false;

   const int cut = StringFind(line,",\"prev\":\"");
   if(cut<0)
      return false;

   const string body = StringSubstr(line,1,cut-1);
   const ulong  calc = PG_HashChain(prev,body);

   const int hpos = StringFind(line,"\"hash\":\"");
   if(hpos<0)
      return false;
   const string stated = StringSubstr(line,hpos+8,16);

   out_digest = calc;
   return (PG_HexU64(calc)==stated);
  }

//+------------------------------------------------------------------+
//| One line for the panel's log tab - short, readable, colour-coded |
//| by severity on the UI side.                                      |
//+------------------------------------------------------------------+
string PG_FormatPanelLine(const PG_LogRecord &r)
  {
   int y,m,d,hh,mi,ss,dow;
   PG_Split(r.ts,y,m,d,hh,mi,ss,dow);
   string head = PG_Pad2(hh)+":"+PG_Pad2(mi)+":"+PG_Pad2(ss)+"  ";
   if(r.rule!=PG_RULE_NONE)
      head += "["+PG_RuleName(r.rule)+"] ";
   if(r.action!=PG_ACT_NONE && r.action!=PG_ACT_WARN)
      head += PG_ActionName(r.action)+" ";
   if(r.ticket!=0)
      head += "#"+IntegerToString(r.ticket)+" ";
   return head+r.reason;
  }

//+------------------------------------------------------------------+
//| Build a record from a verdict plus the engine state              |
//+------------------------------------------------------------------+
void PG_FillRecordFromViolation(const PG_Violation &v,PG_LogRecord &r)
  {
   r.severity   = v.severity;
   r.rule       = v.rule;
   r.action     = v.action;
   r.ticket     = v.ticket;
   r.current    = v.current;
   r.limit_user = v.limit_user;
   r.limit_firm = v.limit_firm;
   r.reason     = v.reason;
  }

#endif // PG_LOG_MQH
//+------------------------------------------------------------------+
