//+------------------------------------------------------------------+
//|                                                  oneminuteman.mq4 |
//|                                     Copyright 2025, nhasibuan     |
//|                          https://github.com/nhasibuan/oneminuteman|
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, nhasibuan"
#property link      "https://github.com/nhasibuan/oneminuteman"
#property version   "10.13"
#property strict
#property description "OneMinuteMan v10.13: Signal-only M1 scalper with event-driven loss-reversal."
#property description "No martingale. Fixed linear risk. FIFO/netting compatible."
#property description "ATR-dynamic risk, virtual SL with safety net, break-even, persistent equity guards."

//==================================================================
//  ARCHITECTURE (single file, component-based)
//  -----------------------------------------------------------------
//  v10.13-no-mart: Martingale removed. Signal-only entry with
//  optional event-driven loss-reversal (reverse after losing close).
//  FIFO/netting compatible -- no concurrent hedging.
//  -----------------------------------------------------------------
//  Design patterns applied:
//   - Facade            : CExpertAdvisor is the single entry point that
//                         the MT4 event handlers delegate to.
//   - Single Responsibility / Strategy-style components:
//       CSpreadMonitor        adaptive spread & slippage
//       CRangeScanner         rolling tick High/Low window
//       CCandleEngine         candlestick classification + signal
//       CPpmEngine            ZigZag pips-per-minute efficiency
//       CVolumeFilter         tick-volume spike gate
//       CSessionClock         timezone / session / day-stamp logic
//       CEquityGuard          drawdown & equity-floor protection
//       CRiskModel            ATR-dynamic SL/TP/trailing resolution
//       CVirtualStopManager   hidden SL registry + enforcement
//       CTrailingManager      break-even + trailing stop logic
//       CTradeExecutor        order send / flatten / history scan
//       CStateStore           versioned binary persistence (Memento)
//   - Guard clauses everywhere; no hidden global mutation: all state
//     lives inside the owning component.
//==================================================================

//==================================================================
// SECTION 0 -- ENUMERATIONS
//==================================================================
// Reversal confirmation -- repurposed from v10.12 martingale gate
// to v10.13 loss-reversal signal confirmation filter.
enum ENUM_MART_CONFIRM {
   MART_CONFIRM_NONE   = 0, // no confirmation (fires on delay only)
   MART_CONFIRM_CANDLE = 1, // candle signal must agree with reverse direction
   MART_CONFIRM_PPM    = 2, // PPM zone must be MEDIUM or HIGH
   MART_CONFIRM_EITHER = 3, // candle OR PPM
   MART_CONFIRM_BOTH   = 4  // candle AND PPM
};

enum TYPE_CANDLESTICK {
   CAND_UNKNOWN = 0,
   CAND_LONG,
   CAND_SHORT,
   CAND_DOJI,
   CAND_MARUBOZU,
   CAND_HAMMER,
   CAND_INVERTED_HAMMER,
   CAND_SPINNING_TOP,
   CAND_DRAGONFLY_DOJI,
   CAND_GRAVESTONE_DOJI,
   CAND_LONG_LEGGED_DOJI
};

enum TYPE_TREND {
   TREND_UNKNOWN = 0,
   TREND_UPPER,
   TREND_DOWN,
   TREND_LATERAL
};

enum PPM_ZONE {
   PPM_ZONE_NONE   = 0,
   PPM_ZONE_LOW,
   PPM_ZONE_MEDIUM,
   PPM_ZONE_HIGH
};

//==================================================================
// SECTION 1 -- INPUTS
//==================================================================

//--- Range Scanner
input int    InpSampleMs   = 50;   // Sampling interval (ms)
input int    InpWindowSize = 1200; // Buffer size (samples): 1200 x 50ms = 60s

//--- Candle Recognizer
input int    InpAverPeriod = 14;   // SMA period for trend + avg body

//--- PPM Engine
input int    InpZzDepth     = 2;    // ZigZag Depth
input int    InpZzDeviation = 2;    // ZigZag Deviation
input int    InpZzBackstep  = 1;    // ZigZag Backstep
input int    InpZzLookback  = 100;  // Bars to scan for ZigZag
input double InpPpmMinHigh  = 2.0;  // PPM threshold -- low efficiency
input double InpPpmTarget   = 4.0;  // PPM target -- ideal entry zone
input double InpAtrDailyRef = 1.5;  // PPM volatility baseline (display only)
input bool   InpShowPPM     = true; // Show PPM panel

//--- Volume Filter
input bool   InpUseVolumeFilter = true;
input int    InpVolLookback     = 20;
input double InpVolMultiplier   = 1.5;

//--- Trade Management
input bool   InpEnableTrading = false;
input double InpBaseLots      = 0.01;
input int    InpSlippage      = 0;    // 0 = AUTO
input int    InpMaxSpread     = 0;    // 0 = AUTO
input int    InpMagic         = 100;
input double InpTP_Pips       = 0;    // 0 = AUTO (ATR)
input double InpSL_Pips       = 0;    // 0 = AUTO (ATR)
input bool   InpHideSL        = true; // Virtual SL
input double InpTrailStart    = 0;    // 0 = AUTO (ATR)
input double InpTrailStep     = 0;    // 0 = AUTO (ATR)

//--- Break-Even & Safety
input double InpBE_TriggerMult = 1.0; // Break-even trigger (x ATR)
input double InpBE_LockPips    = 1.0; // Pips to lock at BE
input bool   InpUseSafetySL    = true;// Send real SL to broker as disconnect safety
input double InpSafetySLMult   = 5.0; // Safety SL distance (x Virtual SL)

//--- Dynamic Risk (ATR)
input int    InpAtrPeriod         = 14;
input double InpAtrSLMult         = 1.5;
input double InpAtrTPMult         = 2.0;
input double InpAtrTrailStartMult = 1.0;
input double InpAtrTrailStepMult  = 0.5;
input double InpMinRiskPips       = 1.0;

//--- Dynamic Execution
input double InpMaxSpreadMult = 2.5;
input double InpSlippageMult  = 1.5;
input double InpSprEmaAlpha   = 0.05;

//--- Loss-Reversal Engine (v10.13)
//    Event-driven reverse-after-losing-close.
//    FIFO/netting compatible: waits for flat account before opening reverse.
//    "Losing close" = LastClosedProfit() < 0 (includes swap + commission).
input bool              InpEnableLossReversal    = true;  // Enable reverse-after-losing-close
input int               InpLossReversalDelaySec  = 5;     // Delay (seconds) after losing close before reverse entry
input double            InpReverseLots           = 0.0;   // 0 = use InpBaseLots
input ENUM_MART_CONFIRM InpReverseConfirm        = MART_CONFIRM_NONE; // Signal confirmation for reverse leg
input int               InpMaxReverseLossesPerDay = 3;    // 0 = unlimited; max reverse losses before disabling for day
input int               InpMaxTradesPerDay       = 0;     // 0 = unlimited; max total trades per day
input int               InpMinHoldSec            = 0;     // 0 = off; minimum seconds to hold before closing

//--- Equity Protection
input double InpMaxDrawdownPct     = 10.0; // Halt if daily drawdown >= 10%
input double InpMinEquity          = 100.0;// Halt if equity drops below this
input bool   InpCloseOnGuardBreach = true; // Force-close open positions on guard breach

//--- Trading Session
input int    InpTzOffsetHours    = 7;
input int    InpSessionStartHour = 5;
input int    InpSessionEndHour   = 24;

//==================================================================
// SECTION 2 -- CONSTANTS, STRUCTURES & UTILITIES
//==================================================================
#define MAX_POSITIONS 20
#define STATE_MAGIC   0x4F4D4D35 // "OMM5" -- v10.13 state format tag (bumped from OMM4)

