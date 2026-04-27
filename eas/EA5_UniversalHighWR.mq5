//+------------------------------------------------------------------+
//|  ProTraderEA.mq5  v1.00                                         |
//|  COMPLETE PROFESSIONAL SYSTEM                                   |
//|  Based on: The Candlestick Trading Bible                        |
//|                                                                  |
//|  STRATEGY (from the book):                                      |
//|  1. Identify trend on H4 (higher highs/lows)                   |
//|  2. Wait for pullback to 50%/61.8% Fib or 21 EMA              |
//|  3. Pattern must form AT key level (S/R, Fib, EMA)             |
//|  4. Confirm on H1 — structure + BOS                            |
//|  5. Enter on M15/M5 via pending limit                          |
//|  6. SL below swing low (buys) / above swing high (sells)       |
//|  7. TP at next S/R level — minimum 1:2, aim 1:3               |
//|  8. Exit immediately on CHOCH                                   |
//|  9. Pyramid only when in profit + breakeven                    |
//|                                                                  |
//|  ADDITIONAL FEATURES:                                           |
//|  - Fair Value Gap (FVG) detection                               |
//|  - Liquidity sweep detection (stop hunt filter)                 |
//|  - False breakout filter                                        |
//|  - Partial take profit at 1:1 RR                               |
//|  - Auto breakeven after 1:1 reached                            |
//|                                                                  |
//|  MARKETS:                                                       |
//|  Step Index 400/500 → M5/M15                                   |
//|  GBPUSD/EURUSD/USDJPY → M15 entry, H1/H4 direction            |
//|  XAUUSD → M15 entry, H1/H4 direction                          |
//|                                                                  |
//|  TIMEFRAME SETUP:                                               |
//|  Chart:    M15 (execution timeframe)                           |
//|  HTF1:     H1  (confirmation — set below)                      |
//|  HTF2:     H4  (trend direction — set below)                   |
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

input group "=== RISK MANAGEMENT (From Book: max 1-2%) ==="
input double Risk_Pct          = 1.0;   // % risk per trade (book: 1% beginner, 2% max)
input double Risk_DailyLoss    = 4.0;   // Stop day at this % loss
input double Risk_DailyProfit  = 6.0;   // Stop day at this % profit
input int    Risk_MaxConsec    = 3;     // Stop after 3 losses (book discipline)

input group "=== PYRAMIDING (Book: only when in profit) ==="
input int    Max_Positions     = 2;     // Max 2 trades at once
input double Pyramid_MinPts    = 20.0;  // Trade 1 must be 20 pts in profit
input bool   Pyramid_Breakeven = true;  // Move SL to breakeven before adding

input group "=== PARTIAL PROFIT (Book: secure gains) ==="
input bool   Use_PartialClose  = true;  // Close 50% at 1:1 RR
input double Breakeven_Trigger = 1.0;   // Move to BE when 1x SL in profit

input group "=== PENDING LIMIT (Book: wait for retracement) ==="
input double Limit_Offset_Pts  = 20.0;  // Wait for pullback before entry
input int    Limit_Expiry_Bars = 4;     // Cancel if not filled in 4 bars

input group "=== SMART SL/TP (Book: swing levels not random) ==="
input int    Swing_SL_Bars     = 12;    // Bars to look back for swing SL
input int    SR_TP_Bars        = 60;    // Bars to look back for TP level
input double SL_Buffer_Pts     = 5.0;   // Extra buffer beyond swing (book: beyond pattern)
input double MinRR             = 2.0;   // Min 1:2 RR (book standard)

input group "=== MULTI-TIMEFRAME (H4=trend H1=confirm) ==="
input ENUM_TIMEFRAMES HTF_Trend   = PERIOD_H4;  // Trend direction timeframe
input ENUM_TIMEFRAMES HTF_Confirm = PERIOD_H1;  // Confirmation timeframe
input int    EMA_Trend         = 200;   // Trend filter EMA (book: 200 SMA)
input int    EMA_Dynamic       = 21;    // Dynamic S/R (book: 21 EMA)
input int    EMA_Fast          = 8;     // Fast EMA (book: 8 EMA)

input group "=== FIBONACCI (Book: 50% and 61.8% levels) ==="
input int    Fib_Bars          = 50;    // Swing bars for Fib calculation
input double Fib_Zone          = 0.006; // Zone width around Fib level

input group "=== STRUCTURE ==="
input int    Swing_Lookback    = 8;
input int    Swing_ScanBars    = 60;
input int    OB_Lookback       = 20;

input group "=== FAIR VALUE GAP ==="
input bool   Use_FVG           = true;  // Use FVG as entry confirmation
input double FVG_MinSize_Pts   = 5.0;  // Minimum FVG size to consider

input group "=== PATTERNS (Book: confluence = multiple signals) ==="
input double PinBar_TailPct    = 0.55;  // Book: long tail = strong rejection
input double PinBar_BodyPct    = 0.40;
input double Doji_BodyPct      = 0.10;
input int    Min_Score         = 3;     // Need 3/9 confluence

input group "=== FILTERS ==="
input bool   Filter_FalseBreak = true;  // Filter inside bar false breakouts (book chapter)
input bool   Filter_Liquidity  = true;  // Filter after liquidity sweeps
input int    Liq_Lookback      = 5;    // Bars to check for liquidity grab

input group "=== SESSION (Book: avoid low volatility) ==="
input bool   Filter_Session    = false;
input int    Sess_Start        = 7;
input int    Sess_End          = 21;

input group "=== EXECUTION ==="
input bool   AutoTrade         = true;
input int    Slippage          = 30;
input bool   ShowDashboard     = true;

