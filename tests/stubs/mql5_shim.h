//+------------------------------------------------------------------+
//|                                                     mql5_shim.h  |
//|   Enough of the MQL5 language surface to compile and RUN the     |
//|   PropGuard core headers under a normal C++ compiler.            |
//+------------------------------------------------------------------+
//
// Why this exists: MetaEditor only runs on Windows, so the engine could
// otherwise never be executed during development. Every header under
// MQL5/Include/PropGuard/Core is written without a single MetaTrader API
// call, which means the *real* source files - not a port, not a copy - can
// be compiled here and driven through scenarios.
//
// If a core header ever stops compiling against this shim, that is the
// signal it has grown a platform dependency and needs to move to
// Include/PropGuard/Broker instead.
//
#ifndef MQL5_SHIM_H
#define MQL5_SHIM_H

#include <string>
#include <cstdio>
#include <cstdarg>
#include <cmath>
#include <cstdint>

//--- MQL5 scalar type names -----------------------------------------
using string   = std::string;
using datetime = long;
using uchar    = unsigned char;
using ushort   = unsigned short;
using uint     = unsigned int;
using ulong    = unsigned long;

//--- MQL5 math library ----------------------------------------------
inline double MathAbs(double v)              { return std::fabs(v); }
inline int    MathAbs(int v)                 { return v<0 ? -v : v; }
inline long   MathAbs(long v)                { return v<0 ? -v : v; }
inline double MathFloor(double v)            { return std::floor(v); }
inline double MathCeil(double v)             { return std::ceil(v); }
inline double MathRound(double v)            { return std::floor(v+0.5); }
inline double MathSqrt(double v)             { return std::sqrt(v); }
inline double MathPow(double a,double b)     { return std::pow(a,b); }
inline double MathMod(double a,double b)     { return std::fmod(a,b); }

template<typename T> inline T MathMax(T a,T b) { return a>b ? a : b; }
template<typename T> inline T MathMin(T a,T b) { return a<b ? a : b; }
inline double MathMax(double a,int b)    { return a>(double)b ? a : (double)b; }
inline double MathMax(int a,double b)    { return (double)a>b ? (double)a : b; }
inline double MathMin(double a,int b)    { return a<(double)b ? a : (double)b; }
inline double MathMin(int a,double b)    { return (double)a<b ? (double)a : b; }

//--- MQL5 conversion library ----------------------------------------
inline string IntegerToString(long v)
  {
   char buf[32];
   std::snprintf(buf,sizeof(buf),"%ld",v);
   return string(buf);
  }

inline string IntegerToString(int v) { return IntegerToString((long)v); }

inline string DoubleToString(double v,int digits=8)
  {
   if(digits<0)
      digits=8;
   char fmt[16];
   char buf[64];
   std::snprintf(fmt,sizeof(fmt),"%%.%df",digits);
   std::snprintf(buf,sizeof(buf),fmt,v);
   return string(buf);
  }

inline double StringToDouble(const string &s) { return std::atof(s.c_str()); }
inline long   StringToInteger(const string &s){ return std::atol(s.c_str()); }

//--- MQL5 string library --------------------------------------------
inline int StringLen(const string &s) { return (int)s.size(); }

inline string StringSubstr(const string &s,int start,int count=-1)
  {
   if(start<0 || start>=(int)s.size())
      return string("");
   if(count<0)
      return s.substr((size_t)start);
   return s.substr((size_t)start,(size_t)count);
  }

inline int StringFind(const string &s,const string &sub,int start=0)
  {
   if(start<0)
      start=0;
   size_t p=s.find(sub,(size_t)start);
   return (p==string::npos) ? -1 : (int)p;
  }

inline bool StringReplace(string &s,const string &from,const string &to)
  {
   if(from.empty())
      return false;
   bool any=false;
   size_t p=0;
   while((p=s.find(from,p))!=string::npos)
     {
      s.replace(p,from.size(),to);
      p += to.size();
      any=true;
     }
   return any;
  }

//--- variadic StringFormat; %s takes a std::string in this shim, so the
//--- helper below converts before handing the pack to snprintf
namespace pg_shim
{
inline const char *arg(const string &s) { return s.c_str(); }
template<typename T> inline T arg(T v)  { return v; }
}

template<typename... Args>
inline string StringFormat(const string &fmt,Args... args)
  {
   char buf[2048];
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wformat-security"
#pragma GCC diagnostic ignored "-Wformat-nonliteral"
   std::snprintf(buf,sizeof(buf),fmt.c_str(),pg_shim::arg(args)...);
#pragma GCC diagnostic pop
   return string(buf);
  }

inline string StringFormat(const string &fmt) { return fmt; }

//--- MQL5 output ------------------------------------------------------
inline void Print(const string &s) { std::printf("%s\n",s.c_str()); }

#endif // MQL5_SHIM_H
