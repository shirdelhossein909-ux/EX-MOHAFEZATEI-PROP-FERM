// Compile-only smoke test: proves the core headers are free of MetaTrader
// dependencies and are syntactically valid outside MetaEditor.
#include "stubs/mql5_shim.h"

#include <PropGuard/Core/PG_Types.mqh>
#include <PropGuard/Core/PG_RuleSet.mqh>
#include <PropGuard/Core/PG_Clock.mqh>
#include <PropGuard/Firms/PG_Firms.mqh>

int main()
  {
   PG_Catalog cat;
   PG_LoadCatalog(cat);
   Print("catalog programs : "+IntegerToString(cat.count));
   Print("distinct firms   : "+IntegerToString(PG_FirmCount(cat)));
   Print("unverified       : "+IntegerToString(PG_UnverifiedCount(cat)));
   Print("epoch 2026-08-05 : "+PG_FormatStamp(PG_Date(2026,8,5)));
   return 0;
  }
