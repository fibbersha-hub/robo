//+------------------------------------------------------------------+
//|                                       MetalsGridConfluence_v3.mq4 |
//|                                       Version 3.10 (bot signature)|
//|                                                                   |
//| Strategy logic (confluence regime, entry, grid, basket TP) is     |
//| unchanged from v1/v2.                                             |
//|                                                                   |
//| Protection layer rebuilt in v3:                                   |
//|  - Reversal (MRP) is evaluated PER INSTRUMENT from that           |
//|    instrument's own closed-bar data only. No cross-instrument     |
//|    coupling: the account budget only blocks adds, never triggers  |
//|    exits or state changes of other instruments.                   |
//|  - Score is reachable up to 100; exit threshold is validated at   |
//|    init (v2 exit at 85 was unreachable: max was 80).              |
//|  - Exit requires confirmation on N consecutive closed bars and    |
//|    has hysteresis on the way down.                                |
//|  - Stress risk uses MODE_TICKSIZE directly (v2 multiplied by      |
//|    POINT again, overstating risk by 1/POINT).                     |
//|  - Mixed-direction basket is flattened, not averaged.             |
//|  - Partial reduction closes least-loss legs first.                |
//|  - Close results are verified against trade and history lists.   |
//|  - Kill-switch has one close path; halt persists until cleared.   |
//|  - Persistent keys keep the v2 prefix, so a v2 halt is honoured.  |
//|                                                                   |
//| v3.10 additions (no change to trading logic):                     |
//|  - BotID: unique signature in every order comment, event line     |
//|    and status file. FilePrefix separates the status/event files   |
//|    of several bots running in one terminal.                       |
//|  - <FilePrefix>_events.txt: OPEN / CLOSE / REDUCE event log.      |
//|  - Default InpSymbols narrowed to XAUUSD,XAGUSD.                  |
//+------------------------------------------------------------------+
#property copyright "fx_research"
#property version   "3.10"
#property strict

enum ENUM_CONFLUENCE_MODE
{
   MODE_2TF_WD_EMA100 = 0,
   MODE_3TF_MWD       = 1,
   MODE_4TF_QMWD      = 2
};

enum ENUM_RISK_LEVEL
{
   RISK_NORMAL      = 0,
   RISK_ELEVATED    = 1,
   RISK_CRITICAL    = 2,
   RISK_EXTREME     = 3,
   RISK_EXCEEDED    = 4,
   RISK_UNAVAILABLE = 5
};

enum ENUM_MRP_STATE
{
   MRP_NORMAL       = 0,
   MRP_WARNING      = 1,
   MRP_DEFENSIVE    = 2,
   MRP_EXIT_PENDING = 3
};

//====================================================================
// STRATEGY INPUTS (unchanged)
//====================================================================

input string  InpSymbols        = "XAUUSD,XAGUSD";
input double  GridStepPct       = 0.40;
input int     MaxLegs           = 7;
input double  MartingaleMult    = 1.3;
input double  TakeProfitPct     = 0.20;
input int     EMAPeriod         = 200;
input int     RSIPeriod         = 14;
input double  BuyRSIlo          = 50.0;
input double  BuyRSIhi          = 68.0;
input double  SellRSIlo         = 32.0;
input double  SellRSIhi         = 50.0;
input ENUM_TIMEFRAMES SignalTF  = PERIOD_M15;
input ENUM_CONFLUENCE_MODE ConfluenceMode = MODE_2TF_WD_EMA100;
input int     D1EMAPeriod       = 100;
input int     WinQ              = 63;
input double  ThrQ              = 0.5;
input int     WinM              = 21;
input double  ThrM              = 0.5;
input int     WinW              = 5;
input double  ThrW              = 0.5;
input int     WinD              = 3;
input double  ThrD              = 0.3;
input int     VolWin            = 63;
input bool    AllowShort        = true;

//==== sizing / plumbing
input bool    UseFixedLot       = true;
input double  FixedLot          = 0.06;
input double  RiskFrac          = 0.06;
input int     MagicBase         = 770000; // unique per bot; keep bots >= 100 apart (magic = MagicBase + symbol index)
input string  BotID             = "MGC1"; // unique bot signature, 1-8 chars A-Z a-z 0-9 _ (stamped into every order comment)
input string  FilePrefix        = "mgc";  // status/event files: <prefix>_status.txt, <prefix>_events.txt (unique per bot in one terminal)
input int     Slippage          = 30;
input bool    LogOnly           = false;
input int     MaxSymbols        = 12;
input int     MaxSpreadPoints   = 0;      // entries and adds blocked above this spread; 0 = off
input int     HeartbeatSec      = 3600;

//==== kill-switch
input double  KillSwitchDDpct   = 25.0;
// After a kill-switch the book is closed; the halt is released automatically once it is flat.
input bool    AutoResumeAfterHalt = true;
// Drawdown built within FastDDHours of the equity peak = fast move: pause FastPauseHours
// (indicators stay live, no orders). Slower drawdown: no pause, resume as soon as flat.
input int     FastDDHours       = 24;
input int     FastPauseHours    = 24;

//==== account risk budget
input bool    RiskManagerEnabled    = true;
input double  RiskBalanceCap        = 20000.0;
input double  MaxRiskPercent        = 40.0;
input int     RiskATRPeriod         = 14;
input double  RiskATRMultiplier     = 3.0;
input double  RiskLevelNormalMax    = 50.0;
input double  RiskLevelElevatedMax  = 75.0;
input double  RiskLevelCriticalMax  = 90.0;
input double  RiskLevelExtremeMax   = 100.0;
input double  GridBlockRiskPercent  = 75.0;

input bool    MarginGuardEnabled    = true;
input double  MaxMarginUsagePercent = 70.0;

//==== reversal protection (evaluated per instrument)
input bool    MRPEnabled                = true;
input bool    MRPShadowMode             = false;  // true = log only (diagnostics); false = protection acts on orders
input int     MRPWarningScore           = 35;
input int     MRPDefensiveScore         = 55;
input int     MRPExitScore              = 75;
input int     MRPHysteresis             = 5;      // score must fall this far below a level to leave it
input int     MRPExitConfirmBars        = 2;      // consecutive closed bars at exit score
input int     MRPReassessmentDays       = 5;
input double  MRPSidewaysReductionPct   = 10.0;
input int     MRPReductionIntervalHours = 24;
input bool    MRPBlockGridInWarning     = true;
input int     MRPOppositeRegimePoints   = 40;
input int     MRPSidewaysPoints         = 20;
input int     MRPEmaBreakPoints         = 15;
input int     MRPRsiPoints              = 10;
input double  MRPRsiLongBelow           = 45.0;
input double  MRPRsiShortAbove          = 55.0;
input int     MRPAdverse1ATRPoints      = 10;
input int     MRPAdverse2ATRPoints      = 10;

//==== execution
input int     TimerSeconds      = 10;
input int     CloseRetryCount   = 5;
input int     CloseRetryDelayMs = 500;
input bool    EnableDetailedLogs = true;

//====================================================================
// STATE (all per-instrument arrays are indexed by symbol index)
//====================================================================

string   Syms[];
int      nSyms = 0;

datetime regimeDay[];
int      regimeVal[];
bool     regimeOK[];
datetime lastSigBar[];
datetime shadowBar[];

ENUM_MRP_STATE mrpState[];
int            mrpScore[];
int            mrpExitCount[];
datetime       mrpEvalBar[];
int            mrpEvalLegs[];

datetime basketFirstOpen[];
datetime basketLastReduction[];
datetime basketLastAssessment[];
bool     basketReduced[];
bool     basketMixedDirection[];
bool     basketOpenPrev[];

double   gPeakEquity        = 0.0;
bool     gHalted            = false;
bool     gKillClosePending  = false;
datetime gLastHeartbeat     = 0;
datetime gLastPeriodic      = 0;
datetime gLastRiskLog       = 0;
datetime gPeakTime          = 0;   // when the equity peak was set
datetime gPauseUntil        = 0;   // no trading before this time after a fast kill-switch

//====================================================================
// KEYS
//====================================================================

// Same prefix as v2 on purpose: a halt set by v2 must be honoured by v3.
string AccountPrefix()
{
   return StringFormat("MGC_%d_%d", AccountNumber(), MagicBase);
}