enum EPattern{PAT_NONE,PAT_PINBAR_BULL,PAT_PINBAR_BEAR,PAT_ENGULF_BULL,PAT_ENGULF_BEAR,PAT_INSIDE_BULL,PAT_INSIDE_BEAR,PAT_INSIDE_FALSE_BULL,PAT_INSIDE_FALSE_BEAR,PAT_MORNING_STAR,PAT_EVENING_STAR,PAT_HAMMER,PAT_SHOOTING_STAR,PAT_DOJI_BULL,PAT_DOJI_BEAR,PAT_HARAMI_BULL,PAT_HARAMI_BEAR,PAT_TWEEZERS_BULL,PAT_TWEEZERS_BEAR};
enum EStructure{STR_BULL,STR_BEAR,STR_RANGE,STR_NONE};
enum EBOS{BOS_BULL,BOS_BEAR,BOS_NONE};

struct SSignal{
   EStructure str;EBOS bos;bool choch;
   bool atFib50,atFib618,atOB,atEMA21,atFVG,afterLiqSweep;
   bool htfTrendOk,htfConfirmOk;
   double fib50,fib618;
   EPattern pattern;
   bool rsiOk,emaOk,isBull;
   double rsiV,atr;
   double smartSL,smartTP,rrAchieved;
   int score;
   string reason; // why this trade
};

int h_emaTrend,h_emaDynamic,h_emaFast;
int h_htfTrend,h_htfConfirm;
int h_rsi,h_atr,h_adx;
int h_htfEMA21;

CTrade g_trade;CPositionInfo g_pos;COrderInfo g_order;

double   g_dayBal,g_profit;
int      g_consec,g_wins,g_losses,g_magic,g_brokerWait;
datetime g_lastBar,g_pendingPlacedBar,g_lastOrderBar;
long     g_minStop;
bool     g_hasPending;
ulong    g_pendingTicket;
bool     g_partialDone;   // track if partial close done this trade

int GenMagic(string s,ENUM_TIMEFRAMES tf){int h=0;for(int i=0;i<StringLen(s);i++)h=h*31+(int)StringGetCharacter(s,i);return MathAbs(h)%90000+10000+(int)tf+1597;}


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

   // Current TF indicators
   h_rsi      =iRSI(_Symbol,PERIOD_CURRENT,14,PRICE_CLOSE);
   h_atr      =iATR(_Symbol,PERIOD_CURRENT,14);
   h_adx      =iADX(_Symbol,PERIOD_CURRENT,14);
   h_emaTrend =iMA(_Symbol,PERIOD_CURRENT,EMA_Trend,0,MODE_EMA,PRICE_CLOSE);
   h_emaDynamic=iMA(_Symbol,PERIOD_CURRENT,EMA_Dynamic,0,MODE_EMA,PRICE_CLOSE);
   h_emaFast  =iMA(_Symbol,PERIOD_CURRENT,EMA_Fast,0,MODE_EMA,PRICE_CLOSE);

   // HTF indicators
   h_htfTrend  =iMA(_Symbol,HTF_Trend,EMA_Trend,0,MODE_EMA,PRICE_CLOSE);
   h_htfConfirm=iMA(_Symbol,HTF_Confirm,EMA_Dynamic,0,MODE_EMA,PRICE_CLOSE);
   h_htfEMA21  =iMA(_Symbol,HTF_Trend,EMA_Dynamic,0,MODE_EMA,PRICE_CLOSE);

   if(h_rsi==INVALID_HANDLE||h_atr==INVALID_HANDLE||h_emaTrend==INVALID_HANDLE)
      {Print("Indicator FAILED");return INIT_FAILED;}

   g_dayBal=AccountInfoDouble(ACCOUNT_BALANCE);
   g_consec=0;g_wins=0;g_losses=0;g_profit=0;
   g_lastBar=0;g_hasPending=false;g_pendingTicket=0;
   g_pendingPlacedBar=0;g_lastOrderBar=0;g_brokerWait=0;g_partialDone=false;

   ScanExistingPending();
   if(Use_Server)ServerHeartbeat("OnInit");
   PrintFormat("ProTraderEA v1.00 | %s %s | Magic:%d | Score:%d/9",
               _Symbol,EnumToString(Period()),g_magic,Min_Score);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int r)
{
   int h[]={h_rsi,h_atr,h_adx,h_emaTrend,h_emaDynamic,h_emaFast,h_htfTrend,h_htfConfirm,h_htfEMA21};
   for(int i=0;i<ArraySize(h);i++) IndicatorRelease(h[i]);
   Comment("");
}

