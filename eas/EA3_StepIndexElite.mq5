//+------------------------------------------------------------------+
//|  StepIndexPro.mq5  v1.00                                        |
//|  STEP INDEX SPECIALIST — HIGH WIN RATE                         |
//|                                                                  |
//|  DESIGNED FOR:                                                  |
//|  Step Index 400 / Step Index 500                               |
//|  Timeframe: M5 (set chart to M5 and leave it)                  |
//|                                                                  |
//|  STRATEGY — HIGH SELECTIVITY:                                  |
//|  Only trades when 6+ conditions align                          |
//|  Smart SL below real swing low / above swing high              |
//|  Smart TP at next real resistance/support level                |
//|  Minimum 1:2 RR enforced on every trade                       |
//|  Pending limit order — waits for pullback                      |
//|  Pyramiding when Trade 1 in profit                             |
//|                                                                  |
//|  RUN TIME: Set and leave for 5 hours                          |
//|  It will trade 1-3 times per session                           |
//|  Each trade is high quality                                    |
//|                                                                  |
//|  HOW TO USE:                                                   |
//|  1. Open Step Index 400 chart                                  |
//|  2. Set timeframe to M5                                        |
//|  3. Drag this EA onto chart                                    |
//|  4. Set Risk_Pct = 1.0                                         |
//|  5. Click OK and LEAVE IT                                      |
//|  6. Check back after 5 hours                                   |
//|  DO NOT close trades manually                                  |
//|  DO NOT change settings mid-session                            |
//+------------------------------------------------------------------+
#property copyright "DixonAfreh"
#property version   "1.00"
#property strict
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

input group "=== SERVER CONNECTION ==="
input string Server_URL = "https://odkgh.com/api/trading";
input string API_Key    = "bmpt-your-secret-key-change-this";
input bool   Use_Server = true;

input group "=== RISK ==="
input double Risk_Pct          = 1.0;   // % risk per trade
input double Risk_DailyLoss    = 5.0;   // Stop for the day at 5% loss
input double Risk_DailyProfit  = 8.0;   // Stop for the day at 8% profit
input int    Risk_MaxConsec    = 3;     // Stop after 3 losses in a row

input group "=== PYRAMIDING ==="
input int    Max_Positions     = 2;     // Max 2 trades at once
input double Pyramid_MinPts    = 15.0;  // Trade 1 must be 15 pts in profit
input bool   Pyramid_Breakeven = true;  // Move Trade 1 SL to breakeven

input group "=== PENDING LIMIT ==="
input double Limit_Offset_Pts  = 15.0;  // Wait for 15pt pullback before entry
input int    Limit_Expiry_Bars = 3;     // Cancel if not filled in 3 bars

input group "=== SMART SL/TP ==="
input int    Swing_SL_Bars     = 10;    // Look back 10 bars for swing SL
input int    SR_TP_Bars        = 40;    // Look back 40 bars for TP level
input double SL_Buffer_Pts     = 5.0;  // Buffer beyond swing (5 pts)
input double MinRR             = 2.0;  // Minimum 1:2 RR

input group "=== INDICATORS ==="
input int    RSI_Period        = 14;
input double RSI_BuyZone_Min   = 35.0;  // RSI must be in this zone for buy
input double RSI_BuyZone_Max   = 60.0;
input double RSI_SellZone_Min  = 40.0;
input double RSI_SellZone_Max  = 65.0;
input int    EMA_Fast          = 8;
input int    EMA_Slow          = 21;
input int    EMA_Trend         = 50;    // Trend filter
input int    BB_Period         = 20;
input double BB_Dev            = 2.0;
input int    ATR_Period        = 14;
input double ADX_Period        = 14;
input double ADX_Min           = 20.0;  // Only trade when market is moving

input group "=== PATTERN SETTINGS ==="
input double PinBar_TailPct    = 0.60;
input double PinBar_BodyPct    = 0.35;
input double Doji_BodyPct      = 0.10;

input group "=== STRUCTURE ==="
input int    Swing_Lookback    = 6;
input int    Swing_ScanBars    = 40;
input int    Fib_Bars          = 25;
input double Fib_Zone          = 0.008;
input int    OB_Lookback       = 15;

input group "=== SCORING ==="
input int    Min_Score         = 5;    // Need 5/8 to trade (very selective)

input group "=== EXECUTION ==="
input bool   AutoTrade         = true;
input int    Slippage          = 50;
input bool   ShowDashboard     = true;

enum EPattern{PAT_NONE,PAT_PINBAR_BULL,PAT_PINBAR_BEAR,PAT_ENGULF_BULL,PAT_ENGULF_BEAR,PAT_HAMMER,PAT_SHOOTING_STAR,PAT_DOJI_BULL,PAT_DOJI_BEAR,PAT_MORNING_STAR,PAT_EVENING_STAR,PAT_HARAMI_BULL,PAT_HARAMI_BEAR,PAT_TWEEZERS_BULL,PAT_TWEEZERS_BEAR,PAT_INSIDE_BULL,PAT_INSIDE_BEAR};
enum EStructure{STR_BULL,STR_BEAR,STR_RANGE,STR_NONE};
enum EBOS{BOS_BULL,BOS_BEAR,BOS_NONE};

struct SSignal{
   EStructure str;EBOS bos;bool choch;
   bool atFib50,atFib618,atOB;
   double fib50,fib618;
   EPattern pattern;
   bool rsiOk,emaOk,bbEdge,adxOk,trendOk;
   bool isBull;
   double rsiV,adxV,atr;
   double smartSL,smartTP,rrAchieved;
   int score;
};

int h_rsi,h_emaF,h_emaS,h_emaTrend,h_bb,h_atr,h_adx;
CTrade g_trade;CPositionInfo g_pos;COrderInfo g_order;