string HaltKey() { return AccountPrefix() + "_HALTED"; }
string PeakKey()     { return AccountPrefix() + "_PEAKEQ"; }
string PeakTimeKey() { return AccountPrefix() + "_PEAKTIME"; }
string PauseKey()    { return AccountPrefix() + "_PAUSEUNTIL"; }

string SymKey(int idx, string suffix)
{
   return AccountPrefix() + "_" + Syms[idx] + "_" + suffix;
}

//====================================================================
// BOT SIGNATURE AND EVENT LOG
//====================================================================

bool NameCharsOK(string s, int maxLen)
{
   int n = StringLen(s);
   if(n < 1 || n > maxLen)
      return false;
   for(int i = 0; i < n; i++)
   {
      int c = StringGetChar(s, i);
      bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                (c >= '0' && c <= '9') || c == '_';
      if(!ok)
         return false;
   }
   return true;
}

// MT4 order comments are limited to 31 characters.
string OrderCommentFor(string tag)
{
   return StringSubstr(BotID + ":" + tag, 0, 31);
}

// Appends one line to <FilePrefix>_events.txt (read by the host watchdog).
void LogEvent(string text)
{
   string line = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + " | " + BotID + " | " + text +
                 " | balance=" + DoubleToString(AccountBalance(), 2) +
                 " equity=" + DoubleToString(AccountEquity(), 2);
   int h = FileOpen(FilePrefix + "_events.txt",
                    FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
      return;
   FileSeek(h, 0, SEEK_END);
   FileWrite(h, line);
   FileClose(h);
}

void SnapshotBasket(string sym, int magic, int &legs, double &lots, int &dir, int &tk[])
{
   legs = 0;
   lots = 0;
   dir = 0;
   ArrayResize(tk, 0);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != sym || OrderMagicNumber() != magic) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      legs++;
      lots += OrderLots();
      dir = (OrderType() == OP_BUY) ? 1 : -1;
      ArrayResize(tk, legs);
      tk[legs - 1] = OrderTicket();
   }
}

double RealizedProfit(int &tk[])
{
   double p = 0;
   for(int i = 0; i < ArraySize(tk); i++)
   {
      if(OrderSelect(tk[i], SELECT_BY_TICKET, MODE_HISTORY))
         p += OrderProfit() + OrderSwap() + OrderCommission();
   }
   return p;
}

//====================================================================
// INIT / DEINIT
//====================================================================

void ResizeStateArrays(int n)
{
   ArrayResize(regimeDay, n);
   ArrayResize(regimeVal, n);
   ArrayResize(regimeOK, n);
   ArrayResize(lastSigBar, n);
   ArrayResize(shadowBar, n);

   ArrayResize(mrpState, n);
   ArrayResize(mrpScore, n);
   ArrayResize(mrpExitCount, n);
   ArrayResize(mrpEvalBar, n);
   ArrayResize(mrpEvalLegs, n);

   ArrayResize(basketFirstOpen, n);
   ArrayResize(basketLastReduction, n);
   ArrayResize(basketLastAssessment, n);
   ArrayResize(basketReduced, n);
   ArrayResize(basketMixedDirection, n);
   ArrayResize(basketOpenPrev, n);
}

bool ValidateParams()
{
   bool ok = true;

   if(!NameCharsOK(BotID, 8))
   {
      Print("PARAM ERROR: BotID must be 1-8 chars from A-Z a-z 0-9 _");
      ok = false;
   }
   if(!NameCharsOK(FilePrefix, 16))
   {
      Print("PARAM ERROR: FilePrefix must be 1-16 chars from A-Z a-z 0-9 _");
      ok = false;
   }

   if(GridStepPct <= 0 || MaxLegs < 1 || MartingaleMult < 1.0 || TakeProfitPct <= 0)
   {
      Print("PARAM ERROR: grid / take-profit parameters out of range");
      ok = false;
   }
   if(KillSwitchDDpct <= 0 || KillSwitchDDpct >= 100)
   {
      Print("PARAM ERROR: KillSwitchDDpct must be in (0,100)");
      ok = false;
   }
   if(MaxRiskPercent <= 0 || MaxRiskPercent > 100)
   {
      Print("PARAM ERROR: MaxRiskPercent must be in (0,100]");
      ok = false;
   }
   if(RiskATRPeriod < 2 || RiskATRMultiplier <= 0)
   {
      Print("PARAM ERROR: ATR period / multiplier invalid");
      ok = false;
   }
   if(!(RiskLevelNormalMax <= RiskLevelElevatedMax &&
        RiskLevelElevatedMax <= RiskLevelCriticalMax &&
        RiskLevelCriticalMax <= RiskLevelExtremeMax))
   {
      Print("PARAM ERROR: risk level boundaries must be non-decreasing");
      ok = false;
   }
   if(GridBlockRiskPercent <= 0)
   {
      Print("PARAM ERROR: GridBlockRiskPercent must be > 0");
      ok = false;
   }
   if(MaxMarginUsagePercent <= 0 || MaxMarginUsagePercent > 100)
   {
      Print("PARAM ERROR: MaxMarginUsagePercent must be in (0,100]");
      ok = false;
   }

   if(!(MRPWarningScore > 0 &&
        MRPWarningScore < MRPDefensiveScore &&
        MRPDefensiveScore < MRPExitScore &&
        MRPExitScore <= 100))
   {
      Print("PARAM ERROR: MRP thresholds must satisfy 0 < Warning < Defensive < Exit <= 100");
      ok = false;
   }
   if(MRPHysteresis < 0 || MRPHysteresis >= MRPWarningScore)
   {
      Print("PARAM ERROR: MRPHysteresis must be in [0, MRPWarningScore)");
      ok = false;
   }
   if(MRPExitConfirmBars < 1)
   {
      Print("PARAM ERROR: MRPExitConfirmBars must be >= 1");
      ok = false;
   }

   // Reachability: the exit score must be attainable at all.
   // Opposite regime path: opposite + EMA + RSI + adverse1 + adverse2.
   int maxOpposite = MRPOppositeRegimePoints + MRPEmaBreakPoints + MRPRsiPoints +
                     MRPAdverse1ATRPoints + MRPAdverse2ATRPoints;
   // Sideways path cannot be an exit by design: sideways -> reduction only.
   int maxSideways = MRPSidewaysPoints + MRPEmaBreakPoints + MRPRsiPoints +
                     MRPAdverse1ATRPoints + MRPAdverse2ATRPoints;

   Print("MRP reachability: max score with opposite regime=", maxOpposite,
         " | max score sideways=", maxSideways,
         " | exit threshold=", MRPExitScore);

   if(maxOpposite < MRPExitScore)
   {
      Print("PARAM ERROR: MRPExitScore is unreachable even with opposite regime");
      ok = false;
   }
   if(maxSideways >= MRPExitScore)
   {
      Print("PARAM ERROR: sideways alone can reach the exit score. Exit would not require an opposite regime");
      ok = false;
   }

   return ok;
}

