//====================================================================
// HEDGE / RECOVERY MODE (v4.10) - per instrument
//====================================================================

int HedgeMagic(int idx)
{
   return MagicBase + HEDGE_MAGIC_OFFSET + idx;
}

bool IsHedgeMagic(int magic)
{
   return (magic >= MagicBase + HEDGE_MAGIC_OFFSET &&
           magic <  MagicBase + 2 * HEDGE_MAGIC_OFFSET);
}

// Hedge orders are really sent only when enabled, not in shadow mode and not in LogOnly.
bool HedgeTrading()
{
   return (HedgeEnabled && !HedgeShadowMode && !LogOnly);
}

// A hedge episode is in progress: the original basket must not be exited by MRP or reduced.
bool HedgeHolds(int idx)
{
   if(!HedgeTrading())
      return false;
   return (CountBasketOrders(Syms[idx], HedgeMagic(idx)) > 0);
}

// Averaging down into a loss while hedging is contradictory: no grid adds.
bool HedgeBlocksAdds(int idx)
{
   if(!HedgeTrading())
      return false;
   if(hedgeState[idx] == HEDGE_ACTIVE)
      return true;
   return (CountBasketOrders(Syms[idx], HedgeMagic(idx)) > 0);
}

void HedgeInitState(int idx)
{
   hedgeState[idx]   = HEDGE_OFF;
   hedgePct[idx]     = 0.0;
   hedgePool[idx]    = 0.0;
   hedgeEpReal[idx]  = 0.0;
   hedgeSig[idx]     = 0;
   hedgeOpenBar[idx] = 0;
   hedgeLastAct[idx] = 0;
   hedgeLogBar[idx]  = 0;
   hedgeLogKey[idx]  = "";
}

// End of an episode: the original basket is gone and no hedge legs remain.
void HedgeResetEpisode(int idx)
{
   HedgeInitState(idx);
}

void HedgeLoadState(int idx)
{
   if(GlobalVariableCheck(SymKey(idx, "HST")))
      hedgeState[idx] = (ENUM_HEDGE_STATE)(int)GlobalVariableGet(SymKey(idx, "HST"));
   if(GlobalVariableCheck(SymKey(idx, "HPOOL")))
      hedgePool[idx] = GlobalVariableGet(SymKey(idx, "HPOOL"));
   if(GlobalVariableCheck(SymKey(idx, "HREAL")))
      hedgeEpReal[idx] = GlobalVariableGet(SymKey(idx, "HREAL"));
   if(GlobalVariableCheck(SymKey(idx, "HOPEN")))
      hedgeOpenBar[idx] = (datetime)GlobalVariableGet(SymKey(idx, "HOPEN"));
   if(GlobalVariableCheck(SymKey(idx, "HACT")))
      hedgeLastAct[idx] = (datetime)GlobalVariableGet(SymKey(idx, "HACT"));
}

void HedgeSaveState(int idx)
{
   GlobalVariableSet(SymKey(idx, "HST"), (double)hedgeState[idx]);
   GlobalVariableSet(SymKey(idx, "HPOOL"), hedgePool[idx]);
   GlobalVariableSet(SymKey(idx, "HREAL"), hedgeEpReal[idx]);
   GlobalVariableSet(SymKey(idx, "HOPEN"), (double)hedgeOpenBar[idx]);
   GlobalVariableSet(SymKey(idx, "HACT"), (double)hedgeLastAct[idx]);
}

// Log line that repeats at most once per closed HedgeTF bar for the same key.
void HedgeLog(int idx, string key, string msg)
{
   datetime b = iTime(Syms[idx], HedgeTF, 1);
   if(b == hedgeLogBar[idx] && key == hedgeLogKey[idx])
      return;
   hedgeLogBar[idx] = b;
   hedgeLogKey[idx] = key;
   Print((HedgeShadowMode ? "[HEDGE SHADOW] " : "[HEDGE] "), Syms[idx], " ", msg);
}

// Booking of a realized hedge result: the episode result changes, profit goes into the pool.
void HedgeBook(int idx, double est)
{
   hedgeEpReal[idx] += est;
   if(est > 0)
      hedgePool[idx] += est;
   hedgeLastAct[idx] = TimeCurrent();
}

