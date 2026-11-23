# ---------------------------------------------------------------- header
rep('''#property copyright "fx_research"
#property version   "3.10"''',
'''//+------------------------------------------------------------------+
//| v4.10 - HEDGE / RECOVERY MODE (per instrument)                    |
//|                                                                   |
//|  Trigger metric: net floating loss of the instrument (original    |
//|  basket + hedge basket + realized result of the episode) as a %   |
//|  of the account risk budget (GetRiskBudget).                      |
//|   < HedgeWatchPct      : normal operation                         |
//|   WatchPct .. ActivePct: WATCH  - statistics only (H4 EMA, RSI,   |
//|                          tick volume), nothing is opened          |
//|   >= HedgeActivePct    : ACTIVE - if the H4 reversal is confirmed |
//|                          legs are opened AGAINST the original     |
//|                          basket (own magic = MagicBase+50+idx)    |
//|  Hedge profit goes into a pool. The pool closes the most losing   |
//|  legs of the original basket (partially or fully), then the hedge |
//|  restarts while the signal holds.                                 |
//|  The hedge volume is capped below 100% of the original basket,    |
//|  so the net position never flips: cap grows from HedgeMinRatio at |
//|  ActivePct to HedgeMaxRatio at HedgeFullLossPct.                  |
//|  While hedge legs are open: MRP exit, MRP reduction and grid adds |
//|  of the original basket are held. Basket TP and kill-switch work  |
//|  as before; the kill-switch closes the hedge baskets as well.     |
//|  Hedge orders skip the account stress budget (they reduce risk)   |
//|  but still pass the margin guard. Stress risk counts the original |
//|  basket only (no netting with the hedge).                         |
//|  HedgeShadowMode=true (default): log only, no hedge orders.       |
//+------------------------------------------------------------------+
#property copyright "fx_research"
#property version   "4.10"
#define HEDGE_MAGIC_OFFSET 50''')

# ---------------------------------------------------------------- enum
rep('''   MRP_EXIT_PENDING = 3
};
''',
'''   MRP_EXIT_PENDING = 3
};

enum ENUM_HEDGE_STATE
{
   HEDGE_OFF    = 0,
   HEDGE_WATCH  = 1,
   HEDGE_ACTIVE = 2
};
''')

# ---------------------------------------------------------------- inputs
rep('''//==== execution
input int     TimerSeconds      = 10;''',
'''//==== hedge / recovery mode (evaluated per instrument)
input bool    HedgeEnabled          = true;
input bool    HedgeShadowMode       = true;   // true = log only (no hedge orders); false = hedge trades
input double  HedgeWatchPct         = 15.0;   // net floating loss, % of risk budget: start observing
input double  HedgeActivePct        = 20.0;   // net floating loss, % of risk budget: hedging allowed
input double  HedgeFullLossPct      = 40.0;   // net loss at which the hedge cap reaches HedgeMaxRatio
input double  HedgeHysteresisPct    = 2.0;    // loss must fall this far below a threshold to leave the state
input ENUM_TIMEFRAMES HedgeTF       = PERIOD_H4;
input int     HedgeEMAPeriod        = 50;     // EMA on HedgeTF
input int     HedgeRSIPeriod        = 14;     // RSI on HedgeTF
input double  HedgeRSILongBelow     = 45.0;   // original long: RSI must be below
input double  HedgeRSIShortAbove    = 55.0;   // original short: RSI must be above
input int     HedgeVolLookback      = 20;     // bars for the average tick volume
input double  HedgeVolMult          = 1.0;    // signal bar volume must be >= average * this
input double  HedgeMinRatio         = 0.30;   // hedge cap at ActivePct, share of the original lots
input double  HedgeMaxRatio         = 0.90;   // hedge cap at FullLossPct (must stay < 1.0)
input double  HedgeLegRatio         = 0.25;   // lots of one hedge leg, share of the original lots
input int     HedgeMaxLegs          = 4;      // max simultaneously open hedge legs
input int     HedgeCooldownMin      = 60;     // minutes between a hedge action and the next hedge leg
input double  HedgeTakeProfitPct    = 0.30;   // hedge basket TP: price move in its favour, %

//==== execution
input int     TimerSeconds      = 10;''')

# ---------------------------------------------------------------- state
rep('''bool     basketOpenPrev[];
''',
'''bool     basketOpenPrev[];

// hedge / recovery mode
ENUM_HEDGE_STATE hedgeState[];
double   hedgePct[];        // net floating loss of the instrument, % of risk budget
double   hedgePool[];       // realized hedge profit not yet spent on compensation
double   hedgeEpReal[];     // realized result of the episode (hedge results minus compensated losses)
int      hedgeSig[];        // last H4 signal (0/1)
datetime hedgeOpenBar[];    // closed HedgeTF bar on which the last hedge leg was opened
datetime hedgeLastAct[];    // last hedge open/close (cooldown)
datetime hedgeLogBar[];
string   hedgeLogKey[];
''')

