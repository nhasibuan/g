//+------------------------------------------------------------------+
//|                                        EA_HOKKY_V5_HEDGE.mq4     |
//| HOKKY V5.01 - Hedged Grid + Trailing Stops + DD Reduction         |
//| Single-file, hardened, MQL4 best-practice rebuild.                |
//|                                                                  |
//| NEW vs V4.30:                                                     |
//|   - Hedge grid: L1,L2,... alternate direction (pendulum grid)     |
//|   - Trailing stop service (per order, ATR-based)                  |
//|   - Hedge offset DD reduction (harvest winning side)              |
//|   - Absolute loss guards (equity floor, basket money stop)        |
//|   - Both directions work independently and simultaneously         |
//|                                                                  |
//| FIXES:                                                            |
//|   - MaxLevel=8, Multiplier=1.30, UseBasketSL=true, Journal=true   |
//|   - Trend filter on H1, MA(50) defaults                           |
//|   - Non-blocking close-all FSM (no Sleep in tick)                 |
//|   - Persistent schema guard, instance lease, protection fault     |
//|                                                                  |
//| V5.01 CLEANUP (XAUUSD M1 hardening):                              |
//|   - Renamed misleading *_Pips inputs: these are ATR multipliers,  |
//|     not pips. InpBasketSL_Pips -> InpBasketSL_ATR,                |
//|     InpHardSLPips -> InpHardSL_ATR. (.set keys updated to match.)  |
//|   - De-duplicated redundant step-check in TrailOneSell (was a     |
//|     double-tested gate; now mirrors TrailOneBuy).                 |
//|   - Clarified InpDDResetMode/InpDDCooldownMin: COOLDOWN with      |
//|     DDCooldownMin<=0 is a PERMANENT latch until manual reset.     |
//|   - Clarified InpHedgeMode: requires a HEDGING (non-netting)       |
//|     account; on a netting server both legs net out and the grid  |
//|     malfunctions silently.                                        |
//|   - Clarified InpSlippage: in points; raise (30-50) for volatile  |
//|     symbols such as XAUUSD so risk-exit fills succeed in spikes.  |
//+------------------------------------------------------------------+
#property strict
#property copyright "HOKKY V5 HEDGE"
#property version   "5.01"
#property description "Hedged grid EA with trailing stops, DD reduction, and layered risk controls."

#include <stderror.mqh>

//--- =================== ENUMS ====================
enum ENUM_LOT_MODE      { LOT_FIXED = 0, LOT_MULTIPLIER = 1, LOT_RECOVERY = 2 };
enum ENUM_DD_MODE       { DD_ACCOUNT = 0, DD_EA_FLOATING = 1 };
enum ENUM_EQUITY_RESET  { EQRESET_LATCHED = 0, EQRESET_COOLDOWN = 1 };
enum ENUM_EA_STATE      { EA_STARTING = 0, EA_WAIT_ATR = 1, EA_RUNNING = 2,
                          EA_CLOSE_ALL_PENDING = 3, EA_DD_LATCHED = 4, EA_PROTECTION_FAULT = 5
                        };
enum ENUM_STATE_COMMAND { STATE_KEEP = 0, STATE_RESET_DD_LATCH = 1, STATE_RESET_RECOVERY = 2,
                          STATE_RESET_SESSION = 3, STATE_RESET_ALL_RISK = 4
                        };

//--- =================== INPUTS: IDENTITY ====================
input string              InpEA_Comment           = "HOKKY_V5";
input int                 InpMagicNumber          = 0;       // 0 = persisted auto magic
input int                 InpSlippage             = 3;       // points; raise to 30-50 for volatile symbols (XAUUSD) so risk-exit OrderClose fills succeed in spikes
input string              InpObjectPrefix         = "H5";
input bool                InpPurgeStateOnInit     = false;
input ENUM_STATE_COMMAND  InpStateCommand         = STATE_KEEP;
input int                 InpStateCommandId       = 0;
input bool                InpRequireBrokerSL      = true;
input int                 InpLeaseStaleSeconds     = 10;

//--- =================== INPUTS: WINDOW ====================
input bool                InpAllowNewBaskets      = true;
input bool                InpAllowAddons          = true;
input int                 InpLoop                 = 10000;
input int                 InpStartTrade           = 0;
input int                 InpEndTrade             = 24;
input double              InpMaxSpreadPoints       = 60.0;

//--- =================== INPUTS: ATR & DISTANCES ====================
// NOTE: every distance below is a MULTIPLE of ATR(InpATRPeriod), not pips.
//        Final price distance = multiplier * ATR. ATR-adaptive by design.
input int                 InpATRPeriod            = 14;
input double              InpDistance             = 1.00;    // grid spacing = X * ATR against newest order
input double              InpTP                   = 0.75;    // basket take-profit = X * ATR from avg price
input double              InpIndivTP              = 0.00;    // per-order TP = X * ATR (0 = off)
input double              InpBasketSL_ATR         = 4.00;    // basket SL distance as ATR MULTIPLE (not pips)
input double              InpSL                   = 0.00;    // per-order soft SL = X * ATR (0 = off)
input double              InpHardSL_ATR           = 6.00;    // per-order broker hard SL as ATR MULTIPLE (not pips)

//--- =================== INPUTS: LOTS & GRID (tamed) ====================
input ENUM_LOT_MODE       InpDbLots               = LOT_MULTIPLIER;
input double              InpLots                 = 0.01;
input double              InpMultiplier           = 1.60;    
input int                 InpMaxLevel             = 8;       
input double              InpMaxLotPerOrder       = 1.00;
input double              InpMaxTotalLots         = 5.00;
input double              InpMaxRecoveryLot        = 0.10;
input bool                InpHaltAddonsWhenCapped = true;

//--- =================== INPUTS: HEDGE GRID ====================
input bool                InpHedgeMode            = true;    // alternating hedge grid (pendulum). REQUIRES a HEDGING (non-netting) account: on a netting server simultaneous BUY+SELL net to zero and the EA malfunctions silently.
input bool                InpAllowBothDirections  = true;    // BUY and SELL baskets can coexist
input bool                InpUseHedgeOffset       = true;    // harvest winner to reduce DD
input double              InpHedgeOffsetMinProfit = 5.0;     // $ on winning side (fixed $; scale to account size)
input double              InpHedgeOffsetMaxLoss   = 20.0;    // $ on losing side (abs, fixed $; scale to account size)
input int                 InpHedgeOffsetCooldown  = 60;      // seconds between harvests

//--- =================== INPUTS: TRAILING STOP ====================
input bool                InpUseTrailingStop      = true;    // NEW
input double              InpTrailStartATR        = 1.00;    // start trailing at X ATR profit
input double              InpTrailDistanceATR     = 0.50;    // trail X ATR behind price
input int                 InpTrailStepPoints      = 20;      // min SL move in points

//--- =================== INPUTS: BASKET EXITS ====================
input bool                InpUseBasketTP          = true;
input bool                InpUseBasketSL          = true;    
input int                 InpMinModifyPoints      = 10;

//--- =================== INPUTS: RISK ====================
input ENUM_DD_MODE        InpDDMode               = DD_EA_FLOATING;  // DD_EA_FLOATING measures only THIS EA's floating P/L vs balance (not whole-account equity). On shared accounts the real account DD can exceed this cap.
input double              InpMaxDrawdownPct       = 20.0;
input double              InpMaxSessionDDPct      = 8.0;
input bool                InpCloseAllOnDDStop     = true;
input ENUM_EQUITY_RESET   InpDDResetMode          = EQRESET_COOLDOWN;  // after a DD breach, how the latch clears
input int                 InpDDCooldownMin        = 60;                // minutes; with EQRESET_COOLDOWN, latch auto-releases after this many minutes. WARNING: value <= 0 makes the latch PERMANENT until manual STATE_RESET_DD_LATCH.
input double              InpMinMarginLevel       = 150.0;
input double              InpMinEquity            = 0.0;
input double              InpMaxBasketLossMoney    = 0.0;

//--- =================== INPUTS: ENTRY FILTERS ====================
input bool                InpUseTrendFilter       = true;
input bool                InpTrendFilterAddons    = true;
input int                 InpTrendMA_Period       = 50;      // H1 EMA(50) = real trend gate; MA(9) on M5 is permissive noise
input ENUM_MA_METHOD      InpTrendMA_Method       = MODE_EMA;
input ENUM_TIMEFRAMES     InpTrendTimeframe       = PERIOD_H1;// H1 default; setting M5 re-enables a noisy permissive filter
input bool                InpUseADXFilter         = false;
input int                 InpADXPeriod            = 14;
input double              InpADXThreshold         = 22.0;
input bool                InpADXUseDI             = true;

//--- =================== INPUTS: UI ====================
input bool                InpUseDashboard         = true;
input bool                InpJournalEnabled      = true;
input string              InpJournalFile          = "HOKKY_trades.csv";

//--- =================== CONSTANTS ====================
#define HOKKY_STATE_SCHEMA   6.0
#define LOT_EPSILON          0.0000001
#define PROTECTION_REPAIR_OK 60
#define PROTECTION_REPAIR_BAD 5
#define DASHBOARD_THROTTLE   1
#define WARN_THROTTLE_SEC    300
#define HEARTBEAT_TOUCH_SEC  3600

//--- =================== STRUCTURES ====================
struct COrderData
  {
   int               ticket;
   int               type;        // OP_BUY / OP_SELL
   int               level;       // grid level (0 = initial)
   datetime          openTime;
   double            openPrice;
   double            lots;
   double            currentSL;
   double            currentTP;
  };

