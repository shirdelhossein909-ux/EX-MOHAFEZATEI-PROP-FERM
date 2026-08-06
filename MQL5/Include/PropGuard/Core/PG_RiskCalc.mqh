//+------------------------------------------------------------------+
//|                                                  PG_RiskCalc.mqh |
//|      PropGuard - what the account is worth if every stop loss    |
//|      is hit at once, in account currency                         |
//+------------------------------------------------------------------+
//
// This answers the question the whole product is built around:
//
//   "If every open position and every pending order I have right now got
//    stopped out, would I still be inside my limits?"
//
// The number has to be pessimistic, because a guard that under-estimates
// is worse than no guard at all. So it includes, per position:
//
//   * the loss from entry price to the stop price
//   * a gap allowance, because a stop is not a guaranteed fill - weekend
//     gaps and news spikes jump straight through it
//   * a slippage allowance in points
//   * round-turn commission
//   * swap already accrued
//
// Positions with no stop loss are unbounded by definition. They are
// counted at their current floating P/L and flagged, never silently
// treated as zero risk.
//
#ifndef PG_RISKCALC_MQH
#define PG_RISKCALC_MQH

#include <PropGuard/Core/PG_Types.mqh>
#include <PropGuard/Core/PG_RuleSet.mqh>

//+------------------------------------------------------------------+
//| Convert a price distance into account currency                   |
//+------------------------------------------------------------------+
double PG_PriceToMoney(const PG_SymbolSpec &s,const double price_distance,
                       const double volume)
  {
   if(s.tick_size<=0.0 || s.tick_value==0.0)
      return 0.0;
   const double ticks = price_distance/s.tick_size;
   return ticks*s.tick_value*volume;
  }

double PG_PointsToMoney(const PG_SymbolSpec &s,const double points,
                        const double volume)
  {
   return PG_PriceToMoney(s,points*s.point,volume);
  }

//+------------------------------------------------------------------+
//| Per-position result                                              |
//+------------------------------------------------------------------+
struct PG_PositionRisk
  {
   long              ticket;
   bool              has_sl;
   double            pl_at_stop;      // signed, account currency, pessimistic
   double            loss_from_now;   // >=0, how much worse than right now
   double            risk_pct;        // of the reference balance

                     PG_PositionRisk()
     { ticket=0; has_sl=false; pl_at_stop=0.0; loss_from_now=0.0; risk_pct=0.0; }
  };

//+------------------------------------------------------------------+
//| Worst-case P/L of one position, in account currency              |
//|                                                                  |
//| Sign convention: negative is a loss. A stop parked in profit      |
//| returns a positive number, reduced by the same allowances.        |
//+------------------------------------------------------------------+
double PG_PositionWorstPL(const PG_Position &p,const PG_SymbolSpec &s,
                          const double gap_buffer_pct,const double slippage_points,
                          bool &has_sl)
  {
   has_sl = (p.sl>0.0);

   if(!has_sl)
     {
      //--- unbounded. The caller is responsible for raising the missing-stop
      //--- violation; all we can honestly report is where it stands now.
      return p.profit+p.swap_accrued;
     }

   //--- raw P/L if price reaches the stop
   const double raw = PG_PriceToMoney(s,(p.sl-p.open_price)*(double)p.dir,p.volume);

   //--- pessimism: the stop may not fill where it was placed
   const double gap  = MathAbs(raw)*(gap_buffer_pct/100.0);
   const double slip = MathAbs(PG_PointsToMoney(s,slippage_points,p.volume));
   const double comm = MathAbs(s.commission_per_lot*p.volume);

   return raw-gap-slip-comm+p.swap_accrued;
  }

//+------------------------------------------------------------------+
//| Worst-case P/L of a pending order that triggers and then stops   |
//+------------------------------------------------------------------+
double PG_PendingWorstPL(const PG_Pending &o,const PG_SymbolSpec &s,
                         const double gap_buffer_pct,const double slippage_points,
                         bool &has_sl)
  {
   has_sl = (o.sl>0.0);
   if(!has_sl)
      return 0.0;   // cannot bound it; the rule engine refuses it separately

   const double raw  = PG_PriceToMoney(s,(o.sl-o.price)*(double)o.dir,o.volume);
   const double gap  = MathAbs(raw)*(gap_buffer_pct/100.0);
   const double slip = MathAbs(PG_PointsToMoney(s,slippage_points,o.volume));
   const double comm = MathAbs(s.commission_per_lot*o.volume);
   return raw-gap-slip-comm;
  }

