//+------------------------------------------------------------------+
//|                                                  oneminuteman.mq4 |
//|                                     Copyright 2025, nhasibuan     |
//|                          https://github.com/nhasibuan/oneminuteman|
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, nhasibuan"
#property link      "https://github.com/nhasibuan/oneminuteman"
#property version   "10.11"
#property strict
#property description "OneMinuteMan v10: Forced-M1 range + candle + PPM engine, rebuilt as a"
#property description "single-file component architecture. ATR-dynamic risk, virtual SL with"
#property description "safety net, break-even, persistent equity guards, martingale recovery."

//==================================================================
//  ARCHITECTURE (single file, component-based)
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
//       CMartingaleController loss-recovery state machine + all
//                             centralized re-entry protections (v10.10)
//       CTradeExecutor        order send / flatten / history scan
//       CStateStore           versioned binary persistence (Memento)
//   - Guard clauses everywhere; no hidden global mutation: all state
//     lives inside the owning component.
//==================================================================

//==================================================================
// SECTION 0 -- ENUMERATIONS
//==================================================================
enum ENUM_MART_MODE {
   MART_SAME_DIRECTION    = 0,
   MART_REVERSE_DIRECTION = 1
};

// v10.10 -- reversal confirmation required before each martingale step
enum ENUM_MART_CONFIRM {
   MART_CONFIRM_NONE   = 0, // no confirmation (time/price gates only)
   MART_CONFIRM_CANDLE = 1, // candle signal must agree with re-entry direction
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

//--- Martingale
input bool           InpUseMartingale    = true;
input ENUM_MART_MODE InpMartMode         = MART_SAME_DIRECTION;
input double         InpMartMult         = 2.0;
input int            InpMartMaxSteps     = 5; // Max re-entries after the initial trade
input int            InpMartCooldownBars = 2; // Fallback cooldown bars (used when schedule empty)

//--- Martingale: Consecutive-Loss Protection (v10.10)
input string InpMartCooldownSchedule = "0,0,1,0,1"; // "" = fixed InpMartCooldownBars (progressive cooldown bars per step)
input string InpMartMultSchedule     = "1.0,2.0,1.0,2.0,1.0"; // "" = fixed InpMartMult (lot multiplier per step)
input int    InpMaxConsecLosses      = 3;   // 0 = off; pause all entries after N consecutive losses
input int    InpConsecLossPauseMin   = 1;   // Pause duration in minutes
input double InpMartMaxADX           = 30.0;// 0 = off; block re-entry when ADX(M1) above or below this
input int    InpMartADXPeriod        = 14;  // ADX period for the trend block
input double InpMartMinAtrDist       = 0.5; // 0 = force new bar; same-bar re-entry needs price move >= ATR x this
input ENUM_MART_CONFIRM InpMartConfirm = MART_CONFIRM_EITHER; // Reversal confirmation before each step
input int    InpMartAtrLowPips       = 0;   // 0 = off; ATR-adaptive steps: full steps at or below this ATR pips
input int    InpMartAtrHighPips      = 0;   // 0 = off; ATR-adaptive steps: only 2 steps above this ATR pips
input bool   InpAutoCalibrateMartAtr = false; // Auto-derive ATR low/high pip thresholds + suggest ADX from recent M1 bars

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
#define STATE_MAGIC   0x4F4D4D34 // "OMM4" -- v10.10 state format tag

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

// v10.10 -- parse comma-separated schedules for progressive cooldown / multiplier
int ParseIntList(string csv, int &out[], int cap) {
   string parts[];
   int n = StringSplit(csv, ',', parts);
   int k = 0;
   for(int i = 0; i < n && k < cap; i++) {
      if(StringLen(parts[i]) == 0) continue;
      out[k++] = (int)StringToInteger(parts[i]);
   }
   return k;
}

int ParseDoubleList(string csv, double &out[], int cap) {
   string parts[];
   int n = StringSplit(csv, ',', parts);
   int k = 0;
   for(int i = 0; i < n && k < cap; i++) {
      if(StringLen(parts[i]) == 0) continue;
      out[k++] = StringToDouble(parts[i]);
   }
   return k;
}

string TFLabel() {
   string full = EnumToString((ENUM_TIMEFRAMES)_Period);
   StringReplace(full, "PERIOD_", "");
   return full;
}

string MartModeName(ENUM_MART_MODE m) {
   return (m == MART_REVERSE_DIRECTION) ? "REVERSE" : "SAME";
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
// SECTION 13 -- CMartingaleController : loss-recovery state machine
//==================================================================
// FIX-5: step semantics now match the documentation. A fresh trade is
// step 0; each re-entry increments the step; re-entries are allowed while
// step < MaxSteps, so MaxSteps really is the number of re-entries.
//
// v10.10: ALL re-entry checks are centralized in ReentryAllowed() -- the
// single decision point for every martingale attempt. New protections:
//   - progressive per-step cooldown schedule
//   - consecutive-loss limiter (pauses ALL entries)
//   - ADX trend block (no martingale against a strong trend)
//   - ATR price-spacing floor (same-bar re-entry needs real price movement)
//   - ATR-adaptive max steps (high volatility -> fewer steps)
//   - reversal confirmation via candle signal and/or PPM zone

// Market snapshot handed to the centralized re-entry decision
struct REENTRY_CONTEXT {
   double atr_pips;           // current ATR in pips (0 = unavailable)
   double adx;                // ADX(M1) on last closed bar (-1 = unavailable)
   double price;              // current Bid
   int    candle_dir;         // candle signal direction (+1/-1/0), 0 = none/invalid
   int    ppm_zone;           // PPM_ZONE value, -1 = invalid
   bool   new_bar_since_loss; // at least one new M1 bar since the losing close
};

#define MART_SCHED_CAP 16

class CMartingaleController {
private:
   bool           m_enabled;
   ENUM_MART_MODE m_mode;
   double         m_mult;
   int            m_max_steps;
   int            m_cooldown_bars;

   // v10.10 protection config
   int               m_cd_sched[MART_SCHED_CAP];
   int               m_cd_sched_n;
   double            m_mult_sched[MART_SCHED_CAP];
   int               m_mult_sched_n;
   int               m_max_consec_losses;
   int               m_pause_minutes;
   double            m_max_adx;
   double            m_min_atr_dist;
   ENUM_MART_CONFIRM m_confirm;
   int               m_atr_low_pips;
   int               m_atr_high_pips;

   // runtime state (persisted)
   int      m_step;
   int      m_last_dir;
   double   m_last_lots;
   bool     m_await_reentry;
   datetime m_last_loss_time;
   int      m_consec_losses;
   datetime m_pause_until;
   double   m_last_loss_price;

   string   m_block_reason; // last ReentryAllowed() block reason, for the panel

public:
   void Init(bool enabled, ENUM_MART_MODE mode, double mult, int maxSteps, int cooldownBars,
             string cdSchedule, string multSchedule,
             int maxConsecLosses, int pauseMinutes,
             double maxAdx, double minAtrDist, ENUM_MART_CONFIRM confirm,
             int atrLowPips, int atrHighPips) {
      m_enabled           = enabled;
      m_mode              = mode;
      m_mult              = mult;
      m_max_steps         = maxSteps;
      m_cooldown_bars     = cooldownBars;
      m_cd_sched_n        = ParseIntList(cdSchedule, m_cd_sched, MART_SCHED_CAP);
      m_mult_sched_n      = ParseDoubleList(multSchedule, m_mult_sched, MART_SCHED_CAP);
      m_max_consec_losses = maxConsecLosses;
      m_pause_minutes     = pauseMinutes;
      m_max_adx           = maxAdx;
      m_min_atr_dist      = minAtrDist;
      m_confirm           = confirm;
      m_atr_low_pips      = atrLowPips;
      m_atr_high_pips     = atrHighPips;
      m_last_dir          = 0;
      m_last_lots         = 0.0;
      m_consec_losses     = 0;
      m_pause_until       = 0;
      m_last_loss_price   = 0.0;
      m_block_reason      = "";
      ResetCycle();
   }

   void SetAtrThresholds(int lowPips, int highPips) {
      m_atr_low_pips  = lowPips;
      m_atr_high_pips = highPips;
   }

   void ResetCycle() {
      m_step          = 0;
      m_await_reentry = false;
      m_last_loss_time = 0;
   }

   int    Step()         { return m_step; }
   int    MaxSteps()     { return m_max_steps; }
   bool   AwaitReentry() { return m_await_reentry; }
   int    LastDir()      { return m_last_dir; }

   void OnFreshEntry(int dir, double lots) {
      m_step          = 0;
      m_last_dir      = dir;
      m_last_lots     = lots;
      m_await_reentry = false;
   }

   void OnReentry(int dir, double lots) {
      m_step++;
      m_last_dir      = dir;
      m_last_lots     = lots;
      m_await_reentry = false;
   }

   // Returns true when the loss should halt trading for the day.
   // v10.10: also tracks the consecutive-loss streak (across cycles) and
   // arms the entry pause when the streak reaches the limit.
   bool OnPositionClosed(double profit, double closePrice) {
      if(profit >= 0.0) {
         m_consec_losses = 0;
         ResetCycle();
         return false;
      }
      m_consec_losses++;
      m_last_loss_price = closePrice;
      if(m_max_consec_losses > 0 && m_consec_losses >= m_max_consec_losses) {
         m_pause_until = TimeCurrent() + m_pause_minutes * 60;
         Print("Consecutive-loss limiter: ", m_consec_losses,
               " losses in a row -- pausing all entries for ", m_pause_minutes, " min.");
      }
      if(!m_enabled)            { ResetCycle(); return false; }
      if(m_step >= m_max_steps) { ResetCycle(); return true; }
      m_await_reentry  = true;
      m_last_loss_time = TimeCurrent();
      return false;
   }

   // v10.10: consecutive-loss pause -- gates ALL entries (fresh + martingale)
   bool EntryPaused() {
      return (m_pause_until > 0 && TimeCurrent() < m_pause_until);
   }

   // Progressive cooldown: bars required before re-entry #(m_step+1).
   int CooldownBarsForStep() {
      if(m_cd_sched_n > 0)
         return m_cd_sched[(int)MathMin(m_step, m_cd_sched_n - 1)];
      return m_cooldown_bars;
   }

   // ATR-adaptive max steps: heuristic, demo-validate before live use.
   int EffectiveMaxSteps(double atrPips) {
      if(m_atr_low_pips <= 0 || m_atr_high_pips <= 0 || atrPips <= 0.0) return m_max_steps;
      if(atrPips <= m_atr_low_pips)  return m_max_steps;
      if(atrPips <= m_atr_high_pips) return (int)MathMax(m_max_steps - 1, 1);
      return (int)MathMin(2, m_max_steps);
   }

   // Cheap pre-check used by the facade before building a full context
   bool CanReenter() {
      return (m_enabled && m_await_reentry && m_step < m_max_steps);
   }

   // v10.10: THE single decision point for every martingale attempt.
   bool ReentryAllowed(const REENTRY_CONTEXT &ctx) {
      m_block_reason = "";
      if(!m_enabled || !m_await_reentry)              return Block("idle");
      if(EntryPaused())                               return Block("consec-loss pause");
      if(m_step >= EffectiveMaxSteps(ctx.atr_pips))   return Block("step cap (ATR-adaptive)");

      // 1. progressive cooldown (bar-based)
      int barsSinceLoss = (m_last_loss_time == 0)
         ? 9999 : iBarShift(Symbol(), PERIOD_M1, m_last_loss_time);
      if(barsSinceLoss < CooldownBarsForStep())        return Block("cooldown");

      // 2. hard floor: require a new M1 bar OR a real price move from the losing close
      if(!ctx.new_bar_since_loss) {
         if(m_min_atr_dist <= 0.0 || ctx.atr_pips <= 0.0 || m_last_loss_price <= 0.0)
            return Block("same-bar re-entry (no spacing data)");
         double needed = ctx.atr_pips * PipSize() * m_min_atr_dist;
         if(MathAbs(ctx.price - m_last_loss_price) < needed)
            return Block("ATR price spacing");
      }

      // 3. trend gate -- mode-aware (v10.11):
      //    SAME    : block when ADX above limit (don't average against a strong trend)
      //    REVERSE : block when ADX below limit (only reverse with a confirmed trend)
      //    Skipped when disabled (limit <= 0) or ADX unavailable.
      if(m_max_adx > 0.0 && ctx.adx > 0.0) {
         if(m_mode == MART_SAME_DIRECTION    && ctx.adx > m_max_adx) return Block("ADX trend block");
         if(m_mode == MART_REVERSE_DIRECTION && ctx.adx < m_max_adx) return Block("ADX needs trend");
      }

      // 4. reversal confirmation via existing signal engines
      if(!ConfirmationOK(ctx)) return Block("no reversal confirmation");

      return true;
   }

   string BlockReason() { return m_block_reason; }

   int ReentryDir() {
      return (m_mode == MART_REVERSE_DIRECTION) ? -m_last_dir : m_last_dir;
   }

   // v10.10: per-step multiplier schedule (decaying multipliers cut drawdown)
   double MultForStep() {
      if(m_mult_sched_n > 0)
         return m_mult_sched[(int)MathMin(m_step, m_mult_sched_n - 1)];
      return m_mult;
   }

   double ReentryLots(double baseLots) {
      double base = (m_last_lots > 0.0) ? m_last_lots : baseLots;
      return NormalizeLots(base * MultForStep());
   }

   int      ConsecLosses() { return m_consec_losses; }
   datetime PauseUntil()   { return m_pause_until; }
   datetime LastLossTime() { return m_last_loss_time; }

private:
   bool Block(string why) { m_block_reason = why; return false; }

   bool ConfirmationOK(const REENTRY_CONTEXT &ctx) {
      if(m_confirm == MART_CONFIRM_NONE) return true;
      bool candleOk = (ctx.candle_dir != 0 && ctx.candle_dir == ReentryDir());
      bool ppmOk    = (ctx.ppm_zone >= PPM_ZONE_MEDIUM);
      switch(m_confirm) {
         case MART_CONFIRM_CANDLE: return candleOk;
         case MART_CONFIRM_PPM:    return ppmOk;
         case MART_CONFIRM_EITHER: return (candleOk || ppmOk);
         case MART_CONFIRM_BOTH:   return (candleOk && ppmOk);
      }
      return false;
   }

public:
   // --- persistence hooks (Memento) ---
   void WriteTo(int h) {
      FileWriteInteger(h, m_step);
      FileWriteInteger(h, m_last_dir);
      FileWriteDouble(h,  m_last_lots);
      FileWriteInteger(h, m_await_reentry ? 1 : 0);
      FileWriteLong(h,    (long)m_last_loss_time);
      // v10.10 additions (state tag bumped to OMM4)
      FileWriteInteger(h, m_consec_losses);
      FileWriteLong(h,    (long)m_pause_until);
      FileWriteDouble(h,  m_last_loss_price);
   }

   void ReadFrom(int h) {
      m_step            = FileReadInteger(h);
      m_last_dir        = FileReadInteger(h);
      m_last_lots       = FileReadDouble(h);
      m_await_reentry   = (FileReadInteger(h) != 0);
      m_last_loss_time  = (datetime)FileReadLong(h);
      m_consec_losses   = FileReadInteger(h);
      m_pause_until     = (datetime)FileReadLong(h);
      m_last_loss_price = FileReadDouble(h);
   }
};

//==================================================================
// SECTION 14 -- CTradeExecutor : order send / flatten / history scan
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
// SECTION 15 -- CStateStore : versioned binary persistence (Memento)
//==================================================================
// FIX-4: the halt flag, halt-until time, day baseline and day stamp are
// now persisted, so a terminal restart can no longer bypass the daily
// drawdown halt or re-anchor the baseline. The file carries a magic tag;
// pre-v10 state files fail the tag check and are discarded safely.
class CStateStore {
private:
   string m_filename;

public:
   void Init(int magic) {
      m_filename = "OMM_State_" + Symbol() + "_" + IntegerToString(magic) + ".bin";
   }

   void Save(CMartingaleController &mart, CVirtualStopManager &vsl,
             bool halted, datetime haltUntil, double dayBaseline, int dayStamp) {
      int h = FileOpen(m_filename, FILE_WRITE | FILE_BIN);
      if(h == INVALID_HANDLE) {
         Print("SaveState: cannot open ", m_filename, " err=", GetLastError());
         return;
      }
      FileWriteInteger(h, STATE_MAGIC);
      mart.WriteTo(h);
      FileWriteInteger(h, halted ? 1 : 0);
      FileWriteLong(h,    (long)haltUntil);
      FileWriteDouble(h,  dayBaseline);
      FileWriteInteger(h, dayStamp);
      vsl.WriteTo(h);
      FileClose(h);
   }

   bool Load(CMartingaleController &mart, CVirtualStopManager &vsl,
             bool &halted, datetime &haltUntil, double &dayBaseline, int &dayStamp) {
      int h = FileOpen(m_filename, FILE_READ | FILE_BIN);
      if(h == INVALID_HANDLE) return false;
      int tag = FileReadInteger(h);
      if(tag != STATE_MAGIC) {
         FileClose(h);
         Print("State file has old/unknown format -- starting fresh.");
         return false;
      }
      mart.ReadFrom(h);
      halted      = (FileReadInteger(h) != 0);
      haltUntil   = (datetime)FileReadLong(h);
      dayBaseline = FileReadDouble(h);
      dayStamp    = FileReadInteger(h);
      vsl.ReadFrom(h);
      FileClose(h);
      return true;
   }
};

//==================================================================
// SECTION 16 -- CExpertAdvisor : Facade wiring all components
//==================================================================
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
   CMartingaleController m_mart;
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

   void SaveState() {
      m_store.Save(m_mart, m_vsl, m_halted, m_halt_until,
                   m_guard.Baseline(), m_guard.DayStamp());
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
      m_mart.ResetCycle();
      HaltForToday(reason);
      return false;
   }

   void UpdateTradeState() {
      int n = m_exec.CountPositions();
      if(n == 0 && m_had_pos) {
         double closePx = 0.0;
         double profit  = m_exec.LastClosedProfit(closePx);
         bool   haltNow = m_mart.OnPositionClosed(profit, closePx);
         if(haltNow) HaltForToday("martingale max steps exhausted on a loss");
         SaveState();
      }
      m_had_pos = (n > 0);
   }

   bool NewBarSinceLoss() {
      datetime t = m_mart.LastLossTime();
      if(t == 0) return true;
      return (iBarShift(Symbol(), PERIOD_M1, t) >= 1);
   }

   // v10.10: build the market snapshot for the centralized re-entry decision
   void BuildReentryContext(REENTRY_CONTEXT &ctx) {
      ctx.atr_pips          = m_risk.AtrPips();
      ctx.adx               = iADX(Symbol(), PERIOD_M1, InpMartADXPeriod, PRICE_CLOSE, MODE_MAIN, 1);
      ctx.price             = Bid;
      ctx.candle_dir        = m_candle_valid ? m_candle_engine.SignalDirection(m_candle) : 0;
      ctx.ppm_zone          = m_ppm_valid    ? (int)m_ppm.zone : -1;
      ctx.new_bar_since_loss = NewBarSinceLoss();
   }

   void ManageEntries(bool allowFresh) {
      if(!InpEnableTrading)              return;
      if(m_exec.CountPositions() > 0)   return;
      if(!TradingWindowOpen())           return;
      if(m_mart.EntryPaused())           return; // consecutive-loss limiter gates ALL entries
      if(!m_spread.SpreadOK())           return;
      if(!EquityGuardOK())               return;

      // --- martingale re-entry path ---
      if(m_mart.CanReenter()) {
         int reDir = m_mart.ReentryDir();
         if(reDir == 0) { m_mart.ResetCycle(); return; }

         REENTRY_CONTEXT ctx;
         BuildReentryContext(ctx);
         if(!m_mart.ReentryAllowed(ctx)) return;
         if(!m_volume.Ok())              return;

         double lots = m_mart.ReentryLots(InpBaseLots);
         if(m_exec.Open(reDir, lots, m_risk, m_vsl, m_spread.EffSlippage())) {
            m_mart.OnReentry(reDir, lots);
            SaveState();
         }
         return;
      }

      // --- fresh entry path ---
      if(!allowFresh || !m_candle_valid || !m_ppm_valid) return;
      if(m_ppm.zone < PPM_ZONE_MEDIUM)                   return;
      if(!m_volume.Ok())                                  return;

      int dir = m_candle_engine.SignalDirection(m_candle);
      if(dir == 0) return;

      double lots = NormalizeLots(InpBaseLots);
      if(m_exec.Open(dir, lots, m_risk, m_vsl, m_spread.EffSlippage())) {
         m_mart.OnFreshEntry(dir, lots);
         SaveState();
      }
   }

   void UpdateComment() {
      string msg = "=== OneMinuteMan v10.11 ===\n";
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
      msg += StringFormat("Open:%d  Mart:%d/%d (%s) %s\n",
                          m_exec.CountPositions(),
                          m_mart.Step(), m_mart.MaxSteps(),
                          MartModeName(InpMartMode),
                          m_mart.AwaitReentry() ? "[AWAIT]" : "");
      msg += StringFormat("ConsecLosses:%d%s%s\n",
                          m_mart.ConsecLosses(),
                          m_mart.EntryPaused()
                             ? StringFormat("  PAUSED until %s",
                                TimeToString(m_mart.PauseUntil(), TIME_MINUTES))
                             : "",
                          (m_mart.AwaitReentry() && StringLen(m_mart.BlockReason()) > 0)
                             ? "  Block:" + m_mart.BlockReason() : "");
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

      // --- input validation ---
      if(InpWindowSize < 60 || InpWindowSize > 50000)
         { Print("Error: InpWindowSize must be 60-50000"); return INIT_PARAMETERS_INCORRECT; }
      if(InpBaseLots <= 0.0)
         { Print("Error: InpBaseLots must be > 0"); return INIT_PARAMETERS_INCORRECT; }
      if(InpMartMult <= 0.0)
         { Print("Error: InpMartMult must be > 0"); return INIT_PARAMETERS_INCORRECT; }
      if(InpSprEmaAlpha <= 0.0 || InpSprEmaAlpha > 1.0)
         { Print("Error: InpSprEmaAlpha must be in (0,1]"); return INIT_PARAMETERS_INCORRECT; }
      if(InpMartCooldownBars < 0)
         { Print("Error: InpMartCooldownBars must be >= 0"); return INIT_PARAMETERS_INCORRECT; }
      if(InpMartMaxSteps < 0)
         { Print("Error: InpMartMaxSteps must be >= 0"); return INIT_PARAMETERS_INCORRECT; }
      if(InpMaxConsecLosses > 0 && InpConsecLossPauseMin < 1)
         { Print("Error: InpConsecLossPauseMin must be >= 1"); return INIT_PARAMETERS_INCORRECT; }
      if(InpMartAtrLowPips > 0 && InpMartAtrHighPips > 0 &&
         InpMartAtrHighPips < InpMartAtrLowPips)
         { Print("Error: InpMartAtrHighPips must be >= InpMartAtrLowPips"); return INIT_PARAMETERS_INCORRECT; }
      if(InpMartMinAtrDist < 0.0)
         { Print("Error: InpMartMinAtrDist must be >= 0"); return INIT_PARAMETERS_INCORRECT; }

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
      m_mart.Init(InpUseMartingale, InpMartMode, InpMartMult,
                  InpMartMaxSteps, InpMartCooldownBars,
                  InpMartCooldownSchedule, InpMartMultSchedule,
                  InpMaxConsecLosses, InpConsecLossPauseMin,
                  InpMartMaxADX, InpMartMinAtrDist, InpMartConfirm,
                  InpMartAtrLowPips, InpMartAtrHighPips);
      m_exec.Init(InpMagic, InpHideSL, InpUseSafetySL, InpSafetySLMult, InpBE_LockPips);
      m_store.Init(InpMagic);

      if(!m_ppm_engine.VerifyIndicator()) {
         Print("ERROR: ZigZag indicator not found (no pivot in ", InpZzLookback, " bars).");
         return INIT_FAILED;
      }

      // --- optional ATR auto-calibration ---
      // ATR thresholds are derived from live M1 percentiles (applied).
      // ADX suggestion is printed only; apply manually after demo validation.
      if(InpAutoCalibrateMartAtr) {
         if(Bars < 60) {
            Print("Auto-calibrate warning: fewer than 60 bars available; keeping manual ATR thresholds.");
         } else {
            int    sampleCount = (int)MathMin(500, Bars - 1);
            double pipSize     = PipSize();
            double atrValues[];
            double adxValues[];
            ArrayResize(atrValues, sampleCount);
            ArrayResize(adxValues, sampleCount);
            int atrCount = 0;
            int adxCount = 0;

            for(int i = 1; i <= sampleCount; i++) {
               double atrPips = iATR(Symbol(), PERIOD_M1, InpAtrPeriod, i) / pipSize;
               if(atrPips > 0.0) atrValues[atrCount++] = atrPips;

               double adx = iADX(Symbol(), PERIOD_M1, InpMartADXPeriod,
                                 PRICE_CLOSE, MODE_MAIN, i);
               if(adx > 0.0) adxValues[adxCount++] = adx;
            }

            if(atrCount < 60) {
               Print("Auto-calibrate warning: fewer than 60 valid M1 ATR samples; keeping manual ATR thresholds.");
            } else {
               ArrayResize(atrValues, atrCount);
               ArraySort(atrValues, WHOLE_ARRAY, 0, MODE_ASCEND);
               int lowIndex  = (int)MathRound((atrCount - 1) * 0.50);
               int highIndex = (int)MathRound((atrCount - 1) * 0.85);
               int lowPips   = (int)MathRound(atrValues[lowIndex]);
               int highPips  = (int)MathRound(atrValues[highIndex]);
               if(highPips < lowPips) highPips = lowPips;
               m_mart.SetAtrThresholds(lowPips, highPips);

               double adxSuggest = 0.0;
               if(adxCount > 0) {
                  ArrayResize(adxValues, adxCount);
                  ArraySort(adxValues, WHOLE_ARRAY, 0, MODE_ASCEND);
                  double percentile = (InpMartMode == MART_SAME_DIRECTION) ? 0.60 : 0.40;
                  int    adxIndex   = (int)MathRound((adxCount - 1) * percentile);
                  adxSuggest        = NormalizeDouble(adxValues[adxIndex], 1);
               }

               Print("Auto-calibrate: ATR thresholds APPLIED low=", lowPips,
                     " high=", highPips,
                     " pips; suggested InpMartMaxADX=", adxSuggest,
                     " (not applied; set manually after demo validation)");
            }
         }
      }

      // --- restore persisted state ---
      bool     halted    = false;
      datetime haltUntil = 0;
      double   baseline  = 0.0;
      int      dayStamp  = 0;
      if(m_store.Load(m_mart, m_vsl, halted, haltUntil, baseline, dayStamp)) {
         int today = m_clock.LocalDayStamp();
         if(dayStamp == today && baseline > 0.0) {
            m_guard.SetBaseline(baseline, dayStamp);
            if(halted && TimeGMT() < haltUntil) {
               m_halted     = true;
               m_halt_until = haltUntil;
               Print("Restored active halt until ", TimeToString(haltUntil), " GMT");
            }
         } else {
            m_guard.ResetBaseline(today);
         }
         Print("State recovered: MartStep=", m_mart.Step(),
               " VSLs=", m_vsl.Count(),
               " AwaitReentry=", m_mart.AwaitReentry() ? "yes" : "no");
      } else {
         m_guard.ResetBaseline(m_clock.LocalDayStamp());
      }

      m_had_pos = (m_exec.CountPositions() > 0);

      if(!EventSetMillisecondTimer(InpSampleMs))
         { Print("Error: Timer failed"); return INIT_FAILED; }

      m_initialized = true;
      Print("OneMinuteMan v10.11 initialized successfully.");
      return INIT_SUCCEEDED;
   }

   void OnDeinitHandler() {
      EventKillTimer();
      Comment("");
      if(m_initialized) SaveState(); // never clobber good state from a failed init
   }

   void OnTimerHandler() {
      if(!m_initialized) return;
      RefreshRates();

      m_spread.Update();
      m_range.Sample(Ask);

      PPM_RESULT tmp;
      if(m_ppm_engine.Calc(tmp)) { m_ppm = tmp; m_ppm_valid = true; }

      // Roll the drawdown baseline on local-day change even without ticks
      m_guard.RollDayIfNeeded(m_clock.LocalDayStamp());

      m_trailing.Manage(m_risk, m_vsl, InpMagic);
      m_vsl.Enforce(m_spread.EffSlippage());
      UpdateComment();
   }

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

      m_guard.RollDayIfNeeded(m_clock.LocalDayStamp());
      UpdateTradeState();

      if(m_exec.CountPositions() > 0) {
         if(!EquityGuardOK()) return;
      }

      m_trailing.Manage(m_risk, m_vsl, InpMagic);
      m_vsl.Enforce(m_spread.EffSlippage());
      ManageEntries(newBar);
   }

   bool IsNewBar() {
      datetime cur = iTime(Symbol(), PERIOD_M1, 0);
      if(cur != m_last_bar_time) { m_last_bar_time = cur; return true; }
      return false;
   }
};

//==================================================================
// SECTION 17 -- MT4 EVENT HANDLERS (delegate to the Facade)
//==================================================================
CExpertAdvisor g_ea;

int  OnInit()                    { return g_ea.OnInitHandler();  }
void OnDeinit(const int reason)  { g_ea.OnDeinitHandler();        }
void OnTimer()                   { g_ea.OnTimerHandler();         }
void OnTick()                    { g_ea.OnTickHandler();          }
//+------------------------------------------------------------------+
