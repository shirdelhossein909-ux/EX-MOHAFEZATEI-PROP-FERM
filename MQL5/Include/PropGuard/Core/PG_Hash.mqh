//+------------------------------------------------------------------+
//|                                                      PG_Hash.mqh |
//|      PropGuard - FNV-1a digests for the log chain and the state  |
//|      signature                                                   |
//+------------------------------------------------------------------+
//
// HONEST SCOPE. This is tamper-EVIDENCE, not tamper-PROOFING.
//
// The trader owns the machine and the key lives inside the EA, so anyone
// determined enough can forge a signature. What this buys is that casual
// edits - hand-editing the state file to widen a locked limit, deleting a
// log line, restoring yesterday's backup - are detected rather than
// silently accepted.
//
// The real protection is architectural and lives in PG_Lock.mqh: when a
// signature fails, PropGuard falls back to the STRICTEST configuration
// ever recorded for the account. That makes tampering pointless rather
// than merely difficult, which is a much stronger property than a bigger
// hash would give.
//
#ifndef PG_HASH_MQH
#define PG_HASH_MQH

//--- written in hex so both compilers type them as unsigned 64-bit
#define PG_FNV_OFFSET  0xCBF29CE484222325
#define PG_FNV_PRIME   0x00000100000001B3

//+------------------------------------------------------------------+
//| FNV-1a over the bytes of a string                                |
//+------------------------------------------------------------------+
ulong PG_HashString(const string s,const ulong seed)
  {
   ulong h = (seed==0 ? (ulong)PG_FNV_OFFSET : seed);
   const int n = StringLen(s);
   for(int i=0;i<n;i++)
     {
      //--- payloads hashed here are ASCII by construction (ids, numbers,
      //--- hex), so a code unit and a byte are the same thing and MQL5
      //--- and the test harness agree digit for digit
      h ^= (ulong)StringGetCharacter(s,i);
      h *= (ulong)PG_FNV_PRIME;
     }
   return h;
  }

ulong PG_Hash(const string s)
  {
   return PG_HashString(s,0);
  }

//--- chain step: this record's digest depends on the previous one
ulong PG_HashChain(const ulong previous,const string payload)
  {
   return PG_HashString(payload,(previous==0 ? (ulong)PG_FNV_OFFSET : previous));
  }

//--- keyed digest used for the state file signature
ulong PG_HashKeyed(const string payload,const string key)
  {
   const ulong k = PG_HashString(key,0);
   return PG_HashString(payload,k);
  }

//+------------------------------------------------------------------+
//| 16-character lowercase hex, stable across platforms              |
//+------------------------------------------------------------------+
string PG_HexU64(const ulong v)
  {
   const string digits = "0123456789abcdef";
   string out = "";
   for(int shift=60; shift>=0; shift-=4)
     {
      const int nib = (int)((v>>shift)&0x0F);
      out += StringSubstr(digits,nib,1);
     }
   return out;
  }

#endif // PG_HASH_MQH
//+------------------------------------------------------------------+