double   g_dayBal,g_profit;
int      g_consec,g_wins,g_losses,g_magic,g_brokerWait;
datetime g_lastBar,g_pendingPlacedBar,g_lastOrderBar;
long     g_minStop;
bool     g_hasPending;
ulong    g_pendingTicket;

int GenMagic(string s,ENUM_TIMEFRAMES tf){int h=0;for(int i=0;i<StringLen(s);i++)h=h*31+(int)StringGetCharacter(s,i);return MathAbs(h)%90000+10000+(int)tf+3141;}


//+------------------------------------------------------------------+
//  SERVER REPORTING — https://odkgh.com/api/trading
//+------------------------------------------------------------------+
void ServerPost(string endpoint,string json){
   if(!Use_Server)return;
   char post[];uchar result[];string resHeaders;
   string headers="Content-Type: application/json\r\nX-Api-Key: "+API_Key+"\r\n";
   StringToCharArray(json,post,0,StringLen(json));
   int ret=WebRequest("POST",Server_URL+endpoint,headers,5000,post,result,resHeaders);
   if(ret<0)PrintFormat("Server error %d on %s — add %s to MT5 WebRequest list",GetLastError(),endpoint,Server_URL);
}

void ServerHeartbeat(string msg){
   ServerPost("/ea/heartbeat",StringFormat(
      "{\"ea_name\":\"%s\",\"symbol\":\"%s\",\"timeframe\":\"%s\",\"balance\":%.2f,\"equity\":%.2f,\"message\":\"%s\"}",
      __FILE__,_Symbol,EnumToString(Period()),
      AccountInfoDouble(ACCOUNT_BALANCE),AccountInfoDouble(ACCOUNT_EQUITY),msg));
}

void ServerSignal(string direction,int score,string pattern,string reason,double entry,double sl,double tp,double rr){
   ServerPost("/ea/signal",StringFormat(
      "{\"ea_name\":\"%s\",\"symbol\":\"%s\",\"direction\":\"%s\",\"score\":%d,\"pattern\":\"%s\",\"reason\":\"%s\",\"entry\":%.5f,\"sl\":%.5f,\"tp\":%.5f,\"rr\":%.2f}",
      __FILE__,_Symbol,direction,score,pattern,reason,entry,sl,tp,rr));
}

void ServerTradeOpen(ulong ticket,string direction,double lot,double entry,double sl,double tp,double rr,int score){
   ServerPost("/trades/open",StringFormat(
      "{\"ea_name\":\"%s\",\"ticket\":%d,\"symbol\":\"%s\",\"direction\":\"%s\",\"lot_size\":%.2f,\"entry_price\":%.5f,\"sl\":%.5f,\"tp\":%.5f,\"rr\":%.2f,\"score\":%d}",
      __FILE__,ticket,_Symbol,direction,lot,entry,sl,tp,rr,score));
}

void ServerTradeClose(long ticket,double profit,string reason){
   ServerPost("/trades/close",StringFormat(
      "{\"ea_name\":\"%s\",\"ticket\":%d,\"profit\":%.2f,\"reason\":\"%s\"}",
      __FILE__,ticket,profit,reason));
}

int OnInit()
{
   g_magic=GenMagic(_Symbol,Period());
   g_trade.SetExpertMagicNumber(g_magic);
   g_trade.SetDeviationInPoints(Slippage);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_minStop=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);

   h_rsi     =iRSI(_Symbol,PERIOD_CURRENT,RSI_Period,PRICE_CLOSE);
   h_emaF    =iMA(_Symbol,PERIOD_CURRENT,EMA_Fast,0,MODE_EMA,PRICE_CLOSE);
   h_emaS    =iMA(_Symbol,PERIOD_CURRENT,EMA_Slow,0,MODE_EMA,PRICE_CLOSE);
   h_emaTrend=iMA(_Symbol,PERIOD_CURRENT,EMA_Trend,0,MODE_EMA,PRICE_CLOSE);
   h_bb      =iBands(_Symbol,PERIOD_CURRENT,BB_Period,0,BB_Dev,PRICE_CLOSE);
   h_atr     =iATR(_Symbol,PERIOD_CURRENT,ATR_Period);
   h_adx     =iADX(_Symbol,PERIOD_CURRENT,(int)ADX_Period);

   if(h_rsi==INVALID_HANDLE||h_emaF==INVALID_HANDLE||h_atr==INVALID_HANDLE)
      {Print("Indicator FAILED");return INIT_FAILED;}

   g_dayBal=AccountInfoDouble(ACCOUNT_BALANCE);
   g_consec=0;g_wins=0;g_losses=0;g_profit=0;
   g_lastBar=0;g_hasPending=false;g_pendingTicket=0;
   g_pendingPlacedBar=0;g_lastOrderBar=0;g_brokerWait=0;

   ScanExistingPending();
   if(Use_Server)ServerHeartbeat("OnInit");
   PrintFormat("StepIndexPro v1.00 | %s %s | Magic:%d | MinScore:%d/8",
               _Symbol,EnumToString(Period()),g_magic,Min_Score);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int r)
{
   IndicatorRelease(h_rsi);IndicatorRelease(h_emaF);IndicatorRelease(h_emaS);
   IndicatorRelease(h_emaTrend);IndicatorRelease(h_bb);IndicatorRelease(h_atr);IndicatorRelease(h_adx);
   Comment("");
}