rep('''   ArrayResize(basketOpenPrev, n);
''',
'''   ArrayResize(basketOpenPrev, n);

   ArrayResize(hedgeState, n);
   ArrayResize(hedgePct, n);
   ArrayResize(hedgePool, n);
   ArrayResize(hedgeEpReal, n);
   ArrayResize(hedgeSig, n);
   ArrayResize(hedgeOpenBar, n);
   ArrayResize(hedgeLastAct, n);
   ArrayResize(hedgeLogBar, n);
   ArrayResize(hedgeLogKey, n);
''')

# ---------------------------------------------------------------- validation
rep('''   return ok;
}

int OnInit()''',
'''   if(MaxSymbols > HEDGE_MAGIC_OFFSET)
   {
      Print("PARAM ERROR: MaxSymbols must be <= ", HEDGE_MAGIC_OFFSET,
            " (hedge magic = MagicBase + ", HEDGE_MAGIC_OFFSET, " + index)");
      ok = false;
   }

   if(HedgeEnabled)
   {
      if(!(HedgeWatchPct > 0 && HedgeWatchPct < HedgeActivePct && HedgeActivePct < HedgeFullLossPct))
      {
         Print("PARAM ERROR: hedge thresholds must satisfy 0 < Watch < Active < FullLoss");
         ok = false;
      }
      if(HedgeHysteresisPct < 0 || HedgeHysteresisPct >= HedgeWatchPct)
      {
         Print("PARAM ERROR: HedgeHysteresisPct must be in [0, HedgeWatchPct)");
         ok = false;
      }
      if(HedgeEMAPeriod < 2 || HedgeRSIPeriod < 2 || HedgeVolLookback < 2 || HedgeVolMult <= 0)
      {
         Print("PARAM ERROR: hedge EMA/RSI period, volume lookback or multiplier out of range");
         ok = false;
      }
      if(!(HedgeRSILongBelow > 0 && HedgeRSILongBelow < 50 &&
           HedgeRSIShortAbove > 50 && HedgeRSIShortAbove < 100))
      {
         Print("PARAM ERROR: HedgeRSILongBelow must be in (0,50), HedgeRSIShortAbove in (50,100)");
         ok = false;
      }
      if(!(HedgeMinRatio > 0 && HedgeMinRatio <= HedgeMaxRatio && HedgeMaxRatio < 1.0))
      {
         Print("PARAM ERROR: hedge ratios must satisfy 0 < Min <= Max < 1.0 (net position must not flip)");
         ok = false;
      }
      if(!(HedgeLegRatio > 0 && HedgeLegRatio <= HedgeMaxRatio))
      {
         Print("PARAM ERROR: HedgeLegRatio must be in (0, HedgeMaxRatio]");
         ok = false;
      }
      if(HedgeMaxLegs < 1 || HedgeCooldownMin < 0 || HedgeTakeProfitPct <= 0)
      {
         Print("PARAM ERROR: HedgeMaxLegs >= 1, HedgeCooldownMin >= 0, HedgeTakeProfitPct > 0 required");
         ok = false;
      }
   }

   return ok;
}

int OnInit()''')

# ---------------------------------------------------------------- init
rep('''      // true => the first flat tick clears any stale persisted basket state
      basketOpenPrev[i] = true;
''',
'''      // true => the first flat tick clears any stale persisted basket state
      basketOpenPrev[i] = true;

      HedgeInitState(i);
''')

rep('''         basketReduced[j] = (GlobalVariableGet(SymKey(j, "REDUCED")) > 0.5);
''',
'''         basketReduced[j] = (GlobalVariableGet(SymKey(j, "REDUCED")) > 0.5);
      HedgeLoadState(j);
''')

rep('''Print("MetalsGridConfluence v3.10 init. BotID=", BotID,''',
    '''Print("MetalsGridConfluence v4.10 init. BotID=", BotID,''')

rep('''" | MRP=", MRPEnabled, " | MRPShadow=", MRPShadowMode,''',
    '''" | MRP=", MRPEnabled, " | MRPShadow=", MRPShadowMode,
         " | Hedge=", HedgeEnabled, " | HedgeShadow=", HedgeShadowMode,
         " | HedgeMagic=", MagicBase + HEDGE_MAGIC_OFFSET, "+idx",''')

rep('''Print("MetalsGridConfluence v3 deinit. Reason=", reason);''',
    '''Print("MetalsGridConfluence v4 deinit. Reason=", reason);''')

# ---------------------------------------------------------------- halt release
rep('''      lastSigBar[i] = 0;
   }

   GlobalVariableSet(HaltKey(), 0);''',
'''      lastSigBar[i] = 0;
      HedgeResetEpisode(i);
   }

   GlobalVariableSet(HaltKey(), 0);''')

# ---------------------------------------------------------------- managed positions
rep('''      if(CountBasketOrders(Syms[i], MagicBase + i) > 0)
         return true;''',
'''      if(CountBasketOrders(Syms[i], MagicBase + i) > 0)
         return true;
      if(CountBasketOrders(Syms[i], HedgeMagic(i)) > 0)
         return true;''')

# ---------------------------------------------------------------- heartbeat
rep('''            " mrpState=", (int)mrpState[i],
            " | eq="''',
'''            " mrpState=", (int)mrpState[i],
            " hedgeState=", (int)hedgeState[i],
            " | eq="''')