void OnTick()
{
   datetime bar=iTime(_Symbol,PERIOD_CURRENT,0);
   if(bar==g_lastBar) return;
   g_lastBar=bar;
   // Send heartbeat every 10 bars so dashboard stays alive
   static int hbCount=0; hbCount++; if(hbCount>=2){hbCount=0;if(Use_Server)ServerHeartbeat("running");}

   ResetDay();
   if(DailyLoss())              {ShowMsg("DAILY LOSS — STOPPED");return;}
   if(DailyProfit())            {ShowMsg("DAILY PROFIT HIT — STOPPED");return;}
   if(g_consec>=Risk_MaxConsec) {ShowMsg("3 LOSSES — PAUSED");return;}

   if(g_brokerWait>0){g_brokerWait--;return;}

   // Active trade management
   ManageActiveTrades();
   ManagePending();
   if(CountOpenPositions()>0) CheckCHOCHExit();
   if(g_hasPending) return;
   if(g_lastOrderBar==iTime(_Symbol,PERIOD_CURRENT,0)) return;

   int openPos  = CountOpenPositions();
   int totalAll = CountAllTrades();
   if(totalAll>=Max_Positions) return;

   if(Filter_Session&&!InSession()){ShowMsg("OUTSIDE SESSION");return;}

   // Build signal
   SSignal sig;
   BuildSignal(sig);

   // Dashboard
   if(ShowDashboard) Dashboard(sig,openPos);

   // Validate signal (book: confluence = multiple conditions)
   if(sig.score<Min_Score) return;
   if(sig.rrAchieved<MinRR) return;
   // Pattern adds score but is not mandatory if score is high enough
   if(sig.score<5 && sig.pattern==PAT_NONE) return;

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

// ═══════════════════════════════════════════
//  ACTIVE TRADE MANAGEMENT
//  - Partial close at 1:1 RR (book: secure profits)
//  - Auto breakeven (book: protect capital)
// ═══════════════════════════════════════════
void ManageActiveTrades()
{
   double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol()!=_Symbol||g_pos.Magic()!=g_magic) continue;

      double entry=g_pos.PriceOpen();
      double sl=g_pos.StopLoss();
      double tp=g_pos.TakeProfit();
      double cur=g_pos.PriceCurrent();
      double slDist=MathAbs(entry-sl);
      if(slDist<=0) continue;

      bool isBuy=(g_pos.PositionType()==POSITION_TYPE_BUY);
      double profitPts=isBuy?(cur-entry)/pt:(entry-cur)/pt;
      double slPts=slDist/pt;

      // Breakeven: when profit >= Breakeven_Trigger × SL distance
      if(profitPts>=slPts*Breakeven_Trigger)
      {
         double beSL=isBuy
            ?NormalizeDouble(entry+SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)*pt,_Digits)
            :NormalizeDouble(entry-SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)*pt,_Digits);

         bool needMove=isBuy?(beSL>sl):(beSL<sl||sl==0);
         if(needMove)
         {
            if(g_trade.PositionModify(g_pos.Ticket(),beSL,tp))
               PrintFormat("BREAKEVEN: #%d entry %.5f → SL %.5f",g_pos.Ticket(),entry,beSL);
         }
      }

      // Partial close at 1:1 RR — book: secure half the profit
      if(Use_PartialClose && !g_partialDone && profitPts>=slPts)
      {
         double halfLot=NormalizeDouble(g_pos.Volume()*0.5,2);
         if(halfLot>=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN))
         {
            if(g_trade.PositionClosePartial(g_pos.Ticket(),halfLot))
            {
               g_partialDone=true;
               PrintFormat("PARTIAL CLOSE 50%% at 1:1 | Remaining %.2f lots",halfLot);
            }
         }
      }
   }
}

void BuildSignal(SSignal &s)
{
   double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double cur=iC(1);

   // HTF trend (H4)
   double htfTrend=G(h_htfTrend,0,1);
   // HTF confirm (H1)
   double htfConfirm=G(h_htfConfirm,0,1);
   // Current TF EMAs
   double ema200=G(h_emaTrend,0,1);
   double ema21=G(h_emaDynamic,0,1);
   double ema8=G(h_emaFast,0,1);
   double rsi=G(h_rsi,0,1);
   double atr=G(h_atr,0,1);
   double adx=G(h_adx,0,1);

   if(rsi==0||atr==0||ema21==0) return;
   s.atr=atr;s.rsiV=rsi;

   // === STEP 1: Trend from H4 (book: identify trend first) ===
   double htfH=iHigh(_Symbol,HTF_Trend,1),htfL=iLow(_Symbol,HTF_Trend,1);
   double htfH2=iHigh(_Symbol,HTF_Trend,3),htfL2=iLow(_Symbol,HTF_Trend,3);
   bool htfBull=(htfH>htfH2&&htfL>htfL2)||(cur>htfTrend);
   bool htfBear=(htfH<htfH2&&htfL<htfL2)||(cur<htfTrend);
   s.htfTrendOk=(htfBull||htfBear);

   // === STEP 2: Confirm on H1 ===
   double h1cur=iClose(_Symbol,HTF_Confirm,1);
   s.htfConfirmOk=(htfBull?(h1cur>htfConfirm):(h1cur<htfConfirm));

   // === STEP 3: Current TF structure ===
   double sH=0,sL=0;
   s.str=DetStructure(sH,sL);
   s.isBull=htfBull||(s.str==STR_BULL&&cur>ema200);

   // BOS/CHOCH
   bool ch=false;s.bos=DetBOS(s.str,ch);s.choch=ch;

   // === STEP 4: Fibonacci 50%/61.8% (book: most important levels) ===
   double f50=0,f618=0;bool at50=false,at618=false;
   CalcFib(s.str,f50,f618,at50,at618);
   s.fib50=f50;s.fib618=f618;s.atFib50=at50;s.atFib618=at618;

   // === STEP 5: 21 EMA touch (book: dynamic S/R) ===
   double eTol=atr*0.5;
   s.atEMA21=(MathAbs(cur-ema21)<=eTol||MathAbs(iL(1)-ema21)<=eTol||MathAbs(iH(1)-ema21)<=eTol);

   // === STEP 6: Order Block ===
   s.atOB=DetOB(s.str);

   // === STEP 7: Fair Value Gap (FVG) ===
   s.atFVG=false;
   if(Use_FVG) s.atFVG=DetFVG(s.isBull,atr);

   // === STEP 8: Liquidity Sweep (book: banks hunt stops first) ===
   s.afterLiqSweep=false;
   if(Filter_Liquidity) s.afterLiqSweep=DetLiquiditySweep(s.isBull);

   // === STEP 9: Pattern (book: must form AT key level) ===
   s.pattern=DetPattern(s.isBull);
   AdjustDir(s);

   // Indicator checks
   s.rsiOk=s.isBull?(rsi>=35&&rsi<=65):(rsi>=35&&rsi<=65);
   s.emaOk=s.isBull?(ema8>ema21):(ema8<ema21);

   // === SCORING (book: confluence = multiple factors) ===
   s.score=0;
   s.reason="";
   if(s.htfTrendOk)                                             {s.score++;s.reason+="H4trend ";}
   if(s.htfConfirmOk)                                           {s.score++;s.reason+="H1conf ";}
   if(s.str!=STR_NONE)                                          {s.score++;s.reason+="struct ";}
   if((s.isBull&&s.bos==BOS_BULL)||(!s.isBull&&s.bos==BOS_BEAR)){s.score++;s.reason+="BOS ";}
   if(s.atFib50||s.atFib618)                                    {s.score++;s.reason+=(s.atFib50?"Fib50 ":"Fib618 ");}
   if(s.atEMA21)                                                 {s.score++;s.reason+="EMA21 ";}
   if(s.atOB)                                                    {s.score++;s.reason+="OB ";}
   if(s.pattern!=PAT_NONE)                                       {s.score++;s.reason+=PatName(s.pattern)+" ";}
   if(s.atFVG)                                                   {s.score++;s.reason+="FVG ";}

   // Smart SL/TP (book: swing levels, next S/R)
   s.smartSL=CalcSmartSL(s.isBull,atr);
   s.smartTP=CalcSmartTP(s.isBull,s.smartSL);
   double slD=MathAbs(cur-s.smartSL),tpD=MathAbs(cur-s.smartTP);
   s.rrAchieved=(slD>0)?tpD/slD:0;
}