const double LONG_BODY_FACTOR   = 1.3;
const double SHORT_BODY_FACTOR  = 0.5;
const double DOJI_BODY_FACTOR   = 0.03;
const double MARUBOZU_SHADE     = 0.01;
const double HAMMER_SHADE       = 2.0;
const double HAMMER_OPP_SHADE   = 0.1;
const double DOJI_TINY_FRACTION = 0.1;

struct CANDLE_STRUCTURE {
   TYPE_CANDLESTICK type;
   TYPE_TREND       unit;
   double           bodysize, shade_high, shade_low, avg_close, avg_body;
   double           open, high, low, close;
};

struct PPM_RESULT {
   double   ppm, pips, atr_ratio;
   int      candles;
   PPM_ZONE zone;
   datetime pivot_start, pivot_end;
};

struct VSL_ENTRY {
   int    ticket;
   int    dir;
   double vsl_price;
   double be_price;
   double safety_sl_price;
   bool   active;
   int    fail_count;
};

struct TRADE_PARAMS {
   double tp_pips, sl_pips, trail_start, trail_step, be_trigger;
};

//------------------------------------------------------------------
// Utility helpers
//------------------------------------------------------------------
double PipSize() {
   return (Digits == 3 || Digits == 5) ? Point * 10 : Point;
}

double PipToPrice(double pips) {
   return pips * PipSize();
}

double NormalizeLots(double lots) {
   double minlot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxlot = MarketInfo(Symbol(), MODE_MAXLOT);
   double step   = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(step <= 0.0) step = 0.01;
   lots = MathFloor(lots / step) * step;
   return NormalizeDouble(MathMin(MathMax(lots, minlot), maxlot), 2);
}

string TFLabel() {
   string full = EnumToString((ENUM_TIMEFRAMES)_Period);
   StringReplace(full, "PERIOD_", "");
   return full;
}

string PpmZoneName(PPM_ZONE z) {
   switch(z) {
      case PPM_ZONE_HIGH:   return "HIGH [ENTER]";
      case PPM_ZONE_MEDIUM: return "MEDIUM [WATCH]";
      case PPM_ZONE_LOW:    return "LOW [AVOID]";
      default:              return "NO DATA";
   }
}

string CandleTypeName(TYPE_CANDLESTICK tp) {
   switch(tp) {
      case CAND_LONG:             return "Long";
      case CAND_SHORT:            return "Short";
      case CAND_DOJI:             return "Doji";
      case CAND_MARUBOZU:         return "Marubozu";
      case CAND_HAMMER:           return "Hammer";
      case CAND_INVERTED_HAMMER:  return "InvertedHammer";
      case CAND_SPINNING_TOP:     return "SpinningTop";
      case CAND_DRAGONFLY_DOJI:   return "DragonflyDoji";
      case CAND_GRAVESTONE_DOJI:  return "GravestoneDoji";
      case CAND_LONG_LEGGED_DOJI: return "LongLeggedDoji";
      default:                    return "Unknown";
   }
}

string TrendName(TYPE_TREND u) {
   switch(u) {
      case TREND_UPPER:   return "Ascending";
      case TREND_DOWN:    return "Descending";
      case TREND_LATERAL: return "Lateral";
      default:            return "Unknown";
   }
}

string ConfirmName(ENUM_MART_CONFIRM c) {
   switch(c) {
      case MART_CONFIRM_NONE:   return "NONE";
      case MART_CONFIRM_CANDLE: return "CANDLE";
      case MART_CONFIRM_PPM:    return "PPM";
      case MART_CONFIRM_EITHER: return "EITHER";
      case MART_CONFIRM_BOTH:   return "BOTH";
      default:                  return "?";
   }
}

//==================================================================
// SECTION 3 -- CSpreadMonitor : adaptive spread & slippage
//==================================================================
class CSpreadMonitor {
private:
   double m_ema;
   double m_alpha;
   double m_max_mult;
   double m_slip_mult;
   int    m_fix_slippage;
   int    m_fix_maxspread;

public:
   CSpreadMonitor() { m_ema = 0.0; }

   void Init(double alpha, double maxMult, double slipMult, int fixSlippage, int fixMaxSpread) {
      m_ema           = 0.0;
      m_alpha         = alpha;
      m_max_mult      = maxMult;
      m_slip_mult     = slipMult;
      m_fix_slippage  = fixSlippage;
      m_fix_maxspread = fixMaxSpread;
   }

   void Update() {
      double cur = (Ask - Bid) / Point;
      if(cur <= 0.0) return;
      m_ema = (m_ema <= 0.0) ? cur : m_ema + m_alpha * (cur - m_ema);
   }

   double AvgPoints() {
      return (m_ema > 0.0) ? m_ema : (Ask - Bid) / Point;
   }

   int EffSlippage() {
      if(m_fix_slippage > 0) return m_fix_slippage;
      int v = (int)MathCeil(AvgPoints() * m_slip_mult);
      return (v < 1) ? 1 : v;
   }

   int EffMaxSpread() {
      if(m_fix_maxspread > 0) return m_fix_maxspread;
      int v = (int)MathCeil(AvgPoints() * m_max_mult);
      return (v < 1) ? 1 : v;
   }

   bool SpreadOK() {
      int spr = (int)MathRound((Ask - Bid) / Point);
      int lim = EffMaxSpread();
      return (lim <= 0 || spr <= lim);
   }
};

//==================================================================
// SECTION 4 -- CRangeScanner : rolling tick High/Low window
//==================================================================
class CRangeScanner {
private:
   double m_prices[];
   int    m_size;
   int    m_head;
   int    m_count;
   double m_high;
   double m_low;

public:
   CRangeScanner() { m_size = 0; m_head = 0; m_count = 0; m_high = 0.0; m_low = 0.0; }

   bool Init(int windowSize) {
      m_size  = windowSize;
      m_head  = 0;
      m_count = 0;
      if(ArrayResize(m_prices, m_size) != m_size) return false;
      ArrayInitialize(m_prices, 0.0);
      return true;
   }

   void Sample(double price) {
      m_prices[m_head] = price;
      if(m_count < m_size) m_count++;
      m_head = (m_head + 1) % m_size;
      Rescan();
   }

   void Rescan() {
      double h    = -DBL_MAX;
      double l    =  DBL_MAX;
      int    lim  = (m_count < m_size) ? m_count : m_size;
      for(int i = 0; i < lim; i++) {
         if(m_prices[i] > h) h = m_prices[i];
         if(m_prices[i] < l) l = m_prices[i];
      }
      m_high = (h == -DBL_MAX) ? 0.0 : h;
      m_low  = (l ==  DBL_MAX) ? 0.0 : l;
   }

   double High()  { return m_high; }
   double Low()   { return m_low; }
   double Range() { return m_high - m_low; }
};

//==================================================================
// SECTION 5 -- CCandleEngine : pattern classification + signal
//==================================================================
class CCandleEngine {
private:
   int m_period;

   void CalcShades(CANDLE_STRUCTURE &c) {
      if(c.close >= c.open) {
         c.shade_high = c.high - c.close;
         c.shade_low  = c.open  - c.low;
      } else {
         c.shade_high = c.high - c.open;
         c.shade_low  = c.close - c.low;
      }
   }

   double AverageClose(int shift) {
      double sum = 0.0;
      for(int i = shift + 1; i <= shift + m_period; i++)
         sum += iClose(Symbol(), PERIOD_M1, i);
      return sum / m_period;
   }

   double AverageBody(int shift) {
      double sum = 0.0;
      for(int i = shift + 1; i <= shift + m_period; i++)
         sum += MathAbs(iClose(Symbol(), PERIOD_M1, i) - iOpen(Symbol(), PERIOD_M1, i));
      return sum / m_period;
   }

public:
   void Init(int averagePeriod) { m_period = averagePeriod; }