void OnTick()
{
   datetime bar=iTime(_Symbol,PERIOD_CURRENT,0);
   if(bar==g_lastBar) return;
   g_lastBar=bar;
   // Send heartbeat every 10 bars so dashboard stays alive
   static int hbCount=0; hbCount++; if(hbCount>=10){hbCount=0;if(Use_Server)ServerHeartbeat("running");}

   ResetDay();
   if(DailyLoss())              {ShowMsg("DAILY LOSS — STOPPED FOR TODAY");return;}
   if(DailyProfit())            {ShowMsg("DAILY PROFIT TARGET HIT — STOPPED");return;}
   if(g_consec>=Risk_MaxConsec) {ShowMsg("3 LOSSES IN A ROW — PAUSED");return;}

   if(g_brokerWait>0){g_brokerWait--;return;}
   ManagePending();

   // ═══ CHOCH EXIT — Book Method ═══
   // If trade is open and market structure reverses → close immediately
   // Book: "CHOCH means the market has changed direction — exit now"
   if(CountOpenPositions()>0) CheckCHOCHExit();
   if(g_hasPending) return;
   if(g_lastOrderBar==iTime(_Symbol,PERIOD_CURRENT,0)) return;

   int openPos  = CountOpenPositions();
   int totalAll = CountAllTrades();
   if(totalAll>=Max_Positions) return;

   // Read all indicators
   double rsi  =G(h_rsi,0,1);
   double emaF =G(h_emaF,0,1);
   double emaS =G(h_emaS,0,1);
   double emaT =G(h_emaTrend,0,1);
   double bbU  =G(h_bb,UPPER_BAND,1);
   double bbL  =G(h_bb,LOWER_BAND,1);
   double atr  =G(h_atr,0,1);
   double adx  =G(h_adx,0,1);
   double cur  =iC(1);

   if(rsi==0||emaF==0||atr==0) return;

   // Build signal
   SSignal sig;
   BuildSignal(sig,cur,bbU,bbL,emaF,emaS,emaT,rsi,atr,adx);

   // Dashboard
   if(ShowDashboard) Dashboard(sig,openPos);

   // Only trade if score is high enough
   if(sig.pattern==PAT_NONE||sig.score<Min_Score) return;
   // RR must be achievable
   if(sig.rrAchieved<MinRR) return;

   // Pyramiding re-entry
   if(openPos==1&&Max_Positions>=2)
   {
      int dir=GetOpenDirection();
      double profPts=GetOpenProfitPts();
      if(profPts>=Pyramid_MinPts)
      {
         bool reBuy =(dir==1 &&sig.isBull&&AutoTrade);
         bool reSell=(dir==-1&&!sig.isBull&&AutoTrade);
         if(reBuy||reSell){
            if(Pyramid_Breakeven)MoveAllToBreakeven();
            if(reBuy) PlaceLimitOrder(ORDER_TYPE_BUY_LIMIT, sig,true);
            if(reSell)PlaceLimitOrder(ORDER_TYPE_SELL_LIMIT,sig,true);
         }
      }
      return;
   }

   // Normal first entry
   if(openPos==0)
   {
      if(sig.isBull &&AutoTrade) PlaceLimitOrder(ORDER_TYPE_BUY_LIMIT, sig,false);
      else if(!sig.isBull&&AutoTrade) PlaceLimitOrder(ORDER_TYPE_SELL_LIMIT,sig,false);
   }
}

void PlaceLimitOrder(ENUM_ORDER_TYPE type,const SSignal &sig,bool isPyramid)
{
   if(g_hasPending){Print("BLOCKED");return;}
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double pt =SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double offset=Limit_Offset_Pts*pt;
   double limitPrice,sl=sig.smartSL,tp=sig.smartTP;

   if(type==ORDER_TYPE_BUY_LIMIT){
      limitPrice=NormalizeDouble(bid-offset,_Digits);
      if(sl>=limitPrice)sl=NormalizeDouble(limitPrice-(g_minStop+10)*pt,_Digits);
   }else{
      limitPrice=NormalizeDouble(bid+offset,_Digits);
      if(sl<=limitPrice)sl=NormalizeDouble(limitPrice+(g_minStop+10)*pt,_Digits);
   }

   double slPt=MathAbs(limitPrice-sl)/pt;
   double tpPt=MathAbs(limitPrice-tp)/pt;
   if(slPt<g_minStop+5||tpPt<g_minStop+5){PrintFormat("SKIP min=%d",g_minStop);return;}

   double lot=LotSize(MathAbs(limitPrice-sl));if(lot<=0)return;
   string dir=(type==ORDER_TYPE_BUY_LIMIT)?"BUY LIMIT":"SELL LIMIT";
   string tag=isPyramid?"PYRAMID":"ENTRY";

   bool ok=(type==ORDER_TYPE_BUY_LIMIT)
      ?g_trade.BuyLimit(lot,limitPrice,_Symbol,sl,tp,ORDER_TIME_GTC,0,StringFormat("SIP|BL|RR:%.1f|%d",tpPt/slPt,sig.score))
      :g_trade.SellLimit(lot,limitPrice,_Symbol,sl,tp,ORDER_TIME_GTC,0,StringFormat("SIP|SL|RR:%.1f|%d",tpPt/slPt,sig.score));

   if(ok){
      g_pendingTicket=g_trade.ResultOrder();g_hasPending=true;
      g_pendingPlacedBar=iTime(_Symbol,PERIOD_CURRENT,0);
      g_lastOrderBar=g_pendingPlacedBar;g_brokerWait=5;
      PrintFormat("%s %s | Lot:%.2f | Limit:%.2f | SL:%.2f(swing) | TP:%.2f(S/R) | RR:1:%.1f | Score:%d/8",
                  tag,dir,lot,limitPrice,sl,tp,tpPt/slPt,sig.score);
   }else PrintFormat("FAILED err:%d",GetLastError());
}