// ═══════════════════════════════════════════
//  FAIR VALUE GAP DETECTION
//  FVG = gap between candle 1 high and candle 3 low
//  (or candle 1 low and candle 3 high for bearish)
//  Book: institutions leave gaps on fast moves
// ═══════════════════════════════════════════
bool DetFVG(bool bullish, double atr)
{
   double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double minSize=FVG_MinSize_Pts*pt;
   double cur=iC(1);

   for(int i=2;i<=10;i++)
   {
      if(bullish)
      {
         // Bullish FVG: gap between bar[i+1] high and bar[i-1] low
         double gap_top=iL(i-1);   // bar before
         double gap_bot=iH(i+1);   // bar after
         if(gap_top>gap_bot&&gap_top-gap_bot>=minSize)
         {
            // Price inside the FVG = filling the gap = good buy entry
            if(cur>=gap_bot&&cur<=gap_top) return true;
         }
      }
      else
      {
         // Bearish FVG: gap between bar[i+1] low and bar[i-1] high
         double gap_bot2=iH(i-1);
         double gap_top2=iL(i+1);
         if(gap_bot2>gap_top2&&gap_bot2-gap_top2>=minSize)
         {
            if(cur>=gap_top2&&cur<=gap_bot2) return true;
         }
      }
   }
   return false;
}

// ═══════════════════════════════════════════
//  LIQUIDITY SWEEP DETECTION
//  Book: "Banks hunt stops before real move"
//  Look for: price went BELOW recent low then quickly reversed (bull)
//  Or: price went ABOVE recent high then quickly reversed (bear)
// ═══════════════════════════════════════════
bool DetLiquiditySweep(bool bullish)
{
   double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double cur=iC(1);

   if(bullish)
   {
      // Find lowest low in last Liq_Lookback bars
      double lowestLow=99999999;
      for(int i=2;i<=Liq_Lookback+1;i++) if(iL(i)<lowestLow)lowestLow=iL(i);

      // Price swept below that low but closed back above it
      bool sweptBelow=(iL(1)<lowestLow||iL(2)<lowestLow);
      bool closedAbove=(iC(1)>lowestLow);
      return(sweptBelow&&closedAbove);
   }
   else
   {
      // Find highest high
      double highestHigh=0;
      for(int i=2;i<=Liq_Lookback+1;i++) if(iH(i)>highestHigh)highestHigh=iH(i);

      bool sweptAbove=(iH(1)>highestHigh||iH(2)>highestHigh);
      bool closedBelow=(iC(1)<highestHigh);
      return(sweptAbove&&closedBelow);
   }
}

// Smart SL at swing high/low (book: below pattern, with buffer)
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

// Smart TP at next S/R (book: "next support or resistance level")
double CalcSmartTP(bool bull,double sl)
{
   double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double cur=iC(1);
   double slDist=MathAbs(cur-sl);
   double minTP=slDist*MinRR;
   double minD=(g_minStop+10)*pt;
   double best=0;
   if(bull){
      double cl=999999999;
      for(int i=3;i<=SR_TP_Bars;i++){double h=iH(i),hP=iH(i-1),hN=iH(i+1);if(h>hP&&h>hN&&h>cur+minTP&&h<cl)cl=h;}
      best=(cl<999999999)?cl:cur+minTP;
      if(best-cur<minD*2)best=cur+minD*2;
   }else{
      double cl=-999999999;
      for(int i=3;i<=SR_TP_Bars;i++){double l=iL(i),lP=iL(i-1),lN=iL(i+1);if(l<lP&&l<lN&&l<cur-minTP&&l>cl)cl=l;}
      best=(cl>-999999999)?cl:cur-minTP;
      if(cur-best<minD*2)best=cur-minD*2;
   }
   return NormalizeDouble(best,_Digits);
}