int OnInit()
{
   if(!ValidateParams())
      return(INIT_PARAMETERS_INCORRECT);

   if(!BuildSymbolList())
   {
      Print("FATAL: no tradable metals found. Set InpSymbols manually.");
      return(INIT_FAILED);
   }

   ResizeStateArrays(nSyms);

   for(int i = 0; i < nSyms; i++)
   {
      regimeDay[i] = 0;
      regimeVal[i] = 0;
      regimeOK[i] = false;
      lastSigBar[i] = 0;
      shadowBar[i] = 0;

      mrpState[i] = MRP_NORMAL;
      mrpScore[i] = 0;
      mrpExitCount[i] = 0;
      mrpEvalBar[i] = 0;
      mrpEvalLegs[i] = -1;

      basketFirstOpen[i] = 0;
      basketLastReduction[i] = 0;
      basketLastAssessment[i] = 0;
      basketReduced[i] = false;
      basketMixedDirection[i] = false;
      // true => the first flat tick clears any stale persisted basket state
      basketOpenPrev[i] = true;
   }

   // The persisted peak is kept across restarts, so a restart inside a drawdown
   // does not hide it. It is reset only when a halt is released.
   gPeakEquity = AccountEquity();
   if(GlobalVariableCheck(PeakKey()))
      gPeakEquity = GlobalVariableGet(PeakKey());
   gPeakTime = TimeCurrent();
   if(GlobalVariableCheck(PeakTimeKey()))
      gPeakTime = (datetime)GlobalVariableGet(PeakTimeKey());

   gHalted = false;
   if(GlobalVariableCheck(HaltKey()))
      gHalted = (GlobalVariableGet(HaltKey()) > 0.5);
   gPauseUntil = 0;
   if(GlobalVariableCheck(PauseKey()))
      gPauseUntil = (datetime)GlobalVariableGet(PauseKey());

   if(gHalted)
      Print("WARNING: halt restored. Pause until ", TimeToString(gPauseUntil),
            " | auto-resume when flat=", (AutoResumeAfterHalt ? "1" : "0"));

   for(int j = 0; j < nSyms; j++)
   {
      if(GlobalVariableCheck(SymKey(j, "MRP")))
         mrpState[j] = (ENUM_MRP_STATE)(int)GlobalVariableGet(SymKey(j, "MRP"));
      if(GlobalVariableCheck(SymKey(j, "FIRST")))
         basketFirstOpen[j] = (datetime)GlobalVariableGet(SymKey(j, "FIRST"));
      if(GlobalVariableCheck(SymKey(j, "REDUCE")))
         basketLastReduction[j] = (datetime)GlobalVariableGet(SymKey(j, "REDUCE"));
      if(GlobalVariableCheck(SymKey(j, "ASSESS")))
         basketLastAssessment[j] = (datetime)GlobalVariableGet(SymKey(j, "ASSESS"));
      if(GlobalVariableCheck(SymKey(j, "REDUCED")))
         basketReduced[j] = (GlobalVariableGet(SymKey(j, "REDUCED")) > 0.5);
   }

   Print("MetalsGridConfluence v3.10 init. BotID=", BotID, " | Magic=", MagicBase,
         " | Files=", FilePrefix, "_*.txt | Symbols(", nSyms, "): ", JoinSyms(),
         " | LogOnly=", LogOnly,
         " | MRP=", MRPEnabled, " | MRPShadow=", MRPShadowMode,
         " | Halted=", gHalted,
         " | Equity=", DoubleToString(AccountEquity(), 2), " ", AccountCurrency());

   Print("RISK BUDGET=", DoubleToString(GetRiskBudget(), 2),
         " | ATR=", RiskATRPeriod,
         " | ATR multiplier=", DoubleToString(RiskATRMultiplier, 2));

   for(int k = 0; k < nSyms; k++)
   {
      string s = Syms[k];
      Print("SPEC ", s,
            " contract=", DoubleToString(MarketInfo(s, MODE_LOTSIZE), 2),
            " minlot=", DoubleToString(MarketInfo(s, MODE_MINLOT), 2),
            " maxlot=", DoubleToString(MarketInfo(s, MODE_MAXLOT), 2),
            " lotstep=", DoubleToString(MarketInfo(s, MODE_LOTSTEP), 2),
            " digits=", DoubleToString(MarketInfo(s, MODE_DIGITS), 0),
            " tickval=", DoubleToString(MarketInfo(s, MODE_TICKVALUE), 4),
            " ticksize=", DoubleToString(MarketInfo(s, MODE_TICKSIZE), 5),
            " point=", DoubleToString(MarketInfo(s, MODE_POINT), 5),
            " spread=", DoubleToString(MarketInfo(s, MODE_SPREAD), 0),
            " marginReq=", DoubleToString(MarketInfo(s, MODE_MARGINREQUIRED), 2));
   }

   SavePersistentState();
   EventSetTimer(MathMax(1, TimerSeconds));
   PeriodicSave(true);

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   SavePersistentState();
   Print("MetalsGridConfluence v3 deinit. Reason=", reason);
}

void OnTick()  { ProcessEngine(); }
void OnTimer() { ProcessEngine(); }

//====================================================================
// MAIN ENGINE
//====================================================================

void ProcessEngine()
{
   CheckKillSwitch();

   if(gKillClosePending)
   {
      // Retry closing until flat. Nothing else happens while closing.
      if(HasManagedPositions())
         CloseAll();
      else
         gKillClosePending = false;
   }

   if(gHalted)
   {
      if(!gKillClosePending && TryReleaseHalt())
      {
         // Released: continue with normal processing below.
      }
      else
      {
         // Paused or waiting for flat: indicators stay live, no orders.
         EvaluateMarketOnly();
         PeriodicSave(false);
         return;
      }
   }

   Heartbeat();

   for(int j = 0; j < nSyms; j++)
      ManageSymbol(j);

   PeriodicSave(false);
}

// Releases the halt only when: AutoResume is on, the pause has elapsed, and no positions remain.
bool TryReleaseHalt()
{
   if(!AutoResumeAfterHalt)
      return false;
   if(TimeCurrent() < gPauseUntil)
      return false;
   if(HasManagedPositions())
      return false;

   gHalted = false;
   gKillClosePending = false;
   gPauseUntil = 0;
   gPeakEquity = AccountEquity();   // new baseline after the loss
   gPeakTime = TimeCurrent();

   for(int i = 0; i < nSyms; i++)
   {
      regimeDay[i] = 0;   // force regime recomputation
      lastSigBar[i] = 0;
   }

   GlobalVariableSet(HaltKey(), 0);
   GlobalVariableSet(PauseKey(), 0);
   GlobalVariableSet(PeakKey(), gPeakEquity);
   GlobalVariableSet(PeakTimeKey(), (double)gPeakTime);

   Print("HALT RELEASED: book flat, pause elapsed. New peak=", DoubleToString(gPeakEquity, 2));
   return true;
}

// Market is evaluated (regimes, indicators, heartbeat), no orders are placed.
void EvaluateMarketOnly()
{
   Heartbeat();
   for(int i = 0; i < nSyms; i++)
      GetRegime(i);
}

void PeriodicSave(bool force)
{
   if(!force && TimeCurrent() - gLastPeriodic < MathMax(1, TimerSeconds))
      return;

   gLastPeriodic = TimeCurrent();
   WriteStatus();
   SavePersistentState();
}

void Heartbeat()
{
   if(HeartbeatSec <= 0)
      return;
   if(TimeCurrent() - gLastHeartbeat < HeartbeatSec)
      return;

   gLastHeartbeat = TimeCurrent();

   for(int i = 0; i < nSyms; i++)
   {
      string s = Syms[i];
      int dg = (int)MarketInfo(s, MODE_DIGITS);
      int reg = GetRegime(i);

      Print("HB ", s,
            " regime=", reg,
            " regimeOK=", (regimeOK[i] ? "1" : "0"),
            " close1=", DoubleToString(iClose(s, SignalTF, 1), dg),
            " ema1=", DoubleToString(iMA(s, SignalTF, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1), dg),
            " rsi1=", DoubleToString(iRSI(s, SignalTF, RSIPeriod, PRICE_CLOSE, 1), 1),
            " mrpState=", (int)mrpState[i],
            " | eq=", DoubleToString(AccountEquity(), 2),
            " halted=", (gHalted ? "1" : "0"));
   }
}

//====================================================================
// KILL SWITCH - sets the flag only; ProcessEngine performs the closing
//====================================================================

void CheckKillSwitch()
{
   double eq = AccountEquity();

   if(eq > gPeakEquity)
   {
      gPeakEquity = eq;
      gPeakTime = TimeCurrent();
      GlobalVariableSet(PeakTimeKey(), (double)gPeakTime);
   }

   if(!gHalted && gPeakEquity > 0 &&
      (gPeakEquity - eq) / gPeakEquity >= KillSwitchDDpct / 100.0)
   {
      double dd = (gPeakEquity - eq) / gPeakEquity * 100.0;
      double hoursFromPeak = (double)(TimeCurrent() - gPeakTime) / 3600.0;

      gHalted = true;
      gKillClosePending = true;

      // Fast move: pause before any trading. Slow drawdown: no pause.
      if(hoursFromPeak <= FastDDHours)
         gPauseUntil = TimeCurrent() + FastPauseHours * 3600;
      else
         gPauseUntil = TimeCurrent();

      Print("!!! KILL-SWITCH !!! Equity DD ", DoubleToString(dd, 2),
            "% >= ", DoubleToString(KillSwitchDDpct, 2),
            "% | hours from peak=", DoubleToString(hoursFromPeak, 1),
            " | pause until ", TimeToString(gPauseUntil), " -> HALT + CLOSE ALL");

      GlobalVariableSet(HaltKey(), 1);
      GlobalVariableSet(PauseKey(), (double)gPauseUntil);
   }
}