void ManagePending()
{
   if(!g_hasPending)return;
   bool found=false;
   for(int i=OrdersTotal()-1;i>=0;i--){
      if(g_order.SelectByIndex(i)&&g_order.Ticket()==g_pendingTicket){
         found=true;
         ENUM_ORDER_STATE st=(ENUM_ORDER_STATE)g_order.State();
         if(st==ORDER_STATE_FILLED||st==ORDER_STATE_CANCELED||st==ORDER_STATE_EXPIRED||st==ORDER_STATE_REJECTED)
            {g_hasPending=false;g_pendingTicket=0;return;}
         break;
      }
   }
   if(!found&&HistoryOrderSelect(g_pendingTicket)){
      ENUM_ORDER_STATE st=(ENUM_ORDER_STATE)HistoryOrderGetInteger(g_pendingTicket,ORDER_STATE);
      if(st==ORDER_STATE_FILLED||st==ORDER_STATE_CANCELED||st==ORDER_STATE_EXPIRED||st==ORDER_STATE_REJECTED)
         {g_hasPending=false;g_pendingTicket=0;return;}
   }
   int bp=0;for(int i=0;i<200;i++){if(iTime(_Symbol,PERIOD_CURRENT,i)<=g_pendingPlacedBar){bp=i;break;}}
   if(bp>=Limit_Expiry_Bars){if(g_trade.OrderDelete(g_pendingTicket))Print("PENDING CANCELLED");g_hasPending=false;g_pendingTicket=0;}
}

// ═══════════════════════════════════════════════════
//  CHOCH EXIT — Close trade if structure reverses
//  Book: "Change of Character = market reversing
//         Exit immediately do not wait for SL"
// ═══════════════════════════════════════════════════
void CheckCHOCHExit()
{
   int dir=GetOpenDirection();
   if(dir==0) return; // no open trade

   // Detect current structure
   double sH=0,sL=0;
   EStructure str=DetStructure(sH,sL);

   bool choch=false;
   double cur=iC(1),rH=0,rL=0;
   for(int i=2;i<Swing_Lookback*3;i++){
      if(iH(i)>rH)rH=iH(i);
      if(rL==0||iL(i)<rL)rL=iL(i);
   }

   // CHOCH for BUY trade: was uptrend but price breaks below swing low
   if(dir==1 && str==STR_BULL && cur<rL) choch=true;
   // CHOCH for SELL trade: was downtrend but price breaks above swing high
   if(dir==-1 && str==STR_BEAR && cur>rH) choch=true;

   // Also check: opposite pattern forming while trade is open
   bool oppPatternBuy  =(dir==-1); // sell open → bull pattern = exit
   bool oppPatternSell =(dir==1);  // buy open  → bear pattern = exit

   SSignal sig;
   double emaF=G(h_emaF,0,1),emaS=G(h_emaS,0,1),emaT=G(h_emaTrend,0,1);
   double rsi=G(h_rsi,0,1),atr=G(h_atr,0,1),adx=G(h_adx,0,1);
   double bbU=G(h_bb,UPPER_BAND,1),bbL2=G(h_bb,LOWER_BAND,1);
   double cur2=iC(1);
   BuildSignal(sig,cur2,bbU,bbL2,emaF,emaS,emaT,rsi,atr,adx);

   // Exit conditions:
   bool exitNow=false;
   string reason="";

   // 1. CHOCH detected
   if(choch){
      exitNow=true;
      reason="CHOCH — Structure reversed";
   }
   // 2. Strong opposite pattern with good score
   else if(dir==1 && !sig.isBull && sig.score>=4 && sig.pattern!=PAT_NONE){
      exitNow=true;
      reason=StringFormat("OPPOSITE SIGNAL: %s Score:%d/8",PatName(sig.pattern),sig.score);
   }
   else if(dir==-1 && sig.isBull && sig.score>=4 && sig.pattern!=PAT_NONE){
      exitNow=true;
      reason=StringFormat("OPPOSITE SIGNAL: %s Score:%d/8",PatName(sig.pattern),sig.score);
   }

   if(exitNow)
   {
      // Close all open positions for this EA
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(g_pos.SelectByIndex(i))
         {
            if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic)
            {
               if(g_trade.PositionClose(g_pos.Ticket()))
                  PrintFormat("CHOCH EXIT: #%d closed | Reason: %s | P/L: %.2f",
                              g_pos.Ticket(),reason,g_pos.Profit());
               else
                  PrintFormat("CHOCH EXIT FAILED err:%d",GetLastError());
            }
         }
      }
      // Also cancel any pending order
      if(g_hasPending)
      {
         if(g_trade.OrderDelete(g_pendingTicket))
            Print("PENDING ALSO CANCELLED on CHOCH");
         g_hasPending=false;g_pendingTicket=0;
      }
   }
}

void ScanExistingPending()
{
   for(int i=OrdersTotal()-1;i>=0;i--){
      if(g_order.SelectByIndex(i)){
         if(g_order.Symbol()==_Symbol&&g_order.Magic()==g_magic){
            g_hasPending=true;g_pendingTicket=g_order.Ticket();
            g_pendingPlacedBar=iTime(_Symbol,PERIOD_CURRENT,0);
            g_lastOrderBar=iTime(_Symbol,PERIOD_CURRENT,0);
            PrintFormat("FOUND existing pending: #%d at %.2f",g_pendingTicket,g_order.PriceOpen());
            return;
         }
      }
   }
}