void PlaceLimitOrder(ENUM_ORDER_TYPE type,const SSignal &sig,bool isPyramid)
{
   if(g_hasPending){Print("BLOCKED");return;}
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double offset=Limit_Offset_Pts*pt;
   double limitPrice,sl=sig.smartSL,tp=sig.smartTP;

   if(type==ORDER_TYPE_BUY_LIMIT){
      limitPrice=NormalizeDouble(bid-offset,_Digits);
      if(sl>=limitPrice)sl=NormalizeDouble(limitPrice-(g_minStop+10)*pt,_Digits);
   }else{
      limitPrice=NormalizeDouble(bid+offset,_Digits);
      if(sl<=limitPrice)sl=NormalizeDouble(limitPrice+(g_minStop+10)*pt,_Digits);
   }

   double slPt=MathAbs(limitPrice-sl)/pt,tpPt=MathAbs(limitPrice-tp)/pt;
   if(slPt<g_minStop+5||tpPt<g_minStop+5){PrintFormat("SKIP min=%d",g_minStop);return;}

   double lot=LotSize(MathAbs(limitPrice-sl));if(lot<=0)return;
   string dir=(type==ORDER_TYPE_BUY_LIMIT)?"BUY LIMIT":"SELL LIMIT";
   string tag=isPyramid?"PYRAMID":"ENTRY";

   bool ok=(type==ORDER_TYPE_BUY_LIMIT)
      ?g_trade.BuyLimit(lot,limitPrice,_Symbol,sl,tp,ORDER_TIME_GTC,0,StringFormat("PRO|BL|RR:%.1f|%d",tpPt/slPt,sig.score))
      :g_trade.SellLimit(lot,limitPrice,_Symbol,sl,tp,ORDER_TIME_GTC,0,StringFormat("PRO|SL|RR:%.1f|%d",tpPt/slPt,sig.score));

   if(ok){
      g_pendingTicket=g_trade.ResultOrder();g_hasPending=true;
      g_pendingPlacedBar=iTime(_Symbol,PERIOD_CURRENT,0);
      g_lastOrderBar=g_pendingPlacedBar;g_brokerWait=5;
      g_partialDone=false;
      PrintFormat("%s %s | Lot:%.2f | Limit:%.5f | SL:%.5f(swing) | TP:%.5f(S/R) | RR:1:%.1f | Score:%d/9 | %s",
                  tag,dir,lot,limitPrice,sl,tp,tpPt/slPt,sig.score,sig.reason);
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

void ScanExistingPending()
{
   for(int i=OrdersTotal()-1;i>=0;i--){
      if(g_order.SelectByIndex(i)){
         if(g_order.Symbol()==_Symbol&&g_order.Magic()==g_magic){
            g_hasPending=true;g_pendingTicket=g_order.Ticket();
            g_pendingPlacedBar=iTime(_Symbol,PERIOD_CURRENT,0);
            g_lastOrderBar=iTime(_Symbol,PERIOD_CURRENT,0);
            PrintFormat("FOUND existing pending: #%d",g_pendingTicket);
            return;
         }
      }
   }
}

void CheckCHOCHExit()
{
   int dir=GetOpenDirection();if(dir==0)return;
   double cur=iC(1),rH=0,rL=0;
   for(int i=2;i<Swing_Lookback*3;i++){if(iH(i)>rH)rH=iH(i);if(rL==0||iL(i)<rL)rL=iL(i);}
   bool choch=false;
   double sH=0,sL=0;EStructure str=DetStructure(sH,sL);
   if(dir==1&&str==STR_BULL&&cur<rL)choch=true;
   if(dir==-1&&str==STR_BEAR&&cur>rH)choch=true;
   if(!choch)return;
   PrintFormat("CHOCH EXIT — structure reversed");
   for(int i=PositionsTotal()-1;i>=0;i--){
      if(g_pos.SelectByIndex(i)){
         if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic){
            if(g_trade.PositionClose(g_pos.Ticket()))
               PrintFormat("CHOCH EXIT: #%d P/L:%.2f",g_pos.Ticket(),g_pos.Profit());
         }
      }
   }
   if(g_hasPending){if(g_trade.OrderDelete(g_pendingTicket))Print("PENDING CANCELLED");g_hasPending=false;g_pendingTicket=0;}
}

// All patterns (book priority: Pin Bar #1, Engulfing #2, Inside Bar #3)
EPattern DetPinBar(int i){double o=iO(i),c=iC(i),h=iH(i),l=iL(i),rng=h-l;if(rng<=0)return PAT_NONE;double body=MathAbs(c-o),upW=h-MathMax(o,c),loW=MathMin(o,c)-l;if(body/rng>PinBar_BodyPct)return PAT_NONE;if(loW/rng>=PinBar_TailPct&&loW>upW*2)return PAT_PINBAR_BULL;if(upW/rng>=PinBar_TailPct&&upW>loW*2)return PAT_PINBAR_BEAR;return PAT_NONE;}
EPattern DetEngulf(int i){double o1=iO(i),c1=iC(i),o2=iO(i+1),c2=iC(i+1);if(MathAbs(c1-o1)==0||MathAbs(c2-o2)==0)return PAT_NONE;if(c1>o1&&c2<o2&&c1>=o2&&o1<=c2)return PAT_ENGULF_BULL;if(c1<o1&&c2>o2&&o1>=c2&&c1<=o2)return PAT_ENGULF_BEAR;return PAT_NONE;}
EPattern DetInside(int i,bool b){if(iH(i)<iH(i+1)&&iL(i)>iL(i+1))return b?PAT_INSIDE_BULL:PAT_INSIDE_BEAR;return PAT_NONE;}
EPattern DetInsideFalseBreak(int i,bool b){if(iH(i-1)<iH(i+1)&&iL(i-1)>iL(i+1)){if(b&&iC(i)>iH(i+1)&&iC(i-1)<iH(i+1))return PAT_INSIDE_FALSE_BULL;if(!b&&iC(i)<iL(i+1)&&iC(i-1)>iL(i+1))return PAT_INSIDE_FALSE_BEAR;}return PAT_NONE;}
EPattern DetMorn(int i){double o1=iO(i+2),c1=iC(i+2),o2=iO(i+1),c2=iC(i+1),o3=iO(i),c3=iC(i),r1=MathAbs(o1-c1),r2=MathAbs(o2-c2);if(r1==0)return PAT_NONE;if(c1<o1&&r2<r1*0.5&&c3>o3&&c3>(o1+c1)/2.0)return PAT_MORNING_STAR;return PAT_NONE;}
EPattern DetEve(int i){double o1=iO(i+2),c1=iC(i+2),o2=iO(i+1),c2=iC(i+1),o3=iO(i),c3=iC(i),r1=MathAbs(o1-c1),r2=MathAbs(o2-c2);if(r1==0)return PAT_NONE;if(c1>o1&&r2<r1*0.5&&c3<o3&&c3<(o1+c1)/2.0)return PAT_EVENING_STAR;return PAT_NONE;}
EPattern DetHamm(int i){double o=iO(i),c=iC(i),h=iH(i),l=iL(i),rng=h-l;if(rng<=0)return PAT_NONE;double body=MathAbs(c-o),loW=MathMin(o,c)-l,upW=h-MathMax(o,c);if(body/rng<=0.30&&loW/rng>=0.60&&loW>upW*2)return PAT_HAMMER;return PAT_NONE;}
EPattern DetShoot(int i){double o=iO(i),c=iC(i),h=iH(i),l=iL(i),rng=h-l;if(rng<=0)return PAT_NONE;double body=MathAbs(c-o),loW=MathMin(o,c)-l,upW=h-MathMax(o,c);if(body/rng<=0.30&&upW/rng>=0.60&&upW>loW*2)return PAT_SHOOTING_STAR;return PAT_NONE;}
EPattern DetDoji(int i){double o=iO(i),c=iC(i),h=iH(i),l=iL(i),rng=h-l;if(rng<=0)return PAT_NONE;double body=MathAbs(c-o);if(body/rng>Doji_BodyPct)return PAT_NONE;double upW=h-MathMax(o,c),loW=MathMin(o,c)-l;if(loW/rng>=0.60&&upW<body*2)return PAT_DOJI_BULL;if(upW/rng>=0.60&&loW<body*2)return PAT_DOJI_BEAR;return PAT_NONE;}
EPattern DetHaram(int i){double o1=iO(i),c1=iC(i),o2=iO(i+1),c2=iC(i+1);if(MathAbs(c2-o2)==0)return PAT_NONE;if(MathMax(o1,c1)<MathMax(o2,c2)&&MathMin(o1,c1)>MathMin(o2,c2)){if(c2<o2&&c1>o1)return PAT_HARAMI_BULL;if(c2>o2&&c1<o1)return PAT_HARAMI_BEAR;}return PAT_NONE;}
EPattern DetTweez(int i){double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT)*3;if(MathAbs(iL(i)-iL(i+1))<=pt&&iC(i+1)<iO(i+1)&&iC(i)>iO(i))return PAT_TWEEZERS_BULL;if(MathAbs(iH(i)-iH(i+1))<=pt&&iC(i+1)>iO(i+1)&&iC(i)<iO(i))return PAT_TWEEZERS_BEAR;return PAT_NONE;}

