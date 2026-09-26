//+------------------------------------------------------------------+
//| HOKKY V5 HEDGE - single-file MQL4 Expert Advisor                 |
//| Defensive ATR grid with explicit risk gates and non-blocking FSM. |
//| Test on demo and compile in MetaEditor before live deployment.    |
//+------------------------------------------------------------------+
#property strict
#property version   "5.10"
#property description "Defensive single-file ATR hedged grid EA"

//--- strategy inputs
input string InpComment="HOKKY_V5";
input int    InpMagic=0;
input int    InpSlippagePoints=30;
input bool   InpHedgeMode=true;
input bool   InpAllowBothDirections=true;
input bool   InpAllowNewBasket=true;
input bool   InpAllowAddons=true;
input int    InpATRPeriod=14;
input double InpGridATR=1.00;
input double InpBasketTP_ATR=0.75;
input double InpBasketSL_ATR=4.00;
input double InpOrderHardSL_ATR=6.00;
input double InpOrderTP_ATR=0.00;
input double InpLots=0.01;
input double InpMultiplier=1.30;
input int    InpMaxOrders=8;
input double InpMaxLotPerOrder=1.00;
input double InpMaxTotalLots=5.00;
input bool   InpUseTrendFilter=true;
input ENUM_TIMEFRAMES InpTrendTF=PERIOD_H1;
input int    InpTrendMAPeriod=50;
input ENUM_MA_METHOD InpTrendMethod=MODE_EMA;
//--- risk inputs
input double InpMaxDrawdownPct=15.0;
input double InpMaxBasketLossMoney=0.0;
input double InpMinEquity=0.0;
input double InpMinMarginLevel=150.0;
input bool   InpCloseAllOnRiskStop=true;
input int    InpCooldownMinutes=0; // 0 = permanent latch; manual reset required
input bool   InpRequireBrokerSL=true;
//--- execution/UI inputs
input double InpMaxSpreadPoints=60.0;
input int    InpStartHour=0;
input int    InpEndHour=24;
input bool   InpUseTrailing=true;
input double InpTrailStartATR=1.00;
input double InpTrailDistanceATR=0.50;
input int    InpTrailStepPoints=20;
input bool   InpJournal=true;
input string InpJournalFile="HOKKY_trades.csv";
input bool   InpDashboard=true;
input bool   InpResetRiskLatch=false;

//--- lifecycle states
#define STATE_STARTING 0
#define STATE_WAIT_ATR 1
#define STATE_RUNNING 2
#define STATE_CLOSE_ALL 3
#define STATE_LATCHED 4
#define STATE_FAULT 5
#define GV_SCHEMA "HOKKY_SCHEMA"
#define GV_LATCH  "HOKKY_LATCH"
#define GV_LATCH_TIME "HOKKY_LATCH_TIME"
#define GV_PEAK "HOKKY_PEAK"

struct PositionInfo
  {
   int ticket;
   int type;
   double lots;
   double openPrice;
   double sl;
   double tp;
   datetime openTime;
  };

int g_magic=0;
int g_state=STATE_STARTING;
string g_reason="starting";
datetime g_lastBar=0;
datetime g_lastTradeAttempt=0;
datetime g_lastDashboard=0;
datetime g_lastProtection=0;
datetime g_sessionStart=0;
double g_atr=0.0;
double g_peakNet=0.0;
int g_closeSide=-1; // -1 all, OP_BUY/OP_SELL side only
bool g_lease=false;
string g_leaseName="";
PositionInfo g_buy[],g_sell[];
int g_buyCount=0,g_sellCount=0;
double g_buyLots=0,g_sellLots=0,g_buyAvg=0,g_sellAvg=0,g_buyPL=0,g_sellPL=0;

//--- forward declarations
void RefreshPositions(); bool RiskStopTriggered(); void StartClose(string reason,bool latch);