   bool Recognize(int shift, CANDLE_STRUCTURE &res) {
      res.open  = iOpen(Symbol(),  PERIOD_M1, shift);
      res.close = iClose(Symbol(), PERIOD_M1, shift);
      res.high  = iHigh(Symbol(),  PERIOD_M1, shift);
      res.low   = iLow(Symbol(),   PERIOD_M1, shift);
      if(res.close == 0) return false;

      res.bodysize  = MathAbs(res.close - res.open);
      CalcShades(res);
      res.avg_close = AverageClose(shift);
      res.avg_body  = AverageBody(shift);

      res.type = CAND_UNKNOWN;
      if(res.bodysize > res.avg_body * LONG_BODY_FACTOR)  res.type = CAND_LONG;
      if(res.bodysize < res.avg_body * SHORT_BODY_FACTOR) res.type = CAND_SHORT;

      double HL = res.high - res.low;
      if(HL > 0.0 && res.bodysize < HL * DOJI_BODY_FACTOR)
         res.type = CAND_DOJI;
      if(res.bodysize > 0.0 &&
         MathMin(res.shade_high, res.shade_low) / res.bodysize < MARUBOZU_SHADE)
         res.type = CAND_MARUBOZU;

      if(res.shade_low  > res.bodysize * HAMMER_SHADE &&
         res.shade_high < res.bodysize * HAMMER_OPP_SHADE)
         res.type = CAND_HAMMER;
      if(res.shade_high > res.bodysize * HAMMER_SHADE &&
         res.shade_low  < res.bodysize * HAMMER_OPP_SHADE)
         res.type = CAND_INVERTED_HAMMER;
      if(res.type == CAND_SHORT &&
         res.shade_low > res.bodysize && res.shade_high > res.bodysize)
         res.type = CAND_SPINNING_TOP;

      if(res.type == CAND_DOJI) {
         double tiny = HL * DOJI_TINY_FRACTION;
         if     (res.shade_low  > 2.0 * res.shade_high && res.shade_high <= tiny) res.type = CAND_DRAGONFLY_DOJI;
         else if(res.shade_high > 2.0 * res.shade_low  && res.shade_low  <= tiny) res.type = CAND_GRAVESTONE_DOJI;
         else if(res.shade_high > tiny && res.shade_low > tiny)                   res.type = CAND_LONG_LEGGED_DOJI;
      }

      if     (res.close > res.avg_close) res.unit = TREND_UPPER;
      else if(res.close < res.avg_close) res.unit = TREND_DOWN;
      else                               res.unit = TREND_LATERAL;

      return true;
   }

   int SignalDirection(const CANDLE_STRUCTURE &c) {
      if(c.type == CAND_HAMMER           || c.type == CAND_DRAGONFLY_DOJI)  return +1;
      if(c.type == CAND_INVERTED_HAMMER  || c.type == CAND_GRAVESTONE_DOJI) return -1;
      if(c.unit == TREND_UPPER && (c.type == CAND_LONG || c.type == CAND_MARUBOZU)) return +1;
      if(c.unit == TREND_DOWN  && (c.type == CAND_LONG || c.type == CAND_MARUBOZU)) return -1;
      return 0;
   }
};

//==================================================================
// SECTION 6 -- CPpmEngine : ZigZag pips-per-minute efficiency
//==================================================================
class CPpmEngine {
private:
   int    m_depth, m_deviation, m_backstep, m_lookback;
   double m_min_high, m_target, m_daily_ref;

public:
   void Init(int depth, int deviation, int backstep, int lookback,
             double minHigh, double target, double dailyRef) {
      m_depth     = depth;
      m_deviation = deviation;
      m_backstep  = backstep;
      m_lookback  = lookback;
      m_min_high  = minHigh;
      m_target    = target;
      m_daily_ref = dailyRef;
   }

   // FIX-1: scan the whole lookback window -- ZigZag legitimately returns 0
   // on non-pivot bars, so probing a single bar produced false negatives.
   bool VerifyIndicator() {
      int bars = (m_lookback < Bars - 1) ? m_lookback : Bars - 1;
      for(int i = 1; i <= bars; i++) {
         double zz = iCustom(Symbol(), PERIOD_M1, "ZigZag", m_depth, m_deviation, m_backstep, 0, i);
         if(zz != 0.0 && zz != EMPTY_VALUE) return true;
      }
      return false;
   }

   bool Calc(PPM_RESULT &res) {
      res.ppm = 0.0; res.pips = 0.0; res.candles = 0;
      res.atr_ratio = 0.0; res.zone = PPM_ZONE_NONE;

      int bars = (m_lookback < Bars - 1) ? m_lookback : Bars - 1;
      if(bars < 4) return false;

      double pivot1 = 0.0, pivot2 = 0.0;
      int    bar1   = -1,  bar2   = -1;

      for(int i = 1; i <= bars; i++) {
         double zzVal = iCustom(Symbol(), PERIOD_M1, "ZigZag",
                                m_depth, m_deviation, m_backstep, 0, i);
         if(zzVal != 0.0 && zzVal != EMPTY_VALUE) {
            if(bar1 < 0) { pivot1 = zzVal; bar1 = i; }
            else         { pivot2 = zzVal; bar2 = i; break; }
         }
      }

      if(bar1 < 0 || bar2 < 0) return false;
      int barDiff = bar2 - bar1;
      if(barDiff < 1) return false;

      double pips = MathAbs(pivot1 - pivot2) / PipSize();
      double ppm  = pips / (double)barDiff;

      res.pips        = pips;
      res.candles     = barDiff;
      res.ppm         = ppm;
      res.atr_ratio   = (m_daily_ref > 0.0) ? ppm / m_daily_ref : 0.0;
      res.pivot_start = iTime(Symbol(), PERIOD_M1, bar2);
      res.pivot_end   = iTime(Symbol(), PERIOD_M1, bar1);

      if     (ppm >= m_target)   res.zone = PPM_ZONE_HIGH;
      else if(ppm >= m_min_high) res.zone = PPM_ZONE_MEDIUM;
      else                       res.zone = PPM_ZONE_LOW;

      return true;
   }
};

//==================================================================
// SECTION 7 -- CVolumeFilter : tick-volume spike gate
//==================================================================
class CVolumeFilter {
private:
   bool   m_enabled;
   int    m_lookback;
   double m_multiplier;

public:
   void Init(bool enabled, int lookback, double multiplier) {
      m_enabled    = enabled;
      m_lookback   = lookback;
      m_multiplier = multiplier;
   }

   bool Ok() {
      if(!m_enabled || m_lookback < 2) return true;
      long vol_last = iVolume(Symbol(), PERIOD_M1, 1);
      if(vol_last <= 0) return true;

      long vol_sum = 0;
      int  n       = 0;
      for(int i = 1; i <= m_lookback; i++) {
         long v = iVolume(Symbol(), PERIOD_M1, i);
         if(v > 0) { vol_sum += v; n++; }
      }
      if(n == 0) return true;
      return (vol_last >= ((double)vol_sum / n) * m_multiplier);
   }
};

//==================================================================
// SECTION 8 -- CSessionClock : timezone / session / day stamp
//==================================================================
class CSessionClock {
private:
   int m_tz, m_start_hour, m_end_hour;

public:
   void Init(int tzOffsetHours, int startHour, int endHour) {
      m_tz         = tzOffsetHours;
      m_start_hour = startHour;
      m_end_hour   = endHour;
   }

   int LocalHour() {
      MqlDateTime dt;
      TimeToStruct(TimeGMT(), dt);
      return (dt.hour + m_tz + 24) % 24;
   }

   bool InSession() {
      int endh = (m_end_hour <= m_start_hour) ? 24 : m_end_hour;
      int lh   = LocalHour();
      return (lh >= m_start_hour && lh < endh);
   }