bool HasManagedPositions()
{
   for(int i = 0; i < nSyms; i++)
   {
      if(CountBasketOrders(Syms[i], MagicBase + i) > 0)
         return true;
   }
   return false;
}

//====================================================================
// SYMBOL ENGINE
//====================================================================

void ManageSymbol(int idx)
{
   string sym = Syms[idx];
   int magic = MagicBase + idx;

   double bid = MarketInfo(sym, MODE_BID);
   double ask = MarketInfo(sym, MODE_ASK);
   if(bid <= 0 || ask <= 0)
      return;

   int dir = 0;
   int legs = 0;
   double totLots = 0, avgPrice = 0, lastPrice = 0, flt = 0;
   bool mixed = false;

   bool hasBasket = ScanBasketEx(sym, magic, dir, legs, totLots,
                                 avgPrice, lastPrice, flt, mixed);

   if(hasBasket)
   {
      basketOpenPrev[idx] = true;
      ManageExistingBasket(idx, dir, legs, totLots, avgPrice, lastPrice, flt, mixed);
      return;
   }

   if(basketOpenPrev[idx])
      ResetBasketState(idx);
   basketOpenPrev[idx] = false;

   if(gHalted || gKillClosePending)
      return;

   TryEntry(idx);
}

//--------------------------------------------------------------------
// Entry logic (unchanged signal definition, one evaluation per bar)
//--------------------------------------------------------------------

void TryEntry(int idx)
{
   string sym = Syms[idx];
   int magic = MagicBase + idx;

   datetime bt = iTime(sym, SignalTF, 0);
   if(bt <= 0 || bt == lastSigBar[idx])
      return;

   // Marked as evaluated before acting: a blocked attempt is not retried on every tick.
   lastSigBar[idx] = bt;

   if(MaxSpreadPoints > 0 && MarketInfo(sym, MODE_SPREAD) > MaxSpreadPoints)
      return;

   int reg = GetRegime(idx);
   if(!regimeOK[idx] || reg == 0)
      return;

   double ema = iMA(sym, SignalTF, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double rsi = iRSI(sym, SignalTF, RSIPeriod, PRICE_CLOSE, 0);
   double closePx = iClose(sym, SignalTF, 0);
   if(ema <= 0)
      return;

   if(reg > 0 && closePx > ema && rsi >= BuyRSIlo && rsi <= BuyRSIhi)
      OpenFirstLeg(idx, +1, magic, "entry-long");
   else if(AllowShort && reg < 0 && closePx < ema && rsi >= SellRSIlo && rsi <= SellRSIhi)
      OpenFirstLeg(idx, -1, magic, "entry-short");
}

void OpenFirstLeg(int idx, int dir, int magic, string tag)
{
   string sym = Syms[idx];
   double lot = NextLegLot(sym, idx, 0);

   if(OpenLeg(sym, dir, lot, magic, tag) && !LogOnly)
      RegisterBasketStart(idx);
}

//--------------------------------------------------------------------
// Existing basket: TP -> reversal (per instrument) -> reduction -> grid
//--------------------------------------------------------------------

void ManageExistingBasket(int idx, int dir, int legs, double totLots,
                          double avgPrice, double lastPrice, double flt, bool mixed)
{
   string sym = Syms[idx];
   int magic = MagicBase + idx;

   double bid = MarketInfo(sym, MODE_BID);
   double ask = MarketInfo(sym, MODE_ASK);

   if(basketFirstOpen[idx] <= 0)
   {
      datetime first = FindFirstBasketOpen(sym, magic);
      if(first > 0)
      {
         basketFirstOpen[idx] = first;
         GlobalVariableSet(SymKey(idx, "FIRST"), (double)first);
      }
   }

   // 0. Structural integrity: a mixed basket cannot be averaged or managed.
   if(mixed)
   {
      basketMixedDirection[idx] = true;
      Print("CRITICAL: mixed-direction basket on ", sym, " -> flattening");
      CloseBasket(sym, magic, "mixed-direction");
      return;
   }

   // 1. Basket take-profit (unchanged rule).
   double tpPrice = (dir > 0)
                    ? avgPrice * (1.0 + TakeProfitPct / 100.0)
                    : avgPrice * (1.0 - TakeProfitPct / 100.0);
   bool tpHit = (dir > 0) ? (bid >= tpPrice) : (ask <= tpPrice);
   if(tpHit)
   {
      CloseBasket(sym, magic, "basket-TP");
      return;
   }

   // 2. Reversal evaluation - this instrument only, closed bars only.
   EvaluateReversal(idx, dir, avgPrice, legs);
   ENUM_MRP_STATE st = mrpState[idx];

   // 3. Reversal exit.
   if(MRPEnabled && st == MRP_EXIT_PENDING)
   {
      if(MRPShadowMode)
      {
         ShadowLog(idx, "EXIT would close basket, score=" + IntegerToString(mrpScore[idx]));
      }
      else
      {
         Print("MRP EXIT ", sym, " score=", mrpScore[idx]);
         CloseBasket(sym, magic, "MRP-exit");
         return;
      }
   }

   // 4. Sideways / age-based reduction (this instrument's regime only).
   int reg = GetRegime(idx);
   bool regOK = regimeOK[idx];
   int ageDays = BasketAgeDays(idx);
   UpdateBasketAgeAssessment(idx, ageDays);

   bool reduceWanted = MRPEnabled && regOK && reg == 0 && !basketReduced[idx] &&
                       (mrpScore[idx] >= MRPWarningScore || ageDays >= MRPReassessmentDays);
   if(reduceWanted)
   {
      if(MRPShadowMode)
         ShadowLog(idx, "would reduce basket, score=" + IntegerToString(mrpScore[idx]) +
                        " age=" + IntegerToString(ageDays));
      else
         ReduceBasketGradually(idx, sym, magic);
   }

   // 5. Grid additions.
   if(legs >= MaxLegs)
      return;
   if(basketReduced[idx])
      return;

   if(RiskManagerEnabled)
   {
      double budget = GetRiskBudget();
      double totalRisk = GetTotalOpenRisk();
      if(totalRisk < 0)
      {
         LogRiskBlock("risk data unavailable, no adds on " + sym);
         return;
      }
      double loadPct = (budget > 0) ? totalRisk / budget * 100.0 : 100.0;
      if(loadPct >= GridBlockRiskPercent)
      {
         LogRiskBlock("grid guard on " + sym + " load=" + DoubleToString(loadPct, 1) + "%");
         return;
      }
   }

   bool mrpBlocksAdds = MRPEnabled &&
                        (st >= MRP_DEFENSIVE || (st == MRP_WARNING && MRPBlockGridInWarning));
   if(mrpBlocksAdds)
   {
      if(!MRPShadowMode)
         return;
      ShadowLog(idx, "would block grid add, state=" + IntegerToString((int)st));
   }

   if(MaxSpreadPoints > 0 && MarketInfo(sym, MODE_SPREAD) > MaxSpreadPoints)
      return;

   double trig = (dir > 0)
                 ? lastPrice * (1.0 - GridStepPct / 100.0)
                 : lastPrice * (1.0 + GridStepPct / 100.0);
   bool add = (dir > 0) ? (ask <= trig) : (bid >= trig);
   if(!add)
      return;

   double lot = NextLegLot(sym, idx, legs);
   OpenLeg(sym, dir, lot, magic, StringFormat("grid-add leg%d", legs + 1));
}

//====================================================================
// REVERSAL (MRP) - per instrument, closed bars, hysteresis
//====================================================================

int ThresholdOf(ENUM_MRP_STATE s)
{
   if(s == MRP_EXIT_PENDING) return MRPExitScore;
   if(s == MRP_DEFENSIVE)    return MRPDefensiveScore;
   if(s == MRP_WARNING)      return MRPWarningScore;
   return 0;
}

void EvaluateReversal(int idx, int dir, double avgPrice, int legs)
{
   if(!MRPEnabled)
   {
      SetMRPState(idx, MRP_NORMAL);
      return;
   }

   string sym = Syms[idx];

   datetime bt = iTime(sym, SignalTF, 1);   // last CLOSED signal bar
   if(bt <= 0)
      return;
   if(bt == mrpEvalBar[idx] && legs == mrpEvalLegs[idx])
      return;

   bool newBar = (bt != mrpEvalBar[idx]);

   int reg = GetRegime(idx);
   if(!regimeOK[idx])
      return;   // no data: keep the current state, make no decision

   double c = iClose(sym, SignalTF, 1);
   double ema = iMA(sym, SignalTF, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
   double rsi = iRSI(sym, SignalTF, RSIPeriod, PRICE_CLOSE, 1);
   double atr = iATR(sym, PERIOD_D1, RiskATRPeriod, 1);
   if(c <= 0 || ema <= 0 || atr <= 0)
      return;

   int score = 0;

   if(reg != 0 && reg != dir)
      score += MRPOppositeRegimePoints;
   if(reg == 0)
      score += MRPSidewaysPoints;

   if((dir > 0 && c < ema) || (dir < 0 && c > ema))
      score += MRPEmaBreakPoints;

   if((dir > 0 && rsi < MRPRsiLongBelow) || (dir < 0 && rsi > MRPRsiShortAbove))
      score += MRPRsiPoints;

   double adverse = (dir > 0) ? (avgPrice - c) : (c - avgPrice);
   if(adverse >= atr)
      score += MRPAdverse1ATRPoints;
   if(adverse >= 2.0 * atr)
      score += MRPAdverse2ATRPoints;

   if(score > 100)
      score = 100;

   mrpScore[idx] = score;
   mrpEvalBar[idx] = bt;
   mrpEvalLegs[idx] = legs;

   ENUM_MRP_STATE target = MRP_NORMAL;
   if(score >= MRPExitScore)           target = MRP_EXIT_PENDING;
   else if(score >= MRPDefensiveScore) target = MRP_DEFENSIVE;
   else if(score >= MRPWarningScore)   target = MRP_WARNING;

   // Exit requires consecutive closed bars at exit score.
   if(target == MRP_EXIT_PENDING)
   {
      if(newBar)
         mrpExitCount[idx]++;
      if(mrpExitCount[idx] < MRPExitConfirmBars)
         target = MRP_DEFENSIVE;
   }
   else if(newBar)
   {
      mrpExitCount[idx] = 0;
   }

   // Hysteresis: leaving a level needs the score to fall below its threshold minus margin.
   ENUM_MRP_STATE cur = mrpState[idx];
   ENUM_MRP_STATE next = target;
   if(target < cur && score >= ThresholdOf(cur) - MRPHysteresis)
      next = cur;

   SetMRPState(idx, next);
}

void SetMRPState(int idx, ENUM_MRP_STATE newState)
{
   if(mrpState[idx] == newState)
      return;

   Print("MRP STATE ", Syms[idx], " ", (int)mrpState[idx], " -> ", (int)newState,
         " score=", mrpScore[idx]);

   mrpState[idx] = newState;
   GlobalVariableSet(SymKey(idx, "MRP"), (double)newState);
}

void ShadowLog(int idx, string msg)
{
   datetime b = iTime(Syms[idx], SignalTF, 1);
   if(b == shadowBar[idx])
      return;
   shadowBar[idx] = b;
   Print("[MRP SHADOW] ", Syms[idx], " ", msg);
}

//====================================================================
// BASKET AGE / STATE
//====================================================================

datetime FindFirstBasketOpen(string sym, int magic)
{
   datetime first = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != sym || OrderMagicNumber() != magic) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if(first == 0 || OrderOpenTime() < first)
         first = OrderOpenTime();
   }
   return first;
}

