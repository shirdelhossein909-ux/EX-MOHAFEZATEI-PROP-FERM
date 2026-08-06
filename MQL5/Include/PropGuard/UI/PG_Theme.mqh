//+------------------------------------------------------------------+
//|                                                     PG_Theme.mqh |
//|      PropGuard - Midnight, Daylight and Candle                   |
//+------------------------------------------------------------------+
//
// One rule governs all three palettes: GREEN MEANS SAFE AND RED MEANS
// DANGER, EVERYWHERE, AND NOWHERE ELSE.
//
// That sounds obvious until the Candle theme, where green and red are
// also the brand. If buttons and headings borrow those colours, a glance
// at the panel stops telling the trader anything - which defeats the
// point of a panel you are supposed to read in one look. So Candle uses
// gold for anything interactive, and keeps its bull/bear pair strictly
// for status.
//
// Colour is never the only signal. Every state also carries an icon and
// a word, because red-green colour blindness affects roughly one man in
// twelve and this is a product sold mostly to men.
//
#ifndef PG_THEME_MQH
#define PG_THEME_MQH

enum ENUM_PG_THEME
  {
   PG_THEME_MIDNIGHT = 0,   // deep charcoal, blue accent
   PG_THEME_DAYLIGHT = 1,   // white, blue accent
   PG_THEME_CANDLE   = 2    // dark, bull/bear pair, gold accent
  };

struct PG_Theme
  {
   ENUM_PG_THEME     id;
   string            name;

   color             bg;            // panel backdrop
   color             surface;       // card background
   color             surface_alt;   // raised rows, table stripes
   color             border;
   color             text;
   color             text_muted;
   color             safe;
   color             warn;
   color             danger;
   color             accent;        // interactive elements only
   color             accent_text;   // text drawn on top of accent
   color             track;         // empty part of a progress bar
   color             marker_user;   // the trader's own limit marker
   color             marker_firm;   // the prop firm's limit marker

   string            font;
   int               font_size;
   int               font_size_small;
   int               font_size_big;
  };

//+------------------------------------------------------------------+
//| Palettes                                                         |
//+------------------------------------------------------------------+
void PG_LoadTheme(const ENUM_PG_THEME which,PG_Theme &t)
  {
   //--- Tahoma renders Persian correctly on Windows and is present on
   //--- every MetaTrader install, which matters more here than elegance
   t.font            = "Tahoma";
   t.font_size       = 8;
   t.font_size_small = 7;
   t.font_size_big   = 11;

   if(which==PG_THEME_DAYLIGHT)
     {
      t.id          = PG_THEME_DAYLIGHT;
      t.name        = "Daylight";
      t.bg          = C'246,248,250';
      t.surface     = C'255,255,255';
      t.surface_alt = C'239,242,245';
      t.border      = C'208,215,222';
      t.text        = C'31,35,40';
      t.text_muted  = C'101,109,118';
      t.safe        = C'26,127,55';
      t.warn        = C'154,103,0';
      t.danger      = C'207,34,46';
      t.accent      = C'9,105,218';
      t.accent_text = C'255,255,255';
      t.track       = C'223,228,234';
      t.marker_user = C'31,35,40';
      t.marker_firm = C'139,148,158';
      return;
     }

   if(which==PG_THEME_CANDLE)
     {
      t.id          = PG_THEME_CANDLE;
      t.name        = "Candle";
      t.bg          = C'11,14,17';
      t.surface     = C'21,26,33';
      t.surface_alt = C'29,36,45';
      t.border      = C'37,44,54';
      t.text        = C'234,239,245';
      t.text_muted  = C'125,136,148';
      t.safe        = C'38,166,154';    // bull
      t.warn        = C'240,185,11';
      t.danger      = C'239,83,80';     // bear
      t.accent      = C'240,185,11';    // gold, so it never reads as status
      t.accent_text = C'11,14,17';
      t.track       = C'37,44,54';
      t.marker_user = C'234,239,245';
      t.marker_firm = C'125,136,148';
      return;
     }

   t.id          = PG_THEME_MIDNIGHT;
   t.name        = "Midnight";
   t.bg          = C'13,17,23';
   t.surface     = C'22,27,34';
   t.surface_alt = C'31,38,48';
   t.border      = C'42,50,61';
   t.text        = C'230,237,243';
   t.text_muted  = C'139,148,158';
   t.safe        = C'63,185,80';
   t.warn        = C'210,153,34';
   t.danger      = C'248,81,73';
   t.accent      = C'47,129,247';
   t.accent_text = C'255,255,255';
   t.track       = C'42,50,61';
   t.marker_user = C'230,237,243';
   t.marker_firm = C'139,148,158';
  }

//+------------------------------------------------------------------+
//| Status colour for a usage percentage of an allowance             |
//+------------------------------------------------------------------+
color PG_UsageColor(const PG_Theme &t,const double used_pct,
                    const double warn_at,const double block_at)
  {
   if(used_pct>=100.0)   return t.danger;
   if(used_pct>=block_at)return t.danger;
   if(used_pct>=warn_at) return t.warn;
   return t.safe;
  }

//+------------------------------------------------------------------+
//| The icon half of the never-colour-alone rule                     |
//+------------------------------------------------------------------+
string PG_StatusIcon(const double used_pct,const double warn_at,
                     const double block_at)
  {
   if(used_pct>=100.0)    return "X";     // breached
   if(used_pct>=block_at) return "!";     // blocked
   if(used_pct>=warn_at)  return "-";     // warning
   return "+";                            // safe
  }

#endif // PG_THEME_MQH
//+------------------------------------------------------------------+
