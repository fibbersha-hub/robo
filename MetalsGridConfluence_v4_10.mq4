//+------------------------------------------------------------------+
//|                         MetalsGridConfluence_v4_10.mq4     |
//|                         Version 4.10 revised hedge/recovery candidate (from 3.10)|
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
//+------------------------------------------------------------------+
//| v4.10 - HEDGE / RECOVERY CANDIDATE (per instrument)       |
//|                                                                   |
//|  Trigger metric: per-symbol episode P/L (original + hedge open   |
//|  P/L plus realized hedge/compensation P/L) divided by an explicit  |
//|  base: account balance by default, or risk budget by selection.    |
//|   < HedgeWatchPct      : normal operation                         |
//|   WatchPct .. ActivePct: WATCH  - statistics only (H4 EMA, RSI,   |
//|                          tick volume), nothing is opened          |
//|   >= HedgeActivePct    : ACTIVE - if the H4 reversal is confirmed |
//|                          legs are opened AGAINST the original     |
//|                          basket (own magic = MagicBase+50+idx)    |
//|  Net realized hedge profit (after costs, with a configurable      |
//|  reserve) funds partial/full closes of losing original legs.       |
//|  Open/hold/exit signals are separated; tick volume is entry-only.  |
//|  Hedge volume is capped at 75% of ORIGINAL remaining lots by       |
//|  default. Hard stops plus a stop-count lockout protect the hedge.  |
//|  While hedge legs are open: MRP exit, MRP reduction and grid adds |
//|  of the original basket are held. Basket TP and kill-switch work  |
//|  as before; the kill-switch closes the hedge baskets as well.     |
//|  Hedge orders skip the account stress budget (they reduce risk)   |
//|  but still pass the margin guard. Stress risk counts the original |
//|  basket only (no netting with the hedge).                         |
//|  Shadow mode is ON by default. This is a review candidate, not a  |
//|  broker-compiled or production-certified release.                 |
//+------------------------------------------------------------------+
#property copyright "fx_research"
#property version   "4.10"
#property strict
#define HEDGE_MAGIC_OFFSET 50

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
 
enum ENUM_HEDGE_STATE
{
   HEDGE_OFF    = 0,
   HEDGE_WATCH  = 1,
   HEDGE_ACTIVE = 2
};

enum ENUM_HEDGE_DD_BASE
{
   HEDGE_DD_ACCOUNT_BALANCE = 0,
   HEDGE_DD_RISK_BUDGET     = 1
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

//==== hedge / recovery mode (per instrument; SHADOW is the safe default)
input bool    HedgeEnabled           = true;
input bool    HedgeShadowMode        = true;    // true = diagnostics only; false = real hedge orders
input ENUM_HEDGE_DD_BASE HedgeDDBase = HEDGE_DD_ACCOUNT_BALANCE; // denominator for 15% / 20%
input double  HedgeWatchPct          = 15.0;    // per-instrument net episode loss / selected base
input double  HedgeActivePct         = 20.0;    // hedging may start only at/above this level
input double  HedgeHysteresisPct     = 2.0;     // hysteresis on exit from WATCH / ACTIVE
input double  HedgeFullLossPct       = 40.0;    // hedge cap reaches max ratio at this loss percentage
input ENUM_TIMEFRAMES HedgeTF        = PERIOD_H4;
input int     HedgeEMAPeriod          = 50;
input int     HedgeRSIPeriod          = 14;
input double  HedgeRSILongBelow       = 45.0;    // for an original BUY basket
input double  HedgeRSIShortAbove      = 55.0;    // for an original SELL basket
input int     HedgeVolLookback        = 20;      // previous CLOSED H4 bars
input double  HedgeVolumeFactor       = 1.20;    // broker tick volume used for ENTRY confirmation only
input int     HedgeEntryConfirmBars   = 2;       // consecutive closed H4 bars for EMA + RSI
input int     HedgeExitConfirmBars    = 2;       // consecutive closed H4 bars failing EMA + RSI to exit
input double  HedgeMinRatio           = 0.25;    // target hedge/original lots at activation
input double  HedgeMaxRatio           = 0.75;    // hard cap remains below 100% of original lots
input double  HedgeLegRatio           = 0.25;    // one hedge leg as a share of original lots
input int     HedgeMaxLegs            = 3;       // maximum simultaneously open hedge legs
input int     HedgeCooldownMin        = 60;      // minimum time between hedge actions
input double  HedgeTakeProfitPct      = 0.30;    // hedge basket price TP, percent
input double  HedgeMaxLossPct         = 1.00;    // hard stop: hedge floating loss / selected base
input int     HedgeMaxStopCount       = 2;       // lock further hedge entries after this many hard stops
input double  HedgeProfitUsePct       = 70.0;    // fraction of realized net hedge profits available for compensation
input double  HedgeLegMinProfit       = 5.0;     // minimum net profit before banking a hedge leg (deposit currency)
 
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
 
// hedge / recovery mode
ENUM_HEDGE_STATE hedgeState[];
double   hedgePct[];        // net floating loss of the instrument, % of selected base
double   hedgePool[];       // net recovery pool; negative values carry hedge-loss deficits
double   hedgeEpReal[];     // realized result of the episode (hedge results minus compensated losses)
int      hedgeSig[];        // last H4 signal (0/1)
datetime hedgeOpenBar[];    // closed HedgeTF bar on which the last hedge leg was opened
datetime hedgeLastAct[];    // last hedge open/close (cooldown)
datetime hedgeLastEvalBar[]; // last processed CLOSED HedgeTF bar (not the last trade bar)
int      hedgeStopCount[];     // hard-loss stops in the current original-basket episode
double   hedgeBaseAtStart[]; // frozen denominator for the current WATCH/ACTIVE episode
datetime hedgeLogBar[];          // five independent log de-duplication slots per symbol
int      hedgeSignalFailCount[];  // consecutive closed H4 bars failing the hold signal

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
      // MODE_* is ignored with SELECT_BY_TICKET; confirm the ticket is closed.
      if(OrderSelect(tk[i], SELECT_BY_TICKET) && OrderCloseTime() > 0)
         p += OrderProfit() + OrderSwap() + OrderCommission();
   }
   return p;
}