//--- =================== GLOBAL STATE ====================
int            g_magic = 0, g_ownerToken = 0;
string         g_prefix = "", g_magicGV = "", g_ownerGV = "", g_beatGV = "", g_objPrefix = "";
bool           g_lockOwned = false, g_leaseLost = false;

ENUM_EA_STATE  g_state = EA_STARTING;
string         g_stateReason = "starting";

datetime       g_lastBarTime = 0, g_atrChartBarTime = 0, g_atrSourceTime = 0;
double         g_atr = 0.0;
bool           g_atrValid = false, g_protectionDirty = true, g_latchAfterClose = false;
datetime       g_nextRepairTime = 0;

int            g_lastTradeError = 0, g_initialTrades = 0, g_previousOpenCount = 0;
datetime       g_lastDashboard = 0, g_lastWarning = 0, g_lastHedgeOffset = 0;

int            g_lastHistoryTotal = -1, g_lastHistoryProcessed = 0;
datetime       g_lastHistoryScan = 0;

COrderData     g_buyOrders[], g_sellOrders[];
int            g_buyCount = 0, g_sellCount = 0;
double         g_buyLots = 0.0, g_sellLots = 0.0, g_buyAvg = 0.0, g_sellAvg = 0.0;
double         g_buyNewestPrice = 0.0, g_sellNewestPrice = 0.0;
double         g_buyPL = 0.0, g_sellPL = 0.0, g_ownFloatingPL = 0.0;
datetime       g_buyNewestTime = 0, g_sellNewestTime = 0;
int            g_buyNewestTicket = 0, g_sellNewestTicket = 0;
int            g_buyNewestLevel = -1, g_sellNewestLevel = -1;

int            g_basketId = 0;
datetime       g_basketStart = 0;
bool           g_basketActive = false;
double         g_basketRealized = 0.0, g_nextRecoveryLot = 0.0;

datetime       g_sessionStart = 0;
double         g_sessionBaseBalance = 0.0, g_sessionRealized = 0.0, g_sessionPeakNet = 0.0, g_sessionDDPct = 0.0;

//+------------------------------------------------------------------+
//| LIFECYCLE                                                         |
//+------------------------------------------------------------------+
int OnInit()
  {
   MathSrand((int)GetTickCount());
   g_ownerToken = (int)(GetTickCount() % 100000000) + MathRand() + 1;
   if(!ValidateInputs())
      return(INIT_PARAMETERS_INCORRECT);
   if(!ResolveMagic())
      return(INIT_FAILED);
   BuildPersistentNames();
   if(!AcquireInstanceLease())
     {
      Print("HOKKY V5: lease blocked");
      return(INIT_FAILED);
     }
   LoadPersistentState();
   RefreshCache();
   if(InpPurgeStateOnInit)
     {
      if(g_buyCount + g_sellCount > 0)
        {
         ReleaseInstanceLease();
         return(INIT_PARAMETERS_INCORRECT);
        }
      PurgeRiskState();
      LoadPersistentState();
     }
   if(!ApplyStateCommand())
     {
      ReleaseInstanceLease();
      return(INIT_PARAMETERS_INCORRECT);
     }
   RestoreOrCreateBasketState();
   UpdateATR(true);
   InvalidateHistoryCache();
   UpdateHistoryState(true);

   if(IsEquityStopLatched())
     {
      g_state = EA_DD_LATCHED;
      g_stateReason = "persistent drawdown latch";
     }
   else
      if(!g_atrValid)
        {
         g_state = EA_WAIT_ATR;
         g_stateReason = "waiting for closed-bar ATR";
        }
      else
        {
         g_state = EA_RUNNING;
         g_stateReason = "monitoring";
        }

   EventSetTimer(1);
   UpdateHeartbeat();
   if(InpUseDashboard)
      UpdateDashboard();
   Print("HOKKY V5.01 HEDGE init. Magic=", g_magic, " HedgeMode=", InpHedgeMode, " Trail=", InpUseTrailingStop);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ReleaseInstanceLease();
   DeleteOwnObjects();
  }

//+------------------------------------------------------------------+
//| TIMER: heartbeat + non-blocking close-all FSM + dashboard         |
//+------------------------------------------------------------------+
void OnTimer()
  {
   UpdateHeartbeat();
   if(g_leaseLost)
      return;
   TouchPersistentState();

   if(g_state == EA_CLOSE_ALL_PENDING || g_state == EA_PROTECTION_FAULT)
     {
      DriveCloseAllFSM();
      UpdateDashboardThrottled();
      return;
     }
   CheckLatchRelease();
   if(InpUseDashboard && TimeCurrent() - g_lastDashboard >= 5)
     {
      g_lastDashboard = TimeCurrent();
      UpdateDashboard();
     }
  }

//+------------------------------------------------------------------+
//| TICK: main pipeline                                               |
//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateHeartbeat();
   if(g_leaseLost)
      return;

   bool newBar = UpdateATR(false);
   RefreshCache();

   int openCount = g_buyCount + g_sellCount;
   if(g_previousOpenCount > 0 && openCount == 0)
      FinalizeBasket();
   g_previousOpenCount = openCount;
   UpdateHistoryState(false);

   if(g_state == EA_CLOSE_ALL_PENDING || g_state == EA_PROTECTION_FAULT)
     {
      DriveCloseAllFSM();
      UpdateDashboardThrottled();
      return;
     }

   CheckLatchRelease();
   if(IsEquityStopLatched())
     {
      g_state = EA_DD_LATCHED;
      UpdateDashboardThrottled();
      return;
     }
   if(CheckRiskStops())
     {
      UpdateDashboardThrottled();
      return;
     }
   if(!g_atrValid)
     {
      g_state = EA_WAIT_ATR;
      UpdateDashboardThrottled();
      return;
     }

// Hedge offset (DD reduction) - runs every tick, throttled internally
   ApplyHedgeOffset();

// Logical exits & trailing stops
   if(ManageLogicalExits())
     {
      RefreshCache();
      UpdateDashboardThrottled();
      return;
     }

   if(newBar)
      g_protectionDirty = true;
   if(g_protectionDirty || TimeCurrent() >= g_nextRepairTime)
      ReconcileBrokerProtection();

   if(g_state == EA_PROTECTION_FAULT || g_state == EA_CLOSE_ALL_PENDING)
     {
      UpdateDashboardThrottled();
      return;
     }

   g_state = EA_RUNNING;
   g_stateReason = "monitoring";

// Entry logic on new bar only
   if(Time[0] != g_lastBarTime)
     {
      g_lastBarTime = Time[0];
      ProcessTrading();
     }
   UpdateDashboardThrottled();
  }

//+------------------------------------------------------------------+
//| FSM: non-blocking close-all driver                               |
//+------------------------------------------------------------------+
void DriveCloseAllFSM()
  {
   bool protectionFault = (g_state == EA_PROTECTION_FAULT);
   if(CloseAllOwnOrdersPass())
     {
      RefreshCache();
      if(g_buyCount + g_sellCount == 0)
        {
         FinalizeBasket();
         if(g_latchAfterClose || protectionFault)
            LatchEquityStop(g_stateReason);
         else
           {
            g_state = g_atrValid ? EA_RUNNING : EA_WAIT_ATR;
            g_stateReason = "basket closed";
           }
         g_latchAfterClose = false;
        }
     }
  }

//+------------------------------------------------------------------+
//| VALIDATION                                                        |
//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   if(InpMagicNumber < 0 || InpATRPeriod < 1 || InpDistance <= 0.0)
      return InitError("Invalid ATR/Magic");
   if(InpTP < 0.0 || InpIndivTP < 0.0 || InpBasketSL_ATR < 0.0 || InpSL < 0.0 || InpHardSL_ATR < 0.0)
      return InitError("ATR distance < 0");
   if(InpLots <= 0.0 || InpMultiplier < 1.0 || InpMaxLevel < 1)
      return InitError("Lot/Grid invalid");
   if(InpStartTrade < 0 || InpStartTrade > 23)
      return InitError("InpStartTrade must be 0..23");
   if(InpEndTrade < 0 || InpEndTrade > 24)
      return InitError("InpEndTrade must be 0..24");
   if(InpLeaseStaleSeconds < 5)
      return InitError("InpLeaseStaleSeconds must be >= 5");
   if(InpRequireBrokerSL && InpHardSL_ATR <= 0.0)
      return InitError("InpRequireBrokerSL requires InpHardSL_ATR > 0");
   if(InpUseBasketTP && InpTP <= 0.0)
      return InitError("InpTP must be > 0 when basket TP is enabled");
   if(InpUseTrailingStop && InpTrailDistanceATR <= 0.0)
      return InitError("Trailing requires InpTrailDistanceATR > 0");
   if(InpUseTrailingStop && InpTrailStartATR < InpTrailDistanceATR)
      return InitError("TrailStartATR must be >= TrailDistanceATR");
   if(NormalizeLotDown(InpLots) <= 0.0)
      return InitError("InpLots below broker minimum");
// Informational (not fatal): COOLDOWN mode with zero cooldown = permanent latch.
   if(InpDDResetMode == EQRESET_COOLDOWN && InpDDCooldownMin <= 0)
      Print("HOKKY V5: DDCooldownMin<=0 with COOLDOWN mode => DD latch is PERMANENT until manual STATE_RESET_DD_LATCH.");
// Informational: hedge mode needs a hedging account.
   if(InpHedgeMode)
      Print("HOKKY V5: HedgeMode is ON. Ensure the account is a HEDGING (non-netting) account.");

   bool hasExit = ((InpUseBasketTP && InpTP > 0.0) || (InpUseBasketSL && InpBasketSL_ATR > 0.0) ||
                   (InpIndivTP > 0.0) || (InpSL > 0.0) || (InpHardSL_ATR > 0.0) ||
                   (InpUseTrailingStop) ||
                   (InpMaxDrawdownPct > 0.0) || (InpMaxSessionDDPct > 0.0) ||
                   (InpMinEquity > 0.0) || (InpMaxBasketLossMoney > 0.0) || (InpMinMarginLevel > 0.0));
   if(!hasExit)
      return InitError("No exit or drawdown mechanism is enabled");
   return(true);
  }