int OnInit()
  {
   if(!ValidateInputs()) return(INIT_PARAMETERS_INCORRECT);
   g_magic=(InpMagic>0 ? InpMagic : 100000+Hash(Symbol()+IntegerToString(AccountNumber()))%899000000);
   g_leaseName="HOKKY_LEASE_"+IntegerToString(AccountNumber())+"_"+Symbol()+"_"+IntegerToString(g_magic);
   if(!AcquireLease()) return(INIT_FAILED);
   g_sessionStart=TimeCurrent();
   if(!GlobalVariableCheck(GV_SCHEMA)) GlobalVariableSet(GV_SCHEMA,5.10);
   if(GlobalVariableCheck(GV_PEAK)) g_peakNet=GlobalVariableGet(GV_PEAK);
   if(InpResetRiskLatch)
     {
      GlobalVariableDel(GV_LATCH); GlobalVariableDel(GV_LATCH_TIME);
     }
   RefreshPositions();
   if(IsLatched()) { g_state=STATE_LATCHED; g_reason="persistent risk latch"; }
   else { g_atr=ClosedATR(); g_state=(g_atr>0 ? STATE_RUNNING : STATE_WAIT_ATR); }
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer(); ReleaseLease(); Comment("");
  }

void OnTimer()
  {
   if(!g_lease) return;
   if(g_state==STATE_CLOSE_ALL || g_state==STATE_FAULT) DriveClose();
   else if(g_state==STATE_LATCHED) TryReleaseLatch();
   if(InpDashboard && TimeCurrent()-g_lastDashboard>=5) { g_lastDashboard=TimeCurrent(); DrawDashboard(); }
  }

void OnTick()
  {
   if(!g_lease) return;
   RefreshPositions();
   g_atr=ClosedATR();
   UpdatePeak();
   if(g_state==STATE_CLOSE_ALL || g_state==STATE_FAULT) { DriveClose(); return; }
   if(g_state==STATE_LATCHED) { TryReleaseLatch(); return; }
   if(RiskStopTriggered()) return;
   if(g_atr<=0) { g_state=STATE_WAIT_ATR; return; }
   ManageExitsAndTrailing();
   if(g_state==STATE_CLOSE_ALL || g_state==STATE_FAULT) return;
   if(Time[0]!=g_lastBar)
     {
      g_lastBar=Time[0];
      if(CanTrade()) ProcessEntries();
     }
   if(InpDashboard && TimeCurrent()-g_lastDashboard>=5) { g_lastDashboard=TimeCurrent(); DrawDashboard(); }
  }

bool ValidateInputs()
  {
   if(InpATRPeriod<2 || InpGridATR<=0 || InpLots<=0 || InpMultiplier<1 || InpMaxOrders<1) return(false);
   if(InpRequireBrokerSL && InpOrderHardSL_ATR<=0) return(false);
   if(InpUseTrailing && (InpTrailStartATR<InpTrailDistanceATR || InpTrailDistanceATR<=0)) return(false);
   if(InpStartHour<0 || InpStartHour>23 || InpEndHour<0 || InpEndHour>24) return(false);
   return(true);
  }

int Hash(string s)
  {
   uint h=5381;
   for(int i=0;i<StringLen(s);i++) h=h*33+(uint)StringGetChar(s,i);
   return((int)(h&0x7fffffff));
  }

bool AcquireLease()
  {
   if(!GlobalVariableCheck(g_leaseName)) GlobalVariableSet(g_leaseName,0);
   double owner=GlobalVariableGet(g_leaseName);
   if(owner!=0) return(false);
   int token=(int)GetTickCount();
   if(!GlobalVariableSetOnCondition(g_leaseName,token,0)) return(false);
   g_lease=true; return(true);
  }

void ReleaseLease()
  {
   if(g_lease && GlobalVariableCheck(g_leaseName)) GlobalVariableSet(g_leaseName,0);
   g_lease=false;
  }

bool IsLatched() { return(GlobalVariableCheck(GV_LATCH) && GlobalVariableGet(GV_LATCH)>0.5); }
void Latch(string why)
  {
   GlobalVariableSet(GV_LATCH,1); GlobalVariableSet(GV_LATCH_TIME,TimeCurrent());
   g_state=STATE_LATCHED; g_reason=why; Print("HOKKY risk latch: ",why);
  }