   // Local calendar day as yyyymmdd -- used to reset the drawdown baseline.
   int LocalDayStamp() {
      datetime lt = (datetime)(TimeGMT() + m_tz * 3600);
      MqlDateTime dt;
      TimeToStruct(lt, dt);
      return dt.year * 10000 + dt.mon * 100 + dt.day;
   }

   datetime NextSessionOpenGMT() {
      datetime    now = TimeGMT();
      MqlDateTime dt;
      TimeToStruct(now, dt);
      int current_local = (dt.hour + m_tz + 24) % 24;
      int days_to_add   = (current_local >= m_start_hour) ? 1 : 0;
      datetime target   = now + days_to_add * 86400;
      TimeToStruct(target, dt);
      dt.hour = (m_start_hour - m_tz + 24) % 24;
      dt.min  = 0;
      dt.sec  = 0;
      return StructToTime(dt);
   }
};

//==================================================================
// SECTION 9 -- CEquityGuard : drawdown & equity-floor protection
//==================================================================
class CEquityGuard {
private:
   double m_min_equity;
   double m_max_dd_pct;
   double m_day_start_balance;
   int    m_day_stamp;

public:
   void Init(double minEquity, double maxDdPct) {
      m_min_equity        = minEquity;
      m_max_dd_pct        = maxDdPct;
      m_day_start_balance = AccountBalance();
      m_day_stamp         = 0;
   }

   double Baseline()  { return m_day_start_balance; }
   int    DayStamp()  { return m_day_stamp; }

   void SetBaseline(double balance, int dayStamp) {
      m_day_start_balance = balance;
      m_day_stamp         = dayStamp;
   }

   void ResetBaseline(int dayStamp) {
      m_day_start_balance = AccountBalance();
      m_day_stamp         = dayStamp;
   }

   // FIX-4 companion: baseline rolls on local-day change, so a multi-day
   // run cannot drift and a restart cannot silently re-anchor the baseline.
   bool RollDayIfNeeded(int today) {
      if(m_day_stamp == today) return false;
      m_day_stamp         = today;
      m_day_start_balance = AccountBalance();
      return true;
   }

   double DrawdownPct() {
      if(m_day_start_balance <= 0.0) return 0.0;
      return (m_day_start_balance - AccountEquity()) / m_day_start_balance * 100.0;
   }

   bool Breached(string &reason) {
      if(AccountEquity() < m_min_equity) {
         reason = StringFormat("equity %.2f below floor %.2f", AccountEquity(), m_min_equity);
         return true;
      }
      double dd = DrawdownPct();
      if(dd >= m_max_dd_pct) {
         reason = StringFormat("daily drawdown %.2f%% >= %.2f%%", dd, m_max_dd_pct);
         return true;
      }
      return false;
   }
};

//==================================================================
// SECTION 10 -- CRiskModel : ATR-dynamic SL/TP/trailing resolution
//==================================================================
class CRiskModel {
private:
   int    m_atr_period;
   double m_sl_mult, m_tp_mult, m_ts_mult, m_step_mult, m_be_mult, m_floor;
   double m_fix_sl, m_fix_tp, m_fix_ts, m_fix_step;

public:
   void Init(int atrPeriod,
             double slMult, double tpMult, double tsMult, double stepMult,
             double beMult, double floorPips,
             double fixSl, double fixTp, double fixTs, double fixStep) {
      m_atr_period = atrPeriod;
      m_sl_mult    = slMult;
      m_tp_mult    = tpMult;
      m_ts_mult    = tsMult;
      m_step_mult  = stepMult;
      m_be_mult    = beMult;
      m_floor      = (floorPips > 0.0) ? floorPips : 1.0;
      m_fix_sl     = fixSl;
      m_fix_tp     = fixTp;
      m_fix_ts     = fixTs;
      m_fix_step   = fixStep;
   }

   double AtrPips() {
      double atr = iATR(Symbol(), PERIOD_M1, m_atr_period, 1);
      double p   = atr / PipSize();
      return (p > 0.0) ? p : 0.0;
   }

   void Resolve(TRADE_PARAMS &p) {
      double atrPips = AtrPips();
      p.sl_pips     = (m_fix_sl   > 0.0) ? m_fix_sl   : MathMax(atrPips * m_sl_mult,   m_floor);
      p.tp_pips     = (m_fix_tp   > 0.0) ? m_fix_tp   : MathMax(atrPips * m_tp_mult,   m_floor);
      p.trail_start = (m_fix_ts   > 0.0) ? m_fix_ts   : MathMax(atrPips * m_ts_mult,   m_floor);
      p.trail_step  = (m_fix_step > 0.0) ? m_fix_step : MathMax(atrPips * m_step_mult, m_floor * 0.5);
      p.be_trigger  = MathMax(atrPips * m_be_mult, m_floor);
   }
};

//==================================================================
// SECTION 11 -- CVirtualStopManager : hidden SL registry + enforcement
//==================================================================
class CVirtualStopManager {
private:
   VSL_ENTRY m_entries[MAX_POSITIONS];
   int       m_count;
   bool      m_hide_sl;

public:
   void Init(bool hideSl) {
      m_count   = 0;
      m_hide_sl = hideSl;
   }

   int Count() { return m_count; }

   void Register(int ticket, int dir, double vslPrice, double bePrice, double safetySl) {
      for(int i = 0; i < m_count; i++) {
         if(m_entries[i].ticket == ticket) {
            m_entries[i].vsl_price = vslPrice;
            return;
         }
      }
      if(m_count >= MAX_POSITIONS) {
         Print("VSL registry full -- ticket ", ticket, " not tracked (raise MAX_POSITIONS).");
         return;
      }
      m_entries[m_count].ticket          = ticket;
      m_entries[m_count].dir             = dir;
      m_entries[m_count].vsl_price       = vslPrice;
      m_entries[m_count].be_price        = bePrice;
      m_entries[m_count].safety_sl_price = safetySl;
      m_entries[m_count].active          = true;
      m_entries[m_count].fail_count      = 0;
      m_count++;
   }

   void Remove(int ticket) {
      for(int i = 0; i < m_count; i++) {
         if(m_entries[i].ticket != ticket) continue;
         for(int j = i; j < m_count - 1; j++) m_entries[j] = m_entries[j + 1];
         m_count--;
         return;
      }
   }

   // Raise (buy) / lower (sell) the virtual stop; never loosen it.
   void Tighten(int ticket, bool isBuy, double newSL) {
      for(int v = 0; v < m_count; v++) {
         if(m_entries[v].ticket != ticket) continue;
         if( isBuy && newSL > m_entries[v].vsl_price)
            m_entries[v].vsl_price = newSL;
         if(!isBuy && (m_entries[v].vsl_price == 0.0 || newSL < m_entries[v].vsl_price))
            m_entries[v].vsl_price = newSL;
         return;
      }
   }

   // FIX-2: an entry is only removed once the position is confirmed closed.
   // A failed OrderClose keeps the entry active and retries on the next call.
   void Enforce(int slippage) {
      if(!m_hide_sl) return;
      for(int i = m_count - 1; i >= 0; i--) {
         if(!m_entries[i].active) continue;

         if(!OrderSelect(m_entries[i].ticket, SELECT_BY_TICKET) ||
            OrderCloseTime() != 0) {
            Remove(m_entries[i].ticket);
            continue;
         }

         bool triggered =
            (m_entries[i].dir > 0 && Bid <= m_entries[i].vsl_price) ||
            (m_entries[i].dir < 0 && Ask >= m_entries[i].vsl_price);
         if(!triggered) continue;

         RefreshRates();
         double closePrice = (m_entries[i].dir > 0) ? Bid : Ask;
         if(OrderClose(m_entries[i].ticket, OrderLots(), closePrice, slippage, clrOrange)) {
            Remove(m_entries[i].ticket);
         } else {
            m_entries[i].fail_count++;
            Print("VSL close failed ticket=", m_entries[i].ticket,
                  " err=", GetLastError(),
                  " attempt=", m_entries[i].fail_count, " -- will retry.");
         }
      }
   }