bool InitError(string text) { Print("Parameter error: ", text); return(false); }

//+------------------------------------------------------------------+
//| IDENTITY & LEASE                                                  |
//+------------------------------------------------------------------+
bool ResolveMagic()
  {
   string accountKey = IntegerToString(AccountNumber());
   string serverKey  = IntegerToString(PositiveHash(AccountServer()));
   string symbolKey  = IntegerToString(PositiveHash(Symbol()));
   g_magicGV = "H5M_" + accountKey + "_" + serverKey + "_" + symbolKey;
   if(InpMagicNumber > 0)
     {
      g_magic = InpMagicNumber;
      return(true);
     }
   if(GlobalVariableCheck(g_magicGV))
      g_magic = (int)GlobalVariableGet(g_magicGV);
   else
     {
      g_magic = GenerateMagicNumber(Symbol() + AccountServer() + IntegerToString(AccountNumber()));
      GlobalVariableSet(g_magicGV, (double)g_magic);
      GlobalVariablesFlush();
     }
   return(g_magic > 0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void BuildPersistentNames()
  {
   string root = "H5_" + IntegerToString(AccountNumber()) + "_" +
                 IntegerToString(PositiveHash(AccountServer())) + "_" +
                 IntegerToString(PositiveHash(Symbol())) + "_" +
                 IntegerToString(g_magic) + "_";
   g_prefix    = root;
   g_ownerGV   = root + "OWN";
   g_beatGV    = root + "BEAT";
   g_objPrefix = InpObjectPrefix + IntegerToString(g_magic) + "_";
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool AcquireInstanceLease()
  {
   datetime now = TimeLocal();
   if(!GlobalVariableCheck(g_ownerGV))
      GlobalVariableSet(g_ownerGV, 0.0);
   if(!GlobalVariableCheck(g_beatGV))
      GlobalVariableSet(g_beatGV, 0.0);
   double observed = GlobalVariableGet(g_ownerGV);
   datetime beat = (datetime)GlobalVariableGet(g_beatGV);
   if(observed != 0.0 && (now - beat) < InpLeaseStaleSeconds)
      return(false);
   if(!GlobalVariableSetOnCondition(g_ownerGV, (double)g_ownerToken, observed))
      return(false);
   GlobalVariableSet(g_beatGV, (double)now);
   GlobalVariablesFlush();
   g_lockOwned = true;
   return(true);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void UpdateHeartbeat()
  {
   if(!g_lockOwned)
      return;
   if((int)GlobalVariableGet(g_ownerGV) != g_ownerToken)
     {
      g_lockOwned = false;
      g_leaseLost = true;
      g_state = EA_PROTECTION_FAULT;
      g_stateReason = "instance lease lost";
      Alert("HOKKY V5: instance lease lost. Standing down.");
      return;
     }
   GlobalVariableSet(g_beatGV, (double)TimeLocal());
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ReleaseInstanceLease()
  {
   if(!g_lockOwned)
      return;
   if((int)GlobalVariableGet(g_ownerGV) == g_ownerToken)
     {
      GlobalVariableSet(g_beatGV, 0.0);
      GlobalVariableSet(g_ownerGV, 0.0);
      GlobalVariablesFlush();
     }
   g_lockOwned = false;
  }

//+------------------------------------------------------------------+
//| PERSISTENT STATE                                                  |
//+------------------------------------------------------------------+
void LoadPersistentState()
  {
   if(GlobalVariableCheck(g_prefix + "SCHEMA"))
     {
      double oldSchema = GlobalVariableGet(g_prefix + "SCHEMA");
      if(oldSchema > 0.0 && oldSchema < HOKKY_STATE_SCHEMA)
        {
         Print("HOKKY V5: schema ", DoubleToString(oldSchema, 1), " -> ",
               DoubleToString(HOKKY_STATE_SCHEMA, 1), " (purging risk state)");
         PurgeRiskState();
        }
     }
   EnsureGV("SCHEMA", HOKKY_STATE_SCHEMA);
   EnsureGV("NEXTLOT", InpLots);
   EnsureGV("BID", 0.0);
   EnsureGV("BSTART", 0.0);
   EnsureGV("BACTIVE", 0.0);
   EnsureGV("SSTART", (double)TimeCurrent());
   EnsureGV("SBASE", AccountBalance());
   EnsureGV("SPEAK", 0.0);
   EnsureGV("LASTCMD", 0.0);
   g_nextRecoveryLot   = GlobalVariableGet(g_prefix + "NEXTLOT");
   if(g_nextRecoveryLot <= 0.0)
      g_nextRecoveryLot = InpLots;
   g_basketId          = (int)GlobalVariableGet(g_prefix + "BID");
   g_basketStart       = (datetime)GlobalVariableGet(g_prefix + "BSTART");
   g_basketActive      = (GlobalVariableGet(g_prefix + "BACTIVE") > 0.5);
   g_sessionStart      = (datetime)GlobalVariableGet(g_prefix + "SSTART");
   g_sessionBaseBalance= GlobalVariableGet(g_prefix + "SBASE");
   g_sessionPeakNet    = GlobalVariableGet(g_prefix + "SPEAK");
   if(g_sessionStart <= 0)
      g_sessionStart = TimeCurrent();
   if(g_sessionBaseBalance <= 0.0)
      g_sessionBaseBalance = AccountBalance();
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void EnsureGV(string key, double value)
  {
   if(!GlobalVariableCheck(g_prefix + key))
      GlobalVariableSet(g_prefix + key, value);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void PurgeRiskState()
  {
   string keys[12] = {"NEXTLOT","EQSTOP","EQTIME","BID","BSTART","BACTIVE",
                      "SSTART","SBASE","SPEAK","LASTCMD","SCHEMA","EQWHY"
                     };
   for(int i = 0; i < ArraySize(keys); i++)
      GlobalVariableDel(g_prefix + keys[i]);
   GlobalVariablesFlush();
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool ApplyStateCommand()
  {
   if(InpStateCommand == STATE_KEEP || InpStateCommandId <= 0)
      return(true);
   if((int)GlobalVariableGet(g_prefix + "LASTCMD") == InpStateCommandId)
      return(true);
   if(g_buyCount + g_sellCount > 0)
     {
      Print("State command refused while managed orders are open.");
      return(false);
     }
   if(InpStateCommand == STATE_RESET_DD_LATCH || InpStateCommand == STATE_RESET_ALL_RISK)
     {
      GlobalVariableDel(g_prefix + "EQSTOP");
      GlobalVariableDel(g_prefix + "EQTIME");
      GlobalVariableDel(g_prefix + "EQWHY");
     }
   if(InpStateCommand == STATE_RESET_RECOVERY || InpStateCommand == STATE_RESET_ALL_RISK)
      GlobalVariableSet(g_prefix + "NEXTLOT", InpLots);
   if(InpStateCommand == STATE_RESET_SESSION || InpStateCommand == STATE_RESET_ALL_RISK)
      ResetSessionState();
   GlobalVariableSet(g_prefix + "LASTCMD", (double)InpStateCommandId);
   GlobalVariablesFlush();
   LoadPersistentState();
   return(true);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ResetSessionState()
  {
   g_sessionStart = TimeCurrent();
   g_sessionBaseBalance = AccountBalance();
   g_sessionRealized = 0.0;
   g_sessionPeakNet = 0.0;
   g_initialTrades = 0;
   GlobalVariableSet(g_prefix + "SSTART", (double)g_sessionStart);
   GlobalVariableSet(g_prefix + "SBASE", g_sessionBaseBalance);
   GlobalVariableSet(g_prefix + "SPEAK", 0.0);
   InvalidateHistoryCache();
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsEquityStopLatched()
  {
   return(GlobalVariableCheck(g_prefix + "EQSTOP") && GlobalVariableGet(g_prefix + "EQSTOP") > 0.5);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void LatchEquityStop(string reason)
  {
   GlobalVariableSet(g_prefix + "EQSTOP", 1.0);
   GlobalVariableSet(g_prefix + "EQTIME", (double)TimeCurrent());
   GlobalVariableSet(g_prefix + "EQWHY", (double)PositiveHash(reason));
   GlobalVariablesFlush();
   g_state = EA_DD_LATCHED;
   g_stateReason = reason;
   Alert("HOKKY V5 RISK STOP latched: ", reason);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CheckLatchRelease()
  {
   if(!IsEquityStopLatched())
      return;
   if(InpDDResetMode == EQRESET_COOLDOWN && InpDDCooldownMin > 0)
     {
      if(TimeCurrent() - (datetime)GlobalVariableGet(g_prefix + "EQTIME") >= InpDDCooldownMin * 60)
        {
         GlobalVariableDel(g_prefix + "EQSTOP");
         GlobalVariableDel(g_prefix + "EQTIME");
         GlobalVariableDel(g_prefix + "EQWHY");
         ResetSessionState();
         GlobalVariablesFlush();
         g_state = g_atrValid ? EA_RUNNING : EA_WAIT_ATR;
         g_stateReason = "risk cooldown released";
        }
     }
  }

//+------------------------------------------------------------------+
//| ATR SERVICE                                                       |
//+------------------------------------------------------------------+
bool UpdateATR(bool force)
  {
   datetime bar = iTime(Symbol(), Period(), 0);
   if(!force && bar == g_atrChartBarTime)
      return(false);
   g_atrChartBarTime = bar;
   double value = iATR(Symbol(), Period(), InpATRPeriod, 1);
   datetime src  = iTime(Symbol(), Period(), 1);
   if(value > Point * 0.5 && src > 0)
     {
      bool changed = (src != g_atrSourceTime);
      g_atr = value;
      g_atrSourceTime = src;
      g_atrValid = true;
      if(changed)
        {
         g_protectionDirty = true;
         g_nextRepairTime = 0;
        }
      return(changed);
     }
   g_atrValid = false;
   return(false);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double ATRDistance(double multiplier)
  {
   return(!g_atrValid || multiplier <= 0.0 ? 0.0 : multiplier * g_atr);
  }

//+------------------------------------------------------------------+
//| CACHE                                                             |
//+------------------------------------------------------------------+
void RefreshCache()
  {
   g_buyCount = 0;
   g_sellCount = 0;
   g_buyLots = 0.0;
   g_sellLots = 0.0;
   g_buyAvg = 0.0;
   g_sellAvg = 0.0;
   g_buyPL = 0.0;
   g_sellPL = 0.0;
   g_ownFloatingPL = 0.0;
   ArrayResize(g_buyOrders, 0);
   ArrayResize(g_sellOrders, 0);
   double buyPV = 0.0, sellPV = 0.0;
   g_buyNewestTime = 0;
   g_sellNewestTime = 0;
   g_buyNewestTicket = 0;
   g_sellNewestTicket = 0;
   g_buyNewestLevel = -1;
   g_sellNewestLevel = -1;

   for(int i = 0; i < OrdersTotal(); i++)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != g_magic)
         continue;
      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;

      COrderData rec;
      rec.ticket = OrderTicket();
      rec.type = type;
      rec.openTime = OrderOpenTime();
      rec.openPrice = OrderOpenPrice();
      rec.lots = OrderLots();
      rec.currentSL = OrderStopLoss();
      rec.currentTP = OrderTakeProfit();
      rec.level = ParseLevelFromComment(OrderComment());

      double net = OrderProfit() + OrderSwap() + OrderCommission();
      g_ownFloatingPL += net;

      if(type == OP_BUY)
        {
         int n = ArraySize(g_buyOrders);
         ArrayResize(g_buyOrders, n + 1);
         g_buyOrders[n] = rec;
         g_buyCount++;
         g_buyLots += rec.lots;
         g_buyPL += net;
         buyPV += rec.openPrice * rec.lots;
         if(IsNewer(rec.openTime, rec.ticket, g_buyNewestTime, g_buyNewestTicket))
           {
            g_buyNewestTime = rec.openTime;
            g_buyNewestTicket = rec.ticket;
            g_buyNewestPrice = rec.openPrice;
            g_buyNewestLevel = rec.level;
           }
        }
      else
        {
         int n = ArraySize(g_sellOrders);
         ArrayResize(g_sellOrders, n + 1);
         g_sellOrders[n] = rec;
         g_sellCount++;
         g_sellLots += rec.lots;
         g_sellPL += net;
         sellPV += rec.openPrice * rec.lots;
         if(IsNewer(rec.openTime, rec.ticket, g_sellNewestTime, g_sellNewestTicket))
           {
            g_sellNewestTime = rec.openTime;
            g_sellNewestTicket = rec.ticket;
            g_sellNewestPrice = rec.openPrice;
            g_sellNewestLevel = rec.level;
           }
        }
     }
   if(g_buyLots > 0.0)
      g_buyAvg  = NormalizeDouble(buyPV / g_buyLots, Digits);
   if(g_sellLots > 0.0)
      g_sellAvg = NormalizeDouble(sellPV / g_sellLots, Digits);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsNewer(datetime candidateTime, int candidateTicket, datetime savedTime, int savedTicket)
  {
   if(candidateTime > savedTime)
      return(true);
   if(candidateTime == savedTime && candidateTicket > savedTicket)
      return(true);
   return(false);
  }

// Parse "|B<id>|L<n>" from order comment. Returns -1 if not found.
int ParseLevelFromComment(string comment)
  {
   int pos = StringFind(comment, "|L");
   if(pos < 0)
      return(-1);
   return((int)StringToInteger(StringSubstr(comment, pos + 2)));
  }

//+------------------------------------------------------------------+
//| BASKET / RECOVERY STATE                                           |
//+------------------------------------------------------------------+
void RestoreOrCreateBasketState()
  {
   int total = g_buyCount + g_sellCount;
   g_previousOpenCount = total;
   if(total > 0 && !g_basketActive)
     {
      datetime earliest = 0;
      for(int i = 0; i < g_buyCount; i++)
         if(earliest == 0 || g_buyOrders[i].openTime < earliest)
            earliest = g_buyOrders[i].openTime;
      for(int j = 0; j < g_sellCount; j++)
         if(earliest == 0 || g_sellOrders[j].openTime < earliest)
            earliest = g_sellOrders[j].openTime;
      g_basketId++;
      g_basketStart = earliest;
      g_basketActive = true;
      SaveBasketState();
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void StartNewBasket()
  {
   g_basketId++;
   g_basketStart = TimeCurrent();
   g_basketActive = true;
   g_basketRealized = 0.0;
   SaveBasketState();
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void SaveBasketState()
  {
   GlobalVariableSet(g_prefix + "BID", (double)g_basketId);
   GlobalVariableSet(g_prefix + "BSTART", (double)g_basketStart);
   GlobalVariableSet(g_prefix + "BACTIVE", g_basketActive ? 1.0 : 0.0);
   GlobalVariablesFlush();
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void InvalidateHistoryCache()
  {
   g_lastHistoryProcessed = 0;
   g_lastHistoryTotal = -1;
   g_lastHistoryScan = 0;
   g_sessionRealized = 0.0;
   g_basketRealized = 0.0;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void UpdateHistoryState(bool force)
  {
   int total = OrdersHistoryTotal();
   if(!force && total == g_lastHistoryTotal && TimeCurrent() - g_lastHistoryScan < 30)
      return;
   if(total < g_lastHistoryProcessed)
     {
      g_lastHistoryProcessed = 0;
      g_sessionRealized = 0.0;
      g_basketRealized = 0.0;
     }
   for(int i = g_lastHistoryProcessed; i < total; i++)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != g_magic)
         continue;
      if((OrderType() != OP_BUY && OrderType() != OP_SELL) || OrderCloseTime() <= 0)
         continue;
      double net = OrderProfit() + OrderSwap() + OrderCommission();
      if(OrderCloseTime() >= g_sessionStart)
         g_sessionRealized += net;
      if(g_basketActive && OrderOpenTime() >= g_basketStart)
         g_basketRealized += net;
     }
   g_lastHistoryProcessed = total;
   g_lastHistoryTotal = total;
   g_lastHistoryScan = TimeCurrent();

   double sessionNet = g_sessionRealized + g_ownFloatingPL;
   if(sessionNet > g_sessionPeakNet)
     {
      g_sessionPeakNet = sessionNet;
      GlobalVariableSet(g_prefix + "SPEAK", g_sessionPeakNet);
     }
   double denom = MathMax(g_sessionBaseBalance + g_sessionPeakNet, 1.0);
   g_sessionDDPct = MathMax(0.0, (g_sessionPeakNet - sessionNet) / denom * 100.0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void FinalizeBasket()
  {
   if(!g_basketActive)
      return;
   UpdateHistoryState(true);
   if(InpDbLots == LOT_RECOVERY)
     {
      if(g_basketRealized < 0.0)
         g_nextRecoveryLot = NormalizeLotDown(MathMax(InpLots, g_nextRecoveryLot) * InpMultiplier);
      else
         g_nextRecoveryLot = NormalizeLotDown(InpLots);
      if(InpMaxRecoveryLot > 0.0 && g_nextRecoveryLot > InpMaxRecoveryLot)
         g_nextRecoveryLot = NormalizeLotDown(InpMaxRecoveryLot);
      if(InpMaxLotPerOrder > 0.0 && g_nextRecoveryLot > InpMaxLotPerOrder)
         g_nextRecoveryLot = NormalizeLotDown(InpMaxLotPerOrder);
      GlobalVariableSet(g_prefix + "NEXTLOT", g_nextRecoveryLot);
     }
   double realized = g_basketRealized;
   g_basketActive = false;
   g_basketStart = 0;
   g_basketRealized = 0.0;
   SaveBasketState();
   InvalidateHistoryCache();
   LogTrade("BASKET-END", 0, 0.0, 0.0, 0.0, 0.0,
            "basket #" + IntegerToString(g_basketId) + " realized=" + DoubleToString(realized, 2));
  }

//+------------------------------------------------------------------+
//| TRADING ENGINE                                                    |
//+------------------------------------------------------------------+
void ProcessTrading()
  {
   if(!g_atrValid || !IsTradeContextUsable() || (!InpAllowNewBaskets && !InpAllowAddons))
      return;
   if(g_initialTrades >= InpLoop)
      return;
   if(!IsWithinTradingHours() || (InpMaxSpreadPoints > 0.0 && CurrentSpreadPoints() > InpMaxSpreadPoints))
      return;

   int own = g_buyCount + g_sellCount;
   if(own == 0)
     {
      if(InpAllowNewBaskets)
         OpenInitialTrade();
      return;
     }
   if(own >= InpMaxLevel || !InpAllowAddons)
      return;

   if(InpHedgeMode)
      ProcessHedgeGrid();
   else
      ProcessClassicGrid();
  }

//+------------------------------------------------------------------+
//| CLASSIC GRID (same-direction martingale)                          |
//+------------------------------------------------------------------+
void ProcessClassicGrid()
  {
   if(g_buyCount > 0 && g_sellCount > 0)
      return; // classic mode: one direction only
   double distance = ATRDistance(InpDistance);
   if(distance <= 0.0)
      return;

   if(g_buyCount > 0 && g_buyNewestPrice > 0.0 && (g_buyNewestPrice - Ask) >= distance)
     {
      if(!InpUseTrendFilter || !InpTrendFilterAddons || IsTrendAligned(OP_BUY))
         OpenAddonTrade(OP_BUY);
     }
   if(g_sellCount > 0 && g_sellNewestPrice > 0.0 && (Bid - g_sellNewestPrice) >= distance)
     {
      if(!InpUseTrendFilter || !InpTrendFilterAddons || IsTrendAligned(OP_SELL))
         OpenAddonTrade(OP_SELL);
     }
  }

//+------------------------------------------------------------------+
//| HEDGE GRID (alternating direction pendulum)                       |
//|                                                                  |
//| Rule:                                                             |
//|   - Look at the NEWEST order overall.                             |
//|   - If price moved against it by >= Distance ATR, open the        |
//|     OPPOSITE direction.                                           |
//|   - This naturally alternates BUY/SELL as the market oscillates.  |
//|   - Both directions accumulate if both sides are stressed.        |
//+------------------------------------------------------------------+
void ProcessHedgeGrid()
  {
   double distance = ATRDistance(InpDistance);
   if(distance <= 0.0)
      return;

// Determine the newest order across both sides
   datetime newestTime = 0;
   int      newestType = -1;
   double   newestPrice = 0.0;
   if(IsNewer(g_buyNewestTime, g_buyNewestTicket, g_sellNewestTime, g_sellNewestTicket))
     {
      newestTime = g_buyNewestTime;
      newestType = OP_BUY;
      newestPrice = g_buyNewestPrice;
     }
   else
      if(g_sellNewestTicket > 0)
        {
         newestTime = g_sellNewestTime;
         newestType = OP_SELL;
         newestPrice = g_sellNewestPrice;
        }
      else
         if(g_buyNewestTicket > 0)
           {
            newestTime = g_buyNewestTime;
            newestType = OP_BUY;
            newestPrice = g_buyNewestPrice;
           }

   if(newestType < 0 || newestPrice <= 0.0)
      return;

// Check if price moved against the newest order by Distance
   if(newestType == OP_BUY)
     {
      if((newestPrice - Ask) >= distance && InpAllowBothDirections)
        {
         if(!InpUseTrendFilter || !InpTrendFilterAddons || IsTrendAligned(OP_SELL))
            OpenAddonTrade(OP_SELL);
        }
     }
   else // OP_SELL
     {
      if((Bid - newestPrice) >= distance && InpAllowBothDirections)
        {
         if(!InpUseTrendFilter || !InpTrendFilterAddons || IsTrendAligned(OP_BUY))
            OpenAddonTrade(OP_BUY);
        }
     }
  }

//+------------------------------------------------------------------+
//| Initial trade (fade)                                              |
//+------------------------------------------------------------------+
void OpenInitialTrade()
  {
   double close2 = iClose(Symbol(), Period(), 2), close1 = iClose(Symbol(), Period(), 1);
   if(close2 <= 0.0 || close1 <= 0.0 || MathAbs(close2 - close1) < Point * 0.5)
      return;
   int cmd = (close2 > close1) ? OP_SELL : OP_BUY; // fade
   if(InpUseTrendFilter && !IsTrendAligned(cmd))
      return;

   StartNewBasket();
   double lot = CalculateLotSize(0);
   int ticket = SafeOrderSend(cmd, lot, BuildOrderComment(0));
   if(ticket > 0)
     {
      g_initialTrades++;
      RefreshCache();
      g_previousOpenCount = g_buyCount + g_sellCount;
      g_protectionDirty = true;
     }
   else
     {
      if(g_buyCount + g_sellCount == 0)
        {
         g_basketActive = false;
         g_basketStart = 0;
         SaveBasketState();
        }
     }
  }

//+------------------------------------------------------------------+
//| Addon trade (hedge or classic)                                    |
//+------------------------------------------------------------------+
void OpenAddonTrade(int cmd)
  {
   int level = g_buyCount + g_sellCount;
   double lot = CalculateLotSize(level);

   if(InpHaltAddonsWhenCapped && level > 0)
     {
      double capLimit = 0.0;
      if(InpMaxLotPerOrder > 0.0)
         capLimit = InpMaxLotPerOrder;
      if(InpMaxRecoveryLot > 0.0 && (capLimit <= 0.0 || InpMaxRecoveryLot < capLimit))
         capLimit = InpMaxRecoveryLot;
      double rawLot = CalculateRawLot(level);
      bool capClamped = (capLimit > 0.0 && rawLot >= capLimit - LOT_EPSILON);
      if(capClamped)
        {
         double prevLot = CalculateLotSize(level - 1);
         if(lot <= prevLot + LOT_EPSILON)
           {
            WarnThrottled("addon halted: lot escalation capped at " + DoubleToString(lot, 2));
            return;
           }
        }
     }

   int ticket = SafeOrderSend(cmd, lot, BuildOrderComment(level));
   if(ticket > 0)
     {
      RefreshCache();
      g_previousOpenCount = g_buyCount + g_sellCount;
      g_protectionDirty = true;
     }
  }

//+------------------------------------------------------------------+
//| EXPOSURE / LOT SIZING                                             |
//+------------------------------------------------------------------+
bool ExposureAllows(double lot, int cmd)
  {
   if(lot <= 0.0)
      return(false);
   if(InpMaxTotalLots > 0.0 && g_buyLots + g_sellLots + lot > InpMaxTotalLots + LOT_EPSILON)
      return(false);
   if(cmd != OP_BUY && cmd != OP_SELL)
      cmd = (g_sellCount > 0) ? OP_SELL : OP_BUY;
   if(AccountFreeMarginCheck(Symbol(), cmd, lot) <= 0.0)
      return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double CalculateRawLot(int orderIndex)
  {
   if(InpDbLots == LOT_MULTIPLIER)
      return(InpLots * MathPow(InpMultiplier, orderIndex));
   if(InpDbLots == LOT_RECOVERY)
     {
      double base = (g_nextRecoveryLot > 0.0) ? g_nextRecoveryLot : InpLots;
      return(base * MathPow(InpMultiplier, orderIndex));
     }
   return(InpLots);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double CalculateLotSize(int orderIndex)
  {
   double lot = CalculateRawLot(orderIndex);
   lot = NormalizeLotDown(lot);
   if(InpMaxLotPerOrder > 0.0 && lot > InpMaxLotPerOrder)
      lot = NormalizeLotDown(InpMaxLotPerOrder);
   if(InpMaxRecoveryLot > 0.0 && lot > InpMaxRecoveryLot)
      lot = NormalizeLotDown(InpMaxRecoveryLot);
   return(lot);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string BuildOrderComment(int level)
  {
   return(InpEA_Comment + "|B" + IntegerToString(g_basketId) + "|L" + IntegerToString(level));
  }

//+------------------------------------------------------------------+
//| LOGICAL EXITS (basket TP/SL, indiv TP/SL, trailing)               |
//+------------------------------------------------------------------+
bool ManageLogicalExits()
  {
   if(g_buyCount == 0 && g_sellCount == 0)
      return(false);

// Basket TP/SL - per direction
   double basketTP = ATRDistance(InpTP), basketSL = ATRDistance(InpBasketSL_ATR);
   if(g_buyCount > 0)
     {
      if(InpUseBasketTP && basketTP > 0.0 && Bid >= g_buyAvg + basketTP)
        { TriggerCloseSide(OP_BUY, "buy basket ATR TP"); return(true); }
      if(InpUseBasketSL && basketSL > 0.0 && Bid <= g_buyAvg - basketSL)
        { TriggerCloseSide(OP_BUY, "buy basket ATR SL"); return(true); }
     }
   if(g_sellCount > 0)
     {
      if(InpUseBasketTP && basketTP > 0.0 && Ask <= g_sellAvg - basketTP)
        { TriggerCloseSide(OP_SELL, "sell basket ATR TP"); return(true); }
      if(InpUseBasketSL && basketSL > 0.0 && Ask >= g_sellAvg + basketSL)
        { TriggerCloseSide(OP_SELL, "sell basket ATR SL"); return(true); }
     }

   bool acted = false;
   double softSL = ATRDistance(InpSL), indivTP = ATRDistance(InpIndivTP), hardSL = ATRDistance(InpHardSL_ATR);

// Individual soft/hard SL and individual TP
   for(int i = 0; i < g_buyCount; i++)
     {
      bool exitSoft  = (softSL > 0.0  && Bid <= (g_buyOrders[i].openPrice - softSL));
      bool exitIndiv = (indivTP > 0.0 && Bid >= (g_buyOrders[i].openPrice + indivTP));
      bool exitHard  = (hardSL > 0.0  && Bid <= (g_buyOrders[i].openPrice - hardSL));
      if((exitSoft || exitIndiv || exitHard) && SafeOrderClose(g_buyOrders[i].ticket, g_buyOrders[i].lots))
         acted = true;
     }
   for(int j = 0; j < g_sellCount; j++)
     {
      bool exitSoft  = (softSL > 0.0  && Ask >= (g_sellOrders[j].openPrice + softSL));
      bool exitIndiv = (indivTP > 0.0 && Ask <= (g_sellOrders[j].openPrice - indivTP));
      bool exitHard  = (hardSL > 0.0  && Ask >= (g_sellOrders[j].openPrice + hardSL));
      if((exitSoft || exitIndiv || exitHard) && SafeOrderClose(g_sellOrders[j].ticket, g_sellOrders[j].lots))
         acted = true;
     }

// Trailing stops
   if(InpUseTrailingStop)
      ApplyTrailingStops();

   return(acted);
  }

//+------------------------------------------------------------------+
//| TRAILING STOP SERVICE                                             |
//|                                                                  |
//| Per-order trailing based on ATR. Only updates SL when:            |
//|   - order is in profit >= TrailStartATR * ATR                     |
//|   - new SL is better (higher for BUY, lower for SELL)             |
//|   - improvement >= TrailStepPoints                                |
//+------------------------------------------------------------------+
void ApplyTrailingStops()
  {
   if(!g_atrValid)
      return;
   double startDist = ATRDistance(InpTrailStartATR);
   double trailDist = ATRDistance(InpTrailDistanceATR);
   double stepPrice = InpTrailStepPoints * Point;
   if(startDist <= 0.0 || trailDist <= 0.0)
      return;

   for(int i = 0; i < g_buyCount; i++)
      TrailOneBuy(g_buyOrders[i], startDist, trailDist, stepPrice);
   for(int j = 0; j < g_sellCount; j++)
      TrailOneSell(g_sellOrders[j], startDist, trailDist, stepPrice);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void TrailOneBuy(const COrderData &ord, double startDist, double trailDist, double stepPrice)
  {
   double profit = Bid - ord.openPrice;
   if(profit < startDist)
      return;
   double newSL = NormalizePrice(Bid - trailDist);
   if(newSL <= 0.0 || newSL <= ord.openPrice)
      return; // never trail below entry (locks loss)
   if(newSL - ord.currentSL < stepPrice)
      return;
   if(SafeOrderModify(ord.ticket, newSL, ord.currentTP))
      LogTrade("TRAIL", ord.ticket, ord.lots, Bid, newSL, ord.currentTP, "buy trail");
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void TrailOneSell(const COrderData &ord, double startDist, double trailDist, double stepPrice)
  {
   double profit = ord.openPrice - Ask;
   if(profit < startDist)
      return;
   double newSL = NormalizePrice(Ask + trailDist);
   if(newSL <= 0.0 || newSL >= ord.openPrice)
      return; // never trail above entry (would lock a loss for SELL)
// First placement: no existing SL -> set it. Otherwise only move SL down
// (lower price is better for SELL) and require at least stepPrice improvement.
// This mirrors TrailOneBuy; the previous double-tested gate was a dead branch.
   if(ord.currentSL > 0.0 && (ord.currentSL - newSL) < stepPrice)
      return;
   if(SafeOrderModify(ord.ticket, newSL, ord.currentTP))
      LogTrade("TRAIL", ord.ticket, ord.lots, Ask, newSL, ord.currentTP, "sell trail");
  }

//+------------------------------------------------------------------+
//| HEDGE OFFSET (DD REDUCTION)                                       |
//|                                                                  |
//| When one side is deeply losing and the other side is in profit,   |
//| close the profitable side. This:                                  |
//|   - locks in the winning side's profit                            |
//|   - reduces net exposure (one leg removed)                        |
//|   - lowers margin usage and DD                                   |
//| The remaining losing side is left to recover (its basket TP/SL    |
//| still applies).                                                   |
//+------------------------------------------------------------------+
void ApplyHedgeOffset()
  {
   if(!InpUseHedgeOffset)
      return;
   if(g_buyCount == 0 || g_sellCount == 0)
      return;
   if(TimeCurrent() - g_lastHedgeOffset < InpHedgeOffsetCooldown)
      return;
   if(InpHedgeOffsetMinProfit <= 0.0 || InpHedgeOffsetMaxLoss <= 0.0)
      return;

   bool buyLosing  = (g_buyPL  <= -InpHedgeOffsetMaxLoss);
   bool sellLosing = (g_sellPL <= -InpHedgeOffsetMaxLoss);
   bool buyWinning = (g_buyPL  >=  InpHedgeOffsetMinProfit);
   bool sellWinning= (g_sellPL >=  InpHedgeOffsetMinProfit);

// Case 1: BUY losing, SELL winning -> close SELL side
   if(buyLosing && sellWinning)
     {
      g_lastHedgeOffset = TimeCurrent();
      LogTrade("HEDGE-OFFSET", 0, 0.0, 0.0, 0.0, 0.0,
               "close SELL (profit=" + DoubleToString(g_sellPL, 2) + ") to offset BUY loss=" + DoubleToString(g_buyPL, 2));
      TriggerCloseSide(OP_SELL, "hedge offset: harvest winning SELL");
      return;
     }
// Case 2: SELL losing, BUY winning -> close BUY side
   if(sellLosing && buyWinning)
     {
      g_lastHedgeOffset = TimeCurrent();
      LogTrade("HEDGE-OFFSET", 0, 0.0, 0.0, 0.0, 0.0,
               "close BUY (profit=" + DoubleToString(g_buyPL, 2) + ") to offset SELL loss=" + DoubleToString(g_sellPL, 2));
      TriggerCloseSide(OP_BUY, "hedge offset: harvest winning BUY");
      return;
     }
  }

//+------------------------------------------------------------------+
//| Non-blocking trigger: set side-close pending state                 |
//+------------------------------------------------------------------+
int g_closeSidePending = -1; // OP_BUY / OP_SELL / -1

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void TriggerCloseSide(int cmd, string reason)
  {
   g_closeSidePending = cmd;
   g_state = EA_CLOSE_ALL_PENDING;
   g_stateReason = reason;
   LogTrade("SIDE-EXIT", 0, 0.0, 0.0, 0.0, 0.0, reason);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void TriggerCloseAll(string reason)
  {
   g_closeSidePending = -1;
   g_state = EA_CLOSE_ALL_PENDING;
   g_stateReason = reason;
   LogTrade("BASKET-EXIT", 0, 0.0, 0.0, 0.0, 0.0, reason);
  }

//+------------------------------------------------------------------+
//| BROKER PROTECTION RECONCILIATION                                  |
//+------------------------------------------------------------------+
void ReconcileBrokerProtection()
  {
   if(!g_atrValid || !IsTradeContextUsable())
     {
      g_nextRepairTime = TimeCurrent() + PROTECTION_REPAIR_BAD;
      return;
     }
   RefreshRates();
   bool allGood = true;
   for(int i = 0; i < g_buyCount; i++)
     {
      if(!ReconcileOne(g_buyOrders[i]))
         allGood = false;
      if(g_state == EA_CLOSE_ALL_PENDING)
         return;
     }
   for(int j = 0; j < g_sellCount; j++)
     {
      if(!ReconcileOne(g_sellOrders[j]))
         allGood = false;
      if(g_state == EA_CLOSE_ALL_PENDING)
         return;
     }
   g_protectionDirty = !allGood;
   g_nextRepairTime = allGood ? TimeCurrent() + PROTECTION_REPAIR_OK
                      : TimeCurrent() + PROTECTION_REPAIR_BAD;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool ReconcileOne(const COrderData &ord)
  {
   double sl = 0.0, tp = 0.0;
   if(InpHardSL_ATR > 0.0)
      sl = (ord.type == OP_BUY) ? (ord.openPrice - ATRDistance(InpHardSL_ATR))
           : (ord.openPrice + ATRDistance(InpHardSL_ATR));
   if(InpIndivTP > 0.0)
      tp = (ord.type == OP_BUY) ? (ord.openPrice + ATRDistance(InpIndivTP))
           : (ord.openPrice - ATRDistance(InpIndivTP));

// If trailing already set a better SL, do not weaken it
   if(ord.currentSL > 0.0)
     {
      if(ord.type == OP_BUY && sl > 0.0 && ord.currentSL > sl)
         sl = ord.currentSL;
      if(ord.type == OP_SELL && sl > 0.0 && ord.currentSL < sl)
         sl = ord.currentSL;
     }

   if(sl > 0.0)
     {
      if((ord.type == OP_BUY && Bid <= sl) || (ord.type == OP_SELL && Ask >= sl))
        {
         TriggerCloseAll("hard SL breach ticket " + IntegerToString(ord.ticket));
         return(false);
        }
     }
   ConformStops(ord.type, sl, tp);
   if(MathAbs(sl - ord.currentSL) < MathMax(InpMinModifyPoints * Point, Point * 0.5) &&
      MathAbs(tp - ord.currentTP) < MathMax(InpMinModifyPoints * Point, Point * 0.5))
      return(true);
   return(SafeOrderModify(ord.ticket, sl, tp));
  }

//+------------------------------------------------------------------+
//| RISK STOPS                                                        |
//+------------------------------------------------------------------+
bool CheckRiskStops()
  {
   if(InpMinEquity > 0.0 && AccountEquity() <= InpMinEquity)
     {
      TriggerRiskStop("equity floor", InpCloseAllOnDDStop);
      return(true);
     }
   if(InpMaxBasketLossMoney > 0.0 && (g_buyCount + g_sellCount) > 0 &&
      g_ownFloatingPL <= -InpMaxBasketLossMoney)
     {
      TriggerRiskStop("basket money stop", InpCloseAllOnDDStop);
      return(true);
     }
   if(InpMinMarginLevel > 0.0 && AccountMargin() > 0.0 &&
      (AccountEquity() / AccountMargin() * 100.0) <= InpMinMarginLevel)
     {
      TriggerRiskStop("margin level breach", true);
      return(true);
     }
   UpdateHistoryState(false);
   if(InpMaxSessionDDPct > 0.0 && g_sessionDDPct >= InpMaxSessionDDPct)
     {
      TriggerRiskStop("session DD breach", InpCloseAllOnDDStop);
      return(true);
     }
   if(InpMaxDrawdownPct <= 0.0)
      return(false);
   double balance = AccountBalance();
   if(balance <= 0.0)
      return(false);
   double dd = (InpDDMode == DD_EA_FLOATING)
               ? MathMax(0.0, -g_ownFloatingPL / balance * 100.0)
               : MathMax(0.0, (balance - AccountEquity()) / balance * 100.0);
   if(dd >= InpMaxDrawdownPct)
     {
      TriggerRiskStop("drawdown breach", InpCloseAllOnDDStop);
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void TriggerRiskStop(string reason, bool closeOrders)
  {
   g_stateReason = reason;
   LogTrade("RISKSTOP", 0, 0.0, 0.0, 0.0, 0.0, reason);
   if(closeOrders && (g_buyCount + g_sellCount) > 0)
     {
      g_latchAfterClose = true;
      g_closeSidePending = -1;
      g_state = EA_CLOSE_ALL_PENDING;
     }
   else
      LatchEquityStop(reason);
  }

//+------------------------------------------------------------------+
//| SAFE TRADE OPERATIONS                                             |
//+------------------------------------------------------------------+
int SafeOrderSend(int cmd, double lot, string comment)
  {
   if(!g_atrValid || !IsTradeContextUsable() || lot <= 0.0 || !ExposureAllows(lot, cmd))
      return(-1);
   RefreshRates();
   double entry = (cmd == OP_BUY) ? Ask : Bid, sl = 0.0, tp = 0.0;
   if(InpHardSL_ATR > 0.0)
      sl = (cmd == OP_BUY) ? (entry - ATRDistance(InpHardSL_ATR))
           : (entry + ATRDistance(InpHardSL_ATR));
   if(InpIndivTP > 0.0)
      tp = (cmd == OP_BUY) ? (entry + ATRDistance(InpIndivTP))
           : (entry - ATRDistance(InpIndivTP));
   ConformStops(cmd, sl, tp);

   int ticket = SendMarketAttempt(cmd, lot, sl, tp, comment);
   if(ticket > 0)
     {
      LogTrade("OPEN", ticket, lot, entry, sl, tp, (cmd == OP_BUY ? "buy" : "sell") + " open");
      return(ticket);
     }
   if(InpRequireBrokerSL || ticket != -2)
      return(-1);

// Fallback: open naked, then attach
   ticket = SendMarketAttempt(cmd, lot, 0.0, 0.0, comment);
   if(ticket <= 0)
      return(-1);
   if(SafeOrderModify(ticket, sl, tp))
     {
      double op = (OrderSelect(ticket, SELECT_BY_TICKET) ? OrderOpenPrice() : entry);
      LogTrade("OPEN", ticket, lot, op, sl, tp, "open fallback-modify");
      return(ticket);
     }
   if(OrderSelect(ticket, SELECT_BY_TICKET) && SafeOrderClose(ticket, OrderLots()))
     {
      double cp = (OrderType() == OP_BUY) ? Bid : Ask;
      LogTrade("CLOSE-FAILSAFE", ticket, lot, cp, 0.0, 0.0, "unprotected open reverted");
      return(-1);
     }
   double fSL = sl, fTP = tp;
   ConformStops(cmd, fSL, fTP);
   if(fSL > 0.0 && SafeOrderModify(ticket, fSL, fTP))
     {
      double op = (OrderSelect(ticket, SELECT_BY_TICKET) ? OrderOpenPrice() : entry);
      LogTrade("OPEN", ticket, lot, op, fSL, fTP, "open last-resort stop");
      return(ticket);
     }
   g_state = EA_PROTECTION_FAULT;
   g_stateReason = "unprotected order " + IntegerToString(ticket);
   Alert("HOKKY V5: unprotected order ", ticket, " - entering protection fault");
   return(-1);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int SendMarketAttempt(int cmd, double lot, double sl, double tp, string comment)
  {
   for(int attempt = 0; attempt < 3; attempt++)
     {
      if(!IsTradeContextUsable())
         return(-1);
      RefreshRates();
      double price = (cmd == OP_BUY) ? Ask : Bid;
      ResetLastError();
      int ticket = OrderSend(Symbol(), cmd, lot, price, InpSlippage,
                             NormalizePrice(sl), NormalizePrice(tp),
                             comment, g_magic, 0, (cmd == OP_BUY) ? clrBlue : clrRed);
      if(ticket > 0)
         return(ticket);
      int err = GetLastError();
      if(err == ERR_INVALID_STOPS)
         return(-2);
      if(!IsTransientTradeError(err))
         return(-1);
      Sleep(50 + attempt * 50);
     }
   return(-1);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool SafeOrderModify(int ticket, double newSL, double newTP)
  {
   for(int attempt = 0; attempt < 3; attempt++)
     {
      if(!OrderSelect(ticket, SELECT_BY_TICKET) || OrderCloseTime() > 0 ||
         OrderSymbol() != Symbol() || OrderMagicNumber() != g_magic ||
         !IsTradeContextUsable())
         return(false);
      int cmd = OrderType();
      double sl = newSL, tp = newTP;
      RefreshRates();
      ConformStops(cmd, sl, tp);
      if(MathAbs(sl - OrderStopLoss()) < Point * 0.5 && MathAbs(tp - OrderTakeProfit()) < Point * 0.5)
         return(true);
      ResetLastError();
      if(OrderModify(ticket, OrderOpenPrice(), NormalizePrice(sl), NormalizePrice(tp), 0, clrNONE))
         return(true);
      int err = GetLastError();
      if(err == ERR_NO_RESULT)
         return(true);
      if(err == ERR_INVALID_STOPS)
        {
         double pad = (attempt + 1) * 2.0 * Point;
         if(cmd == OP_BUY)
           { if(newSL > 0.0) newSL -= pad; if(newTP > 0.0) newTP += pad; }
         else
           { if(newSL > 0.0) newSL += pad; if(newTP > 0.0) newTP -= pad; }
        }
      else
         if(!IsTransientTradeError(err))
            return(false);
      Sleep(50 + attempt * 50);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool SafeOrderClose(int ticket, double lots)
  {
   for(int attempt = 0; attempt < 3; attempt++)
     {
      if(!OrderSelect(ticket, SELECT_BY_TICKET) || OrderCloseTime() > 0 ||
         OrderSymbol() != Symbol() || OrderMagicNumber() != g_magic ||
         !IsTradeContextUsable())
         return(false);
      RefreshRates();
      double price = (OrderType() == OP_BUY) ? Bid : Ask;
      ResetLastError();
      if(OrderClose(ticket, lots, price, InpSlippage, clrYellow))
        {
         LogTrade("CLOSE", ticket, lots, price, 0.0, 0.0, "logical close");
         return(true);
        }
      if(!IsTransientTradeError(GetLastError()))
         return(false);
      Sleep(50 + attempt * 50);
     }
   return(false);
  }

// Single non-blocking pass. If g_closeSidePending >= 0, only that side is closed.
bool CloseAllOwnOrdersPass()
  {
   if(!IsTradeContextUsable())
      return(false);
   RefreshRates();
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES) || OrderSymbol() != Symbol() ||
         OrderMagicNumber() != g_magic)
         continue;
      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;
      if(g_closeSidePending >= 0 && type != g_closeSidePending)
         continue;
      double price = (type == OP_BUY) ? Bid : Ask;
      ResetLastError();
      if(!OrderClose(OrderTicket(), OrderLots(), price, InpSlippage, clrYellow))
        {
         int err = GetLastError();
         if(!IsTransientTradeError(err))
            Print("CloseAll failed. Ticket=", OrderTicket(), " error=", err);
        }
      else
         LogTrade("CLOSE", OrderTicket(), OrderLots(), price, 0.0, 0.0, "close pass");
     }
   RefreshCache();
   if(g_closeSidePending >= 0)
     {
      // Side-close done when that side is empty
      int remaining = (g_closeSidePending == OP_BUY) ? g_buyCount : g_sellCount;
      if(remaining == 0)
         g_closeSidePending = -1;
      return(remaining == 0);
     }
   return(g_buyCount + g_sellCount == 0);
  }

//+------------------------------------------------------------------+
//| UTILITY                                                           |
//+------------------------------------------------------------------+
bool IsTradeContextUsable()
  {
   if(IsTesting())
      return(IsTradeAllowed());
   if(IsTradeAllowed() && !IsTradeContextBusy())
      return(true);
   for(int waited = 0; waited < 1000 && IsTradeContextBusy(); waited += 50)
      Sleep(50);
   return(IsTradeAllowed() && !IsTradeContextBusy());
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsTransientTradeError(int err)
  {
   switch(err)
     {
      case ERR_SERVER_BUSY:
      case ERR_NO_CONNECTION:
      case ERR_TRADE_TIMEOUT:
      case ERR_PRICE_CHANGED:
      case ERR_OFF_QUOTES:
      case ERR_BROKER_BUSY:
      case ERR_REQUOTE:
      case ERR_TRADE_CONTEXT_BUSY:
      case ERR_TOO_MANY_REQUESTS:
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
  {
   if(InpStartTrade == InpEndTrade)
      return(true);
   int hour = TimeHour(TimeCurrent());
   if(InpStartTrade < InpEndTrade)
      return(hour >= InpStartTrade && hour < InpEndTrade);
   return(hour >= InpStartTrade || hour < InpEndTrade);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double CurrentSpreadPoints()
  {
   return((Ask - Bid) / Point);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ConformStops(int cmd, double &sl, double &tp)
  {
   if(cmd != OP_BUY && cmd != OP_SELL)
      return;
   double minDist = MathMax(MarketInfo(Symbol(), MODE_STOPLEVEL) * Point,
                            MarketInfo(Symbol(), MODE_FREEZELEVEL) * Point);
   if(cmd == OP_BUY)
     {
      if(sl > 0.0 && (Bid - sl) < minDist)
         sl = Bid - minDist;
      if(tp > 0.0 && (tp - Bid) < minDist)
         tp = Bid + minDist;
     }
   else
     {
      if(sl > 0.0 && (sl - Ask) < minDist)
         sl = Ask + minDist;
      if(tp > 0.0 && (Ask - tp) < minDist)
         tp = Ask - minDist;
     }
   sl = NormalizePrice(sl);
   tp = NormalizePrice(tp);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
  {
   return(price <= 0.0 ? 0.0 : NormalizeDouble(price, Digits));
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double NormalizeLotDown(double lot)
  {
   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(step <= 0.0)
      step = 0.01;
   double result = MathFloor(lot / step + 1e-9) * step;
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   if(maxLot > 0.0 && result > maxLot)
      result = maxLot;
   if(result < MarketInfo(Symbol(), MODE_MINLOT))
      return(0.0);
   return(NormalizeDouble(result, 8));
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int PositiveHash(string text)
  {
   uint hash = 5381;
   int len = StringLen(text);
   for(int i = 0; i < len; i++)
      hash = hash * 33 + (uint)StringGetChar(text, i);
   return((int)(hash & 0x7FFFFFFF));
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int GenerateMagicNumber(string seed)
  {
   int magic = PositiveHash(seed);
   return(magic <= 0 ? 100000 + (MathAbs(magic) % 100000000) : magic);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void WarnThrottled(string text)
  {
   if(TimeCurrent() - g_lastWarning < WARN_THROTTLE_SEC)
      return;
   g_lastWarning = TimeCurrent();
   Print("WARN: ", text);
  }

//+------------------------------------------------------------------+
//| JOURNAL                                                           |
//+------------------------------------------------------------------+
void LogTrade(string action, int ticket, double lots, double price,
              double sl, double tp, string note)
  {
   if(!InpJournalEnabled)
      return;
   int handle = FileOpen(InpJournalFile, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ';');
   if(handle == INVALID_HANDLE)
      return;
   FileSeek(handle, 0, SEEK_END);
   if(FileSize(handle) == 0)
      FileWrite(handle, "time","action","ticket","symbol","lots","price","sl","tp","balance","equity","note");
   FileWrite(handle, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), action,
             IntegerToString(ticket), Symbol(), DoubleToString(lots, 2),
             DoubleToString(price, Digits), DoubleToString(sl, Digits),
             DoubleToString(tp, Digits), DoubleToString(AccountBalance(), 2),
             DoubleToString(AccountEquity(), 2), note);
   FileClose(handle);
  }

//+------------------------------------------------------------------+
//| ENTRY FILTERS                                                     |
//+------------------------------------------------------------------+
bool IsTrendAligned(int cmd)
  {
   double ma = iMA(Symbol(), InpTrendTimeframe, InpTrendMA_Period, 0, InpTrendMA_Method, PRICE_CLOSE, 1);
   double close = iClose(Symbol(), InpTrendTimeframe, 1);
   if(ma <= 0.0 || close <= 0.0)
      return(false);
   bool maOk = (cmd == OP_BUY) ? (close > ma) : (close < ma);
   if(!InpUseADXFilter)
      return(maOk);
   double adx = iADX(Symbol(), InpTrendTimeframe, InpADXPeriod, PRICE_CLOSE, MODE_MAIN, 1);
   if(adx < InpADXThreshold)
      return(false);
   if(InpADXUseDI)
     {
      double diP = iADX(Symbol(), InpTrendTimeframe, InpADXPeriod, PRICE_CLOSE, MODE_PLUSDI, 1);
      double diM = iADX(Symbol(), InpTrendTimeframe, InpADXPeriod, PRICE_CLOSE, MODE_MINUSDI, 1);
      return(maOk && ((cmd == OP_BUY) ? (diP > diM) : (diM > diP)));
     }
   return(maOk);
  }

//+------------------------------------------------------------------+
//| PERSISTENT-STATE TOUCH                                            |
//+------------------------------------------------------------------+
void TouchPersistentState()
  {
   static datetime lastTouch = 0;
   if(TimeCurrent() - lastTouch < HEARTBEAT_TOUCH_SEC)
      return;
   lastTouch = TimeCurrent();
   for(int i = 0; i < GlobalVariablesTotal(); i++)
     {
      string name = GlobalVariableName(i);
      if(StringFind(name, g_prefix) == 0)
         GlobalVariableSet(name, GlobalVariableGet(name));
     }
  }

//+------------------------------------------------------------------+
//| DASHBOARD                                                         |
//+------------------------------------------------------------------+
void UpdateDashboardThrottled()
  {
   if(!InpUseDashboard || TimeCurrent() - g_lastDashboard < DASHBOARD_THROTTLE)
      return;
   g_lastDashboard = TimeCurrent();
   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string StateText(ENUM_EA_STATE s)
  {
   switch(s)
     {
      case EA_STARTING:
         return("STARTING");
      case EA_WAIT_ATR:
         return("WAIT_ATR");
      case EA_RUNNING:
         return("RUNNING");
      case EA_CLOSE_ALL_PENDING:
         return("CLOSE_ALL");
      case EA_DD_LATCHED:
         return("DD_LATCHED");
      case EA_PROTECTION_FAULT:
         return("PROTECTION_FAULT");
     }
   return("?");
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void SetLabel(string id, int x, int y, string text, color clrText, int fontsize)
  {
   string obj = g_objPrefix + id;
   if(ObjectFind(0, obj) < 0)
     {
      ObjectCreate(0, obj, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, obj, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, obj, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, obj, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, obj, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, obj, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, obj, OBJPROP_FONTSIZE, fontsize);
   ObjectSetInteger(0, obj, OBJPROP_COLOR, clrText);
   ObjectSetString(0, obj, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   if(!InpUseDashboard)
      return;
   int x = 12, y = 22, dy = 15, line = 0;
   color stateClr = (g_state == EA_RUNNING) ? clrLime :
                    (g_state == EA_WAIT_ATR ? clrYellow :
                     (g_state == EA_CLOSE_ALL_PENDING ? clrOrange : clrRed));
   double marginLevel = (AccountMargin() > 0.0) ? AccountEquity() / AccountMargin() * 100.0 : 0.0;

   SetLabel("00", x, y + dy*line++, "HOKKY V5.01 HEDGE | Magic " + IntegerToString(g_magic) +
            " | " + Symbol() + " M" + IntegerToString(Period()) +
            " | Hedge=" + (InpHedgeMode ? "ON" : "OFF"), clrWhite, 9);
   SetLabel("01", x, y + dy*line++, "State: " + StateText(g_state) + " - " + g_stateReason, stateClr, 9);
   SetLabel("02", x, y + dy*line++, "ATR(" + IntegerToString(InpATRPeriod) + "): " +
            (g_atrValid ? DoubleToString(g_atr, Digits) : "INVALID") +
            " spread: " + DoubleToString(CurrentSpreadPoints(), 1), clrSilver, 9);
   SetLabel("03", x, y + dy*line++, "BUY  n=" + IntegerToString(g_buyCount) +
            " lots=" + DoubleToString(g_buyLots, 2) +
            " avg=" + DoubleToString(g_buyAvg, Digits) +
            " PL=" + DoubleToString(g_buyPL, 2), clrDodgerBlue, 9);
   SetLabel("04", x, y + dy*line++, "SELL n=" + IntegerToString(g_sellCount) +
            " lots=" + DoubleToString(g_sellLots, 2) +
            " avg=" + DoubleToString(g_sellAvg, Digits) +
            " PL=" + DoubleToString(g_sellPL, 2), clrTomato, 9);
   SetLabel("05", x, y + dy*line++, "Net Float: " + DoubleToString(g_ownFloatingPL, 2) +
            " basket #" + IntegerToString(g_basketId) +
            (g_basketActive ? " active" : " idle"), clrSilver, 9);
   SetLabel("06", x, y + dy*line++, "Session DD: " + DoubleToString(g_sessionDDPct, 2) +
            "% / " + DoubleToString(InpMaxSessionDDPct, 1) +
            "%  DD: " + DoubleToString(InpMaxDrawdownPct, 1) + "%",
            (g_sessionDDPct > 0.7 * InpMaxSessionDDPct ? clrOrange : clrSilver), 9);
   SetLabel("07", x, y + dy*line++, "Margin: " +
            (marginLevel > 0.0 ? DoubleToString(marginLevel, 1) + "%" : "n/a") +
            " free: " + DoubleToString(AccountFreeMargin(), 2), clrSilver, 9);
   SetLabel("08", x, y + dy*line++, "Next lot: " + DoubleToString(g_nextRecoveryLot, 2) +
            " mult: " + DoubleToString(InpMultiplier, 2) +
            " maxLvl: " + IntegerToString(InpMaxLevel) +
            (InpHaltAddonsWhenCapped ? " haltCap" : ""), clrSilver, 9);
   SetLabel("09", x, y + dy*line++, "Trail: " + (InpUseTrailingStop ? "ON" : "OFF") +
            " | HedgeOffset: " + (InpUseHedgeOffset ? "ON" : "OFF") +
            " | latch: " + (IsEquityStopLatched() ? "ACTIVE" : "clear"),
            IsEquityStopLatched() ? clrRed : clrSilver, 9);
   SetLabel("10", x, y + dy*line++, "Not financial advice - demo-test before live use.", clrGray, 8);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DeleteOwnObjects()
  {
   for(int i = ObjectsTotal() - 1; i >= 0; i--)
     {
      string name = ObjectName(i);
      if(StringFind(name, g_objPrefix) == 0)
         ObjectDelete(name);
     }
  }
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