//+------------------------------------------------------------------+
//| Aggregate result across the whole account                        |
//+------------------------------------------------------------------+
struct PG_RiskResult
  {
   double            worst_equity;      // equity if every stop is hit
   double            worst_loss;        // equity - worst_equity, >= 0
   double            open_worst_pl;     // sum over open positions
   double            pending_worst_pl;  // sum over pendings
   double            total_lots;
   int               no_sl_positions;
   int               no_sl_pendings;
   bool              unbounded;         // at least one position has no stop
   PG_PositionRisk   per_position[PG_MAX_POSITIONS];
   int               per_position_count;

                     PG_RiskResult() { Reset(); }

   void              Reset()
     {
      worst_equity=0.0; worst_loss=0.0;
      open_worst_pl=0.0; pending_worst_pl=0.0; total_lots=0.0;
      no_sl_positions=0; no_sl_pendings=0; unbounded=false;
      per_position_count=0;
     }

   //--- the single position contributing the most loss, or -1
   int               WorstOffender() const
     {
      int  best=-1;
      double worst=0.0;
      for(int i=0;i<per_position_count;i++)
         if(per_position[i].loss_from_now>worst)
           {
            worst=per_position[i].loss_from_now;
            best=i;
           }
      return best;
     }
  };

//+------------------------------------------------------------------+
//| Look up the symbol spec a position points at                     |
//+------------------------------------------------------------------+
int PG_FindSpec(const PG_MarketView &mv,const string symbol)
  {
   for(int i=0;i<mv.spec_count;i++)
      if(mv.specs[i].name==symbol)
         return i;
   return -1;
  }

//+------------------------------------------------------------------+
//| The whole-account worst case                                     |
//|                                                                  |
//| include_pendings should be true whenever pending orders are      |
//| allowed to sit on the book: a resting order is a loss that has   |
//| not happened yet, and ignoring it is how accounts die overnight. |
//+------------------------------------------------------------------+
void PG_ComputeRisk(const PG_MarketView &mv,const PG_UserConfig &cfg,
                    const bool include_pendings,PG_RiskResult &out)
  {
   out.Reset();

   const double gap  = cfg.gap_buffer_pct;
   const double slip = cfg.slippage_points;
   const double ref  = (mv.initial_balance>0.0 ? mv.initial_balance : mv.balance);

   for(int i=0;i<mv.position_count && i<PG_MAX_POSITIONS;i++)
     {
      const int si = (mv.positions[i].spec_index>=0
                      ? mv.positions[i].spec_index
                      : PG_FindSpec(mv,mv.positions[i].symbol));
      if(si<0 || si>=mv.spec_count)
         continue;

      bool has_sl=false;
      const double wpl = PG_PositionWorstPL(mv.positions[i],mv.specs[si],
                                            gap,slip,has_sl);

      out.open_worst_pl += wpl;
      out.total_lots    += mv.positions[i].volume;

      if(!has_sl)
        {
         out.no_sl_positions++;
         out.unbounded=true;
        }

      PG_PositionRisk pr;
      pr.ticket        = mv.positions[i].ticket;
      pr.has_sl        = has_sl;
      pr.pl_at_stop    = wpl;
      pr.loss_from_now = MathMax(0.0,mv.positions[i].profit-wpl);
      pr.risk_pct      = (ref>0.0 ? (pr.loss_from_now/ref)*100.0 : 0.0);
      if(out.per_position_count<PG_MAX_POSITIONS)
        {
         out.per_position[out.per_position_count]=pr;
         out.per_position_count++;
        }
     }

   if(include_pendings)
     {
      for(int i=0;i<mv.pending_count && i<PG_MAX_PENDINGS;i++)
        {
         const int si = (mv.pendings[i].spec_index>=0
                         ? mv.pendings[i].spec_index
                         : PG_FindSpec(mv,mv.pendings[i].symbol));
         if(si<0 || si>=mv.spec_count)
            continue;

         bool has_sl=false;
         const double wpl = PG_PendingWorstPL(mv.pendings[i],mv.specs[si],
                                              gap,slip,has_sl);
         if(!has_sl)
           {
            out.no_sl_pendings++;
            continue;
           }
         //--- only a losing outcome is worth counting; a pending that would
         //--- trigger straight into profit is not a risk to protect against
         if(wpl<0.0)
            out.pending_worst_pl += wpl;
        }
     }

   //--- equity = balance + floating. At the stops, floating becomes the
   //--- worst-case sum, and any pending that fires adds its own loss.
   out.worst_equity = mv.balance+out.open_worst_pl+out.pending_worst_pl;
   out.worst_loss   = MathMax(0.0,mv.equity-out.worst_equity);
  }