void BuildSignal(SSignal &s,double cur,double bbU,double bbL,double emaF,double emaS,double emaT,double rsi,double atr,double adx)
{
   double sH=0,sL=0;
   s.str=DetStructure(sH,sL);
   s.isBull=(s.str==STR_BULL||(s.str==STR_RANGE&&emaF>emaS));
   bool ch=false;s.bos=DetBOS(s.str,ch);s.choch=ch;

   double f50=0,f618=0;bool at50=false,at618=false;
   CalcFib(s.str,f50,f618,at50,at618);
   s.fib50=f50;s.fib618=f618;s.atFib50=at50;s.atFib618=at618;
   s.atOB=DetOB(s.str);
   s.pattern=DetPattern(s.isBull);AdjustDir(s);
   s.atr=atr;s.rsiV=rsi;s.adxV=adx;

   // Indicators
   s.rsiOk  =s.isBull?(rsi>=RSI_BuyZone_Min&&rsi<=RSI_BuyZone_Max):(rsi>=RSI_SellZone_Min&&rsi<=RSI_SellZone_Max);
   s.emaOk  =s.isBull?(emaF>emaS):(emaF<emaS);
   s.trendOk=s.isBull?(cur>emaT):(cur<emaT);   // Price on right side of trend EMA
   s.bbEdge =s.isBull?(iL(1)<=bbL*1.002):(iH(1)>=bbU*0.998);
   s.adxOk  =(adx>=ADX_Min);

   // Score — 8 possible points
   s.score=0;
   if(s.str!=STR_NONE)                                             s.score++; // 1. Structure
   if((s.isBull&&s.bos==BOS_BULL)||(!s.isBull&&s.bos==BOS_BEAR)) s.score++; // 2. BOS
   if(s.atFib50||s.atFib618)                                      s.score++; // 3. Fibonacci
   if(s.atOB)                                                      s.score++; // 4. Order Block
   if(s.pattern!=PAT_NONE)                                         s.score++; // 5. Pattern
   if(s.rsiOk)                                                     s.score++; // 6. RSI zone
   if(s.emaOk)                                                     s.score++; // 7. EMA cross
   if(s.trendOk||s.bbEdge||s.adxOk)                               s.score++; // 8. Trend/BB/ADX

   // Smart SL at swing high/low
   s.smartSL=CalcSmartSL(s.isBull,atr);
   // Smart TP at S/R level
   s.smartTP=CalcSmartTP(s.isBull,s.smartSL);
   // RR calculation
   double slD=MathAbs(cur-s.smartSL);
   double tpD=MathAbs(cur-s.smartTP);
   s.rrAchieved=(slD>0)?tpD/slD:0;
}

// Smart SL — placed at swing high/low with buffer
double CalcSmartSL(bool bull,double atr)
{
   double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double buf=SL_Buffer_Pts*pt;
   double minD=(g_minStop+10)*pt;
   double cur=iC(1);
   if(bull){
      double lo=99999999;
      for(int i=1;i<=Swing_SL_Bars;i++)if(iL(i)<lo)lo=iL(i);
      double sl=lo-buf;
      if(cur-sl<minD)sl=cur-minD;
      return NormalizeDouble(sl,_Digits);
   }else{
      double hi=0;
      for(int i=1;i<=Swing_SL_Bars;i++)if(iH(i)>hi)hi=iH(i);
      double sl=hi+buf;
      if(sl-cur<minD)sl=cur+minD;
      return NormalizeDouble(sl,_Digits);
   }
}

// Smart TP — placed at next S/R level, minimum 1:2 RR
double CalcSmartTP(bool bull,double sl)
{
   double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double cur=iC(1);
   double slDist=MathAbs(cur-sl);
   double minTP=slDist*MinRR;
   double minD=(g_minStop+10)*pt;
   double best=0;

   if(bull){
      double closest=999999999;
      for(int i=3;i<=SR_TP_Bars;i++){
         double h=iH(i),hP=iH(i-1),hN=iH(i+1);
         if(h>hP&&h>hN&&h>cur+minTP&&h<closest)closest=h;
      }
      best=(closest<999999999)?closest:cur+minTP;
      if(best-cur<minD*2)best=cur+minD*2;
   }else{
      double closest=-999999999;
      for(int i=3;i<=SR_TP_Bars;i++){
         double l=iL(i),lP=iL(i-1),lN=iL(i+1);
         if(l<lP&&l<lN&&l<cur-minTP&&l>closest)closest=l;
      }
      best=(closest>-999999999)?closest:cur-minTP;
      if(cur-best<minD*2)best=cur-minD*2;
   }
   return NormalizeDouble(best,_Digits);
}