int BasketAgeDays(int idx)
{
   if(basketFirstOpen[idx] <= 0)
      return 0;
   return (int)((TimeCurrent() - basketFirstOpen[idx]) / 86400);
}

void RegisterBasketStart(int idx)
{
   basketFirstOpen[idx] = TimeCurrent();
   basketLastReduction[idx] = 0;
   basketLastAssessment[idx] = 0;
   basketReduced[idx] = false;
   GlobalVariableSet(SymKey(idx, "FIRST"), (double)basketFirstOpen[idx]);
   GlobalVariableSet(SymKey(idx, "REDUCED"), 0);
}

void UpdateBasketAgeAssessment(int idx, int age)
{
   if(age < MRPReassessmentDays)
      return;

   datetime now = TimeCurrent();
   if(basketLastAssessment[idx] > 0 && now - basketLastAssessment[idx] < 86400)
      return;

   basketLastAssessment[idx] = now;
   GlobalVariableSet(SymKey(idx, "ASSESS"), (double)now);
   Print("AGE REASSESSMENT ", Syms[idx], " age=", age, " days");
}

void ResetBasketState(int idx)
{
   basketFirstOpen[idx] = 0;
   basketLastReduction[idx] = 0;
   basketLastAssessment[idx] = 0;
   basketReduced[idx] = false;
   basketMixedDirection[idx] = false;

   mrpScore[idx] = 0;
   mrpState[idx] = MRP_NORMAL;
   mrpExitCount[idx] = 0;
   mrpEvalBar[idx] = 0;
   mrpEvalLegs[idx] = -1;

   if(GlobalVariableCheck(SymKey(idx, "FIRST")))
      GlobalVariableDel(SymKey(idx, "FIRST"));
   if(GlobalVariableCheck(SymKey(idx, "REDUCE")))
      GlobalVariableDel(SymKey(idx, "REDUCE"));
   if(GlobalVariableCheck(SymKey(idx, "ASSESS")))
      GlobalVariableDel(SymKey(idx, "ASSESS"));

   GlobalVariableSet(SymKey(idx, "REDUCED"), 0);
   GlobalVariableSet(SymKey(idx, "MRP"), 0);
}

//====================================================================
// GRADUAL REDUCTION - least-loss legs first
//====================================================================

void ReduceBasketGradually(int idx, string sym, int magic)
{
   if(basketReduced[idx])
      return;

   datetime now = TimeCurrent();
   if(basketLastReduction[idx] > 0 &&
      now - basketLastReduction[idx] < MRPReductionIntervalHours * 3600)
      return;

   int      tickets[];
   double   legLots[];
   double   pnlPerLot[];
   int      n = 0;
   double   total = 0;
   int      dir = 0;
   bool     mixed = false;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != sym || OrderMagicNumber() != magic) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

      int od = (OrderType() == OP_BUY) ? 1 : -1;
      if(dir == 0) dir = od;
      else if(dir != od) mixed = true;

      double lots = OrderLots();
      if(lots <= 0) continue;

      double pnl = OrderProfit() + OrderSwap() + OrderCommission();

      n++;
      ArrayResize(tickets, n);
      ArrayResize(legLots, n);
      ArrayResize(pnlPerLot, n);
      tickets[n - 1] = OrderTicket();
      legLots[n - 1] = lots;
      pnlPerLot[n - 1] = pnl / lots;
      total += lots;
   }

   if(n == 0 || mixed)
      return;

   double minLot = MarketInfo(sym, MODE_MINLOT);
   double target = NormalizeLotsDown(sym, total * MRPSidewaysReductionPct / 100.0);

   if(target < minLot)
   {
      Print("MRP REDUCTION SKIPPED: target below minimum ", sym);
      basketLastReduction[idx] = now;
      GlobalVariableSet(SymKey(idx, "REDUCE"), (double)now);
      return;
   }

   if(LogOnly)
   {
      Print("[LOGONLY] MRP REDUCTION ", sym, " target=", DoubleToString(target, 4));
      return;
   }

   bool used[];
   ArrayResize(used, n);
   for(int k = 0; k < n; k++)
      used[k] = false;

   double remaining = target;
   double closed = 0;
   bool failed = false;

   for(int round = 0; round < n; round++)
   {
      if(remaining < minLot)
         break;

      // Least loss per lot first (highest pnl per lot).
      int best = -1;
      for(int k = 0; k < n; k++)
      {
         if(!used[k] && (best < 0 || pnlPerLot[k] > pnlPerLot[best]))
            best = k;
      }
      if(best < 0)
         break;

      used[best] = true;

      double vol = NormalizeLotsDown(sym, MathMin(legLots[best], remaining));
      // Avoid leaving an unclosable dust remainder on the leg.
      if(legLots[best] - vol > 0 && legLots[best] - vol < minLot)
         vol = legLots[best];
      if(vol < minLot)
         continue;

      if(ClosePartialTicket(tickets[best], vol))
      {
         closed += vol;
         remaining -= vol;
         LogEvent("REDUCE " + sym + " " + DoubleToString(vol, 2) + " lots (MRP)");
      }
      else
      {
         failed = true;
      }
   }

   basketLastReduction[idx] = now;
   GlobalVariableSet(SymKey(idx, "REDUCE"), (double)now);

   if(closed > 0)
   {
      basketReduced[idx] = true;
      GlobalVariableSet(SymKey(idx, "REDUCED"), 1);
      Print("MRP REDUCTION DONE ", sym,
            " closed=", DoubleToString(closed, 4),
            " target=", DoubleToString(target, 4),
            (failed ? " (partial failures)" : ""),
            ". Grid additions disabled for this basket.");
   }
   else
   {
      Print("MRP REDUCTION FAILED ", sym, ". Retry after interval.");
   }
}