void TryReleaseLatch()
  {
   if(!IsLatched()) { g_state=STATE_RUNNING; return; }
   if(InpCooldownMinutes>0 && TimeCurrent()-(datetime)GlobalVariableGet(GV_LATCH_TIME)>=InpCooldownMinutes*60)
     {
      GlobalVariableDel(GV_LATCH); GlobalVariableDel(GV_LATCH_TIME); g_state=STATE_RUNNING; g_reason="cooldown released";
     }
  }

void RefreshPositions()
  {
   g_buyCount=0; g_sellCount=0; g_buyLots=0; g_sellLots=0; g_buyAvg=0; g_sellAvg=0; g_buyPL=0; g_sellPL=0;
   ArrayResize(g_buy,0); ArrayResize(g_sell,0);
   double bp=0,sp=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES) || OrderSymbol()!=Symbol() || OrderMagicNumber()!=g_magic) continue;
      int t=OrderType(); if(t!=OP_BUY && t!=OP_SELL) continue;
      PositionInfo p; p.ticket=OrderTicket(); p.type=t; p.lots=OrderLots(); p.openPrice=OrderOpenPrice(); p.sl=OrderStopLoss(); p.tp=OrderTakeProfit(); p.openTime=OrderOpenTime();
      double pl=OrderProfit()+OrderSwap()+OrderCommission();
      if(t==OP_BUY) { int n=ArraySize(g_buy); ArrayResize(g_buy,n+1); g_buy[n]=p; g_buyCount++; g_buyLots+=p.lots; bp+=p.openPrice*p.lots; g_buyPL+=pl; }
      else { int n=ArraySize(g_sell); ArrayResize(g_sell,n+1); g_sell[n]=p; g_sellCount++; g_sellLots+=p.lots; sp+=p.openPrice*p.lots; g_sellPL+=pl; }
     }
   if(g_buyLots>0) g_buyAvg=bp/g_buyLots;
   if(g_sellLots>0) g_sellAvg=sp/g_sellLots;
  }

double ClosedATR() { if(iBars(Symbol(),Period())<InpATRPeriod+2) return(0); return(iATR(Symbol(),Period(),InpATRPeriod,1)); }
double NetFloating() { return(g_buyPL+g_sellPL); }
void UpdatePeak()
  {
   double net=NetFloating();
   if(net>g_peakNet) { g_peakNet=net; GlobalVariableSet(GV_PEAK,g_peakNet); }
  }

bool RiskStopTriggered()
  {
   if(InpMinEquity>0 && AccountEquity()<=InpMinEquity) { StartClose("equity floor",true); return(true); }
   if(InpMinMarginLevel>0 && AccountMargin()>0 && AccountEquity()/AccountMargin()*100.0<=InpMinMarginLevel) { StartClose("margin level",true); return(true); }
   if(InpMaxBasketLossMoney>0 && g_buyCount+g_sellCount>0 && NetFloating()<=-InpMaxBasketLossMoney) { StartClose("basket money loss",true); return(true); }
   if(InpMaxDrawdownPct>0)
     {
      double base=MathMax(AccountBalance(),1.0);
      double dd=MathMax(0.0,-NetFloating()/base*100.0);
      if(dd>=InpMaxDrawdownPct) { StartClose("drawdown",true); return(true); }
     }
   return(false);
  }

bool CanTrade()
  {
   if(!InpAllowNewBasket && g_buyCount+g_sellCount==0) return(false);
   if(!InpAllowAddons && g_buyCount+g_sellCount>0) return(false);
   if(g_buyCount+g_sellCount>=InpMaxOrders) return(false);
   int h=TimeHour(TimeCurrent());
   bool hours=(InpStartHour==InpEndHour || (InpStartHour<InpEndHour ? (h>=InpStartHour && h<InpEndHour) : (h>=InpStartHour || h<InpEndHour)));
   if(!hours || (InpMaxSpreadPoints>0 && (Ask-Bid)/Point>InpMaxSpreadPoints)) return(false);
   if(TimeCurrent()-g_lastTradeAttempt<2) return(false);
   return(IsTradeAllowed() && !IsTradeContextBusy());
  }