// H4 reversal confirmation against the ORIGINAL direction (closed bar only):
// close beyond EMA, RSI beyond its threshold, tick volume of the bar above its average.
bool HedgeSignal(int idx, int dir, string &info)
{
   string sym = Syms[idx];

   double c   = iClose(sym, HedgeTF, 1);
   double ema = iMA(sym, HedgeTF, HedgeEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
   double rsi = iRSI(sym, HedgeTF, HedgeRSIPeriod, PRICE_CLOSE, 1);
   double v1  = (double)iVolume(sym, HedgeTF, 1);

   double sum = 0;
   int cnt = 0;
   for(int k = 2; k <= HedgeVolLookback + 1; k++)
   {
      double v = (double)iVolume(sym, HedgeTF, k);
      if(v > 0)
      {
         sum += v;
         cnt++;
      }
   }

   if(c <= 0 || ema <= 0 || rsi <= 0 || cnt < HedgeVolLookback / 2)
   {
      info = "signal: no data";
      return false;
   }

   double avgVol = sum / cnt;
   bool emaOK = (dir > 0) ? (c < ema) : (c > ema);
   bool rsiOK = (dir > 0) ? (rsi < HedgeRSILongBelow) : (rsi > HedgeRSIShortAbove);
   bool volOK = (v1 >= avgVol * HedgeVolMult);

   info = StringFormat("signal: ema=%s rsi=%s(%.1f) vol=%s(%.0f/%.0f)",
                       (emaOK ? "Y" : "n"), (rsiOK ? "Y" : "n"), rsi,
                       (volOK ? "Y" : "n"), v1, avgVol);

   return (emaOK && rsiOK && volOK);
}

// OFF -> WATCH -> ACTIVE by net loss (% of risk budget), with hysteresis on the way down.
// ACTIVE is held while hedge legs are open.
void HedgeUpdateState(int idx, double pct, int hLegs)
{
   ENUM_HEDGE_STATE cur = hedgeState[idx];
   ENUM_HEDGE_STATE nx = cur;

   if(cur == HEDGE_OFF)
   {
      if(pct >= HedgeActivePct)     nx = HEDGE_ACTIVE;
      else if(pct >= HedgeWatchPct) nx = HEDGE_WATCH;
   }
   else if(cur == HEDGE_WATCH)
   {
      if(pct >= HedgeActivePct)                        nx = HEDGE_ACTIVE;
      else if(pct < HedgeWatchPct - HedgeHysteresisPct) nx = HEDGE_OFF;
   }
   else
   {
      if(hLegs == 0 && pct < HedgeActivePct - HedgeHysteresisPct)
         nx = (pct >= HedgeWatchPct - HedgeHysteresisPct) ? HEDGE_WATCH : HEDGE_OFF;
   }

   if(nx == cur)
      return;

   Print("HEDGE STATE ", Syms[idx], " ", (int)cur, " -> ", (int)nx,
         " netLossPct=", DoubleToString(pct, 2));
   LogEvent("HEDGE STATE " + Syms[idx] + " " + IntegerToString((int)cur) + "->" +
            IntegerToString((int)nx) + " netLossPct=" + DoubleToString(pct, 1));
   hedgeState[idx] = nx;
   GlobalVariableSet(SymKey(idx, "HST"), (double)nx);
}

// Volume cap of the hedge as a share of the original basket. It stays below 100%,
// so the net position can never flip. Grows from Min at ActivePct to Max at FullLossPct.
double HedgeCapRatio(double pct)
{
   double span = HedgeFullLossPct - HedgeActivePct;
   double f = (span > 0) ? (pct - HedgeActivePct) / span : 1.0;
   if(f < 0) f = 0;
   if(f > 1) f = 1;
   return HedgeMinRatio + (HedgeMaxRatio - HedgeMinRatio) * f;
}

double HedgeOpenLot(string sym, double origLots, double hLots, double pct)
{
   double cap = origLots * HedgeCapRatio(pct);
   double room = cap - hLots;
   double want = MathMin(room, origLots * HedgeLegRatio);
   if(want <= 0)
      return 0;
   double lot = NormalizeLotsDown(sym, want);
   if(lot < MarketInfo(sym, MODE_MINLOT))
      return 0;
   return lot;
}

// Closes the whole hedge basket and books its result. True if no hedge legs remain.
bool HedgeCloseAll(int idx, string why)
{
   string sym = Syms[idx];
   int hm = HedgeMagic(idx);

   int d = 0, l = 0;
   double lt = 0, av = 0, la = 0, fl = 0;
   bool mx = false;
   if(!ScanBasketEx(sym, hm, d, l, lt, av, la, fl, mx))
      return true;
   if(LogOnly)
      return true;

   bool ok = CloseBasket(sym, hm, "hedge-" + why);
   if(ok)
   {
      HedgeBook(idx, fl);
      Print("HEDGE CLOSED ", sym, " (", why, ") result~", DoubleToString(fl, 2),
            " pool=", DoubleToString(hedgePool[idx], 2));
   }
   return ok;
}

// Hedge without an original basket: close it and clear the episode.
// Returns true while hedge legs are still open (no new entry before they are gone).
bool HedgeOrphanCleanup(int idx)
{
   string sym = Syms[idx];
   int hm = HedgeMagic(idx);

   if(CountBasketOrders(sym, MagicBase + idx) > 0)
      return false;   // original is still there: not an orphan

   if(CountBasketOrders(sym, hm) > 0)
   {
      if(LogOnly)
         return false;
      Print("HEDGE ORPHAN ", sym, ": original basket is gone -> closing hedge");
      HedgeCloseAll(idx, "orig-closed");
      if(CountBasketOrders(sym, hm) > 0)
         return true;
   }

   HedgeResetEpisode(idx);
   return false;
}

// Pool compensation: the pool closes the most losing legs of the original basket,
// fully when the pool covers the leg's loss, otherwise a proportional part of it.
// True if anything was closed.
bool HedgeCompensate(int idx, string sym, int magic)
{
   double pool = hedgePool[idx];
   if(pool <= 0)
      return false;

   double minLot = MarketInfo(sym, MODE_MINLOT);

   int    tk[];
   double lt[];
   double ls[];     // loss of the leg, positive number
   bool   used[];
   int    n = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != sym || OrderMagicNumber() != magic) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

      double pnl = OrderProfit() + OrderSwap() + OrderCommission();
      if(pnl >= 0 || OrderLots() <= 0) continue;

      n++;
      ArrayResize(tk, n);
      ArrayResize(lt, n);
      ArrayResize(ls, n);
      ArrayResize(used, n);
      tk[n - 1] = OrderTicket();
      lt[n - 1] = OrderLots();
      ls[n - 1] = -pnl;
      used[n - 1] = false;
   }

   bool any = false;

   for(int round = 0; round < n; round++)
   {
      if(pool <= 0)
         break;

      int best = -1;
      for(int k = 0; k < n; k++)
      {
         if(!used[k] && (best < 0 || ls[k] > ls[best]))
            best = k;
      }
      if(best < 0)
         break;
      used[best] = true;

      double vol;
      if(pool >= ls[best])
         vol = lt[best];
      else
         vol = NormalizeLotsDown(sym, lt[best] * pool / ls[best]);

      // never leave a remainder below the minimum lot
      if(lt[best] - vol > 0 && lt[best] - vol < minLot)
         vol = NormalizeLotsDown(sym, lt[best] - minLot);
      if(vol < minLot)
         continue;

      double est = ls[best] * vol / lt[best];

      if(ClosePartialTicket(tk[best], vol))
      {
         pool -= est;
         hedgeEpReal[idx] -= est;
         any = true;
         Print("HEDGE COMPENSATION ", sym, " closed ", DoubleToString(vol, 2),
               " lots of loser #", tk[best], " loss~", DoubleToString(est, 2),
               " poolLeft=", DoubleToString(MathMax(0.0, pool), 2));
         LogEvent("HEDGE-COMP " + sym + " " + DoubleToString(vol, 2) + " lots loss~" +
                  DoubleToString(est, 2));
      }
   }

   hedgePool[idx] = MathMax(0.0, pool);
   return any;
}