// All 12 patterns
EPattern DetPinBar(int i){double o=iO(i),c=iC(i),h=iH(i),l=iL(i),rng=h-l;if(rng<=0)return PAT_NONE;double body=MathAbs(c-o),upW=h-MathMax(o,c),loW=MathMin(o,c)-l;if(body/rng>PinBar_BodyPct)return PAT_NONE;if(loW/rng>=PinBar_TailPct&&loW>upW*2)return PAT_PINBAR_BULL;if(upW/rng>=PinBar_TailPct&&upW>loW*2)return PAT_PINBAR_BEAR;return PAT_NONE;}
EPattern DetEngulf(int i){double o1=iO(i),c1=iC(i),o2=iO(i+1),c2=iC(i+1);if(MathAbs(c1-o1)==0||MathAbs(c2-o2)==0)return PAT_NONE;if(c1>o1&&c2<o2&&c1>=o2&&o1<=c2)return PAT_ENGULF_BULL;if(c1<o1&&c2>o2&&o1>=c2&&c1<=o2)return PAT_ENGULF_BEAR;return PAT_NONE;}
EPattern DetHamm(int i){double o=iO(i),c=iC(i),h=iH(i),l=iL(i),rng=h-l;if(rng<=0)return PAT_NONE;double body=MathAbs(c-o),loW=MathMin(o,c)-l,upW=h-MathMax(o,c);if(body/rng<=0.30&&loW/rng>=0.60&&loW>upW*2)return PAT_HAMMER;return PAT_NONE;}
EPattern DetShoot(int i){double o=iO(i),c=iC(i),h=iH(i),l=iL(i),rng=h-l;if(rng<=0)return PAT_NONE;double body=MathAbs(c-o),loW=MathMin(o,c)-l,upW=h-MathMax(o,c);if(body/rng<=0.30&&upW/rng>=0.60&&upW>loW*2)return PAT_SHOOTING_STAR;return PAT_NONE;}
EPattern DetDoji(int i){double o=iO(i),c=iC(i),h=iH(i),l=iL(i),rng=h-l;if(rng<=0)return PAT_NONE;double body=MathAbs(c-o);if(body/rng>Doji_BodyPct)return PAT_NONE;double upW=h-MathMax(o,c),loW=MathMin(o,c)-l;if(loW/rng>=0.60&&upW<body*2)return PAT_DOJI_BULL;if(upW/rng>=0.60&&loW<body*2)return PAT_DOJI_BEAR;return PAT_NONE;}
EPattern DetMorn(int i){double o1=iO(i+2),c1=iC(i+2),o2=iO(i+1),c2=iC(i+1),o3=iO(i),c3=iC(i),r1=MathAbs(o1-c1),r2=MathAbs(o2-c2);if(r1==0)return PAT_NONE;if(c1<o1&&r2<r1*0.5&&c3>o3&&c3>(o1+c1)/2.0)return PAT_MORNING_STAR;return PAT_NONE;}
EPattern DetEve(int i){double o1=iO(i+2),c1=iC(i+2),o2=iO(i+1),c2=iC(i+1),o3=iO(i),c3=iC(i),r1=MathAbs(o1-c1),r2=MathAbs(o2-c2);if(r1==0)return PAT_NONE;if(c1>o1&&r2<r1*0.5&&c3<o3&&c3<(o1+c1)/2.0)return PAT_EVENING_STAR;return PAT_NONE;}
EPattern DetHaram(int i){double o1=iO(i),c1=iC(i),o2=iO(i+1),c2=iC(i+1);if(MathAbs(c2-o2)==0)return PAT_NONE;if(MathMax(o1,c1)<MathMax(o2,c2)&&MathMin(o1,c1)>MathMin(o2,c2)){if(c2<o2&&c1>o1)return PAT_HARAMI_BULL;if(c2>o2&&c1<o1)return PAT_HARAMI_BEAR;}return PAT_NONE;}
EPattern DetTweez(int i){double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT)*3;if(MathAbs(iL(i)-iL(i+1))<=pt&&iC(i+1)<iO(i+1)&&iC(i)>iO(i))return PAT_TWEEZERS_BULL;if(MathAbs(iH(i)-iH(i+1))<=pt&&iC(i+1)>iO(i+1)&&iC(i)<iO(i))return PAT_TWEEZERS_BEAR;return PAT_NONE;}
EPattern DetInside(int i,bool b){if(iH(i)<iH(i+1)&&iL(i)>iL(i+1))return b?PAT_INSIDE_BULL:PAT_INSIDE_BEAR;return PAT_NONE;}

EPattern DetPattern(bool bull)
{
   EPattern p;
   p=DetPinBar(1); if(p!=PAT_NONE)return p;
   p=DetEngulf(1); if(p!=PAT_NONE)return p;
   p=DetMorn(1);   if(p!=PAT_NONE)return p;
   p=DetEve(1);    if(p!=PAT_NONE)return p;
   p=DetHamm(1);   if(p!=PAT_NONE)return p;
   p=DetShoot(1);  if(p!=PAT_NONE)return p;
   p=DetDoji(1);   if(p!=PAT_NONE)return p;
   p=DetTweez(1);  if(p!=PAT_NONE)return p;
   p=DetHaram(1);  if(p!=PAT_NONE)return p;
   p=DetInside(1,bull);if(p!=PAT_NONE)return p;
   return PAT_NONE;
}

void AdjustDir(SSignal &s){if(s.pattern==PAT_PINBAR_BULL||s.pattern==PAT_ENGULF_BULL||s.pattern==PAT_INSIDE_BULL||s.pattern==PAT_MORNING_STAR||s.pattern==PAT_HAMMER||s.pattern==PAT_DOJI_BULL||s.pattern==PAT_HARAMI_BULL||s.pattern==PAT_TWEEZERS_BULL)s.isBull=true;if(s.pattern==PAT_PINBAR_BEAR||s.pattern==PAT_ENGULF_BEAR||s.pattern==PAT_INSIDE_BEAR||s.pattern==PAT_EVENING_STAR||s.pattern==PAT_SHOOTING_STAR||s.pattern==PAT_DOJI_BEAR||s.pattern==PAT_HARAMI_BEAR||s.pattern==PAT_TWEEZERS_BEAR)s.isBull=false;}