// Book priority: Pin Bar first, then Engulfing, then Inside Bar false breakout
EPattern DetPattern(bool bull)
{
   EPattern p;
   p=DetPinBar(1);    if(p!=PAT_NONE)return p;  // Book: #1 strongest
   p=DetEngulf(1);    if(p!=PAT_NONE)return p;  // Book: #2
   if(Filter_FalseBreak){p=DetInsideFalseBreak(1,bull);if(p!=PAT_NONE)return p;} // Book: false breakout
   p=DetMorn(1);      if(p!=PAT_NONE)return p;
   p=DetEve(1);       if(p!=PAT_NONE)return p;
   p=DetHamm(1);      if(p!=PAT_NONE)return p;
   p=DetShoot(1);     if(p!=PAT_NONE)return p;
   p=DetDoji(1);      if(p!=PAT_NONE)return p;
   p=DetTweez(1);     if(p!=PAT_NONE)return p;
   p=DetHaram(1);     if(p!=PAT_NONE)return p;
   p=DetInside(1,bull);if(p!=PAT_NONE)return p; // Book: #3
   return PAT_NONE;
}

void AdjustDir(SSignal &s){if(s.pattern==PAT_PINBAR_BULL||s.pattern==PAT_ENGULF_BULL||s.pattern==PAT_INSIDE_BULL||s.pattern==PAT_INSIDE_FALSE_BULL||s.pattern==PAT_MORNING_STAR||s.pattern==PAT_HAMMER||s.pattern==PAT_DOJI_BULL||s.pattern==PAT_HARAMI_BULL||s.pattern==PAT_TWEEZERS_BULL)s.isBull=true;if(s.pattern==PAT_PINBAR_BEAR||s.pattern==PAT_ENGULF_BEAR||s.pattern==PAT_INSIDE_BEAR||s.pattern==PAT_INSIDE_FALSE_BEAR||s.pattern==PAT_EVENING_STAR||s.pattern==PAT_SHOOTING_STAR||s.pattern==PAT_DOJI_BEAR||s.pattern==PAT_HARAMI_BEAR||s.pattern==PAT_TWEEZERS_BEAR)s.isBull=false;}
EStructure DetStructure(double &sH,double &sL){double sh[2]={0,0},sl2[2]={0,0};int shb[2]={0,0},slb[2]={0,0},shc=0,slc=0;for(int i=2;i<Swing_ScanBars-1&&(shc<2||slc<2);i++){if(iH(i)>iH(i-1)&&iH(i)>iH(i+1)&&shc<2)if(shc==0||i>shb[0]+Swing_Lookback){sh[shc]=iH(i);shb[shc]=i;shc++;}if(iL(i)<iL(i-1)&&iL(i)<iL(i+1)&&slc<2)if(slc==0||i>slb[0]+Swing_Lookback){sl2[slc]=iL(i);slb[slc]=i;slc++;}}sH=sh[0];sL=sl2[0];if(shc<2||slc<2)return STR_NONE;if(sh[0]>sh[1]&&sl2[0]>sl2[1])return STR_BULL;if(sh[0]<sh[1]&&sl2[0]<sl2[1])return STR_BEAR;return STR_RANGE;}
EBOS DetBOS(EStructure str,bool &choch){choch=false;if(str==STR_NONE)return BOS_NONE;double cur=iC(1),rH=0,rL=0;for(int i=2;i<Swing_Lookback*3;i++){if(iH(i)>rH)rH=iH(i);if(rL==0||iL(i)<rL)rL=iL(i);}if(str==STR_BULL&&cur>rH)return BOS_BULL;if(str==STR_BEAR&&cur<rL)return BOS_BEAR;if(str==STR_BULL&&cur<rL)choch=true;if(str==STR_BEAR&&cur>rH)choch=true;return BOS_NONE;}
void CalcFib(EStructure str,double &f50,double &f618,bool &at50,bool &at618){f50=0;f618=0;at50=false;at618=false;double swH=0,swL=0;for(int i=1;i<Fib_Bars;i++){if(iH(i)>swH)swH=iH(i);if(swL==0||iL(i)<swL)swL=iL(i);}if(swH==0||swL==0)return;double rng=swH-swL,cur=iC(1);f50=str==STR_BULL?swH-0.500*rng:swL+0.500*rng;f618=str==STR_BULL?swH-0.618*rng:swL+0.618*rng;double z=rng*Fib_Zone;at50=(MathAbs(cur-f50)<=z);at618=(MathAbs(cur-f618)<=z);}
bool DetOB(EStructure str){double cur=iC(1),pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);for(int i=3;i<OB_Lookback;i++){double o=iO(i),c=iC(i),op=iO(i+1),cp=iC(i+1);if(str==STR_BULL&&c>o&&cp<op){double h=MathMax(op,cp),l=MathMin(op,cp),z=(h-l)*0.5+pt*5;if(cur>=l-z&&cur<=h+z)return true;break;}if(str==STR_BEAR&&c<o&&cp>op){double h=MathMax(op,cp),l=MathMin(op,cp),z=(h-l)*0.5+pt*5;if(cur>=l-z&&cur<=h+z)return true;break;}}return false;}