// The hedge must stay below HedgeMaxRatio of the original basket, also after the
// original shrank through compensation. Excess is closed, most profitable first.
bool HedgeTrimExcess(int idx)
{
   string sym = Syms[idx];

   int od = 0, ol = 0;
   double oLots = 0, oa = 0, olast = 0, of = 0;
   bool om = false;
   if(!ScanBasketEx(sym, MagicBase + idx, od, ol, oLots, oa, olast, of, om))
      return false;

   double cap = oLots * HedgeMaxRatio;

   double step = MarketInfo(sym, MODE_LOTSTEP);
   if(step <= 0) step = 0.01;
   double minLot = MarketInfo(sym, MODE_MINLOT);

   int    tk[];
   double lt[];
   double pl[];     // pnl per lot
   bool   used[];
   int    n = 0;
   double hLots = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != sym || OrderMagicNumber() != HedgeMagic(idx)) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if(OrderLots() <= 0) continue;

      n++;
      ArrayResize(tk, n);
      ArrayResize(lt, n);
      ArrayResize(pl, n);
      ArrayResize(used, n);
      tk[n - 1] = OrderTicket();
      lt[n - 1] = OrderLots();
      pl[n - 1] = (OrderProfit() + OrderSwap() + OrderCommission()) / OrderLots();
      used[n - 1] = false;
      hLots += OrderLots();
   }

   if(n == 0 || hLots - cap <= step * 0.000001)
      return false;

   double remaining = MathCeil((hLots - cap) / step - 0.000001) * step;
   bool any = false;

   for(int round = 0; round < n; round++)
   {
      if(remaining < minLot * 0.5)
         break;

      int best = -1;
      for(int k = 0; k < n; k++)
      {
         if(!used[k] && (best < 0 || pl[k] > pl[best]))
            best = k;
      }
      if(best < 0)
         break;
      used[best] = true;

      double vol = NormalizeLotsDown(sym, MathMin(lt[best], remaining));
      if(lt[best] - vol > 0 && lt[best] - vol < minLot)
         vol = lt[best];
      if(vol < minLot)
         vol = MathMin(lt[best], minLot);

      if(ClosePartialTicket(tk[best], vol))
      {
         HedgeBook(idx, pl[best] * vol);
         remaining -= vol;
         any = true;
         Print("HEDGE TRIM ", sym, " closed ", DoubleToString(vol, 2),
               " lots (cap ", DoubleToString(HedgeMaxRatio * 100.0, 0), "% of original)");
      }
   }

   return any;
}