//====================================================================
// REGIME (confluence) - unchanged logic, plus data-availability flag
//====================================================================

int GetRegime(int idx)
{
   string sym = Syms[idx];
   datetime d1 = iTime(sym, PERIOD_D1, 0);

   if(d1 > 0 && d1 == regimeDay[idx])
      return regimeVal[idx];

   bool ok = false;
   int r = ComputeRegime(sym, ok);

   regimeVal[idx] = r;
   regimeOK[idx] = ok;
   if(ok)
      regimeDay[idx] = d1;   // cache only valid results

   return r;
}

int ComputeRegime(string sym, bool &ok)
{
   ok = false;

   int need = MathMax(MathMax(VolWin + 2, WinQ + 2), D1EMAPeriod + 2);
   if(iBars(sym, PERIOD_D1) < need)
      return 0;

   double vol = DailyVol(sym, VolWin);
   if(vol <= 0)
      return 0;

   double c1 = iClose(sym, PERIOD_D1, 1);
   if(c1 <= 0)
      return 0;

   int dw = ZDir(sym, WinW, vol, ThrW);
   int dd = ZDir(sym, WinD, vol, ThrD);

   if(ConfluenceMode == MODE_2TF_WD_EMA100)
   {
      double ema = iMA(sym, PERIOD_D1, D1EMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
      if(ema <= 0)
         return 0;

      ok = true;
      int dema = (c1 > ema) ? 1 : ((c1 < ema) ? -1 : 0);
      if(dw != 0 && dw == dd && dd == dema)
         return dw;
      return 0;
   }
   else if(ConfluenceMode == MODE_3TF_MWD)
   {
      int dm = ZDir(sym, WinM, vol, ThrM);
      ok = true;
      if(dm != 0 && dm == dw && dw == dd)
         return dm;
      return 0;
   }
   else if(ConfluenceMode == MODE_4TF_QMWD)
   {
      int dq = ZDir(sym, WinQ, vol, ThrQ);
      int dm = ZDir(sym, WinM, vol, ThrM);
      ok = true;
      if(dq != 0 && dq == dm && dm == dw && dw == dd)
         return dq;
      return 0;
   }

   return 0;
}

int ZDir(string sym, int win, double vol, double thr)
{
   double c1 = iClose(sym, PERIOD_D1, 1);
   double cw = iClose(sym, PERIOD_D1, 1 + win);
   if(c1 <= 0 || cw <= 0)
      return 0;

   double ret = c1 / cw - 1.0;
   double z = ret / (vol * MathSqrt((double)win));

   if(z > thr)  return 1;
   if(z < -thr) return -1;
   return 0;
}

string RegimeDetail(string sym)
{
   double vol = DailyVol(sym, VolWin);
   if(vol <= 0)
      return "nodata";

   int dw = ZDir(sym, WinW, vol, ThrW);
   int dd = ZDir(sym, WinD, vol, ThrD);
   double c1 = iClose(sym, PERIOD_D1, 1);
   double ema = iMA(sym, PERIOD_D1, D1EMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
   int dema = (c1 > ema) ? 1 : ((c1 < ema) ? -1 : 0);
   int dm = ZDir(sym, WinM, vol, ThrM);
   int dq = ZDir(sym, WinQ, vol, ThrQ);

   if(ConfluenceMode == MODE_2TF_WD_EMA100)
      return StringConcatenate("W=", dw, " D=", dd, " EMA100=", dema, " [M=", dm, " Q=", dq, "]");
   if(ConfluenceMode == MODE_3TF_MWD)
      return StringConcatenate("M=", dm, " W=", dw, " D=", dd, " [EMA100=", dema, " Q=", dq, "]");
   return StringConcatenate("Q=", dq, " M=", dm, " W=", dw, " D=", dd, " [EMA100=", dema, "]");
}

double DailyVol(string sym, int n)
{
   double r[];
   ArrayResize(r, n);

   int m = 0;
   for(int i = 1; i <= n; i++)
   {
      double a = iClose(sym, PERIOD_D1, i);
      double b = iClose(sym, PERIOD_D1, i + 1);
      if(a > 0 && b > 0)
      {
         r[m] = a / b - 1.0;
         m++;
      }
   }

   if(m < 5)
      return 0.0;

   double mean = 0;
   for(int k = 0; k < m; k++)
      mean += r[k];
   mean /= m;

   double v = 0;
   for(int j = 0; j < m; j++)
      v += (r[j] - mean) * (r[j] - mean);
   v /= m;

   return MathSqrt(v);
}

//====================================================================
// RISK - stress per lot uses the correct tick units
//====================================================================

// Stress loss per 1.0 lot if price moves RiskATRMultiplier*ATR against the position.
// MODE_TICKSIZE is already in price units. v2 multiplied it by MODE_POINT again.
double StressRiskPerLot(string sym)
{
   double atr = iATR(sym, PERIOD_D1, RiskATRPeriod, 1);
   double tickSize = MarketInfo(sym, MODE_TICKSIZE);
   double tickValue = MarketInfo(sym, MODE_TICKVALUE);

   if(atr <= 0 || tickSize <= 0 || tickValue <= 0)
      return -1;

   double stressDist = atr * RiskATRMultiplier;
   return stressDist / tickSize * tickValue;
}

double GetRiskBudget()
{
   double base = MathMin(AccountBalance(), RiskBalanceCap);
   if(base < 0)
      base = 0;
   return base * MaxRiskPercent / 100.0;
}

// Sum of stress losses over all managed positions. -1 if any symbol with exposure lacks data.
double GetTotalOpenRisk()
{
   double total = 0;
   for(int i = 0; i < nSyms; i++)
   {
      double r = GetSymbolRisk(Syms[i], MagicBase + i);
      if(r < 0)
         return -1;
      total += r;
   }
   return total;
}

double GetSymbolRisk(string sym, int magic)
{
   double lots = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != sym || OrderMagicNumber() != magic) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      lots += OrderLots();
   }

   if(lots <= 0)
      return 0;

   double perLot = StressRiskPerLot(sym);
   if(perLot < 0)
      return -1;

   return perLot * lots;
}

ENUM_RISK_LEVEL GetRiskLevel(double loadPct, double riskValue)
{
   if(riskValue < 0)                  return RISK_UNAVAILABLE;
   if(GetRiskBudget() <= 0)           return RISK_EXCEEDED;
   if(loadPct > RiskLevelExtremeMax)  return RISK_EXCEEDED;
   if(loadPct >= RiskLevelCriticalMax) return RISK_EXTREME;
   if(loadPct >= RiskLevelElevatedMax) return RISK_CRITICAL;
   if(loadPct >= RiskLevelNormalMax)   return RISK_ELEVATED;
   return RISK_NORMAL;
}

string RiskLevelName(ENUM_RISK_LEVEL level)
{
   if(level == RISK_NORMAL)   return "NORMAL";
   if(level == RISK_ELEVATED) return "ELEVATED";
   if(level == RISK_CRITICAL) return "CRITICAL";
   if(level == RISK_EXTREME)  return "EXTREME";
   if(level == RISK_EXCEEDED) return "EXCEEDED";
   return "UNAVAILABLE";
}

void LogRiskBlock(string msg)
{
   if(!EnableDetailedLogs)
      return;
   if(TimeCurrent() - gLastRiskLog < 300)
      return;
   gLastRiskLog = TimeCurrent();
   Print("RISK GUARD: ", msg);
}