// Returns realized net P/L for a snapshot of tickets. If a broker does not
// expose every closed ticket in history immediately, the caller can use a
// conservative pre-close estimate and must log that the value is estimated.
double RealizedProfitVerified(int &tk[], double fallbackEstimate, bool &verified)
{
   double p = 0.0;
   int found = 0;
   for(int i = 0; i < ArraySize(tk); i++)
   {
      // SELECT_BY_TICKET ignores pool; OrderCloseTime verifies history membership.
      if(OrderSelect(tk[i], SELECT_BY_TICKET) && OrderCloseTime() > 0)
      {
         p += OrderProfit() + OrderSwap() + OrderCommission();
         found++;
      }
   }
   verified = (found == ArraySize(tk));
   if(verified)
      return p;
   return fallbackEstimate;
}

bool ClosedTicketProfit(int ticket, double fallbackEstimate, double &pnl, bool &verified)
{
   // SELECT_BY_TICKET ignores pool; a non-zero close time is the reliable test.
   if(OrderSelect(ticket, SELECT_BY_TICKET) && OrderCloseTime() > 0)
   {
      pnl = OrderProfit() + OrderSwap() + OrderCommission();
      verified = true;
      return true;
   }
   pnl = fallbackEstimate;
   verified = false;
   return false;
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
 
   ArrayResize(hedgeState, n);
   ArrayResize(hedgePct, n);
   ArrayResize(hedgePool, n);
   ArrayResize(hedgeEpReal, n);
   ArrayResize(hedgeSig, n);
   ArrayResize(hedgeOpenBar, n);
   ArrayResize(hedgeLastAct, n);
   ArrayResize(hedgeLastEvalBar, n);
   ArrayResize(hedgeStopCount, n);
   ArrayResize(hedgeBaseAtStart, n);
   ArrayResize(hedgeLogBar, n * 5);
   ArrayResize(hedgeSignalFailCount, n);
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

   if(MaxSymbols < 1 || MaxSymbols > HEDGE_MAGIC_OFFSET)
   {
      Print("PARAM ERROR: MaxSymbols must be between 1 and ", HEDGE_MAGIC_OFFSET,
            " because hedge magic uses MagicBase + ", HEDGE_MAGIC_OFFSET, " + symbol index");
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
         Print("PARAM ERROR: HedgeHysteresisPct must be in [0, Watch)");
         ok = false;
      }
      if(HedgeEMAPeriod < 2 || HedgeRSIPeriod < 2 || HedgeVolLookback < 2 || HedgeVolumeFactor <= 0)
      {
         Print("PARAM ERROR: invalid hedge EMA/RSI/volume settings");
         ok = false;
      }
      if(HedgeEntryConfirmBars < 1 || HedgeExitConfirmBars < 1)
      {
         Print("PARAM ERROR: hedge entry/exit confirmation bars must be >= 1");
         ok = false;
      }
      if(!(HedgeRSILongBelow > 0 && HedgeRSILongBelow < 50 &&
           HedgeRSIShortAbove > 50 && HedgeRSIShortAbove < 100))
      {
         Print("PARAM ERROR: hedge RSI thresholds must straddle 50");
         ok = false;
      }
      if(!(HedgeMinRatio > 0 && HedgeMinRatio <= HedgeMaxRatio && HedgeMaxRatio < 1.0))
      {
         Print("PARAM ERROR: hedge ratios must satisfy 0 < Min <= Max < 1.0");
         ok = false;
      }
      if(!(HedgeLegRatio > 0 && HedgeLegRatio <= HedgeMaxRatio))
      {
         Print("PARAM ERROR: HedgeLegRatio must be in (0, HedgeMaxRatio]");
         ok = false;
      }
      if(HedgeMaxLegs < 1 || HedgeCooldownMin < 0 || HedgeTakeProfitPct <= 0 ||
         HedgeMaxLossPct <= 0 || HedgeMaxStopCount < 1)
      {
         Print("PARAM ERROR: invalid hedge limits / cooldown / TP / hard loss / hard-stop count");
         ok = false;
      }
      if(HedgeProfitUsePct < 0 || HedgeProfitUsePct > 100 || HedgeLegMinProfit < 0)
      {
         Print("PARAM ERROR: HedgeProfitUsePct must be 0..100 and HedgeLegMinProfit >= 0");
         ok = false;
      }
      if(HedgeDDBase != HEDGE_DD_ACCOUNT_BALANCE && HedgeDDBase != HEDGE_DD_RISK_BUDGET)
      {
         Print("PARAM ERROR: invalid HedgeDDBase");
         ok = false;
      }
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
 
      HedgeInitState(i);
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
      HedgeLoadState(j);
      hedgeSignalFailCount[j] = 0;
   }

   Print("MetalsGridConfluence v4.10 init. BotID=", BotID, " | Magic=", MagicBase,
         " | Files=", FilePrefix, "_*.txt | Symbols(", nSyms, "): ", JoinSyms(),
         " | LogOnly=", LogOnly,
         " | MRP=", MRPEnabled, " | MRPShadow=", MRPShadowMode,
         " | Hedge=", HedgeEnabled, " | HedgeShadow=", HedgeShadowMode,
         " | HedgeMagic=", MagicBase + HEDGE_MAGIC_OFFSET, "+idx",
         " | HedgeDDBase=", (HedgeDDBase == HEDGE_DD_ACCOUNT_BALANCE ? "BALANCE" : "RISK_BUDGET"),
         " | HedgeMaxLossPct=", DoubleToString(HedgeMaxLossPct, 2),
         " | HedgeMaxStopCount=", HedgeMaxStopCount,
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
   Print("MetalsGridConfluence v4.10 deinit. Reason=", reason);
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
      HedgeResetEpisode(i);
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
            " hedgeState=", (int)hedgeState[i],
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
      if(CountBasketOrders(Syms[i], MagicBase + i) > 0 ||
         CountBasketOrders(Syms[i], HedgeMagic(i)) > 0)
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

   // Hedge cleanup comes before the next original entry. If a live orphan cannot
   // be closed (or LogOnly prevents actions), do not open a new original basket.
   if(HedgeOrphanCleanup(idx))
      return;

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
      HedgeCloseAll(idx, "original-mixed-direction");
      CloseBasket(sym, magic, "mixed-direction");
      if(CountBasketOrders(sym, magic) == 0 && CountBasketOrders(sym, HedgeMagic(idx)) == 0)
         HedgeResetEpisode(idx);
      return;
   }

   // 1. Basket take-profit (unchanged rule).
   double tpPrice = (dir > 0)
                    ? avgPrice * (1.0 + TakeProfitPct / 100.0)
                    : avgPrice * (1.0 - TakeProfitPct / 100.0);
   bool tpHit = (dir > 0) ? (bid >= tpPrice) : (ask <= tpPrice);
   if(tpHit)
   {
      HedgeCloseAll(idx, "original-TP");
      if(CloseBasket(sym, magic, "basket-TP"))
      {
         if(CountBasketOrders(sym, HedgeMagic(idx)) == 0)
            HedgeResetEpisode(idx);
      }
      return;
   }
 
   // 1b. Hedge / recovery layer (this instrument only).
   if(ManageHedge(idx, dir, flt))
   {
      // The original basket was changed by compensation: refresh its parameters.
      if(!ScanBasketEx(sym, magic, dir, legs, totLots, avgPrice, lastPrice, flt, mixed))
         return;
   }

   // 2. Reversal evaluation - this instrument only, closed bars only.
   EvaluateReversal(idx, dir, avgPrice, legs);
   ENUM_MRP_STATE st = mrpState[idx];

   // 3. Reversal exit (held while hedge legs are open).
   bool hedgeHold = HedgeHolds(idx);
   if(MRPEnabled && st == MRP_EXIT_PENDING && hedgeHold)
      HedgeLog(idx, "mrp-hold", "MRP exit held: hedge episode in progress, score=" +
                                 IntegerToString(mrpScore[idx]));
   if(MRPEnabled && st == MRP_EXIT_PENDING && !hedgeHold)
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

   bool hedgeEpisodeActive = (HedgeTrading() && hedgeState[idx] == HEDGE_ACTIVE);
   bool reduceWanted = MRPEnabled && regOK && reg == 0 && !basketReduced[idx] &&
                       !hedgeHold && !hedgeEpisodeActive &&
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
   if(HedgeBlocksAdds(idx))
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
         // During a live WATCH episode, MRP may still reduce the original basket.
         // Carry its realized net result into the episode ledger so moving a loss
         // from floating P/L to history does not make measured drawdown disappear.
         if(HedgeEnabled && !LogOnly && hedgeState[idx] != HEDGE_OFF)
         {
            double estimate = pnlPerLot[best] * vol;
            double realized = estimate;
            bool verified = false;
            ClosedTicketProfit(tickets[best], estimate, realized, verified);
            hedgeEpReal[idx] += realized;
            HedgeSaveState(idx);
            if(!verified)
               Print("MRP/HEDGE ledger uses estimated partial-close P/L on ", sym,
                     " ticket=", tickets[best]);
         }
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
   // Hedge legs reduce the net risk: they skip the stress budget but still pass the margin guard.
   if(IsHedgeMagic(magic))
   {
      if(!MarginLimitAllows(lot, sym))
         return false;
   }
   else if(!RiskBudgetAllows(sym, magic, dir, lot))
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
      if(!OrderSelect(ticket, SELECT_BY_TICKET))
      {
         Print("CLOSE UNKNOWN: #", ticket, " not found in terminal orders/history");
         return false;
      }
      // The pool argument is ignored for SELECT_BY_TICKET. A non-zero close time
      // means this ticket is already closed and must not be sent to OrderClose again.
      if(OrderCloseTime() > 0)
         return true;

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
      // Only the original basket resets the per-basket state; a hedge basket must not.
      if(idx >= 0 && magic == MagicBase + idx)
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
      // Hedge first: the original basket returns to its un-hedged state, then it is closed too.
      if(!CloseBasket(Syms[i], HedgeMagic(i), "kill-switch-hedge"))
         allClosed = false;
      if(!CloseBasket(Syms[i], MagicBase + i, "kill-switch"))
         allClosed = false;
      if(CountBasketOrders(Syms[i], HedgeMagic(i)) == 0 &&
         CountBasketOrders(Syms[i], MagicBase + i) == 0)
         HedgeResetEpisode(i);
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
      HedgeSaveState(i);

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
      " | mrpShadow=", (MRPShadowMode ? "1" : "0"),
      " | hedge=", (HedgeEnabled ? "1" : "0"),
      " | hedgeShadow=", (HedgeShadowMode ? "1" : "0"));

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
         " reduced=", (basketReduced[i] ? "1" : "0"),
         HedgeStatusStr(i));
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
   return (CountBasketOrders(Syms[idx], HedgeMagic(idx)) > 0);
}