// Main per-instrument hedge routine. Called from ManageExistingBasket after the basket TP check.
// Returns true if the ORIGINAL basket was changed (the caller rescans it).
bool ManageHedge(int idx, int dir, int legs, double totLots, double flt)
{
   bool changed = false;
   string sym = Syms[idx];
   int magic = MagicBase + idx;
   int hm = HedgeMagic(idx);

   int hDir = 0, hLegs = 0;
   double hLots = 0, hAvg = 0, hLast = 0, hFlt = 0;
   bool hMixed = false;
   bool hasH = ScanBasketEx(sym, hm, hDir, hLegs, hLots, hAvg, hLast, hFlt, hMixed);

   // Hedge legs while the mode is off or shadow: close them, shadow mode never holds orders.
   if(hasH && !LogOnly && (!HedgeEnabled || HedgeShadowMode))
   {
      HedgeCloseAll(idx, HedgeEnabled ? "shadow-mode" : "disabled");
      hasH = ScanBasketEx(sym, hm, hDir, hLegs, hLots, hAvg, hLast, hFlt, hMixed);
   }
   if(!HedgeEnabled)
      return false;

   // Validation: a hedge must be a single-direction basket AGAINST the original.
   if(hasH && (hMixed || hDir == dir))
   {
      Print("CRITICAL: invalid hedge basket on ", sym, " (mixed or same direction) -> closing");
      HedgeCloseAll(idx, "invalid");
      return false;
   }

   // Trigger metric: net floating loss of the instrument as a % of the risk budget.
   double budget = GetRiskBudget();
   double netLoss = -(flt + (hasH ? hFlt : 0.0) + hedgeEpReal[idx]);
   double pct = 0.0;
   if(budget > 0)
      pct = netLoss / budget * 100.0;
   else if(netLoss > 0)
      pct = 999.0;
   hedgePct[idx] = pct;

   HedgeUpdateState(idx, pct, hLegs);
   if(hedgeState[idx] == HEDGE_OFF)
   {
      hedgeSig[idx] = 0;
      return false;
   }

   string info = "";
   bool sig = HedgeSignal(idx, dir, info);
   hedgeSig[idx] = sig ? 1 : 0;

   HedgeLog(idx, "stats",
            StringFormat("state=%d dir=%d netLoss=%.2f (%.1f%% of budget) hedgeLots=%.2f pool=%.2f | %s",
                         (int)hedgeState[idx], dir, netLoss, pct, hLots, hedgePool[idx], info));

   if(hedgeState[idx] != HEDGE_ACTIVE)
      return false;

   bool trading = HedgeTrading();
   datetime hb = iTime(sym, HedgeTF, 1);

   if(trading)
   {
      // 1. Close the hedge when the reversal signal is gone or the hedge reached its own TP.
      if(hLegs > 0)
      {
         bool tp = false;
         if(HedgeTakeProfitPct > 0 && hAvg > 0)
         {
            double bid = MarketInfo(sym, MODE_BID);
            double ask = MarketInfo(sym, MODE_ASK);
            if(hDir < 0)
               tp = (ask <= hAvg * (1.0 - HedgeTakeProfitPct / 100.0));
            else
               tp = (bid >= hAvg * (1.0 + HedgeTakeProfitPct / 100.0));
         }
         if(!sig || tp)
            HedgeCloseAll(idx, tp ? "TP" : "signal-lost");
      }

      // 2. Pool compensates the most losing legs of the original basket.
      if(hedgePool[idx] > 0)
      {
         if(HedgeCompensate(idx, sym, magic))
            changed = true;
      }

      // 3. The hedge never exceeds the cap of the (possibly smaller) original basket.
      HedgeTrimExcess(idx);
   }

   // 4. Open / restart the hedge while the signal holds.
   if(!sig)
      return changed;

   int od = 0, ol = 0;
   double oLots = 0, oa = 0, olast = 0, of = 0;
   bool om = false;
   if(!ScanBasketEx(sym, magic, od, ol, oLots, oa, olast, of, om))
      return true;   // original fully compensated: the caller will find it flat

   hasH = ScanBasketEx(sym, hm, hDir, hLegs, hLots, hAvg, hLast, hFlt, hMixed);

   if(hLegs >= HedgeMaxLegs)
      return changed;
   if(hb > 0 && hb == hedgeOpenBar[idx])
      return changed;   // one leg per closed bar
   if(hedgeLastAct[idx] > 0 && TimeCurrent() - hedgeLastAct[idx] < HedgeCooldownMin * 60)
      return changed;
   if(MaxSpreadPoints > 0 && MarketInfo(sym, MODE_SPREAD) > MaxSpreadPoints)
      return changed;

   double lot = HedgeOpenLot(sym, oLots, hLots, pct);
   if(lot <= 0)
      return changed;

   if(!trading)
   {
      HedgeLog(idx, "open", StringFormat("SHADOW: would open %s hedge %.2f lots (original %.2f, cap %.0f%%)",
                                         (od > 0 ? "SELL" : "BUY"), lot, oLots, HedgeCapRatio(pct) * 100.0));
      return changed;
   }

   if(OpenLeg(sym, -od, lot, hm, "hedge"))
   {
      hedgeOpenBar[idx] = hb;
      hedgeLastAct[idx] = TimeCurrent();
      Print("HEDGE OPEN ", sym, " ", (od > 0 ? "SELL" : "BUY"), " ", DoubleToString(lot, 2),
            " lots, netLossPct=", DoubleToString(pct, 1));
   }

   return changed;
}