// Permission for a new order: margin always, account stress budget when enabled.
bool RiskBudgetAllows(string sym, int magic, int dir, double lot)
{
   if(!MarginLimitAllows(lot, sym))
      return false;

   if(!RiskManagerEnabled)
      return true;

   double budget = GetRiskBudget();
   double current = GetTotalOpenRisk();
   double perLot = StressRiskPerLot(sym);

   if(current < 0 || perLot < 0)
   {
      LogRiskBlock("risk data unavailable, order blocked on " + sym);
      return false;
   }

   double projected = current + perLot * lot;
   if(projected > budget)
   {
      LogRiskBlock("budget exceeded on " + sym +
                   " current=" + DoubleToString(current, 2) +
                   " proposed=" + DoubleToString(perLot * lot, 2) +
                   " budget=" + DoubleToString(budget, 2));
      return false;
   }

   return true;
}

bool MarginLimitAllows(double lot, string sym)
{
   if(!MarginGuardEnabled)
      return true;

   double equity = AccountEquity();
   if(equity <= 0)
      return false;

   double marginRequired = MarketInfo(sym, MODE_MARGINREQUIRED);
   if(marginRequired <= 0)
   {
      LogRiskBlock("margin requirement unavailable: " + sym);
      return false;
   }

   double projectedMargin = AccountMargin() + marginRequired * lot;
   double usage = projectedMargin / equity * 100.0;

   if(usage >= MaxMarginUsagePercent)
   {
      LogRiskBlock("margin guard on " + sym + " usage=" + DoubleToString(usage, 2) + "%");
      return false;
   }

   return true;
}

//====================================================================
// SIZING
//====================================================================

double NextLegLot(string sym, int idx, int legIndex)
{
   double base;

   if(UseFixedLot)
      base = FixedLot;
   else
   {
      double share = AccountEquity() / MathMax(1, nSyms);
      double price = MarketInfo(sym, MODE_ASK);
      double contract = MarketInfo(sym, MODE_LOTSIZE);
      double notionalPerLot = price * contract;
      base = (notionalPerLot > 0) ? (share * RiskFrac) / notionalPerLot : FixedLot;
   }

   double lot = base * MathPow(MartingaleMult, legIndex);
   return NormalizeLot(sym, lot);
}

int LotDigits(string sym)
{
   double step = MarketInfo(sym, MODE_LOTSTEP);
   if(step >= 1.0)   return 0;
   if(step >= 0.1)   return 1;
   if(step >= 0.01)  return 2;
   if(step >= 0.001) return 3;
   return 4;
}

double NormalizeLot(string sym, double lot)
{
   double minlot = MarketInfo(sym, MODE_MINLOT);
   double maxlot = MarketInfo(sym, MODE_MAXLOT);
   double step = MarketInfo(sym, MODE_LOTSTEP);
   if(step <= 0) step = 0.01;

   lot = MathRound(lot / step) * step;
   if(lot < minlot) lot = minlot;
   if(maxlot > 0 && lot > maxlot) lot = maxlot;

   return NormalizeDouble(lot, LotDigits(sym));
}

double NormalizeLotsDown(string sym, double lot)
{
   double step = MarketInfo(sym, MODE_LOTSTEP);
   if(step <= 0) step = 0.01;

   lot = MathFloor((lot + step * 0.000001) / step) * step;
   return NormalizeDouble(lot, LotDigits(sym));
}

//====================================================================
// ORDER EXECUTION
//====================================================================

bool IsRetryableError(int err)
{
   return (err == 135 || err == 136 || err == 138 || err == 146);
}

bool OpenLeg(string sym, int dir, double lot, int magic, string tag)
{
   if(gHalted || gKillClosePending)
      return false;
   if(lot <= 0)
      return false;
   if(!RiskBudgetAllows(sym, magic, dir, lot))
      return false;

   if(LogOnly)
   {
      double p = (dir > 0) ? MarketInfo(sym, MODE_ASK) : MarketInfo(sym, MODE_BID);
      Print("[LOGONLY] ", sym, " ", (dir > 0 ? "BUY" : "SELL"),
            " ", DoubleToString(lot, LotDigits(sym)),
            " @ ", DoubleToString(p, (int)MarketInfo(sym, MODE_DIGITS)),
            " (", tag, ")");
      return true;
   }

   if(!IsTradeAllowed())
   {
      Print("TRADE NOT ALLOWED by terminal, order skipped: ", sym);
      return false;
   }

   int type = (dir > 0) ? OP_BUY : OP_SELL;

   for(int attempt = 0; attempt < 3; attempt++)
   {
      double price = (dir > 0) ? MarketInfo(sym, MODE_ASK) : MarketInfo(sym, MODE_BID);
      if(price <= 0)
         return false;

      int digits = (int)MarketInfo(sym, MODE_DIGITS);

      ResetLastError();
      int ticket = OrderSend(sym, type, lot, NormalizeDouble(price, digits), Slippage,
                             0, 0, OrderCommentFor(tag), magic, 0,
                             (dir > 0) ? clrDodgerBlue : clrOrangeRed);
      if(ticket > 0)
      {
         double fill = price;
         if(OrderSelect(ticket, SELECT_BY_TICKET))
            fill = OrderOpenPrice();
         Print("OPEN [", BotID, "] ", sym, " ", (dir > 0 ? "BUY" : "SELL"),
               " ", DoubleToString(lot, LotDigits(sym)), " (", tag, ") #", ticket);
         LogEvent("OPEN " + sym + " " + (dir > 0 ? "BUY" : "SELL") + " " +
                  DoubleToString(lot, LotDigits(sym)) + " @ " +
                  DoubleToString(fill, digits) + " (" + tag + ")");
         return true;
      }

      int err = GetLastError();
      Print("OrderSend FAIL ", sym, " ", tag, " err=", err, " attempt=", attempt + 1);

      if(!IsRetryableError(err))
         return false;
      Sleep(CloseRetryDelayMs);
   }

   return false;
}

// Closes a ticket (lots <= 0 means all). Success is confirmed by the trade or history list.
bool ClosePartialTicket(int ticket, double lots)
{
   for(int attempt = 0; attempt < MathMax(1, CloseRetryCount); attempt++)
   {
      if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
      {
         if(OrderSelect(ticket, SELECT_BY_TICKET, MODE_HISTORY))
            return true;   // closed (fully)
         Print("CLOSE UNKNOWN: #", ticket, " found neither in trades nor history");
         return false;
      }

      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL)
         return false;

      string sym = OrderSymbol();
      double avail = OrderLots();
      double vol = (lots <= 0) ? avail : MathMin(lots, avail);
      vol = NormalizeLotsDown(sym, vol);
      if(vol <= 0)
         return false;

      int digits = (int)MarketInfo(sym, MODE_DIGITS);
      double price = (type == OP_BUY) ? MarketInfo(sym, MODE_BID) : MarketInfo(sym, MODE_ASK);
      if(price <= 0)
      {
         Sleep(CloseRetryDelayMs);
         continue;
      }

      ResetLastError();
      if(OrderClose(ticket, vol, NormalizeDouble(price, digits), Slippage, clrYellow))
      {
         Print("CLOSE OK #", ticket, " lots=", DoubleToString(vol, 4));
         return true;
      }

      int err = GetLastError();
      Print("CLOSE FAIL #", ticket, " err=", err, " attempt=", attempt + 1);

      if(!IsRetryableError(err))
         return false;
      Sleep(CloseRetryDelayMs);
   }

   return false;
}

// Returns true only if the symbol's magic has no positions afterwards.
bool CloseBasket(string sym, int magic, string why)
{
   if(LogOnly)
   {
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
         if(OrderSymbol() != sym || OrderMagicNumber() != magic) continue;
         if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
         Print("[LOGONLY] CLOSE ", sym, " #", OrderTicket(), " (", why, ")");
      }
      return true;
   }

   int evLegs = 0, evDir = 0;
   double evLots = 0;
   int evTk[];
   SnapshotBasket(sym, magic, evLegs, evLots, evDir, evTk);

   for(int pass = 0; pass < MathMax(1, CloseRetryCount); pass++)
   {
      int tickets[];
      int n = 0;

      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
         if(OrderSymbol() != sym || OrderMagicNumber() != magic) continue;
         if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

         n++;
         ArrayResize(tickets, n);
         tickets[n - 1] = OrderTicket();
      }

      if(n == 0)
         break;

      for(int k = 0; k < n; k++)
         ClosePartialTicket(tickets[k], -1.0);

      if(CountBasketOrders(sym, magic) == 0)
         break;

      Sleep(CloseRetryDelayMs);
   }

   if(CountBasketOrders(sym, magic) == 0)
   {
      int idx = FindSymbolIndex(sym);
      if(idx >= 0)
         ResetBasketState(idx);
      Print("CLOSE BASKET VERIFIED [", BotID, "] ", sym, " (", why, ")");
      if(evLegs > 0)
         LogEvent("CLOSE " + sym + " " + (evDir > 0 ? "BUY" : "SELL") + " " +
                  IntegerToString(evLegs) + " legs " + DoubleToString(evLots, 2) +
                  " lots | profit=" + DoubleToString(RealizedProfit(evTk), 2) +
                  " (" + why + ")");
      return true;
   }

   Print("CLOSE BASKET INCOMPLETE ", sym, " remaining=", CountBasketOrders(sym, magic),
         " reason=", why);
   return false;
}