   // --- persistence hooks (Memento) ---
   void WriteTo(int h) {
      FileWriteInteger(h, m_count);
      for(int i = 0; i < m_count; i++) {
         FileWriteInteger(h, m_entries[i].ticket);
         FileWriteInteger(h, m_entries[i].dir);
         FileWriteDouble(h,  m_entries[i].vsl_price);
         FileWriteDouble(h,  m_entries[i].be_price);
         FileWriteDouble(h,  m_entries[i].safety_sl_price);
      }
   }

   // FIX-3: count is clamped to MAX_POSITIONS, extra records are drained,
   // and closed/unknown tickets are dropped instead of counted.
   void ReadFrom(int h) {
      int saved = FileReadInteger(h);
      m_count = 0;
      for(int i = 0; i < saved; i++) {
         int    ticket = FileReadInteger(h);
         int    dir    = FileReadInteger(h);
         double vsl    = FileReadDouble(h);
         double be     = FileReadDouble(h);
         double safety = FileReadDouble(h);
         if(m_count >= MAX_POSITIONS) continue; // drain, don't store
         if(!OrderSelect(ticket, SELECT_BY_TICKET) || OrderCloseTime() != 0) continue; // stale
         m_entries[m_count].ticket          = ticket;
         m_entries[m_count].dir             = dir;
         m_entries[m_count].vsl_price       = vsl;
         m_entries[m_count].be_price        = be;
         m_entries[m_count].safety_sl_price = safety;
         m_entries[m_count].active          = true;
         m_entries[m_count].fail_count      = 0;
         m_count++;
      }
   }
};

//==================================================================
// SECTION 12 -- CTrailingManager : break-even + trailing stop
//==================================================================
class CTrailingManager {
private:
   bool   m_hide_sl;
   double m_be_lock_pips;

   void ApplyBrokerSL(double newSL) {
      if((OrderType() == OP_BUY  && newSL > OrderStopLoss()) ||
         (OrderType() == OP_SELL && (OrderStopLoss() == 0.0 || newSL < OrderStopLoss()))) {
         if(!OrderModify(OrderTicket(), OrderOpenPrice(), newSL, OrderTakeProfit(), 0, clrGreen))
            Print("OrderModify failed ticket=", OrderTicket(), " err=", GetLastError());
      }
   }

public:
   void Init(bool hideSl, double beLockPips) {
      m_hide_sl      = hideSl;
      m_be_lock_pips = beLockPips;
   }

   void Manage(CRiskModel &risk, CVirtualStopManager &vsl, int magic) {
      TRADE_PARAMS p;
      risk.Resolve(p);
      double ps = PipSize();

      for(int i = OrdersTotal() - 1; i >= 0; i--) {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
         if(OrderSymbol() != Symbol() || OrderMagicNumber() != magic) continue;
         if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

         bool   isBuy  = (OrderType() == OP_BUY);
         double gained = isBuy
            ? (Bid - OrderOpenPrice()) / ps
            : (OrderOpenPrice() - Ask) / ps;

         if(gained >= p.be_trigger) {
            double beSL = isBuy
               ? OrderOpenPrice() + PipToPrice(m_be_lock_pips)
               : OrderOpenPrice() - PipToPrice(m_be_lock_pips);
            if(m_hide_sl) vsl.Tighten(OrderTicket(), isBuy, beSL);
            else          ApplyBrokerSL(beSL);
         }

         if(gained >= p.trail_start) {
            double trailSL = isBuy
               ? NormalizeDouble(Bid - PipToPrice(p.trail_step), Digits)
               : NormalizeDouble(Ask + PipToPrice(p.trail_step), Digits);
            if(m_hide_sl) vsl.Tighten(OrderTicket(), isBuy, trailSL);
            else          ApplyBrokerSL(trailSL);
         }
      }
   }
};

//==================================================================
// SECTION 13 -- CTradeExecutor : order send / flatten / history scan
//==================================================================
class CTradeExecutor {
private:
   int    m_magic;
   bool   m_hide_sl;
   bool   m_use_safety_sl;
   double m_safety_mult;
   double m_be_lock_pips;

public:
   void Init(int magic, bool hideSl, bool useSafetySl, double safetyMult, double beLockPips) {
      m_magic        = magic;
      m_hide_sl      = hideSl;
      m_use_safety_sl = useSafetySl;
      m_safety_mult  = safetyMult;
      m_be_lock_pips = beLockPips;
   }

   int CountPositions() {
      int n = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--) {
         if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES) &&
            OrderSymbol()      == Symbol()   &&
            OrderMagicNumber() == m_magic    &&
            (OrderType() == OP_BUY || OrderType() == OP_SELL)) n++;
      }
      return n;
   }

   // Returns the net profit of the most recently closed position (includes swap+commission).
   // "Losing close" is defined as LastClosedProfit() < 0.
   double LastClosedProfit(double &closePrice) {
      datetime best = 0;
      double   prof = 0.0;
      closePrice    = 0.0;
      for(int i = OrdersHistoryTotal() - 1; i >= 0; i--) {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
         if(OrderSymbol()      != Symbol()  ||
            OrderMagicNumber() != m_magic)    continue;
         if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
         if(OrderCloseTime() > best) {
            best       = OrderCloseTime();
            prof       = OrderProfit() + OrderSwap() + OrderCommission();
            closePrice = OrderClosePrice();
         }
      }
      return prof;
   }

   // Returns the direction of the most recently closed position (+1 buy, -1 sell, 0 none).
   int LastClosedDir() {
      datetime best = 0;
      int      dir  = 0;
      for(int i = OrdersHistoryTotal() - 1; i >= 0; i--) {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
         if(OrderSymbol()      != Symbol()  ||
            OrderMagicNumber() != m_magic)    continue;
         if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
         if(OrderCloseTime() > best) {
            best = OrderCloseTime();
            dir  = (OrderType() == OP_BUY) ? +1 : -1;
         }
      }
      return dir;
   }

   bool Open(int dir, double lots, CRiskModel &risk, CVirtualStopManager &vsl, int slippage) {
      TRADE_PARAMS p;
      risk.Resolve(p);

      RefreshRates();
      double price   = (dir > 0) ? Ask : Bid;
      double stopLvl = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
      double slDist  = MathMax(PipToPrice(p.sl_pips), stopLvl);
      double tpDist  = MathMax(PipToPrice(p.tp_pips), stopLvl);

      double slPrice = (dir > 0) ? price - slDist : price + slDist;
      double tpPrice = (dir > 0) ? price + tpDist : price - tpDist;
      double bePrice = (dir > 0)
         ? price + PipToPrice(m_be_lock_pips)
         : price - PipToPrice(m_be_lock_pips);

      double orderSL = m_hide_sl ? 0.0 : NormalizeDouble(slPrice, Digits);
      if(m_hide_sl && m_use_safety_sl)
         orderSL = NormalizeDouble(
            (dir > 0) ? price - slDist * m_safety_mult
                      : price + slDist * m_safety_mult, Digits);

      int ticket = OrderSend(
         Symbol(),
         (dir > 0) ? OP_BUY : OP_SELL,
         lots,
         NormalizeDouble(price, Digits),
         slippage,
         orderSL,
         NormalizeDouble(tpPrice, Digits),
         "OneMinuteMan",
         m_magic, 0,
         (dir > 0) ? clrBlue : clrRed);

      if(ticket < 0) {
         Print("OrderSend failed: err=", GetLastError());
         return false;
      }

      if(m_hide_sl)
         vsl.Register(ticket, dir,
            NormalizeDouble(slPrice, Digits),
            NormalizeDouble(bePrice, Digits),
            orderSL);
      return true;
   }

   // FIX-6: emergency flatten used when the equity guard breaches
   // while positions are still open.
   void CloseAll(int slippage, CVirtualStopManager &vsl) {
      for(int i = OrdersTotal() - 1; i >= 0; i--) {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
         if(OrderSymbol()      != Symbol()  ||
            OrderMagicNumber() != m_magic)    continue;
         if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
         RefreshRates();
         double closePrice = (OrderType() == OP_BUY) ? Bid : Ask;
         if(OrderClose(OrderTicket(), OrderLots(), closePrice, slippage, clrRed))
            vsl.Remove(OrderTicket());
         else
            Print("Emergency close failed ticket=", OrderTicket(), " err=", GetLastError());
      }
   }
};