string HedgeStatusStr(int idx)
{
   int hd = 0, hl = 0;
   double ht = 0, ha = 0, hla = 0, hf = 0;
   bool hm = false;
   bool has = ScanBasketEx(Syms[idx], HedgeMagic(idx), hd, hl, ht, ha, hla, hf, hm);

   return StringConcatenate(" hedgeState=", (int)hedgeState[idx],
                            " hedgePct=", DoubleToString(hedgePct[idx], 1),
                            " hedgeSig=", hedgeSig[idx],
                            " hedge=",
                            (has
                             ? StringConcatenate("dir=", hd, " legs=", hl,
                                                 " lots=", DoubleToString(ht, 4),
                                                 " float=", DoubleToString(hf, 2))
                             : "flat"),
                            " hedgePool=", DoubleToString(hedgePool[idx], 2),
                            " hedgeEpReal=", DoubleToString(hedgeEpReal[idx], 2));
}

import sys

SRC = "/mnt/user-data/uploads/MetalsGridConfluence_v4.mq4"
FUN = "/home/claude/hedge_funcs.mq4"
DST = "/mnt/user-data/outputs/MetalsGridConfluence_v4.mq4"

with open(SRC, "r", encoding="ascii") as f:
    t = f.read()
with open(FUN, "r", encoding="ascii") as f:
    funcs = f.read()


def rep(old, new, count=1):
    global t
    n = t.count(old)
    if n != count:
        print("PATCH FAIL (found %d, expected %d):\n%s" % (n, count, old[:200]))
        sys.exit(1)
    t = t.replace(old, new)