// Averaging down into a loss while hedging is contradictory: no grid adds.
bool HedgeBlocksAdds(int idx)
{
   if(CountBasketOrders(Syms[idx], HedgeMagic(idx)) > 0)
      return true;
   // Shadow mode must not alter normal grid behavior when no hedge trades exist.
   return (HedgeTrading() && hedgeState[idx] == HEDGE_ACTIVE);
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
   hedgeLastEvalBar[idx] = 0;
   hedgeStopCount[idx] = 0;
   hedgeBaseAtStart[idx] = 0.0;
   hedgeSignalFailCount[idx] = 0;
   for(int s = 0; s < 5; s++)
      hedgeLogBar[idx * 5 + s] = 0;
}

// End of an episode: the original basket is gone and no hedge legs remain.
void HedgeResetEpisode(int idx)
{
   HedgeInitState(idx);
   GlobalVariableSet(SymKey(idx, "HST"), 0);
   GlobalVariableSet(SymKey(idx, "HPOOL"), 0);
   GlobalVariableSet(SymKey(idx, "HREAL"), 0);
   GlobalVariableSet(SymKey(idx, "HOPEN"), 0);
   GlobalVariableSet(SymKey(idx, "HACT"), 0);
   GlobalVariableSet(SymKey(idx, "HEVAL"), 0);
   GlobalVariableSet(SymKey(idx, "HBASE"), 0);
   GlobalVariableSet(SymKey(idx, "HSTOPS"), 0);
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
   if(GlobalVariableCheck(SymKey(idx, "HEVAL")))
      hedgeLastEvalBar[idx] = (datetime)GlobalVariableGet(SymKey(idx, "HEVAL"));
   if(GlobalVariableCheck(SymKey(idx, "HBASE")))
      hedgeBaseAtStart[idx] = GlobalVariableGet(SymKey(idx, "HBASE"));
   if(GlobalVariableCheck(SymKey(idx, "HSTOPS")))
      hedgeStopCount[idx] = (int)GlobalVariableGet(SymKey(idx, "HSTOPS"));
}