//==================================================================
// SECTION 14 -- CStateStore : versioned binary persistence (Memento)
//==================================================================
// v10.13: Martingale fields removed. Loss-reversal state added.
// Format: OMM5 (0x4F4D4D35). Old OMM4 files safely discarded.
// FIX-4: the halt flag, halt-until time, day baseline and day stamp are
// now persisted, so a terminal restart can no longer bypass the daily
// drawdown halt or re-anchor the baseline.
class CStateStore {
private:
   string m_filename;

public:
   void Init(int magic) {
      m_filename = "OMM_State_" + Symbol() + "_" + IntegerToString(magic) + ".bin";
   }

   void Save(CVirtualStopManager &vsl,
             bool halted, datetime haltUntil, double dayBaseline, int dayStamp,
             int reversalLossesToday, int tradesToday,
             datetime lastLossCloseTime, bool reversalPending, int reversalDir) {
      int h = FileOpen(m_filename, FILE_WRITE | FILE_BIN);
      if(h == INVALID_HANDLE) {
         Print("SaveState: cannot open ", m_filename, " err=", GetLastError());
         return;
      }
      FileWriteInteger(h, STATE_MAGIC);
      // equity guard state
      FileWriteInteger(h, halted ? 1 : 0);
      FileWriteLong(h,    (long)haltUntil);
      FileWriteDouble(h,  dayBaseline);
      FileWriteInteger(h, dayStamp);
      // loss-reversal state (v10.13)
      FileWriteInteger(h, reversalLossesToday);
      FileWriteInteger(h, tradesToday);
      FileWriteLong(h,    (long)lastLossCloseTime);
      FileWriteInteger(h, reversalPending ? 1 : 0);
      FileWriteInteger(h, reversalDir);
      // virtual stop manager
      vsl.WriteTo(h);
      FileClose(h);
   }

   bool Load(CVirtualStopManager &vsl,
             bool &halted, datetime &haltUntil, double &dayBaseline, int &dayStamp,
             int &reversalLossesToday, int &tradesToday,
             datetime &lastLossCloseTime, bool &reversalPending, int &reversalDir) {
      int h = FileOpen(m_filename, FILE_READ | FILE_BIN);
      if(h == INVALID_HANDLE) return false;
      int tag = FileReadInteger(h);
      if(tag != STATE_MAGIC) {
         FileClose(h);
         Print("State file has old/unknown format (expected OMM5) -- starting fresh.");
         return false;
      }
      // equity guard state
      halted      = (FileReadInteger(h) != 0);
      haltUntil   = (datetime)FileReadLong(h);
      dayBaseline = FileReadDouble(h);
      dayStamp    = FileReadInteger(h);
      // loss-reversal state (v10.13)
      reversalLossesToday = FileReadInteger(h);
      tradesToday         = FileReadInteger(h);
      lastLossCloseTime   = (datetime)FileReadLong(h);
      reversalPending     = (FileReadInteger(h) != 0);
      reversalDir         = FileReadInteger(h);
      // virtual stop manager
      vsl.ReadFrom(h);
      FileClose(h);
      return true;
   }
};

//==================================================================
// SECTION 15 -- CExpertAdvisor : Facade wiring all components
//==================================================================
// v10.13: Martingale controller removed. Signal-only entry with
// event-driven loss-reversal. FIFO/netting compatible.
class CExpertAdvisor {
private:
   CSpreadMonitor        m_spread;
   CRangeScanner         m_range;
   CCandleEngine         m_candle_engine;
   CPpmEngine            m_ppm_engine;
   CVolumeFilter         m_volume;
   CSessionClock         m_clock;
   CEquityGuard          m_guard;
   CRiskModel            m_risk;
   CVirtualStopManager   m_vsl;
   CTrailingManager      m_trailing;
   CTradeExecutor        m_exec;
   CStateStore           m_store;

   CANDLE_STRUCTURE m_candle;
   bool             m_candle_valid;
   PPM_RESULT       m_ppm;
   bool             m_ppm_valid;
   bool             m_had_pos;
   bool             m_halted;
   datetime         m_halt_until;
   bool             m_initialized;
   datetime         m_last_bar_time;

   // v10.13 loss-reversal state
   bool             m_reversal_pending;   // armed after a losing close
   int              m_reversal_dir;       // direction for the reverse leg (+1/-1)
   datetime         m_last_loss_close_time; // when the losing position closed
   int              m_reversal_losses_today; // count of reverse-leg losses today
   int              m_trades_today;       // total trades opened today
   bool             m_last_was_reversal;  // true if the current/last position was a reverse leg

   void SaveState() {
      m_store.Save(m_vsl, m_halted, m_halt_until,
                   m_guard.Baseline(), m_guard.DayStamp(),
                   m_reversal_losses_today, m_trades_today,
                   m_last_loss_close_time, m_reversal_pending, m_reversal_dir);
   }

   void HaltForToday(string reason) {
      m_halt_until = m_clock.NextSessionOpenGMT();
      m_halted     = true;
      Print("Trading halted (", reason, ") until ", TimeToString(m_halt_until), " GMT");
      SaveState();
   }

   bool TradingWindowOpen() {
      if(m_halted) {
         if(TimeGMT() < m_halt_until) return false;
         m_halted = false;
         m_guard.ResetBaseline(m_clock.LocalDayStamp());
         SaveState();
      }
      return m_clock.InSession();
   }

   // FIX-6: guard is evaluated on every tick -- including while a position
   // is open -- and can optionally flatten immediately.
   bool EquityGuardOK() {
      string reason = "";
      if(!m_guard.Breached(reason)) return true;
      if(InpCloseOnGuardBreach && m_exec.CountPositions() > 0) {
         Print("Equity guard breached with open positions -- flattening. (", reason, ")");
         m_exec.CloseAll(m_spread.EffSlippage(), m_vsl);
      }
      m_reversal_pending = false;
      HaltForToday(reason);
      return false;
   }