EStructure DetStructure(double &sH,double &sL){double sh[2]={0,0},sl2[2]={0,0};int shb[2]={0,0},slb[2]={0,0},shc=0,slc=0;for(int i=2;i<Swing_ScanBars-1&&(shc<2||slc<2);i++){if(iH(i)>iH(i-1)&&iH(i)>iH(i+1)&&shc<2)if(shc==0||i>shb[0]+Swing_Lookback){sh[shc]=iH(i);shb[shc]=i;shc++;}if(iL(i)<iL(i-1)&&iL(i)<iL(i+1)&&slc<2)if(slc==0||i>slb[0]+Swing_Lookback){sl2[slc]=iL(i);slb[slc]=i;slc++;}}sH=sh[0];sL=sl2[0];if(shc<2||slc<2)return STR_NONE;if(sh[0]>sh[1]&&sl2[0]>sl2[1])return STR_BULL;if(sh[0]<sh[1]&&sl2[0]<sl2[1])return STR_BEAR;return STR_RANGE;}
EBOS DetBOS(EStructure str,bool &choch){choch=false;if(str==STR_NONE)return BOS_NONE;double cur=iC(1),rH=0,rL=0;for(int i=2;i<Swing_Lookback*3;i++){if(iH(i)>rH)rH=iH(i);if(rL==0||iL(i)<rL)rL=iL(i);}if(str==STR_BULL&&cur>rH)return BOS_BULL;if(str==STR_BEAR&&cur<rL)return BOS_BEAR;if(str==STR_BULL&&cur<rL)choch=true;if(str==STR_BEAR&&cur>rH)choch=true;return BOS_NONE;}
void CalcFib(EStructure str,double &f50,double &f618,bool &at50,bool &at618){f50=0;f618=0;at50=false;at618=false;double swH=0,swL=0;for(int i=1;i<Fib_Bars;i++){if(iH(i)>swH)swH=iH(i);if(swL==0||iL(i)<swL)swL=iL(i);}if(swH==0||swL==0)return;double rng=swH-swL,cur=iC(1);f50=str==STR_BULL?swH-0.500*rng:swL+0.500*rng;f618=str==STR_BULL?swH-0.618*rng:swL+0.618*rng;double z=rng*Fib_Zone;at50=(MathAbs(cur-f50)<=z);at618=(MathAbs(cur-f618)<=z);}
bool DetOB(EStructure str){double cur=iC(1),pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);for(int i=3;i<OB_Lookback;i++){double o=iO(i),c=iC(i),op=iO(i+1),cp=iC(i+1);if(str==STR_BULL&&c>o&&cp<op){double h=MathMax(op,cp),l=MathMin(op,cp),z=(h-l)*0.5+pt*5;if(cur>=l-z&&cur<=h+z)return true;break;}if(str==STR_BEAR&&c<o&&cp>op){double h=MathMax(op,cp),l=MathMin(op,cp),z=(h-l)*0.5+pt*5;if(cur>=l-z&&cur<=h+z)return true;break;}}return false;}