bool TrendOK(int type)
  {
   if(!InpUseTrendFilter) return(true);
   double ma=iMA(Symbol(),InpTrendTF,InpTrendMAPeriod,0,InpTrendMethod,PRICE_CLOSE,1);
   double c=iClose(Symbol(),InpTrendTF,1);
   if(ma<=0 || c<=0) return(false);
   return(type==OP_BUY ? c>=ma : c<=ma);
  }

void ProcessEntries()
  {
   if(g_buyCount+g_sellCount==0)
     {
      double c2=iClose(Symbol(),Period(),2),c1=iClose(Symbol(),Period(),1);
      int type=(c2>0 && c1>c2 ? OP_BUY : OP_SELL);
      if(TrendOK(type)) OpenOrder(type,0);
      return;
     }
   double newest=0; int newestType=-1; datetime when=0;
   for(int i=0;i<g_buyCount;i++) if(g_buy[i].openTime>=when){when=g_buy[i].openTime;newest=g_buy[i].openPrice;newestType=OP_BUY;}
   for(int j=0;j<g_sellCount;j++) if(g_sell[j].openTime>=when){when=g_sell[j].openTime;newest=g_sell[j].openPrice;newestType=OP_SELL;}
   if(newestType<0) return;
   int next=InpHedgeMode ? (newestType==OP_BUY?OP_SELL:OP_BUY) : newestType;
   if(!InpAllowBothDirections && ((next==OP_BUY && g_sellCount>0)||(next==OP_SELL && g_buyCount>0))) return;
   bool moved=(next==OP_BUY ? Ask<=newest-g_atr*InpGridATR : Bid>=newest+g_atr*InpGridATR);
   if(moved && TrendOK(next)) OpenOrder(next,g_buyCount+g_sellCount);
  }

double NextLot(int level)
  {
   double lot=InpLots*MathPow(InpMultiplier,level);
   if(InpMaxLotPerOrder>0 && lot>InpMaxLotPerOrder) lot=InpMaxLotPerOrder;
   double step=MarketInfo(Symbol(),MODE_LOTSTEP); if(step<=0) step=0.01;
   lot=MathFloor(lot/step+1e-9)*step;
   return(NormalizeDouble(lot,2));
  }

bool ExposureOK(double lot,int type)
  {
   if(lot<=0) return(false);
   if(InpMaxTotalLots>0 && g_buyLots+g_sellLots+lot>InpMaxTotalLots+1e-9) return(false);
   if(AccountFreeMarginCheck(Symbol(),type,lot)<=0) return(false);
   return(true);
  }

void OpenOrder(int type,int level)
  {
   double lot=NextLot(level); if(!ExposureOK(lot,type)) return;
   RefreshRates(); double price=(type==OP_BUY?Ask:Bid),sl=0,tp=0;
   if(InpOrderHardSL_ATR>0) sl=(type==OP_BUY?price-g_atr*InpOrderHardSL_ATR:price+g_atr*InpOrderHardSL_ATR);
   if(InpOrderTP_ATR>0) tp=(type==OP_BUY?price+g_atr*InpOrderTP_ATR:price-g_atr*InpOrderTP_ATR);
   ConformStops(type,sl,tp);
   g_lastTradeAttempt=TimeCurrent(); ResetLastError();
   int ticket=OrderSend(Symbol(),type,lot,price,InpSlippagePoints,sl,tp,InpComment,g_magic,0,(type==OP_BUY?clrBlue:clrRed));
   if(ticket<0) { Print("OrderSend failed: ",GetLastError()); return; }
   Journal("OPEN",ticket,lot,price,sl,tp);
  }

void ManageExitsAndTrailing()
  {
   if(g_buyCount>0 && InpBasketTP_ATR>0 && Bid>=g_buyAvg+g_atr*InpBasketTP_ATR) { StartClose("buy basket TP",false); return; }
   if(g_sellCount>0 && InpBasketTP_ATR>0 && Ask<=g_sellAvg-g_atr*InpBasketTP_ATR) { StartClose("sell basket TP",false); return; }
   if(InpBasketSL_ATR>0)
     {
      if(g_buyCount>0 && Bid<=g_buyAvg-g_atr*InpBasketSL_ATR) { StartClose("buy basket SL",true); return; }
      if(g_sellCount>0 && Ask>=g_sellAvg+g_atr*InpBasketSL_ATR) { StartClose("sell basket SL",true); return; }
     }
   if(!InpUseTrailing) return;
   for(int i=0;i<g_buyCount;i++) Trail(g_buy[i]);
   for(int j=0;j<g_sellCount;j++) Trail(g_sell[j]);
  }