void HedgeSaveState(int idx)
{
   GlobalVariableSet(SymKey(idx, "HST"), (double)hedgeState[idx]);
   GlobalVariableSet(SymKey(idx, "HPOOL"), hedgePool[idx]);
   GlobalVariableSet(SymKey(idx, "HREAL"), hedgeEpReal[idx]);
   GlobalVariableSet(SymKey(idx, "HOPEN"), (double)hedgeOpenBar[idx]);
   GlobalVariableSet(SymKey(idx, "HACT"), (double)hedgeLastAct[idx]);
   GlobalVariableSet(SymKey(idx, "HEVAL"), (double)hedgeLastEvalBar[idx]);
   GlobalVariableSet(SymKey(idx, "HBASE"), hedgeBaseAtStart[idx]);
   GlobalVariableSet(SymKey(idx, "HSTOPS"), (double)hedgeStopCount[idx]);
}

// Each common event type has its own per-symbol H4 de-duplication slot.
// stats, open, MRP hold, close, and miscellaneous messages cannot evict each other.
void HedgeLog(int idx, string key, string msg)
{
   int slot = 4;
   if(key == "stats") slot = 0;
   else if(key == "open") slot = 1;
   else if(key == "mrp-hold") slot = 2;
   else if(key == "close") slot = 3;

   int k = idx * 5 + slot;
   datetime b = iTime(Syms[idx], HedgeTF, 1);
   if(b <= 0)
   {
      int tfSeconds = PeriodSeconds(HedgeTF);
      if(tfSeconds <= 0) tfSeconds = 14400;
      b = (datetime)((TimeCurrent() / tfSeconds) * tfSeconds);
   }
   if(b == hedgeLogBar[k])
      return;
   hedgeLogBar[k] = b;
   Print((HedgeShadowMode ? "[HEDGE SHADOW] " : "[HEDGE] "), Syms[idx], " ", msg);
}

// Booking a realized hedge close. Only net realized profit, after commission
// and swap, contributes to the pool; a hedge loss consumes any existing pool.
void HedgeBook(int idx, double realizedNet, bool verified, string why)
{
   hedgeEpReal[idx] += realizedNet;
   if(realizedNet > 0)
      hedgePool[idx] += realizedNet * HedgeProfitUsePct / 100.0;
   else if(realizedNet < 0)
      hedgePool[idx] += realizedNet; // preserve any deficit for future hedge profits
   hedgeLastAct[idx] = TimeCurrent();
   HedgeSaveState(idx);
   Print("HEDGE BOOK ", Syms[idx], " reason=", why,
         " net=", DoubleToString(realizedNet, 2),
         " source=", (verified ? "history" : "estimate"),
         " episode=", DoubleToString(hedgeEpReal[idx], 2),
         " pool=", DoubleToString(hedgePool[idx], 2));
}

// Common two-closed-bar EMA/RSI test. No current (shift 0) bar is used.
bool HedgeSignalCore(int idx, int dir, string &info, bool &dataOK)
{
   dataOK = false;
   info = "signal: no data";
   string sym = Syms[idx];
   int need = MathMax(HedgeEMAPeriod, HedgeRSIPeriod) + HedgeEntryConfirmBars + HedgeVolumeLookback + 5;
   if(dir == 0 || iBars(sym, HedgeTF) < need)
      return false;

   for(int shift = 1; shift <= HedgeEntryConfirmBars; shift++)
   {
      double c = iClose(sym, HedgeTF, shift);
      double ema = iMA(sym, HedgeTF, HedgeEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, shift);
      double rsi = iRSI(sym, HedgeTF, HedgeRSIPeriod, PRICE_CLOSE, shift);
      if(c <= 0 || ema <= 0 || rsi <= 0)
         return false;

      bool priceAdverse = (dir > 0) ? (c < ema) : (c > ema);
      bool rsiAdverse = (dir > 0) ? (rsi < HedgeRSILongBelow) : (rsi > HedgeRSIShortAbove);
      if(!(priceAdverse && rsiAdverse))
      {
         dataOK = true;
         info = StringFormat("ema/rsi confirm failed at shift %d (rsi=%.1f)", shift, rsi);
         return false;
      }
   }

   dataOK = true;
   info = "two closed H4 bars: EMA+RSI adverse";
   return true;
}

// ENTRY signal: two closed bars must confirm EMA+RSI and the latest closed
// bar's broker tick volume must exceed its preceding-bar average.
bool HedgeEntrySignal(int idx, int dir, string &info, bool &dataOK)
{
   if(!HedgeSignalCore(idx, dir, info, dataOK))
      return false;

   string sym = Syms[idx];
   double sum = 0.0;
   int cnt = 0;
   for(int k = 2; k <= HedgeVolLookback + 1; k++)
   {
      double v = (double)iVolume(sym, HedgeTF, k);
      if(v > 0) { sum += v; cnt++; }
   }
   double v1 = (double)iVolume(sym, HedgeTF, 1);
   if(cnt < MathMax(2, HedgeVolLookback / 2) || sum <= 0)
   {
      dataOK = false;
      info = "signal: insufficient tick-volume history";
      return false;
   }

   double avgVol = sum / cnt;
   bool volumeOK = (v1 >= avgVol * HedgeVolumeFactor);
   info = StringFormat("EMA+RSI=Y tickVol=%s(%.0f/%.0f)",
                       (volumeOK ? "Y" : "n"), v1, avgVol);
   return volumeOK;
}