   // v10.13: Detect position closure and arm loss-reversal if applicable.
   void UpdateTradeState() {
      int n = m_exec.CountPositions();
      if(n == 0 && m_had_pos) {
         // A position just closed -- check if it was a loss
         double closePx = 0.0;
         double profit  = m_exec.LastClosedProfit(closePx);
         int    lastDir = m_exec.LastClosedDir();

         if(profit < 0.0) {
            // Track reverse-leg losses separately
            if(m_last_was_reversal) {
               m_reversal_losses_today++;
            }
            // Arm the loss-reversal if enabled and within daily limits
            if(InpEnableLossReversal && lastDir != 0) {
               bool withinLimits = true;
               if(InpMaxReverseLossesPerDay > 0 && m_reversal_losses_today >= InpMaxReverseLossesPerDay)
                  withinLimits = false;
               if(InpMaxTradesPerDay > 0 && m_trades_today >= InpMaxTradesPerDay)
                  withinLimits = false;

               if(withinLimits) {
                  m_reversal_pending     = true;
                  m_reversal_dir         = -lastDir; // opposite direction
                  m_last_loss_close_time = TimeCurrent();
                  Print("Loss-reversal armed: dir=", (m_reversal_dir > 0) ? "BUY" : "SELL",
                        " after loss $", DoubleToString(profit, 2),
                        " revLosses=", m_reversal_losses_today,
                        "/", InpMaxReverseLossesPerDay);
               } else {
                  m_reversal_pending = false;
                  Print("Loss-reversal skipped: daily limit reached (",
                        "revLosses=", m_reversal_losses_today,
                        " trades=", m_trades_today, ")");
               }
            }
         } else {
            // Winning close -- reset reversal state
            m_reversal_pending = false;
         }
         m_last_was_reversal = false;
         SaveState();
      }
      m_had_pos = (n > 0);
   }

   // v10.13: Event-driven loss-reversal entry.
   // Fires once after a losing close, with optional delay and confirmation.
   // FIFO/netting compatible: waits for CountPositions() == 0.
   void ManageReverseEntry() {
      if(!InpEnableLossReversal || !InpEnableTrading) return;
      if(!m_reversal_pending)                         return;
      if(m_exec.CountPositions() != 0)               return; // wait for flat
      if(!TradingWindowOpen())                        return;
      if(!m_spread.SpreadOK())                        return;

      // Delay gate
      if(TimeCurrent() - m_last_loss_close_time < InpLossReversalDelaySec) return;

      // Daily limit check
      if(InpMaxReverseLossesPerDay > 0 && m_reversal_losses_today >= InpMaxReverseLossesPerDay) {
         m_reversal_pending = false;
         return;
      }
      if(InpMaxTradesPerDay > 0 && m_trades_today >= InpMaxTradesPerDay) {
         m_reversal_pending = false;
         return;
      }

      // Confirmation gate (reuses ENUM_MART_CONFIRM)
      if(!ReverseConfirmationOK()) return;

      // Execute the reverse entry
      double lots = (InpReverseLots > 0.0)
                       ? NormalizeLots(InpReverseLots)
                       : NormalizeLots(InpBaseLots);
      if(m_exec.Open(m_reversal_dir, lots, m_risk, m_vsl, m_spread.EffSlippage())) {
         m_reversal_pending  = false;
         m_last_was_reversal = true;
         m_trades_today++;
         Print("Loss-reversal fired: dir=", (m_reversal_dir > 0) ? "BUY" : "SELL",
               " lots=", DoubleToString(lots, 2),
               " trades=", m_trades_today);
         SaveState();
      }
   }

   // Check reversal confirmation gate (candle/PPM filter)
   bool ReverseConfirmationOK() {
      if(InpReverseConfirm == MART_CONFIRM_NONE) return true;

      bool candleOk = false;
      if(m_candle_valid) {
         int sigDir = m_candle_engine.SignalDirection(m_candle);
         candleOk = (sigDir != 0 && sigDir == m_reversal_dir);
      }
      bool ppmOk = (m_ppm_valid && m_ppm.zone >= PPM_ZONE_MEDIUM);

      switch(InpReverseConfirm) {
         case MART_CONFIRM_CANDLE: return candleOk;
         case MART_CONFIRM_PPM:    return ppmOk;
         case MART_CONFIRM_EITHER: return (candleOk || ppmOk);
         case MART_CONFIRM_BOTH:   return (candleOk && ppmOk);
      }
      return false;
   }

   // v10.13: Fresh signal entry only -- no martingale re-entry path.
   void ManageEntries(bool allowFresh) {
      if(!InpEnableTrading)              return;
      if(m_exec.CountPositions() > 0)   return; // single-position invariant
      if(!TradingWindowOpen())           return;
      if(!m_spread.SpreadOK())           return;
      if(!EquityGuardOK())               return;

      // Skip fresh entry if a reversal is pending (let reversal fire first)
      if(m_reversal_pending)             return;

      // Daily trade limit
      if(InpMaxTradesPerDay > 0 && m_trades_today >= InpMaxTradesPerDay) return;

      // --- fresh entry path (signal-only, no martingale) ---
      if(!allowFresh || !m_candle_valid || !m_ppm_valid) return;
      if(m_ppm.zone < PPM_ZONE_MEDIUM)                   return;
      if(!m_volume.Ok())                                  return;

      int dir = m_candle_engine.SignalDirection(m_candle);
      if(dir == 0) return;

      double lots = NormalizeLots(InpBaseLots);
      if(m_exec.Open(dir, lots, m_risk, m_vsl, m_spread.EffSlippage())) {
         m_last_was_reversal = false;
         m_trades_today++;
         SaveState();
      }
   }