//+------------------------------------------------------------------+
//| The one place a prospective order's worst-case loss is computed. |
//|                                                                  |
//| Both the pre-trade gate and the panel's lot calculator call this |
//| with identical arguments. That is deliberate: when two code      |
//| paths compute "the same" money by different arithmetic, floating |
//| point makes them disagree in the last bits, and the panel ends   |
//| up offering a lot size the gate then refuses.                    |
//+------------------------------------------------------------------+
double PG_WorstLossMagnitude(const PG_SymbolSpec &s,const double entry,
                             const double sl,const double volume,
                             const double gap_buffer_pct,
                             const double slippage_points)
  {
   if(volume<=0.0 || sl<=0.0 || s.tick_size<=0.0 || s.tick_value==0.0)
      return 0.0;
   const double raw  = MathAbs(PG_PriceToMoney(s,MathAbs(entry-sl),volume));
   const double gap  = raw*(gap_buffer_pct/100.0);
   const double slip = MathAbs(PG_PointsToMoney(s,slippage_points,volume));
   const double comm = MathAbs(s.commission_per_lot*volume);
   return raw+gap+slip+comm;
  }

//+------------------------------------------------------------------+
//| Does a projected loss fit inside a budget?                       |
//|                                                                  |
//| Prices carry rounding error, so a position that costs exactly the |
//| budget can measure a few femto-dollars over it. Refusing that     |
//| makes the guard look broken: the panel offers 2.00 lots and the   |
//| gate rejects 2.00 lots. The tolerance is relative plus an         |
//| absolute floor, and it is used by EVERY budget comparison so the  |
//| calculator and the gate can never disagree.                      |
//+------------------------------------------------------------------+
bool PG_FitsBudget(const double loss,const double budget)
  {
   return (loss<=budget+MathAbs(budget)*1e-9+1e-6);
  }

//+------------------------------------------------------------------+
//| Panel lot calculator: the largest volume whose worst case fits    |
//| inside risk_money, rounded down to the broker's volume step.      |
//|                                                                   |
//| The answer is verified against PG_WorstLossMagnitude before it is  |
//| returned, so whatever the panel offers is guaranteed to survive    |
//| the gate rather than merely being close enough on paper.           |
//+------------------------------------------------------------------+
double PG_MaxLotForRisk(const PG_SymbolSpec &s,const double entry,const double sl,
                        const double risk_money,const double gap_buffer_pct,
                        const double slippage_points)
  {
   if(risk_money<=0.0 || s.tick_size<=0.0 || s.tick_value==0.0)
      return 0.0;

   const double dist = MathAbs(entry-sl);
   if(dist<=0.0)
      return 0.0;

   const double per_lot = PG_WorstLossMagnitude(s,entry,sl,1.0,
                                                gap_buffer_pct,slippage_points);
   if(per_lot<=0.0)
      return 0.0;

   const double step = (s.volume_step>0.0 ? s.volume_step : 0.01);
   double lots = risk_money/per_lot;

   //--- floor to the broker's volume step, then clamp to its bounds
   lots = MathFloor(lots/step+1e-9)*step;
   if(lots>s.volume_max)
      lots = s.volume_max;

   //--- step down until the answer actually fits. At most a couple of
   //--- iterations in practice; the bound is there so a pathological
   //--- symbol spec can never spin the tick handler.
   for(int guard=0; guard<64; guard++)
     {
      if(lots<s.volume_min)
         return 0.0;
      const double rounded = MathRound(lots*100000.0)/100000.0;
      if(PG_FitsBudget(PG_WorstLossMagnitude(s,entry,sl,rounded,gap_buffer_pct,
                                             slippage_points),risk_money))
         return rounded;
      lots -= step;
     }
   return 0.0;
  }

//+------------------------------------------------------------------+
//| Worst case a hypothetical new order would add. Used both by the  |
//| pre-trade check and by the panel's "can I take this trade?" line.|
//+------------------------------------------------------------------+
double PG_HypotheticalWorstLoss(const PG_SymbolSpec &s,const int dir,
                                const double volume,const double entry,
                                const double sl,const double gap_buffer_pct,
                                const double slippage_points)
  {
   if(sl<=0.0 || volume<=0.0)
      return 0.0;

   //--- a stop parked on the profitable side of entry is not a loss
   const bool losing_side = ((dir>0 && sl<entry) || (dir<0 && sl>entry));
   if(!losing_side)
      return 0.0;

   return PG_WorstLossMagnitude(s,entry,sl,volume,gap_buffer_pct,slippage_points);
  }

#endif // PG_RISKCALC_MQH
//+------------------------------------------------------------------+