void Trail(PositionInfo &p)
  {
   double profit=(p.type==OP_BUY?Bid-p.openPrice:p.openPrice-Ask); if(profit<g_atr*InpTrailStartATR) return;
   double sl=(p.type==OP_BUY?Bid-g_atr*InpTrailDistanceATR:Ask+g_atr*InpTrailDistanceATR);
   if(p.type==OP_BUY && (p.sl<=0 || sl-p.sl>=InpTrailStepPoints*Point) && sl>p.openPrice) Modify(p.ticket,sl,p.tp);
   if(p.type==OP_SELL && (p.sl<=0 || p.sl-sl>=InpTrailStepPoints*Point) && sl<p.openPrice) Modify(p.ticket,sl,p.tp);
  }

void StartClose(string reason,bool latch)
  {
   g_reason=reason; g_closeSide=-1; g_state=STATE_CLOSE_ALL;
   if(latch) g_state=STATE_FAULT;
   Print("Close requested: ",reason);
  }
void DriveClose()
  {
   for(int i=OrdersTotal()-1;i>=0;i--)
     if(OrderSelect(i,SELECT_BY_POS,MODE_TRADES) && OrderSymbol()==Symbol() && OrderMagicNumber()==g_magic && (OrderType()==OP_BUY||OrderType()==OP_SELL))
       { RefreshRates(); double p=(OrderType()==OP_BUY?Bid:Ask); if(!OrderClose(OrderTicket(),OrderLots(),p,InpSlippagePoints,clrYellow)) Print("OrderClose failed: ",GetLastError()); return; }
   RefreshPositions();
   if(g_buyCount+g_sellCount==0)
     {
      bool fault=(g_state==STATE_FAULT); g_state=STATE_RUNNING;
      if(fault) Latch(g_reason);
     }
  }

bool Modify(int ticket,double sl,double tp)
  {
   if(!OrderSelect(ticket,SELECT_BY_TICKET) || OrderCloseTime()>0) return(false);
   ConformStops(OrderType(),sl,tp); ResetLastError();
   return(OrderModify(ticket,OrderOpenPrice(),sl,tp,0,clrNONE));
  }
void ConformStops(int type,double &sl,double &tp)
  {
   double minDist=MathMax(MarketInfo(Symbol(),MODE_STOPLEVEL),MarketInfo(Symbol(),MODE_FREEZELEVEL))*Point;
   RefreshRates();
   if(type==OP_BUY) { if(sl>0 && Bid-sl<minDist) sl=Bid-minDist; if(tp>0 && tp-Bid<minDist) tp=Bid+minDist; }
   else { if(sl>0 && sl-Ask<minDist) sl=Ask+minDist; if(tp>0 && Ask-tp<minDist) tp=Ask-minDist; }
   if(sl>0) sl=NormalizeDouble(sl,Digits); if(tp>0) tp=NormalizeDouble(tp,Digits);
  }

void DrawDashboard()
  { if(!InpDashboard) return; Comment("HOKKY V5.10 | ",Symbol()," | state=",g_state," | buy=",g_buyCount," sell=",g_sellCount," | ATR=",DoubleToString(g_atr,Digits)," | float=",DoubleToString(NetFloating(),2)," | ",g_reason); }
void Journal(string action,int ticket,double lot,double price,double sl,double tp)
  {
   if(!InpJournal) return;
   int h=FileOpen(InpJournalFile,FILE_CSV|FILE_READ|FILE_WRITE|FILE_SHARE_READ|FILE_SHARE_WRITE,';'); if(h==INVALID_HANDLE) return;
   FileSeek(h,0,SEEK_END); FileWrite(h,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),action,ticket,Symbol(),lot,price,sl,tp,AccountBalance(),AccountEquity()); FileClose(h);
  }