// HOLD signal: EMA+RSI only. Tick-volume is deliberately NOT an exit criterion.
bool HedgeHoldSignal(int idx, int dir, string &info, bool &dataOK)
{
   return HedgeSignalCore(idx, dir, info, dataOK);
}

// Selected denominator for the instrument episode drawdown percentage.
double HedgeDrawdownBaseValue()
{
   if(HedgeDDBase == HEDGE_DD_RISK_BUDGET)
      return GetRiskBudget();
   return AccountBalance();
}

string HedgeDrawdownBaseName()
{
   return (HedgeDDBase == HEDGE_DD_RISK_BUDGET ? "risk-budget" : "account-balance");
}

// The numerator is this symbol's net episode P/L: live original + live hedge
// + realized hedge P/L + realized original losses paid from the hedge pool.
double HedgeEpisodeLoss(double originalFloat, double hedgeFloat, double episodeRealized)
{
   double net = originalFloat + hedgeFloat + episodeRealized;
   return MathMax(0.0, -net);
}

// OFF -> WATCH -> ACTIVE with hysteresis. ACTIVE is held while hedge trades exist.
void HedgeUpdateState(int idx, double pct, int hLegs)
{
   ENUM_HEDGE_STATE cur = hedgeState[idx];
   ENUM_HEDGE_STATE nx = cur;

   if(cur == HEDGE_OFF)
   {
      if(pct >= HedgeActivePct) nx = HEDGE_ACTIVE;
      else if(pct >= HedgeWatchPct) nx = HEDGE_WATCH;
   }
   else if(cur == HEDGE_WATCH)
   {
      if(pct >= HedgeActivePct) nx = HEDGE_ACTIVE;
      else if(pct < HedgeWatchPct - HedgeHysteresisPct) nx = HEDGE_OFF;
   }
   else if(hLegs == 0 && pct < HedgeActivePct - HedgeHysteresisPct)
   {
      nx = (pct >= HedgeWatchPct - HedgeHysteresisPct) ? HEDGE_WATCH : HEDGE_OFF;
   }

   if(nx == cur) return;
   Print("HEDGE STATE ", Syms[idx], " ", (int)cur, " -> ", (int)nx,
         " episodeLossPct=", DoubleToString(pct, 2));
   LogEvent("HEDGE STATE " + Syms[idx] + " " + IntegerToString((int)cur) + "->" +
            IntegerToString((int)nx) + " episodeLossPct=" + DoubleToString(pct, 2));
   hedgeState[idx] = nx;
   if(nx == HEDGE_OFF)
   {
      hedgeBaseAtStart[idx] = 0.0;
      hedgeStopCount[idx] = 0;
   }
   GlobalVariableSet(SymKey(idx, "HST"), (double)nx);
   GlobalVariableSet(SymKey(idx, "HBASE"), hedgeBaseAtStart[idx]);
   GlobalVariableSet(SymKey(idx, "HSTOPS"), (double)hedgeStopCount[idx]);
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

// Closes the whole hedge basket. Realized history P/L is preferred over the
// pre-close floating estimate; estimates are explicitly identified in logs.
bool HedgeCloseAll(int idx, string why)
{
   string sym = Syms[idx];
   int hm = HedgeMagic(idx);
   int tickets[];
   double estimates[];
   int n = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != sym || OrderMagicNumber() != hm) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      n++;
      ArrayResize(tickets, n);
      ArrayResize(estimates, n);
      tickets[n - 1] = OrderTicket();
      estimates[n - 1] = OrderProfit() + OrderSwap() + OrderCommission();
   }

   if(n == 0)
      return true;

   if(LogOnly)
   {
      Print("[LOGONLY] would close hedge basket ", sym, " reason=", why);
      return false;
   }

   double bookedNetTotal = 0.0;
   int bookedTickets = 0;
   for(int k = 0; k < n; k++)
   {
      bool closeOK = ClosePartialTicket(tickets[k], -1.0);
      double realized = estimates[k];
      bool verified = false;
      bool historyFound = ClosedTicketProfit(tickets[k], estimates[k], realized, verified);
      if(!closeOK && !historyFound)
      {
         continue;
      }
      if(!closeOK && !verified)
      {
         continue;
      }
      HedgeBook(idx, realized, verified, why + "-ticket");
      bookedNetTotal += realized;
      bookedTickets++;
      LogEvent("HEDGE-CLOSE " + sym + " ticket=" + IntegerToString(tickets[k]) +
               " net=" + DoubleToString(realized, 2) +
               " source=" + (verified ? "history" : "estimate"));
   }

   if(bookedTickets > 0 && bookedNetTotal < 0.0)
   {
      hedgeStopCount[idx]++;
      HedgeSaveState(idx);
      Print("HEDGE LOSS-CLOSE COUNTER ", sym, " ", hedgeStopCount[idx], "/", HedgeMaxStopCount,
            " netClosed=", DoubleToString(bookedNetTotal, 2));
   }

   int remaining = CountBasketOrders(sym, hm);
   if(remaining > 0)
   {
      Print("HEDGE CLOSE INCOMPLETE ", sym, " remaining=", remaining,
            " reason=", why, "; successful tickets already booked individually");
      return false;
   }

   Print("HEDGE CLOSE VERIFIED ", sym, " reason=", why,
         "; every confirmed closed ticket booked individually");
   return true;
}