# ---------------------------------------------------------------- ManageSymbol
rep('''   if(basketOpenPrev[idx])
      ResetBasketState(idx);
   basketOpenPrev[idx] = false;
''',
'''   if(basketOpenPrev[idx])
      ResetBasketState(idx);
   basketOpenPrev[idx] = false;

   // A hedge without an original basket is an orphan: close it, then clear the episode.
   if(HedgeOrphanCleanup(idx))
      return;
''')

# ---------------------------------------------------------------- ManageExistingBasket
rep('''   if(tpHit)
   {
      CloseBasket(sym, magic, "basket-TP");
      return;
   }
''',
'''   if(tpHit)
   {
      if(CloseBasket(sym, magic, "basket-TP"))
         HedgeOrphanCleanup(idx);
      return;
   }

   // 1b. Hedge / recovery layer (this instrument only).
   if(ManageHedge(idx, dir, legs, totLots, flt))
   {
      // The original basket was changed by compensation: refresh its parameters.
      if(!ScanBasketEx(sym, magic, dir, legs, totLots, avgPrice, lastPrice, flt, mixed))
         return;
   }
''')

rep('''   // 3. Reversal exit.
   if(MRPEnabled && st == MRP_EXIT_PENDING)
''',
'''   // 3. Reversal exit (held while hedge legs are open).
   bool hedgeHold = HedgeHolds(idx);
   if(MRPEnabled && st == MRP_EXIT_PENDING && hedgeHold)
      HedgeLog(idx, "mrp-hold", "MRP exit held: hedge episode in progress, score=" +
                                 IntegerToString(mrpScore[idx]));
   if(MRPEnabled && st == MRP_EXIT_PENDING && !hedgeHold)
''')

rep('''   bool reduceWanted = MRPEnabled && regOK && reg == 0 && !basketReduced[idx] &&''',
    '''   bool reduceWanted = MRPEnabled && regOK && reg == 0 && !basketReduced[idx] && !hedgeHold &&''')

rep('''   if(basketReduced[idx])
      return;

   if(RiskManagerEnabled)
   {
      double budget = GetRiskBudget();''',
'''   if(basketReduced[idx])
      return;
   if(HedgeBlocksAdds(idx))
      return;

   if(RiskManagerEnabled)
   {
      double budget = GetRiskBudget();''')

# ---------------------------------------------------------------- OpenLeg
rep('''   if(!RiskBudgetAllows(sym, magic, dir, lot))
      return false;

   if(LogOnly)''',
'''   // Hedge legs reduce the net risk: they skip the stress budget but still pass the margin guard.
   if(IsHedgeMagic(magic))
   {
      if(!MarginLimitAllows(lot, sym))
         return false;
   }
   else if(!RiskBudgetAllows(sym, magic, dir, lot))
      return false;

   if(LogOnly)''')

# ---------------------------------------------------------------- CloseBasket reset guard
rep('''      if(idx >= 0)
         ResetBasketState(idx);
      Print("CLOSE BASKET VERIFIED''',
'''      // Only the original basket resets the per-basket state; a hedge basket must not.
      if(idx >= 0 && magic == MagicBase + idx)
         ResetBasketState(idx);
      Print("CLOSE BASKET VERIFIED''')

# ---------------------------------------------------------------- kill-switch
rep('''   for(int i = 0; i < nSyms; i++)
   {
      if(!CloseBasket(Syms[i], MagicBase + i, "kill-switch"))
         allClosed = false;
   }''',
'''   for(int i = 0; i < nSyms; i++)
   {
      // Hedge first: the original basket returns to its un-hedged state, then it is closed too.
      if(!CloseBasket(Syms[i], HedgeMagic(i), "kill-switch-hedge"))
         allClosed = false;
      if(!CloseBasket(Syms[i], MagicBase + i, "kill-switch"))
         allClosed = false;
   }''')

# ---------------------------------------------------------------- persistence
rep('''      GlobalVariableSet(SymKey(i, "REDUCED"), basketReduced[i] ? 1 : 0);
''',
'''      GlobalVariableSet(SymKey(i, "REDUCED"), basketReduced[i] ? 1 : 0);
      HedgeSaveState(i);
''')

# ---------------------------------------------------------------- status
rep('''      " | mrpShadow=", (MRPShadowMode ? "1" : "0"));''',
'''      " | mrpShadow=", (MRPShadowMode ? "1" : "0"),
      " | hedge=", (HedgeEnabled ? "1" : "0"),
      " | hedgeShadow=", (HedgeShadowMode ? "1" : "0"));''')

rep('''         " reduced=", (basketReduced[i] ? "1" : "0"));''',
'''         " reduced=", (basketReduced[i] ? "1" : "0"),
         HedgeStatusStr(i));''')

# ---------------------------------------------------------------- hedge functions
rep('''//+------------------------------------------------------------------+
//| END OF FILE''',
funcs + '''//+------------------------------------------------------------------+
//| END OF FILE''')

with open(DST, "w", encoding="ascii", newline="\n") as f:
    f.write(t)
print("OK", len(t.splitlines()), "lines")