   void UpdateComment() {
      string msg = "=== OneMinuteMan v10.13 (no-mart) ===\n";
      msg += StringFormat("Symbol:%-6s  Engines:M1 (forced)  Chart:%s\n", Symbol(), TFLabel());
      msg += "--- Range ---\n";
      msg += StringFormat("High:%.5f  Low:%.5f  Range:%.5f\n",
                          m_range.High(), m_range.Low(), m_range.Range());
      msg += "--- Candle ---\n";
      if(m_candle_valid)
         msg += StringFormat("Pattern:%s Trend:%s\n",
                             CandleTypeName(m_candle.type), TrendName(m_candle.unit));
      if(InpShowPPM && m_ppm_valid)
         msg += StringFormat("PPM:%.2f  Zone:%s\n", m_ppm.ppm, PpmZoneName(m_ppm.zone));
      msg += "--- Trade ---\n";
      msg += StringFormat("Trading:%s  Spread:%d/%d  Equity:$%.2f  DD:%.2f%%\n",
                          InpEnableTrading ? "ON" : "OFF",
                          (int)((Ask - Bid) / Point), m_spread.EffMaxSpread(),
                          AccountEquity(), m_guard.DrawdownPct());
      msg += StringFormat("Open:%d  Trades:%d%s\n",
                          m_exec.CountPositions(),
                          m_trades_today,
                          (InpMaxTradesPerDay > 0)
                             ? StringFormat("/%d", InpMaxTradesPerDay) : "");
      // Loss-reversal status
      msg += StringFormat("Reversal:%s  Confirm:%s\n",
                          InpEnableLossReversal ? "ON" : "OFF",
                          ConfirmName(InpReverseConfirm));
      if(m_reversal_pending) {
         int delayRemaining = (int)(InpLossReversalDelaySec - (TimeCurrent() - m_last_loss_close_time));
         if(delayRemaining < 0) delayRemaining = 0;
         msg += StringFormat("  PENDING %s in %d s\n",
                             (m_reversal_dir > 0) ? "BUY" : "SELL",
                             delayRemaining);
      }
      msg += StringFormat("RevLosses:%d%s\n",
                          m_reversal_losses_today,
                          (InpMaxReverseLossesPerDay > 0)
                             ? StringFormat("/%d", InpMaxReverseLossesPerDay) : "");
      msg += StringFormat("Session: %s  HideSL:%s  VSLs:%d\n",
                          TradingWindowOpen() ? "OPEN" : "CLOSED",
                          InpHideSL ? "ON" : "OFF", m_vsl.Count());
      if(m_halted)
         msg += StringFormat("HALTED until: %s (GMT)\n",
                             TimeToString(m_halt_until, TIME_MINUTES));
      Comment(msg);
   }

public:
   int OnInitHandler() {
      m_initialized  = false;
      m_candle_valid = false;
      m_ppm_valid    = false;
      m_had_pos      = false;
      m_halted       = false;
      m_halt_until   = 0;
      m_last_bar_time = 0;

      // v10.13 loss-reversal state init
      m_reversal_pending      = false;
      m_reversal_dir          = 0;
      m_last_loss_close_time  = 0;
      m_reversal_losses_today = 0;
      m_trades_today          = 0;
      m_last_was_reversal     = false;

      // --- input validation ---
      if(InpWindowSize < 60 || InpWindowSize > 50000)
         { Print("Error: InpWindowSize must be 60-50000"); return INIT_PARAMETERS_INCORRECT; }
      if(InpBaseLots <= 0.0)
         { Print("Error: InpBaseLots must be > 0"); return INIT_PARAMETERS_INCORRECT; }
      if(InpSprEmaAlpha <= 0.0 || InpSprEmaAlpha > 1.0)
         { Print("Error: InpSprEmaAlpha must be in (0,1]"); return INIT_PARAMETERS_INCORRECT; }
      if(InpLossReversalDelaySec < 0)
         { Print("Error: InpLossReversalDelaySec must be >= 0"); return INIT_PARAMETERS_INCORRECT; }
      if(InpMaxReverseLossesPerDay < 0)
         { Print("Error: InpMaxReverseLossesPerDay must be >= 0"); return INIT_PARAMETERS_INCORRECT; }
      if(InpMaxTradesPerDay < 0)
         { Print("Error: InpMaxTradesPerDay must be >= 0"); return INIT_PARAMETERS_INCORRECT; }

      // --- component initialization ---
      m_spread.Init(InpSprEmaAlpha, InpMaxSpreadMult, InpSlippageMult,
                    InpSlippage, InpMaxSpread);
      if(!m_range.Init(InpWindowSize))
         { Print("Error: buffer allocation failed"); return INIT_FAILED; }
      m_candle_engine.Init(InpAverPeriod);
      m_ppm_engine.Init(InpZzDepth, InpZzDeviation, InpZzBackstep, InpZzLookback,
                        InpPpmMinHigh, InpPpmTarget, InpAtrDailyRef);
      m_volume.Init(InpUseVolumeFilter, InpVolLookback, InpVolMultiplier);
      m_clock.Init(InpTzOffsetHours, InpSessionStartHour, InpSessionEndHour);
      m_guard.Init(InpMinEquity, InpMaxDrawdownPct);
      m_risk.Init(InpAtrPeriod, InpAtrSLMult, InpAtrTPMult,
                  InpAtrTrailStartMult, InpAtrTrailStepMult, InpBE_TriggerMult,
                  InpMinRiskPips, InpSL_Pips, InpTP_Pips, InpTrailStart, InpTrailStep);
      m_vsl.Init(InpHideSL);
      m_trailing.Init(InpHideSL, InpBE_LockPips);
      m_exec.Init(InpMagic, InpHideSL, InpUseSafetySL, InpSafetySLMult, InpBE_LockPips);
      m_store.Init(InpMagic);

      if(!m_ppm_engine.VerifyIndicator()) {
         Print("ERROR: ZigZag indicator not found (no pivot in ", InpZzLookback, " bars).");
         return INIT_FAILED;
      }

      // --- restore persisted state ---
      bool     halted    = false;
      datetime haltUntil = 0;
      double   baseline  = 0.0;
      int      dayStamp  = 0;
      int      revLosses = 0;
      int      trades    = 0;
      datetime llct      = 0;
      bool     revPend   = false;
      int      revDir    = 0;

      if(m_store.Load(m_vsl, halted, haltUntil, baseline, dayStamp,
                      revLosses, trades, llct, revPend, revDir)) {
         int today = m_clock.LocalDayStamp();
         if(dayStamp == today && baseline > 0.0) {
            m_guard.SetBaseline(baseline, dayStamp);
            m_reversal_losses_today = revLosses;
            m_trades_today          = trades;
            m_last_loss_close_time  = llct;
            m_reversal_pending      = revPend;
            m_reversal_dir          = revDir;
            if(halted && TimeGMT() < haltUntil) {
               m_halted     = true;
               m_halt_until = haltUntil;
               Print("Restored active halt until ", TimeToString(haltUntil), " GMT");
            }
         } else {
            // New day -- reset daily counters
            m_guard.ResetBaseline(today);
            m_reversal_losses_today = 0;
            m_trades_today          = 0;
            m_reversal_pending      = false;
         }
         Print("State recovered (OMM5): VSLs=", m_vsl.Count(),
               " RevPending=", m_reversal_pending ? "yes" : "no",
               " RevLosses=", m_reversal_losses_today,
               " Trades=", m_trades_today);
      } else {
         m_guard.ResetBaseline(m_clock.LocalDayStamp());
      }

      m_had_pos = (m_exec.CountPositions() > 0);

      if(!EventSetMillisecondTimer(InpSampleMs))
         { Print("Error: Timer failed"); return INIT_FAILED; }

      m_initialized = true;
      Print("OneMinuteMan v10.13 (no-mart) initialized successfully.");
      return INIT_SUCCEEDED;
   }

   void OnDeinitHandler() {
      EventKillTimer();
      Comment("");
      if(m_initialized) SaveState(); // never clobber good state from a failed init
   }

   // Timer path: SL enforcement, trailing, range sampling, reverse entry.
   // Conflict resolution policy (CR6): Timer always runs SL enforcement first.
   // Order actions are guarded by CountPositions() checks.
   void OnTimerHandler() {
      if(!m_initialized) return;
      RefreshRates();

      m_spread.Update();
      m_range.Sample(Ask);

      PPM_RESULT tmp;
      if(m_ppm_engine.Calc(tmp)) { m_ppm = tmp; m_ppm_valid = true; }

      // Roll the drawdown baseline on local-day change even without ticks
      if(m_guard.RollDayIfNeeded(m_clock.LocalDayStamp())) {
         // New day: reset daily counters
         m_reversal_losses_today = 0;
         m_trades_today          = 0;
         m_reversal_pending      = false;
      }

      m_trailing.Manage(m_risk, m_vsl, InpMagic);
      m_vsl.Enforce(m_spread.EffSlippage());
      ManageReverseEntry();
      UpdateComment();
   }

   // Tick path: candle recognition, signal evaluation, trade state tracking.
   // Conflict resolution policy (CR6): If timer just closed a position,
   // UpdateTradeState() will detect it and proceed safely.
   void OnTickHandler() {
      if(!m_initialized) return;
      bool newBar = IsNewBar();

      if(newBar) {
         CANDLE_STRUCTURE bar;
         if(m_candle_engine.Recognize(1, bar)) {
            m_candle       = bar;
            m_candle_valid = true;
         }
      }

      if(m_guard.RollDayIfNeeded(m_clock.LocalDayStamp())) {
         m_reversal_losses_today = 0;
         m_trades_today          = 0;
         m_reversal_pending      = false;
      }
      UpdateTradeState();

      if(m_exec.CountPositions() > 0) {
         if(!EquityGuardOK()) return;
      }

      m_trailing.Manage(m_risk, m_vsl, InpMagic);
      m_vsl.Enforce(m_spread.EffSlippage());
      ManageReverseEntry();
      ManageEntries(newBar);
   }

   bool IsNewBar() {
      datetime cur = iTime(Symbol(), PERIOD_M1, 0);
      if(cur != m_last_bar_time) { m_last_bar_time = cur; return true; }
      return false;
   }
};

//==================================================================
// SECTION 16 -- MT4 EVENT HANDLERS (delegate to the Facade)
//==================================================================
CExpertAdvisor g_ea;

int  OnInit()                    { return g_ea.OnInitHandler();  }
void OnDeinit(const int reason)  { g_ea.OnDeinitHandler();        }
void OnTimer()                   { g_ea.OnTimerHandler();         }
void OnTick()                    { g_ea.OnTickHandler();          }
//+------------------------------------------------------------------+