// Hedge without an original basket is an orphan. Do not allow a fresh original
// entry until the orphan has actually disappeared. LogOnly cannot execute closes.
bool HedgeOrphanCleanup(int idx)
{
   string sym = Syms[idx];
   int hm = HedgeMagic(idx);
   if(CountBasketOrders(sym, MagicBase + idx) > 0)
      return false;

   if(CountBasketOrders(sym, hm) > 0)
   {
      Print("HEDGE ORPHAN ", sym, ": original basket is gone");
      if(LogOnly)
      {
         Print("CRITICAL: LogOnly prevents orphan cleanup; new entries are blocked");
         return true;
      }
      HedgeCloseAll(idx, "orig-closed");
      if(CountBasketOrders(sym, hm) > 0)
         return true;
   }

   if(hedgeState[idx] != HEDGE_OFF || hedgePool[idx] != 0.0 || hedgeEpReal[idx] != 0.0 ||
      hedgeOpenBar[idx] != 0 || hedgeLastAct[idx] != 0 || hedgeBaseAtStart[idx] != 0.0)
      HedgeResetEpisode(idx);
   return false;
}

// Bank individual profitable hedge tickets on a newly closed H4 bar. This
// realizes hedge gains net of swap/commission and moves only the configured
// share into the compensation pool; remaining positions continue as the hedge.
void HedgeBankProfitableLegs(int idx)
{
   if(LogOnly || HedgeLegMinProfit <= 0.0)
      return;
   string sym = Syms[idx];
   int hm = HedgeMagic(idx);
   int tickets[];
   double estimates[];
   int n = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != sym || OrderMagicNumber() != hm) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      double pnl = OrderProfit() + OrderSwap() + OrderCommission();
      if(pnl < HedgeLegMinProfit) continue;
      n++;
      ArrayResize(tickets, n);
      ArrayResize(estimates, n);
      tickets[n - 1] = OrderTicket();
      estimates[n - 1] = pnl;
   }

   for(int k = 0; k < n; k++)
   {
      if(ClosePartialTicket(tickets[k], -1.0))
      {
         double realized = estimates[k];
         bool verified = false;
         ClosedTicketProfit(tickets[k], estimates[k], realized, verified);
         HedgeBook(idx, realized, verified, "bank-profit");
         LogEvent("HEDGE-BANK " + sym + " ticket=" + IntegerToString(tickets[k]) +
                  " net=" + DoubleToString(realized, 2));
      }
   }
}

// Pool compensation closes the most losing original legs. Sizing is based on
// the current net loss, but the episode ledger and pool are updated from realized
// history P/L after the close whenever the broker exposes it.
bool HedgeCompensate(int idx, string sym, int magic)
{
   double pool = hedgePool[idx];
   if(pool <= 0.0 || LogOnly)
      return false;

   double minLot = MarketInfo(sym, MODE_MINLOT);
   int tk[];
   double lt[];
   double lossPerLot[];
   bool used[];
   int n = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != sym || OrderMagicNumber() != magic) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if(OrderLots() <= 0) continue;

      double pnl = OrderProfit() + OrderSwap() + OrderCommission();
      if(pnl >= 0) continue;
      n++;
      ArrayResize(tk, n);
      ArrayResize(lt, n);
      ArrayResize(lossPerLot, n);
      ArrayResize(used, n);
      tk[n - 1] = OrderTicket();
      lt[n - 1] = OrderLots();
      lossPerLot[n - 1] = (-pnl) / OrderLots();
      used[n - 1] = false;
   }

   bool any = false;
   for(int round = 0; round < n && pool > 0.0; round++)
   {
      int best = -1;
      for(int k = 0; k < n; k++)
         if(!used[k] && (best < 0 || lossPerLot[k] > lossPerLot[best])) best = k;
      if(best < 0) break;
      used[best] = true;

      double vol = NormalizeLotsDown(sym, MathMin(lt[best], pool / lossPerLot[best]));
      if(lt[best] - vol > 0 && lt[best] - vol < minLot)
         vol = NormalizeLotsDown(sym, lt[best] - minLot);
      if(vol < minLot) continue;

      double estimate = -lossPerLot[best] * vol;
      if(ClosePartialTicket(tk[best], vol))
      {
         double realized = estimate;
         bool verified = false;
         ClosedTicketProfit(tk[best], estimate, realized, verified);
         hedgeEpReal[idx] += realized;
         // A realized original-basket loss is charged against the pool.
         pool += realized; // keep a negative deficit if slippage exceeds the available pool
         hedgePool[idx] = pool;
         HedgeSaveState(idx);
         any = true;
         Print("HEDGE COMPENSATION ", sym, " ticket=", tk[best],
               " lots=", DoubleToString(vol, 4),
               " realizedLoss=", DoubleToString(-realized, 2),
               " source=", (verified ? "history" : "estimate"),
               " poolLeft=", DoubleToString(pool, 2));
         LogEvent("HEDGE-COMP " + sym + " ticket=" + IntegerToString(tk[best]) +
                  " lots=" + DoubleToString(vol, 4) +
                  " realized=" + DoubleToString(realized, 2));
      }
   }
   hedgePool[idx] = pool;
   if(any) hedgeLastAct[idx] = TimeCurrent();
   HedgeSaveState(idx);
   return any;
}

// Enforce the ratio cap after the original basket shrinks. The most profitable
// hedge legs are trimmed first; each close is booked using realized net P/L.
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
   int tk[];
   double lt[];
   double pl[];
   bool used[];
   int n = 0;
   double hLots = 0.0;

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

   if(n == 0 || hLots <= cap + step * 0.000001)
      return false;

   double remaining = MathCeil((hLots - cap) / step - 0.000001) * step;
   bool any = false;
   double bookedTrimNet = 0.0;
   int bookedTrimTickets = 0;
   for(int round = 0; round < n && remaining >= minLot * 0.5; round++)
   {
      int best = -1;
      for(int k = 0; k < n; k++)
         if(!used[k] && (best < 0 || pl[k] > pl[best])) best = k;
      if(best < 0) break;
      used[best] = true;

      double vol = NormalizeLotsDown(sym, MathMin(lt[best], remaining));
      if(lt[best] - vol > 0 && lt[best] - vol < minLot)
         vol = lt[best];
      if(vol < minLot) continue;

      double estimate = pl[best] * vol;
      if(ClosePartialTicket(tk[best], vol))
      {
         double realized = estimate;
         bool verified = false;
         ClosedTicketProfit(tk[best], estimate, realized, verified);
         HedgeBook(idx, realized, verified, "trim");
         bookedTrimNet += realized;
         bookedTrimTickets++;
         remaining -= vol;
         any = true;
         Print("HEDGE TRIM ", sym, " ticket=", tk[best],
               " lots=", DoubleToString(vol, 4), " cap=",
               DoubleToString(HedgeMaxRatio * 100.0, 0), "%");
      }
   }
   if(bookedTrimTickets > 0 && bookedTrimNet < 0.0)
   {
      hedgeStopCount[idx]++;
      HedgeSaveState(idx);
      Print("HEDGE TRIM LOSS COUNTER ", sym, " ", hedgeStopCount[idx], "/", HedgeMaxStopCount,
            " netTrim=", DoubleToString(bookedTrimNet, 2));
   }
   return any;
}