int CountBasketOrders(string sym, int magic)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == sym && OrderMagicNumber() == magic &&
         (OrderType() == OP_BUY || OrderType() == OP_SELL))
         count++;
   }
   return count;
}

void CloseAll()
{
   bool allClosed = true;

   for(int i = 0; i < nSyms; i++)
   {
      if(!CloseBasket(Syms[i], MagicBase + i, "kill-switch"))
         allClosed = false;
   }

   gKillClosePending = (!allClosed || HasManagedPositions());

   if(!gKillClosePending)
      Print("KILL-SWITCH: all managed baskets closed.");
   else
      Print("KILL-SWITCH: close incomplete, retry on next engine pass.");
}

//====================================================================
// STATE PERSISTENCE
//====================================================================

void SavePersistentState()
{
   GlobalVariableSet(PeakKey(), gPeakEquity);
   GlobalVariableSet(PeakTimeKey(), (double)gPeakTime);
   GlobalVariableSet(HaltKey(), gHalted ? 1 : 0);
   GlobalVariableSet(PauseKey(), (double)gPauseUntil);

   for(int i = 0; i < nSyms; i++)
   {
      GlobalVariableSet(SymKey(i, "MRP"), (double)mrpState[i]);
      GlobalVariableSet(SymKey(i, "REDUCED"), basketReduced[i] ? 1 : 0);

      if(basketFirstOpen[i] > 0)
         GlobalVariableSet(SymKey(i, "FIRST"), (double)basketFirstOpen[i]);
      if(basketLastReduction[i] > 0)
         GlobalVariableSet(SymKey(i, "REDUCE"), (double)basketLastReduction[i]);
      if(basketLastAssessment[i] > 0)
         GlobalVariableSet(SymKey(i, "ASSESS"), (double)basketLastAssessment[i]);
   }
}

//====================================================================
// STATUS FILE
//====================================================================

void WriteStatus()
{
   int h = FileOpen(FilePrefix + "_status.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
      return;

   double equity = AccountEquity();
   double budget = GetRiskBudget();
   double used = GetTotalOpenRisk();

   double dd = (gPeakEquity > 0) ? (gPeakEquity - equity) / gPeakEquity * 100.0 : 0;
   double loadPct = (budget > 0 && used >= 0) ? used / budget * 100.0 : 0;
   ENUM_RISK_LEVEL level = GetRiskLevel(loadPct, used);

   FileWrite(h,
      "time=", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
      " | bot=", BotID,
      " | balance=", DoubleToString(AccountBalance(), 2),
      " | equity=", DoubleToString(equity, 2),
      " | freemargin=", DoubleToString(AccountFreeMargin(), 2),
      " | margin=", DoubleToString(AccountMargin(), 2),
      " | peakEq=", DoubleToString(gPeakEquity, 2),
      " | ddPct=", DoubleToString(dd, 2),
      " | halted=", (gHalted ? "1" : "0"),
      " | closePending=", (gKillClosePending ? "1" : "0"),
      " | logOnly=", (LogOnly ? "1" : "0"),
      " | riskBudget=", DoubleToString(budget, 2),
      " | riskUsed=", DoubleToString(used, 2),
      " | riskLoadPct=", DoubleToString(loadPct, 2),
      " | riskLevel=", RiskLevelName(level),
      " | mrpShadow=", (MRPShadowMode ? "1" : "0"));

   for(int i = 0; i < nSyms; i++)
   {
      string s = Syms[i];
      int magic = MagicBase + i;
      int dg = (int)MarketInfo(s, MODE_DIGITS);

      int dir = 0, legs = 0;
      double tot = 0, avg = 0, last = 0, flt = 0;
      bool mixed = false;
      bool hasB = ScanBasketEx(s, magic, dir, legs, tot, avg, last, flt, mixed);

      FileWrite(h,
         s,
         " regime=", IntegerToString(GetRegime(i)),
         " regimeOK=", (regimeOK[i] ? "1" : "0"),
         " tf[", RegimeDetail(s), "]",
         " close1=", DoubleToString(iClose(s, SignalTF, 1), dg),
         " ema1=", DoubleToString(iMA(s, SignalTF, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1), dg),
         " rsi1=", DoubleToString(iRSI(s, SignalTF, RSIPeriod, PRICE_CLOSE, 1), 1),
         " basket=",
         (hasB
          ? StringConcatenate("dir=", dir, " legs=", legs,
                              " lots=", DoubleToString(tot, 4),
                              " float=", DoubleToString(flt, 2),
                              " mixed=", (mixed ? "1" : "0"))
          : "flat"),
         " risk=", DoubleToString(GetSymbolRisk(s, magic), 2),
         " mrpScore=", mrpScore[i],
         " mrpState=", (int)mrpState[i],
         " exitCount=", mrpExitCount[i],
         " ageDays=", BasketAgeDays(i),
         " reduced=", (basketReduced[i] ? "1" : "0"));
   }

   FileClose(h);
}

//====================================================================
// SYMBOL DISCOVERY
//====================================================================

bool BuildSymbolList()
{
   nSyms = 0;
   ArrayResize(Syms, MaxSymbols);

   if(StringLen(InpSymbols) > 0)
   {
      string parts[];
      int k = StringSplit(InpSymbols, ',', parts);

      for(int i = 0; i < k && nSyms < MaxSymbols; i++)
      {
         string s = Trim(parts[i]);
         if(StringLen(s) == 0)
            continue;

         SymbolSelect(s, true);
         if(MarketInfo(s, MODE_BID) > 0)
            Syms[nSyms++] = s;
         else
            Print("WARN: symbol not available, skipped: ", s);
      }
   }
   else
   {
      Print("FATAL: InpSymbols is empty. Set the traded instruments explicitly, comma-separated.");
   }

   ArrayResize(Syms, MathMax(nSyms, 1));
   return(nSyms > 0);
}

//====================================================================
// HELPERS
//====================================================================

int FindSymbolIndex(string sym)
{
   for(int i = 0; i < nSyms; i++)
   {
      if(Syms[i] == sym)
         return i;
   }
   return -1;
}

string JoinSyms()
{
   string s = "";
   for(int i = 0; i < nSyms; i++)
   {
      if(i > 0) s += ",";
      s += Syms[i];
   }
   return s;
}

string Trim(string s)
{
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
}

// Scans the basket for this symbol/magic. Mixed direction is reported, not averaged.
bool ScanBasketEx(string sym, int magic, int &dir, int &legs, double &totLots,
                  double &avgPrice, double &lastPrice, double &flt, bool &mixed)
{
   dir = 0;
   legs = 0;
   totLots = 0;
   avgPrice = 0;
   lastPrice = 0;
   flt = 0;
   mixed = false;

   double wsum = 0;
   datetime lastOpen = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != sym || OrderMagicNumber() != magic) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

      int od = (OrderType() == OP_BUY) ? 1 : -1;
      if(dir == 0)
         dir = od;
      else if(dir != od)
         mixed = true;

      legs++;
      totLots += OrderLots();
      wsum += OrderOpenPrice() * OrderLots();
      flt += OrderProfit() + OrderSwap() + OrderCommission();

      if(OrderOpenTime() >= lastOpen)
      {
         lastOpen = OrderOpenTime();
         lastPrice = OrderOpenPrice();
      }
   }

   if(legs == 0 || totLots <= 0)
      return false;

   avgPrice = wsum / totLots;
   return true;
}

//+------------------------------------------------------------------+
//| END OF FILE                                                       |
//+------------------------------------------------------------------+