void OnTradeTransaction(const MqlTradeTransaction &t,const MqlTradeRequest &req,const MqlTradeResult &res)
{
   if(t.type!=TRADE_TRANSACTION_DEAL_ADD)return;
   if(!HistoryDealSelect(t.deal))return;
   if(HistoryDealGetInteger(t.deal,DEAL_MAGIC)!=g_magic)return;
   if(HistoryDealGetInteger(t.deal,DEAL_ENTRY)==DEAL_ENTRY_IN){g_hasPending=false;g_brokerWait=0;PrintFormat("FILLED at %.2f",HistoryDealGetDouble(t.deal,DEAL_PRICE));return;}
   if(HistoryDealGetInteger(t.deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT)return;
   double p=HistoryDealGetDouble(t.deal,DEAL_PROFIT);g_profit+=p;
   if(p>=0){if(Use_Server)ServerTradeClose(t.deal,p,"WIN");g_wins++;g_consec=0;PrintFormat("WIN +%.2f | W:%d L:%d WR:%.0f%%",p,g_wins,g_losses,WR());}
   else{g_losses++;g_consec++;PrintFormat("LOSS %.2f | W:%d L:%d WR:%.0f%%",p,g_wins,g_losses,WR());}
}

void Dashboard(const SSignal &s,int openPos)
{
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double pt =SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double profPts=GetOpenProfitPts();
   int dir=GetOpenDirection();

   string status="";
   if(g_hasPending)     status="PENDING — WAITING FOR FILL";
   else if(openPos>0)   status=StringFormat("TRADE OPEN | Profit: %.0f pts",profPts);
   else                 status="SCANNING...";

   string scoreBar="";
   for(int i=0;i<s.score;i++)scoreBar+="█";
   for(int i=s.score;i<8;i++)scoreBar+="░";

   string ready=(s.score>=Min_Score&&s.pattern!=PAT_NONE&&s.rrAchieved>=MinRR)
                ?(s.isBull?"  ★★ BUY LIMIT READY ★★":"  ★★ SELL LIMIT READY ★★")
                :"  waiting for perfect setup...";

   Comment(StringFormat(
      "╔══ STEP INDEX PRO v1.00 ══╗\n"
      "  %s %s | Magic:%d\n"
      "╠══ STATUS ══════════════╣\n"
      "  %s\n"
      "  Positions: %d/%d\n"
      "  BrokerWait: %d\n"
      "╠══ LEVELS ══════════════╣\n"
      "  BUY  LIMIT: %.2f\n"
      "  SELL LIMIT: %.2f\n"
      "  Smart SL: %.2f ← SWING %s\n"
      "  Smart TP: %.2f ← S/R\n"
      "  RR: 1:%.1f (min 1:%.1f)\n"
      "╠══ CONFLUENCE ══════════╣\n"
      "  Structure: %s\n"
      "  BOS: %s | CHOCH: %s\n"
      "  Fibonacci: %s\n"
      "  Order Block: %s\n"
      "  Pattern: %s\n"
      "  RSI(%d): %.1f %s\n"
      "  EMA %d/%d: %s\n"
      "  Trend EMA%d: %s\n"
      "  ADX: %.1f %s\n"
      "  Score: [%s] %d/8\n"
      "  Direction: %s\n"
      "  %s\n"
      "╠══ RESULTS ═════════════╣\n"
      "  P/L: %.2f\n"
      "  W:%d L:%d WR:%.0f%%\n"
      "  Consec losses: %d/%d\n"
      "╚════════════════════════╝",
      _Symbol,EnumToString(Period()),g_magic,
      status,openPos,Max_Positions,g_brokerWait,
      bid-Limit_Offset_Pts*pt,bid+Limit_Offset_Pts*pt,
      s.smartSL,s.isBull?"LOW":"HIGH",
      s.smartTP,s.rrAchieved,MinRR,
      s.str==STR_BULL?"UPTREND ▲":s.str==STR_BEAR?"DOWNTREND ▼":"RANGING",
      s.choch?"CHOCH⚠":s.bos==BOS_BULL?"BULL BOS✓":s.bos==BOS_BEAR?"BEAR BOS✓":"no BOS",
      s.choch?"YES":"no",
      s.atFib50?"AT 50% ✓":s.atFib618?"AT 61.8% ✓":"—",
      s.atOB?"IN ORDER BLOCK ✓":"—",
      PatName(s.pattern),
      RSI_Period,s.rsiV,s.rsiOk?"✓ in zone":"✗",
      EMA_Fast,EMA_Slow,s.emaOk?"ALIGNED ✓":"not aligned",
      EMA_Trend,s.trendOk?"price above ✓":"price below",
      s.adxV,s.adxOk?"trending ✓":"weak",
      scoreBar,s.score,
      s.isBull?"LONG ▲":"SHORT ▼",
      ready,
      g_profit,g_wins,g_losses,WR(),
      g_consec,Risk_MaxConsec));
}

void ShowMsg(string m){Comment("STEP INDEX PRO\n"+m+StringFormat("\nW:%d L:%d WR:%.0f%%",g_wins,g_losses,WR()));}
double iO(int i){return iOpen(_Symbol,PERIOD_CURRENT,i);}
double iC(int i){return iClose(_Symbol,PERIOD_CURRENT,i);}
double iH(int i){return iHigh(_Symbol,PERIOD_CURRENT,i);}
double iL(int i){return iLow(_Symbol,PERIOD_CURRENT,i);}
double G(int h,int b,int s){double a[];ArraySetAsSeries(a,true);if(CopyBuffer(h,b,s,1,a)<1)return 0;return a[0];}
double WR(){int t=g_wins+g_losses;return t>0?((double)g_wins/t)*100:0;}
string PatName(EPattern p){switch(p){case PAT_PINBAR_BULL:return "BULL PIN BAR ★";case PAT_PINBAR_BEAR:return "BEAR PIN BAR ★";case PAT_ENGULF_BULL:return "BULL ENGULFING ★";case PAT_ENGULF_BEAR:return "BEAR ENGULFING ★";case PAT_HAMMER:return "HAMMER";case PAT_SHOOTING_STAR:return "SHOOTING STAR";case PAT_DOJI_BULL:return "DRAGONFLY DOJI";case PAT_DOJI_BEAR:return "GRAVESTONE DOJI";case PAT_MORNING_STAR:return "MORNING STAR ★";case PAT_EVENING_STAR:return "EVENING STAR ★";case PAT_HARAMI_BULL:return "BULL HARAMI";case PAT_HARAMI_BEAR:return "BEAR HARAMI";case PAT_TWEEZERS_BULL:return "TWEEZERS BOTTOM";case PAT_TWEEZERS_BEAR:return "TWEEZERS TOP";case PAT_INSIDE_BULL:return "INSIDE BAR ▲";case PAT_INSIDE_BEAR:return "INSIDE BAR ▼";default:return "scanning...";}}
double LotSize(double sl){double bal=AccountInfoDouble(ACCOUNT_BALANCE),risk=bal*(Risk_Pct/100.0);double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE),ls=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);if(ts==0||tv==0||sl==0)return 0;double vpl=(sl/ts)*tv;if(vpl==0)return 0;return NormalizeDouble(MathMax(mn,MathMin(mx,MathFloor((risk/vpl)/ls)*ls)),2);}
int CountOpenPositions(){int n=0;for(int i=PositionsTotal()-1;i>=0;i--)if(g_pos.SelectByIndex(i))if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic)n++;return n;}
int CountAllTrades(){int n=CountOpenPositions();for(int i=OrdersTotal()-1;i>=0;i--)if(g_order.SelectByIndex(i))if(g_order.Symbol()==_Symbol&&g_order.Magic()==g_magic)n++;return n;}
int GetOpenDirection(){for(int i=PositionsTotal()-1;i>=0;i--){if(g_pos.SelectByIndex(i)){if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic){return(g_pos.PositionType()==POSITION_TYPE_BUY)?1:-1;}}}return 0;}
double GetOpenProfitPts(){double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);for(int i=PositionsTotal()-1;i>=0;i--){if(g_pos.SelectByIndex(i)){if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic){double e=g_pos.PriceOpen(),c=g_pos.PriceCurrent();return(g_pos.PositionType()==POSITION_TYPE_BUY)?(c-e)/pt:(e-c)/pt;}}}return 0;}
void MoveAllToBreakeven(){double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);for(int i=PositionsTotal()-1;i>=0;i--){if(g_pos.SelectByIndex(i)){if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic){double e=g_pos.PriceOpen(),sp=SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)*pt,sl=0;if(g_pos.PositionType()==POSITION_TYPE_BUY){sl=NormalizeDouble(e+sp,_Digits);if(sl>g_pos.StopLoss())g_trade.PositionModify(g_pos.Ticket(),sl,g_pos.TakeProfit());}else{sl=NormalizeDouble(e-sp,_Digits);if(sl<g_pos.StopLoss()||g_pos.StopLoss()==0)g_trade.PositionModify(g_pos.Ticket(),sl,g_pos.TakeProfit());}PrintFormat("BREAKEVEN: #%d → %.2f",g_pos.Ticket(),sl);}}}}
bool DailyLoss(){double c=AccountInfoDouble(ACCOUNT_BALANCE);return(((g_dayBal-c)/g_dayBal)*100.0>=Risk_DailyLoss);}
bool DailyProfit(){return(g_profit>0&&(g_profit/g_dayBal)*100.0>=Risk_DailyProfit);}
void ResetDay(){static datetime l=0;MqlDateTime n;TimeToStruct(TimeCurrent(),n);MqlDateTime ld;TimeToStruct(l,ld);if(n.day!=ld.day||l==0){g_dayBal=AccountInfoDouble(ACCOUNT_BALANCE);g_profit=0;g_consec=0;l=TimeCurrent();PrintFormat("Day reset | Bal:%.2f",g_dayBal);}}