// Main per-instrument hedge routine. Called after basket TP/mixed checks.
// Returns true only if original-basket lots changed through pool compensation.
bool ManageHedge(int idx, int dir, double flt)
{
   bool changed = false;
   string sym = Syms[idx];
   int magic = MagicBase + idx;
   int hm = HedgeMagic(idx);

   int hDir = 0, hLegs = 0;
   double hLots = 0, hAvg = 0, hLast = 0, hFlt = 0;
   bool hMixed = false;
   bool hasH = ScanBasketEx(sym, hm, hDir, hLegs, hLots, hAvg, hLast, hFlt, hMixed);

   // Existing hedge positions must not be abandoned if settings change to shadow/disabled.
   if(hasH && !LogOnly && (!HedgeEnabled || HedgeShadowMode))
   {
      if(!HedgeCloseAll(idx, HedgeEnabled ? "shadow-mode-enabled" : "hedge-disabled"))
         return false;
      hasH = ScanBasketEx(sym, hm, hDir, hLegs, hLots, hAvg, hLast, hFlt, hMixed);
   }

   if(hasH && (hMixed || hDir == dir))
   {
      Print("CRITICAL: invalid hedge basket on ", sym, " (mixed or same direction) -> closing");
      if(!HedgeCloseAll(idx, "invalid-hedge-direction"))
         return false;
      return false;
   }

   if(!HedgeEnabled)
      return false;

   double currentBase = HedgeDrawdownBaseValue();
   if(hedgeState[idx] == HEDGE_OFF && hedgeBaseAtStart[idx] > 0.0)
   {
      hedgeBaseAtStart[idx] = 0.0;
      GlobalVariableSet(SymKey(idx, "HBASE"), 0);
   }
   double base = (hedgeBaseAtStart[idx] > 0.0) ? hedgeBaseAtStart[idx] : currentBase;
   if(hedgeState[idx] != HEDGE_OFF && hedgeBaseAtStart[idx] <= 0.0 && currentBase > 0.0)
   {
      hedgeBaseAtStart[idx] = currentBase;
      base = hedgeBaseAtStart[idx];
      GlobalVariableSet(SymKey(idx, "HBASE"), hedgeBaseAtStart[idx]);
   }
   double episodeLoss = HedgeEpisodeLoss(flt, (hasH ? hFlt : 0.0), hedgeEpReal[idx]);
   double pct = (base > 0.0) ? episodeLoss / base * 100.0 : (episodeLoss > 0.0 ? 999.0 : 0.0);
   hedgePct[idx] = pct;
   ENUM_HEDGE_STATE stateBeforeUpdate = hedgeState[idx];
   HedgeUpdateState(idx, pct, hLegs);
   if(stateBeforeUpdate == HEDGE_OFF && hedgeState[idx] != HEDGE_OFF && hedgeBaseAtStart[idx] <= 0.0)
   {
      hedgeBaseAtStart[idx] = currentBase;
      base = hedgeBaseAtStart[idx];
      GlobalVariableSet(SymKey(idx, "HBASE"), hedgeBaseAtStart[idx]);
   }
   if(hedgeState[idx] == HEDGE_OFF && hedgeBaseAtStart[idx] > 0.0)
   {
      hedgeBaseAtStart[idx] = 0.0;
      GlobalVariableSet(SymKey(idx, "HBASE"), 0);
   }

   datetime hb = iTime(sym, HedgeTF, 1);
   bool newH4 = (hb > 0 && hb != hedgeLastEvalBar[idx]);
   if(newH4)
   {
      hedgeLastEvalBar[idx] = hb;
      GlobalVariableSet(SymKey(idx, "HEVAL"), (double)hb);
   }

   string entryInfo = "";
   string holdInfo = "";
   bool entryDataOK = false;
   bool holdDataOK = false;
   bool entrySignal = false;
   bool holdSignal = false;
   if(hedgeState[idx] != HEDGE_OFF && dir != 0)
   {
      entrySignal = HedgeEntrySignal(idx, dir, entryInfo, entryDataOK);
      holdSignal = HedgeHoldSignal(idx, dir, holdInfo, holdDataOK);
      hedgeSig[idx] = entrySignal ? 1 : 0;
      HedgeLog(idx, "stats",
               StringFormat("state=%d episodeLoss=%.2f (%.2f%% of %s) originalFloat=%.2f hedgeFloat=%.2f hedgeLots=%.2f pool=%.2f | entry=%s hold=%s",
                            (int)hedgeState[idx], episodeLoss, pct, HedgeDrawdownBaseName(),
                            flt, hFlt, hLots, hedgePool[idx],
                            (entrySignal ? "Y" : "n"), (holdSignal ? "Y" : "n")));
   }
   else
   {
      hedgeSig[idx] = 0;
   }

   // A closed hedge's net profit pool can still reduce original losers even if
   // the state has already fallen below ACTIVE. This uses realized P/L only.
   if(HedgeTrading() && hedgePool[idx] > 0.0)
   {
      if(HedgeCompensate(idx, sym, magic))
      {
         changed = true;
         if(!ScanBasketEx(sym, magic, dir, legs, totLots, hAvg, hLast, flt, hMixed))
            return true;
      }
   }

   if(!HedgeEnabled || hedgeState[idx] != HEDGE_ACTIVE)
      return changed;

   bool trading = HedgeTrading();
   if(!trading)
   {
      if(HedgeShadowMode && entrySignal)
      {
         double capRatio = HedgeCapRatio(pct);
         HedgeLog(idx, "open", StringFormat("SHADOW: would open %s hedge up to %.2f lots (%.0f%% of original); no orders sent",
                                             (dir > 0 ? "SELL" : "BUY"), totLots * capRatio, capRatio * 100.0));
      }
      return changed;
   }

   // Existing hedge hard loss stop (floating loss only); it is independent of account kill-switch.
   if(hLegs > 0 && base > 0.0 && hFlt < 0.0)
   {
      double hedgeLossPct = (-hFlt) / base * 100.0;
      if(hedgeLossPct >= HedgeMaxLossPct)
      {
         Print("HEDGE HARD STOP ", sym, " hedgeLoss=", DoubleToString(-hFlt, 2),
               " (", DoubleToString(hedgeLossPct, 2), "% of ", HedgeDrawdownBaseName(), ")");
         if(!HedgeCloseAll(idx, "hard-loss-stop"))
            return changed;
         hedgeOpenBar[idx] = hb;
         hedgeLastAct[idx] = TimeCurrent();
         HedgeSaveState(idx);
         return changed;
      }
   }

   // TP closes the hedge leg basket and banks the actual realized net result.
   if(hLegs > 0 && HedgeTakeProfitPct > 0 && hAvg > 0.0)
   {
      double bid = MarketInfo(sym, MODE_BID);
      double ask = MarketInfo(sym, MODE_ASK);
      bool tp = (hDir < 0)
                ? (ask <= hAvg * (1.0 - HedgeTakeProfitPct / 100.0))
                : (bid >= hAvg * (1.0 + HedgeTakeProfitPct / 100.0));
      if(tp)
      {
         if(!HedgeCloseAll(idx, "take-profit"))
            return changed;
         hedgeOpenBar[idx] = hb;
         hedgeLastAct[idx] = TimeCurrent();
         HedgeSaveState(idx);
         hLegs = CountBasketOrders(sym, hm);
      }
   }

   // Exit confirmation depends only on EMA+RSI, never on tick-volume contraction.
   if(hLegs > 0 && newH4 && holdDataOK)
   {
      if(holdSignal)
         hedgeSignalFailCount[idx] = 0;
      else
         hedgeSignalFailCount[idx]++;

      if(hedgeSignalFailCount[idx] >= HedgeExitConfirmBars)
      {
         Print("HEDGE EXIT SIGNAL ", sym, " failed for ", hedgeSignalFailCount[idx], " closed H4 bars");
         if(!HedgeCloseAll(idx, "ema-rsi-signal-lost"))
            return changed;
         hedgeOpenBar[idx] = hb;
         hedgeLastAct[idx] = TimeCurrent();
         hedgeSignalFailCount[idx] = 0;
         HedgeSaveState(idx);
         hLegs = CountBasketOrders(sym, hm);
      }
   }

   // Bank profitable hedge tickets only once per newly closed H4 bar; tick volume
   // does not participate in exit logic. Then use the realized pool to compensate.
   if(hLegs > 0 && newH4)
      HedgeBankProfitableLegs(idx);

   // Use newly banked hedge profits against the most losing original legs.
   if(hedgePool[idx] > 0.0 && HedgeCompensate(idx, sym, magic))
   {
      changed = true;
      if(!ScanBasketEx(sym, magic, dir, legs, totLots, hAvg, hLast, flt, hMixed))
         return true;
   }

   // Ratio cap is re-enforced after every original-basket reduction.
   if(CountBasketOrders(sym, hm) > 0)
      HedgeTrimExcess(idx);

   // Re-scan hedge after close/trim before deciding whether another leg can open.
   hasH = ScanBasketEx(sym, hm, hDir, hLegs, hLots, hAvg, hLast, hFlt, hMixed);
   if(hedgeStopCount[idx] >= HedgeMaxStopCount)
   {
      HedgeLog(idx, "open", "hedge entries locked after repeated hard-loss stops; waiting for drawdown to leave ACTIVE");
      return changed;
   }
   if(!entrySignal || !entryDataOK || hLegs >= HedgeMaxLegs)
      return changed;
   if(hb <= 0 || hb == hedgeOpenBar[idx])
      return changed;  // one new hedge leg per closed H4 bar
   if(hedgeLastAct[idx] > 0 && TimeCurrent() - hedgeLastAct[idx] < HedgeCooldownMin * 60)
      return changed;
   if(MaxSpreadPoints > 0 && MarketInfo(sym, MODE_SPREAD) > MaxSpreadPoints)
      return changed;

   // The original basket may have changed through compensation; refresh lots.
   int od = 0, ol = 0;
   double oLots = 0, oa = 0, olast = 0, of = 0;
   bool om = false;
   if(!ScanBasketEx(sym, magic, od, ol, oLots, oa, olast, of, om))
      return true;

   double lot = HedgeOpenLot(sym, oLots, hLots, pct);
   if(lot <= 0.0)
      return changed;

   if(OpenLeg(sym, -od, lot, hm, "hedge-recovery"))
   {
      hedgeOpenBar[idx] = hb;
      hedgeLastAct[idx] = TimeCurrent();
      hedgeSignalFailCount[idx] = 0;
      HedgeSaveState(idx);
      Print("HEDGE OPEN ", sym, " ", (od > 0 ? "SELL" : "BUY"), " ",
            DoubleToString(lot, LotDigits(sym)), " lots; original=", DoubleToString(oLots, 4),
            " cap=", DoubleToString(HedgeCapRatio(pct) * 100.0, 1),
            "% DD=", DoubleToString(pct, 2), "%");
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
                            " hedgeEpReal=", DoubleToString(hedgeEpReal[idx], 2),
                            " hedgeBase=", HedgeDrawdownBaseName(),
                            " hedgeMaxLossPct=", DoubleToString(HedgeMaxLossPct, 2),
                            " hedgeStopCount=", hedgeStopCount[idx]);
}
//+------------------------------------------------------------------+
//| END OF FILE                                                       |
//+------------------------------------------------------------------+