void OnTradeTransaction(const MqlTradeTransaction &t,const MqlTradeRequest &req,const MqlTradeResult &res)
{
   if(t.type!=TRADE_TRANSACTION_DEAL_ADD)return;
   if(!HistoryDealSelect(t.deal))return;
   if(HistoryDealGetInteger(t.deal,DEAL_MAGIC)!=g_magic)return;
   if(HistoryDealGetInteger(t.deal,DEAL_ENTRY)==DEAL_ENTRY_IN){g_hasPending=false;g_brokerWait=0;g_partialDone=false;PrintFormat("FILLED at %.5f",HistoryDealGetDouble(t.deal,DEAL_PRICE));return;}
   if(HistoryDealGetInteger(t.deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT)return;
   double p=HistoryDealGetDouble(t.deal,DEAL_PROFIT);g_profit+=p;
   if(p>=0){if(Use_Server)ServerTradeClose(t.deal,p,"WIN");g_wins++;g_consec=0;PrintFormat("WIN +%.2f W:%d L:%d WR:%.0f%%",p,g_wins,g_losses,WR());}
   else{g_losses++;g_consec++;PrintFormat("LOSS %.2f W:%d L:%d WR:%.0f%%",p,g_wins,g_losses,WR());}
   g_partialDone=false;
}

void Dashboard(const SSignal &s,int openPos)
{
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double profPts=GetOpenProfitPts();
   string pyStr=(openPos==1)?StringFormat("PROFIT:%.0fpts(need %.0f)",profPts,Pyramid_MinPts):"—";
   string scoreBar="";for(int i=0;i<s.score;i++)scoreBar+="█";for(int i=s.score;i<9;i++)scoreBar+="░";
   string ready="";
   if(s.score>=Min_Score&&s.pattern!=PAT_NONE&&s.rrAchieved>=MinRR)
      ready=s.isBull?"  ★★ BUY LIMIT READY ★★":"  ★★ SELL LIMIT READY ★★";
   else ready="  waiting for perfect setup...";

   Comment(StringFormat(
      "╔══ PRO TRADER EA v1.00 ══╗\n"
      "  %s %s | Magic:%d\n"
      "  Book: Candlestick Trading Bible\n"
      "╠══ STATUS ══════════════╣\n"
      "  Positions:%d/%d Pending:%s\n"
      "  BrokerWait:%d %s\n"
      "╠══ LEVELS ══════════════╣\n"
      "  BUY LIMIT : %.5f\n"
      "  SELL LIMIT: %.5f\n"
      "  Smart SL  : %.5f ← SWING %s\n"
      "  Smart TP  : %.5f ← S/R\n"
      "  RR        : 1:%.1f (min 1:%.1f)\n"
      "╠══ MULTI-TF (Book Top-Down) ╣\n"
      "  H4 Trend : %s\n"
      "  H1 Confirm: %s\n"
      "╠══ CONFLUENCE (Score) ══╣\n"
      "  [%s] %d/9\n"
      "  Structure : %s\n"
      "  BOS/CHOCH : %s\n"
      "  Fibonacci : %s\n"
      "  21 EMA    : %s\n"
      "  OB        : %s\n"
      "  FVG       : %s\n"
      "  Liq Sweep : %s\n"
      "  Pattern   : %s\n"
      "  Direction : %s\n"
      "  Reason    : %s\n"
      "  %s\n"
      "╠══ RESULTS ═════════════╣\n"
      "  P/L:%.2f W:%d L:%d WR:%.0f%%\n"
      "  Consec:%d/%d\n"
      "╚════════════════════════╝",
      _Symbol,EnumToString(Period()),g_magic,
      openPos,Max_Positions,g_hasPending?"WAITING":"none",
      g_brokerWait,pyStr,
      bid-Limit_Offset_Pts*pt,bid+Limit_Offset_Pts*pt,
      s.smartSL,s.isBull?"LOW":"HIGH",s.smartTP,s.rrAchieved,MinRR,
      s.htfTrendOk?"ALIGNED ✓":"not confirmed",
      s.htfConfirmOk?"CONFIRMED ✓":"not confirmed",
      scoreBar,s.score,
      s.str==STR_BULL?"UPTREND ▲":s.str==STR_BEAR?"DOWNTREND ▼":"RANGING",
      s.choch?"CHOCH⚠":s.bos==BOS_BULL?"BULL BOS✓":s.bos==BOS_BEAR?"BEAR BOS✓":"no BOS",
      s.atFib50?"AT 50% ✓":s.atFib618?"AT 61.8% ✓":"—",
      s.atEMA21?"EMA21 TOUCH ✓":"—",
      s.atOB?"IN ORDER BLOCK ✓":"—",
      s.atFVG?"FVG DETECTED ✓":"—",
      s.afterLiqSweep?"SWEEP ✓ (book: banks hunted stops)":"—",
      PatName(s.pattern),
      s.isBull?"LONG ▲":"SHORT ▼",
      s.reason==""?"scanning...":s.reason,
      ready,
      g_profit,g_wins,g_losses,WR(),
      g_consec,Risk_MaxConsec));
}

void ShowMsg(string m){Comment("PRO TRADER EA\n"+m+StringFormat("\nW:%d L:%d WR:%.0f%%",g_wins,g_losses,WR()));}
double iO(int i){return iOpen(_Symbol,PERIOD_CURRENT,i);}
double iC(int i){return iClose(_Symbol,PERIOD_CURRENT,i);}
double iH(int i){return iHigh(_Symbol,PERIOD_CURRENT,i);}
double iL(int i){return iLow(_Symbol,PERIOD_CURRENT,i);}
double G(int h,int b,int s){double a[];ArraySetAsSeries(a,true);if(CopyBuffer(h,b,s,1,a)<1)return 0;return a[0];}
double WR(){int t=g_wins+g_losses;return t>0?((double)g_wins/t)*100:0;}
string PatName(EPattern p){switch(p){case PAT_PINBAR_BULL:return "BULL PIN BAR ★";case PAT_PINBAR_BEAR:return "BEAR PIN BAR ★";case PAT_ENGULF_BULL:return "BULL ENGULF ★";case PAT_ENGULF_BEAR:return "BEAR ENGULF ★";case PAT_INSIDE_BULL:return "INSIDE BAR▲";case PAT_INSIDE_BEAR:return "INSIDE BAR▼";case PAT_INSIDE_FALSE_BULL:return "FALSE BREAK BULL ★";case PAT_INSIDE_FALSE_BEAR:return "FALSE BREAK BEAR ★";case PAT_MORNING_STAR:return "MORNING STAR ★";case PAT_EVENING_STAR:return "EVENING STAR ★";case PAT_HAMMER:return "HAMMER";case PAT_SHOOTING_STAR:return "SHOOTING STAR";case PAT_DOJI_BULL:return "DRAGONFLY";case PAT_DOJI_BEAR:return "GRAVESTONE";case PAT_HARAMI_BULL:return "BULL HARAMI";case PAT_HARAMI_BEAR:return "BEAR HARAMI";case PAT_TWEEZERS_BULL:return "TWEEZERS BTM";case PAT_TWEEZERS_BEAR:return "TWEEZERS TOP";default:return "scanning...";}}
double LotSize(double sl){double bal=AccountInfoDouble(ACCOUNT_BALANCE),risk=bal*(Risk_Pct/100.0);double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE),ls=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);if(ts==0||tv==0||sl==0)return 0;double vpl=(sl/ts)*tv;if(vpl==0)return 0;return NormalizeDouble(MathMax(mn,MathMin(mx,MathFloor((risk/vpl)/ls)*ls)),2);}
int CountOpenPositions(){int n=0;for(int i=PositionsTotal()-1;i>=0;i--)if(g_pos.SelectByIndex(i))if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic)n++;return n;}
int CountAllTrades(){int n=CountOpenPositions();for(int i=OrdersTotal()-1;i>=0;i--)if(g_order.SelectByIndex(i))if(g_order.Symbol()==_Symbol&&g_order.Magic()==g_magic)n++;return n;}
int GetOpenDirection(){for(int i=PositionsTotal()-1;i>=0;i--){if(g_pos.SelectByIndex(i)){if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic){return(g_pos.PositionType()==POSITION_TYPE_BUY)?1:-1;}}}return 0;}
double GetOpenProfitPts(){double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);for(int i=PositionsTotal()-1;i>=0;i--){if(g_pos.SelectByIndex(i)){if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic){double e=g_pos.PriceOpen(),c=g_pos.PriceCurrent();return(g_pos.PositionType()==POSITION_TYPE_BUY)?(c-e)/pt:(e-c)/pt;}}}return 0;}
void MoveAllToBreakeven(){double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);for(int i=PositionsTotal()-1;i>=0;i--){if(g_pos.SelectByIndex(i)){if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic){double e=g_pos.PriceOpen(),sp=SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)*pt,sl=0;if(g_pos.PositionType()==POSITION_TYPE_BUY){sl=NormalizeDouble(e+sp,_Digits);if(sl>g_pos.StopLoss())g_trade.PositionModify(g_pos.Ticket(),sl,g_pos.TakeProfit());}else{sl=NormalizeDouble(e-sp,_Digits);if(sl<g_pos.StopLoss()||g_pos.StopLoss()==0)g_trade.PositionModify(g_pos.Ticket(),sl,g_pos.TakeProfit());}PrintFormat("BREAKEVEN: #%d → %.5f",g_pos.Ticket(),sl);}}}}
bool InSession(){MqlDateTime t;TimeToStruct(TimeGMT(),t);return(t.hour>=Sess_Start&&t.hour<Sess_End);}
bool DailyLoss(){double c=AccountInfoDouble(ACCOUNT_BALANCE);return(((g_dayBal-c)/g_dayBal)*100.0>=Risk_DailyLoss);}
bool DailyProfit(){return(g_profit>0&&(g_profit/g_dayBal)*100.0>=Risk_DailyProfit);}
void ResetDay(){static datetime l=0;MqlDateTime n;TimeToStruct(TimeCurrent(),n);MqlDateTime ld;TimeToStruct(l,ld);if(n.day!=ld.day||l==0){g_dayBal=AccountInfoDouble(ACCOUNT_BALANCE);g_profit=0;g_consec=0;l=TimeCurrent();PrintFormat("Day reset | Bal:%.2f",g_dayBal);}}
