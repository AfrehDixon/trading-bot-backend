//+------------------------------------------------------------------+
//|  FundedNextEA.mq5  v2.02                                        |
//|  PROP FIRM RULES + PENDING LIMITS + PYRAMIDING RE-ENTRY         |
//|  Re-entry only when Trade 1 in profit + same direction          |
//|  Trade 1 SL moved to breakeven before re-entry                 |
//+------------------------------------------------------------------+
//|  FUNDED ACCOUNT: H1 Forex/Gold (safest for prop firm)          |
//|  STEP INDEX: M5 | VOLATILITY: M15 | BOOM/CRASH: M5             |
//+------------------------------------------------------------------+
#property copyright "DixonAfreh"
#property version   "2.02"
#property strict
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
enum EAccountType{STELLAR_2STEP,STELLAR_1STEP,STELLAR_LITE,CUSTOM};
enum EPhase{PHASE_1,PHASE_2,FUNDED};
input group "=== SERVER CONNECTION ==="
input string Server_URL = "https://odkgh.com/api/trading";
input string API_Key    = "bmpt-your-secret-key-change-this";
input bool   Use_Server = true;

input group "=== FUNDEDNEXT ACCOUNT ==="
input EAccountType AccountType=STELLAR_2STEP;input EPhase CurrentPhase=PHASE_1;input double AccountBalance=5000.0;
input group "=== CUSTOM LIMITS ==="
input double Custom_DailyLossPct=5.0;input double Custom_MaxLossPct=10.0;input double Custom_ProfitTarget=8.0;
input group "=== RISK ==="
input double Risk_Pct=0.5;input int Risk_MaxConsec=3;
input group "=== PYRAMIDING RE-ENTRY ==="
input int    Max_Positions=2;input double Pyramid_MinPts=15.0;input bool Pyramid_Breakeven=true;
input group "=== PENDING LIMIT ==="
input double Limit_Offset_Pts=30.0;input int Limit_Expiry_Bars=3;
input group "=== SMART SL/TP ==="
input double MinRR=3.0;input int Swing_SL_Bars=15;input int SR_TP_Bars=50;input double SL_BufferATR=0.3;
input group "=== INDICATORS ==="
input ENUM_TIMEFRAMES HTF=PERIOD_H4;input int HTF_EMA_Fast=50;input int HTF_EMA_Slow=200;input int EMA_21=21;
input int RSI_Period=14;input double RSI_BuyMin=38.0;input double RSI_BuyMax=65.0;input double RSI_SellMin=35.0;input double RSI_SellMax=62.0;
input int ATR_Period=14;input int ADX_Period=14;input double ADX_Min=18.0;input int BB_Period=20;input double BB_Dev=2.0;
input group "=== PATTERNS ==="
input double PinBar_TailPct=0.58;input double PinBar_BodyPct=0.38;input double Doji_BodyPct=0.10;
input group "=== STRUCTURE ==="
input int Swing_Lookback=8;input int Swing_ScanBars=60;input int Fib_Bars=40;input double Fib_Zone=0.005;input int OB_Lookback=20;
input group "=== CONFLUENCE ==="
input int Min_Score=5;
input group "=== SESSION ==="
input bool Filter_Session=true;input int Sess_Start=7;input int Sess_End=20;
input group "=== SPREAD ==="
input bool Filter_Spread=true;input int MaxSpread_Forex=30;input int MaxSpread_Gold=200;input int MaxSpread_Synth=99999;
input group "=== EXECUTION ==="
input bool AutoTrade=true;input int Slippage=30;input bool ShowDashboard=true;
enum EPattern{PAT_NONE,PAT_PINBAR_BULL,PAT_PINBAR_BEAR,PAT_ENGULF_BULL,PAT_ENGULF_BEAR,PAT_INSIDE_BULL,PAT_INSIDE_BEAR,PAT_MORNING_STAR,PAT_EVENING_STAR,PAT_HAMMER,PAT_SHOOTING_STAR,PAT_DOJI_BULL,PAT_DOJI_BEAR,PAT_DOJI_NEU,PAT_HARAMI_BULL,PAT_HARAMI_BEAR,PAT_TWEEZERS_BULL,PAT_TWEEZERS_BEAR};
enum EStructure{STR_BULL,STR_BEAR,STR_RANGE,STR_NONE};enum EBOS{BOS_BULL,BOS_BEAR,BOS_NONE};enum ESymType{SYM_FOREX,SYM_GOLD,SYM_SYNTH,SYM_OTHER};
struct SPropLimits{double dailyLossPct,maxLossPct,profitTarget,dailyLossAmt,maxLossAmt,profitTargetAmt;int minTradingDays;};
struct SSignal{EStructure str;EBOS bos;bool choch,atFib50,atFib618,atOB;double fib50,fib618;EPattern pattern;bool htfOk,rsiOk,bbEdge,adxOk,isBull;double rsiV,adxV,atr,smartSL,smartTP,rrAchieved;int score;};
int h_htfF,h_htfS,h_ema21,h_rsi,h_atr,h_adx,h_bb;
CTrade g_trade;CPositionInfo g_pos;COrderInfo g_order;
double g_startBal,g_dayStartBal,g_profit,g_dayProfit,g_highestBal;
int g_consec,g_wins,g_losses,g_magic,g_tradingDays,g_brokerWait;
datetime g_lastBar,g_lastTradeDay,g_pendingPlacedBar,g_lastOrderBar;
long g_minStop;ESymType g_symType;SPropLimits g_limits;bool g_targetReached,g_hasPending;ulong g_pendingTicket;
int GenMagic(string s,ENUM_TIMEFRAMES tf){int h=0;for(int i=0;i<StringLen(s);i++)h=h*31+(int)StringGetCharacter(s,i);return MathAbs(h)%90000+10000+(int)tf+2468;}
ESymType DetSym(){string s=_Symbol;StringToLower(s);if(StringFind(s,"xau")>=0||StringFind(s,"gold")>=0)return SYM_GOLD;if(StringFind(s,"eur")>=0||StringFind(s,"gbp")>=0||StringFind(s,"usd")>=0||StringFind(s,"jpy")>=0||StringFind(s,"aud")>=0||StringFind(s,"nzd")>=0)return SYM_FOREX;if(StringFind(s,"step")>=0||StringFind(s,"boom")>=0||StringFind(s,"crash")>=0||StringFind(s,"vol")>=0||StringFind(s,"v75")>=0||StringFind(s,"v10")>=0)return SYM_SYNTH;return SYM_OTHER;}
void SetPropLimits(){double bal=AccountBalance;switch(AccountType){case STELLAR_2STEP:g_limits.dailyLossPct=5.0;g_limits.maxLossPct=10.0;g_limits.profitTarget=(CurrentPhase==PHASE_1)?8.0:(CurrentPhase==PHASE_2)?5.0:0.0;g_limits.minTradingDays=5;break;case STELLAR_1STEP:g_limits.dailyLossPct=3.0;g_limits.maxLossPct=6.0;g_limits.profitTarget=(CurrentPhase==PHASE_1)?10.0:0.0;g_limits.minTradingDays=2;break;case STELLAR_LITE:g_limits.dailyLossPct=4.0;g_limits.maxLossPct=8.0;g_limits.profitTarget=(CurrentPhase==PHASE_1)?8.0:(CurrentPhase==PHASE_2)?4.0:0.0;g_limits.minTradingDays=5;break;default:g_limits.dailyLossPct=Custom_DailyLossPct;g_limits.maxLossPct=Custom_MaxLossPct;g_limits.profitTarget=Custom_ProfitTarget;g_limits.minTradingDays=5;}g_limits.dailyLossAmt=bal*(g_limits.dailyLossPct/100.0);g_limits.maxLossAmt=bal*(g_limits.maxLossPct/100.0);g_limits.profitTargetAmt=bal*(g_limits.profitTarget/100.0);}

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

int OnInit(){g_magic=GenMagic(_Symbol,Period());g_symType=DetSym();g_minStop=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);g_trade.SetExpertMagicNumber(g_magic);g_trade.SetDeviationInPoints(Slippage);g_trade.SetTypeFilling(ORDER_FILLING_IOC);SetPropLimits();h_htfF=iMA(_Symbol,HTF,HTF_EMA_Fast,0,MODE_EMA,PRICE_CLOSE);h_htfS=iMA(_Symbol,HTF,HTF_EMA_Slow,0,MODE_EMA,PRICE_CLOSE);h_ema21=iMA(_Symbol,PERIOD_CURRENT,EMA_21,0,MODE_EMA,PRICE_CLOSE);h_rsi=iRSI(_Symbol,PERIOD_CURRENT,RSI_Period,PRICE_CLOSE);h_atr=iATR(_Symbol,PERIOD_CURRENT,ATR_Period);h_adx=iADX(_Symbol,PERIOD_CURRENT,ADX_Period);h_bb=iBands(_Symbol,PERIOD_CURRENT,BB_Period,0,BB_Dev,PRICE_CLOSE);if(h_htfF==INVALID_HANDLE||h_ema21==INVALID_HANDLE||h_rsi==INVALID_HANDLE||h_atr==INVALID_HANDLE){Print("Indicator FAILED");return INIT_FAILED;}g_startBal=AccountInfoDouble(ACCOUNT_BALANCE);g_dayStartBal=g_startBal;g_highestBal=g_startBal;g_lastBar=0;g_consec=0;g_wins=0;g_losses=0;g_profit=0;g_dayProfit=0;g_tradingDays=0;g_lastTradeDay=0;g_targetReached=false;g_hasPending=false;g_pendingTicket=0;g_pendingPlacedBar=0;g_lastOrderBar=0;g_brokerWait=0;ScanExistingPending();PrintFormat("FundedNextEA v2.02 | %s | %s %s | PYRAMIDING ON",_Symbol,AccTypeName(),PhaseName());PrintFormat("DLL=%.1f%%(%.2f) MLL=%.1f%%(%.2f) Target=%.1f%%(%.2f)",g_limits.dailyLossPct,g_limits.dailyLossAmt,g_limits.maxLossPct,g_limits.maxLossAmt,g_limits.profitTarget,g_limits.profitTargetAmt);return INIT_SUCCEEDED;}
void OnDeinit(const int r){int h[]={h_htfF,h_htfS,h_ema21,h_rsi,h_atr,h_adx,h_bb};for(int i=0;i<ArraySize(h);i++)IndicatorRelease(h[i]);Comment("");}
void OnTick()
{
   datetime bar=iTime(_Symbol,PERIOD_CURRENT,0);if(bar==g_lastBar)return;g_lastBar=bar;
   static int hbCount=0; hbCount++; if(hbCount>=2){hbCount=0;if(Use_Server)ServerHeartbeat("running");}
   ResetDaily();UpdateHighestBal();
   double equity=AccountInfoDouble(ACCOUNT_EQUITY),bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double dayLoss=g_dayStartBal-equity,maxDD=g_highestBal-equity,totalProfit=bal-g_startBal;
   if(dayLoss>=g_limits.dailyLossAmt*0.85){ShowMsg(StringFormat("DAILY LOSS\n$%.2f/$%.2f",dayLoss,g_limits.dailyLossAmt));return;}
   if(maxDD>=g_limits.maxLossAmt*0.85){ShowMsg(StringFormat("MAX DRAWDOWN\n$%.2f/$%.2f",maxDD,g_limits.maxLossAmt));return;}
   if(g_limits.profitTarget>0&&totalProfit>=g_limits.profitTargetAmt){g_targetReached=true;ShowMsg(StringFormat("TARGET HIT!\n+$%.2f=%.1f%%\nSubmit for next phase!",totalProfit,(totalProfit/g_startBal)*100));return;}
   if(g_consec>=Risk_MaxConsec){ShowMsg("MAX LOSSES");return;}
   MqlDateTime t;TimeToStruct(TimeGMT(),t);if(t.day_of_week==5&&t.hour>=20){ShowMsg("FRIDAY CUTOFF");return;}
   if(g_brokerWait>0){g_brokerWait--;return;}
   ManagePending();if(g_hasPending)return;
   if(CountOpenPositions()>0)CheckCHOCHExit();
   if(g_lastOrderBar==iTime(_Symbol,PERIOD_CURRENT,0))return;
   if(Filter_Session&&g_symType==SYM_FOREX&&!InSession()){ShowMsg("OUTSIDE SESSION");return;}
   double sp=(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);int maxSp=(g_symType==SYM_SYNTH)?MaxSpread_Synth:(g_symType==SYM_GOLD)?MaxSpread_Gold:MaxSpread_Forex;if(Filter_Spread&&sp>maxSp){ShowMsg(StringFormat("SPREAD WIDE: %d > %d",(int)sp,maxSp));return;}
   int openPos=CountOpenPositions(),totalAll=CountAllTrades();
   if(totalAll>=Max_Positions)return;
   SSignal sig;if(!Evaluate(sig))return;
   if(ShowDashboard)Dashboard(sig,dayLoss,maxDD,totalProfit,bal,openPos);
   if(sig.pattern==PAT_NONE||sig.score<Min_Score)return;
   // Pyramiding re-entry
   if(openPos==1&&Max_Positions>=2)
   {
      int dir=GetOpenDirection();double profitPts=GetOpenProfitPts();
      if(profitPts>=Pyramid_MinPts)
      {
         bool reBuy=(dir==1&&sig.isBull&&AutoTrade),reSell=(dir==-1&&!sig.isBull&&AutoTrade);
         if(reBuy||reSell){if(Pyramid_Breakeven)MoveAllToBreakeven();if(reBuy)PlaceLimitOrder(ORDER_TYPE_BUY_LIMIT,sig,true);if(reSell)PlaceLimitOrder(ORDER_TYPE_SELL_LIMIT,sig,true);}
      }
      return;
   }
   // Normal entry
   if(openPos==0){if(sig.isBull&&AutoTrade)PlaceLimitOrder(ORDER_TYPE_BUY_LIMIT,sig,false);else if(!sig.isBull&&AutoTrade)PlaceLimitOrder(ORDER_TYPE_SELL_LIMIT,sig,false);}
}
void PlaceLimitOrder(ENUM_ORDER_TYPE type,const SSignal &sig,bool isPyramid){if(g_hasPending){Print("BLOCKED");return;}double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT),offset=Limit_Offset_Pts*pt;double limitPrice,sl=sig.smartSL,tp=sig.smartTP;if(type==ORDER_TYPE_BUY_LIMIT){limitPrice=NormalizeDouble(bid-offset,_Digits);if(sl>=limitPrice)sl=NormalizeDouble(limitPrice-(g_minStop+15)*pt,_Digits);}else{limitPrice=NormalizeDouble(bid+offset,_Digits);if(sl<=limitPrice)sl=NormalizeDouble(limitPrice+(g_minStop+15)*pt,_Digits);}double slPt=MathAbs(limitPrice-sl)/pt,tpPt=MathAbs(limitPrice-tp)/pt;if(slPt<g_minStop+5||tpPt<g_minStop+5){PrintFormat("SKIP min=%d",g_minStop);return;}double lot=LotSize(MathAbs(limitPrice-sl));if(lot<=0)return;string dir=(type==ORDER_TYPE_BUY_LIMIT)?"BUY LIMIT":"SELL LIMIT";string tag=isPyramid?"PYRAMID":"ENTRY";bool ok=(type==ORDER_TYPE_BUY_LIMIT)?g_trade.BuyLimit(lot,limitPrice,_Symbol,sl,tp,ORDER_TIME_GTC,0,"FN|"+tag):g_trade.SellLimit(lot,limitPrice,_Symbol,sl,tp,ORDER_TIME_GTC,0,"FN|"+tag);if(ok){g_pendingTicket=g_trade.ResultOrder();g_hasPending=true;g_pendingPlacedBar=iTime(_Symbol,PERIOD_CURRENT,0);g_lastOrderBar=g_pendingPlacedBar;g_brokerWait=5;datetime today=StringToTime(TimeToString(TimeCurrent(),TIME_DATE));if(today!=g_lastTradeDay){g_tradingDays++;g_lastTradeDay=today;}PrintFormat("%s %s Lot:%.2f At:%.5f SL:%.5f TP:%.5f RR:1:%.1f Score:%d/7",tag,dir,lot,limitPrice,sl,tp,sig.rrAchieved,sig.score);}else PrintFormat("FAILED err:%d",GetLastError());}
void ManagePending(){if(!g_hasPending)return;bool found=false;for(int i=OrdersTotal()-1;i>=0;i--){if(g_order.SelectByIndex(i)&&g_order.Ticket()==g_pendingTicket){found=true;ENUM_ORDER_STATE st=(ENUM_ORDER_STATE)g_order.State();if(st==ORDER_STATE_FILLED||st==ORDER_STATE_CANCELED||st==ORDER_STATE_EXPIRED||st==ORDER_STATE_REJECTED){g_hasPending=false;g_pendingTicket=0;return;}break;}}if(!found&&HistoryOrderSelect(g_pendingTicket)){ENUM_ORDER_STATE st=(ENUM_ORDER_STATE)HistoryOrderGetInteger(g_pendingTicket,ORDER_STATE);if(st==ORDER_STATE_FILLED||st==ORDER_STATE_CANCELED||st==ORDER_STATE_EXPIRED||st==ORDER_STATE_REJECTED){g_hasPending=false;g_pendingTicket=0;return;}}int barsPassed=0;for(int i=0;i<200;i++){if(iTime(_Symbol,PERIOD_CURRENT,i)<=g_pendingPlacedBar){barsPassed=i;break;}}if(barsPassed>=Limit_Expiry_Bars){if(g_trade.OrderDelete(g_pendingTicket))Print("CANCELLED");g_hasPending=false;g_pendingTicket=0;}}

void CheckCHOCHExit(){
   int dir=GetOpenDirection();if(dir==0)return;
   double cur=iC(1),rH=0,rL=0;
   for(int i=2;i<Swing_Lookback*3;i++){if(iH(i)>rH)rH=iH(i);if(rL==0||iL(i)<rL)rL=iL(i);}
   bool choch=false;
   double sH=0,sL=0;EStructure str=DetStr(sH,sL);
   if(dir==1&&str==STR_BULL&&cur<rL)choch=true;
   if(dir==-1&&str==STR_BEAR&&cur>rH)choch=true;
   if(!choch)return;
   PrintFormat("CHOCH DETECTED — closing all trades");
   for(int i=PositionsTotal()-1;i>=0;i--){
      if(g_pos.SelectByIndex(i)){
         if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic){
            if(g_trade.PositionClose(g_pos.Ticket()))
               PrintFormat("CHOCH EXIT: #%d closed P/L:%.2f",g_pos.Ticket(),g_pos.Profit());
         }
      }
   }
   if(g_hasPending){
      if(g_trade.OrderDelete(g_pendingTicket))Print("PENDING CANCELLED on CHOCH");
      g_hasPending=false;g_pendingTicket=0;
   }
}

void ScanExistingPending(){for(int i=OrdersTotal()-1;i>=0;i--){if(g_order.SelectByIndex(i)){if(g_order.Symbol()==_Symbol&&g_order.Magic()==g_magic){g_hasPending=true;g_pendingTicket=g_order.Ticket();g_pendingPlacedBar=iTime(_Symbol,PERIOD_CURRENT,0);g_lastOrderBar=iTime(_Symbol,PERIOD_CURRENT,0);PrintFormat("FOUND existing pending: #%d at %.5f",g_pendingTicket,g_order.PriceOpen());return;}}}Print("No existing pending on restart");}
int GetOpenDirection(){for(int i=PositionsTotal()-1;i>=0;i--){if(g_pos.SelectByIndex(i)){if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic){return(g_pos.PositionType()==POSITION_TYPE_BUY)?1:-1;}}}return 0;}
double GetOpenProfitPts(){double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);for(int i=PositionsTotal()-1;i>=0;i--){if(g_pos.SelectByIndex(i)){if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic){double e=g_pos.PriceOpen(),c=g_pos.PriceCurrent();return(g_pos.PositionType()==POSITION_TYPE_BUY)?(c-e)/pt:(e-c)/pt;}}}return 0;}
void MoveAllToBreakeven(){double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);for(int i=PositionsTotal()-1;i>=0;i--){if(g_pos.SelectByIndex(i)){if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic){double e=g_pos.PriceOpen(),sp=SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)*pt,sl=0;if(g_pos.PositionType()==POSITION_TYPE_BUY){sl=NormalizeDouble(e+sp,_Digits);if(sl>g_pos.StopLoss())g_trade.PositionModify(g_pos.Ticket(),sl,g_pos.TakeProfit());}else{sl=NormalizeDouble(e-sp,_Digits);if(sl<g_pos.StopLoss()||g_pos.StopLoss()==0)g_trade.PositionModify(g_pos.Ticket(),sl,g_pos.TakeProfit());}PrintFormat("BREAKEVEN: #%d SL→%.5f",g_pos.Ticket(),sl);}}}}
double SmartSL(bool bull,double atr){double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT),buf=atr*SL_BufferATR,minD=(g_minStop+10)*pt,cur=iC(1);if(bull){double lo=99999999;for(int i=1;i<=Swing_SL_Bars;i++)if(iL(i)<lo)lo=iL(i);double sl=lo-buf;if(cur-sl<minD)sl=cur-minD;return NormalizeDouble(sl,_Digits);}else{double hi=0;for(int i=1;i<=Swing_SL_Bars;i++)if(iH(i)>hi)hi=iH(i);double sl=hi+buf;if(sl-cur<minD)sl=cur+minD;return NormalizeDouble(sl,_Digits);}}
double SmartTP(bool bull,double sl,double atr){double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT),cur=iC(1),slDist=MathAbs(cur-sl),minTP=slDist*MinRR,minD=(g_minStop+10)*pt;double best=0;if(bull){double cl=999999999;for(int i=3;i<=SR_TP_Bars;i++){double h=iH(i),hP=iH(i-1),hN=iH(i+1);if(h>hP&&h>hN&&h>cur+minTP&&h<cl)cl=h;}best=(cl<999999999)?cl:cur+minTP;if(best-cur<minD*3)best=cur+minD*3;}else{double cl=-999999999;for(int i=3;i<=SR_TP_Bars;i++){double l=iL(i),lP=iL(i-1),lN=iL(i+1);if(l<lP&&l<lN&&l<cur-minTP&&l>cl)cl=l;}best=(cl>-999999999)?cl:cur-minTP;if(cur-best<minD*3)best=cur-minD*3;}return NormalizeDouble(best,_Digits);}
EPattern DetPinBar(int s){double o=iO(s),c=iC(s),h=iH(s),l=iL(s),rng=h-l;if(rng<=0)return PAT_NONE;double body=MathAbs(c-o),upW=h-MathMax(o,c),loW=MathMin(o,c)-l;if(body/rng>PinBar_BodyPct)return PAT_NONE;if(loW/rng>=PinBar_TailPct&&loW>upW*2)return PAT_PINBAR_BULL;if(upW/rng>=PinBar_TailPct&&upW>loW*2)return PAT_PINBAR_BEAR;return PAT_NONE;}
EPattern DetEngulf(int s){double o1=iO(s),c1=iC(s),o2=iO(s+1),c2=iC(s+1);if(MathAbs(c1-o1)==0||MathAbs(c2-o2)==0)return PAT_NONE;if(c1>o1&&c2<o2&&c1>=o2&&o1<=c2)return PAT_ENGULF_BULL;if(c1<o1&&c2>o2&&o1>=c2&&c1<=o2)return PAT_ENGULF_BEAR;return PAT_NONE;}
EPattern DetInside(int s,bool b){if(iH(s)<iH(s+1)&&iL(s)>iL(s+1))return b?PAT_INSIDE_BULL:PAT_INSIDE_BEAR;return PAT_NONE;}
EPattern DetMorn(int s){double o1=iO(s+2),c1=iC(s+2),o2=iO(s+1),c2=iC(s+1),o3=iO(s),c3=iC(s),r1=MathAbs(o1-c1),r2=MathAbs(o2-c2);if(r1==0)return PAT_NONE;if(c1<o1&&r2<r1*0.5&&c3>o3&&c3>(o1+c1)/2.0)return PAT_MORNING_STAR;return PAT_NONE;}
EPattern DetEve(int s){double o1=iO(s+2),c1=iC(s+2),o2=iO(s+1),c2=iC(s+1),o3=iO(s),c3=iC(s),r1=MathAbs(o1-c1),r2=MathAbs(o2-c2);if(r1==0)return PAT_NONE;if(c1>o1&&r2<r1*0.5&&c3<o3&&c3<(o1+c1)/2.0)return PAT_EVENING_STAR;return PAT_NONE;}
EPattern DetHamm(int s){double o=iO(s),c=iC(s),h=iH(s),l=iL(s),rng=h-l;if(rng<=0)return PAT_NONE;double body=MathAbs(c-o),loW=MathMin(o,c)-l,upW=h-MathMax(o,c);if(body/rng<=0.30&&loW/rng>=0.60&&loW>upW*2)return PAT_HAMMER;return PAT_NONE;}
EPattern DetShoot(int s){double o=iO(s),c=iC(s),h=iH(s),l=iL(s),rng=h-l;if(rng<=0)return PAT_NONE;double body=MathAbs(c-o),loW=MathMin(o,c)-l,upW=h-MathMax(o,c);if(body/rng<=0.30&&upW/rng>=0.60&&upW>loW*2)return PAT_SHOOTING_STAR;return PAT_NONE;}
EPattern DetDoji(int s){double o=iO(s),c=iC(s),h=iH(s),l=iL(s),rng=h-l;if(rng<=0)return PAT_NONE;double body=MathAbs(c-o);if(body/rng>Doji_BodyPct)return PAT_NONE;double upW=h-MathMax(o,c),loW=MathMin(o,c)-l;if(loW/rng>=0.60&&upW<body*2)return PAT_DOJI_BULL;if(upW/rng>=0.60&&loW<body*2)return PAT_DOJI_BEAR;return PAT_DOJI_NEU;}
EPattern DetHaram(int s){double o1=iO(s),c1=iC(s),o2=iO(s+1),c2=iC(s+1);if(MathAbs(c2-o2)==0)return PAT_NONE;if(MathMax(o1,c1)<MathMax(o2,c2)&&MathMin(o1,c1)>MathMin(o2,c2)){if(c2<o2&&c1>o1)return PAT_HARAMI_BULL;if(c2>o2&&c1<o1)return PAT_HARAMI_BEAR;}return PAT_NONE;}
EPattern DetTweez(int s){double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT)*3;if(MathAbs(iL(s)-iL(s+1))<=pt&&iC(s+1)<iO(s+1)&&iC(s)>iO(s))return PAT_TWEEZERS_BULL;if(MathAbs(iH(s)-iH(s+1))<=pt&&iC(s+1)>iO(s+1)&&iC(s)<iO(s))return PAT_TWEEZERS_BEAR;return PAT_NONE;}
EPattern DetPat(bool bull){EPattern p;p=DetPinBar(1);if(p!=PAT_NONE)return p;p=DetEngulf(1);if(p!=PAT_NONE)return p;p=DetMorn(1);if(p!=PAT_NONE)return p;p=DetEve(1);if(p!=PAT_NONE)return p;p=DetHamm(1);if(p!=PAT_NONE)return p;p=DetShoot(1);if(p!=PAT_NONE)return p;p=DetDoji(1);if(p!=PAT_NONE)return p;p=DetTweez(1);if(p!=PAT_NONE)return p;p=DetHaram(1);if(p!=PAT_NONE)return p;p=DetInside(1,bull);if(p!=PAT_NONE)return p;return PAT_NONE;}
void AdjDir(SSignal &s){if(s.pattern==PAT_PINBAR_BULL||s.pattern==PAT_ENGULF_BULL||s.pattern==PAT_INSIDE_BULL||s.pattern==PAT_MORNING_STAR||s.pattern==PAT_HAMMER||s.pattern==PAT_DOJI_BULL||s.pattern==PAT_HARAMI_BULL||s.pattern==PAT_TWEEZERS_BULL)s.isBull=true;if(s.pattern==PAT_PINBAR_BEAR||s.pattern==PAT_ENGULF_BEAR||s.pattern==PAT_INSIDE_BEAR||s.pattern==PAT_EVENING_STAR||s.pattern==PAT_SHOOTING_STAR||s.pattern==PAT_DOJI_BEAR||s.pattern==PAT_HARAMI_BEAR||s.pattern==PAT_TWEEZERS_BEAR)s.isBull=false;}
EStructure DetStr(double &sH,double &sL){double sh[2]={0,0},sl2[2]={0,0};int shb[2]={0,0},slb[2]={0,0},shc=0,slc=0;for(int i=2;i<Swing_ScanBars-1&&(shc<2||slc<2);i++){if(iH(i)>iH(i-1)&&iH(i)>iH(i+1)&&shc<2)if(shc==0||i>shb[0]+Swing_Lookback){sh[shc]=iH(i);shb[shc]=i;shc++;}if(iL(i)<iL(i-1)&&iL(i)<iL(i+1)&&slc<2)if(slc==0||i>slb[0]+Swing_Lookback){sl2[slc]=iL(i);slb[slc]=i;slc++;}}sH=sh[0];sL=sl2[0];if(shc<2||slc<2)return STR_NONE;if(sh[0]>sh[1]&&sl2[0]>sl2[1])return STR_BULL;if(sh[0]<sh[1]&&sl2[0]<sl2[1])return STR_BEAR;return STR_RANGE;}
EBOS DetBOS(EStructure str,bool &choch){choch=false;if(str==STR_NONE)return BOS_NONE;double cur=iC(1),rH=0,rL=0;for(int i=2;i<Swing_Lookback*3;i++){if(iH(i)>rH)rH=iH(i);if(rL==0||iL(i)<rL)rL=iL(i);}if(str==STR_BULL&&cur>rH)return BOS_BULL;if(str==STR_BEAR&&cur<rL)return BOS_BEAR;if(str==STR_BULL&&cur<rL)choch=true;if(str==STR_BEAR&&cur>rH)choch=true;return BOS_NONE;}
void CalcFib(EStructure str,double &f50,double &f618,bool &at50,bool &at618){f50=0;f618=0;at50=false;at618=false;double swH=0,swL=0;for(int i=1;i<Fib_Bars;i++){if(iH(i)>swH)swH=iH(i);if(swL==0||iL(i)<swL)swL=iL(i);}if(swH==0||swL==0)return;double rng=swH-swL,cur=iC(1);f50=str==STR_BULL?swH-0.500*rng:swL+0.500*rng;f618=str==STR_BULL?swH-0.618*rng:swL+0.618*rng;double z=rng*Fib_Zone;at50=(MathAbs(cur-f50)<=z);at618=(MathAbs(cur-f618)<=z);}
bool DetOB(EStructure str){double cur=iC(1),pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);for(int i=3;i<OB_Lookback;i++){double o=iO(i),c=iC(i),op=iO(i+1),cp=iC(i+1);if(str==STR_BULL&&c>o&&cp<op){double h=MathMax(op,cp),l=MathMin(op,cp),z=(h-l)*0.5+pt*5;if(cur>=l-z&&cur<=h+z)return true;break;}if(str==STR_BEAR&&c<o&&cp>op){double h=MathMax(op,cp),l=MathMin(op,cp),z=(h-l)*0.5+pt*5;if(cur>=l-z&&cur<=h+z)return true;break;}}return false;}
bool Evaluate(SSignal &s){double htfF=Buf(h_htfF,0,1),htfS=Buf(h_htfS,0,1),e21=Buf(h_ema21,0,1),rsi=Buf(h_rsi,0,1),atr=Buf(h_atr,0,1),adx=Buf(h_adx,0,1);double bbU=Buf(h_bb,UPPER_BAND,1),bbL=Buf(h_bb,LOWER_BAND,1),cur=iC(1),lo1=iL(1),hi1=iH(1);if(rsi==0||atr==0||e21==0)return false;s.rsiV=rsi;s.adxV=adx;s.atr=atr;double sH=0,sL=0;s.str=DetStr(sH,sL);s.isBull=(s.str==STR_BULL)||(s.str==STR_RANGE&&htfF>htfS);bool ch=false;s.bos=DetBOS(s.str,ch);s.choch=ch;CalcFib(s.str,s.fib50,s.fib618,s.atFib50,s.atFib618);s.atOB=DetOB(s.str);s.pattern=DetPat(s.isBull);AdjDir(s);s.htfOk=(s.isBull==(htfF>htfS));s.rsiOk=s.isBull?(rsi>=RSI_BuyMin&&rsi<=RSI_BuyMax):(rsi>=RSI_SellMin&&rsi<=RSI_SellMax);s.adxOk=(adx>=ADX_Min);s.bbEdge=s.isBull?(lo1<=bbL*1.002):(hi1>=bbU*0.998);s.score=0;if(s.htfOk)s.score++;if(s.str!=STR_NONE)s.score++;if((s.isBull&&s.bos==BOS_BULL)||(!s.isBull&&s.bos==BOS_BEAR))s.score++;if(s.atFib50||s.atFib618)s.score++;if(s.atOB)s.score++;if(s.rsiOk)s.score++;if(s.bbEdge||s.adxOk)s.score++;s.smartSL=SmartSL(s.isBull,atr);s.smartTP=SmartTP(s.isBull,s.smartSL,atr);double slD=MathAbs(cur-s.smartSL),tpD=MathAbs(cur-s.smartTP);s.rrAchieved=(slD>0)?tpD/slD:0;return true;}
void OnTradeTransaction(const MqlTradeTransaction &t,const MqlTradeRequest &req,const MqlTradeResult &res){if(t.type!=TRADE_TRANSACTION_DEAL_ADD)return;if(!HistoryDealSelect(t.deal))return;if(HistoryDealGetInteger(t.deal,DEAL_MAGIC)!=g_magic)return;if(HistoryDealGetInteger(t.deal,DEAL_ENTRY)==DEAL_ENTRY_IN){g_hasPending=false;g_brokerWait=0;PrintFormat("LIMIT FILLED at %.5f",HistoryDealGetDouble(t.deal,DEAL_PRICE));return;}if(HistoryDealGetInteger(t.deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT)return;double p=HistoryDealGetDouble(t.deal,DEAL_PROFIT);g_profit+=p;g_dayProfit+=p;if(p>=0){g_wins++;g_consec=0;}else{g_losses++;g_consec++;}PrintFormat("%s %.2f W:%d L:%d WR:%.1f%%",p>=0?"WIN":"LOSS",p,g_wins,g_losses,WR());}
void Dashboard(const SSignal &s,double dayLoss,double dd,double totalProfit,double bal,int openPos){double dll=(g_limits.dailyLossAmt>0)?(dayLoss/g_limits.dailyLossAmt)*100:0,mll=(g_limits.maxLossAmt>0)?(dd/g_limits.maxLossAmt)*100:0,tgt=(g_limits.profitTargetAmt>0)?(totalProfit/g_limits.profitTargetAmt)*100:0;double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);double pp=GetOpenProfitPts();int dir=GetOpenDirection();string pyInfo=(openPos==1)?StringFormat("Profit:%.0fpts(need %.0f) Dir:%s",pp,Pyramid_MinPts,dir==1?"BUY":"SELL"):"—";string fire=(s.score>=Min_Score&&s.pattern!=PAT_NONE)?(s.isBull?" BUY LIMIT!":" SELL LIMIT!"):"";Comment(StringFormat("FUNDEDNEXT EA v2.02\n%s|%s|%s\nBrokerWait:%d Pending:%s\nBUY:%.5f SELL:%.5f\nDLL:$%.2f/$%.2f(%.0f%%)%s\nMLL:$%.2f/$%.2f(%.0f%%)%s\nProfit:$%.2f/$%.2f(%.0f%%)%s\nDays:%d/%d\n═══ PYRAMID ═══\nPositions:%d/%d %s\n═══ SIGNAL ═══\nSL:%.5f←%s TP:%.5f RR:1:%.1f\nHTF:%s Str:%s BOS:%s\nFib:%s OB:%s Pat:%s\nRSI:%.1f%s ADX:%.1f Score:%d/%d%s\nDir:%s\nW:%d L:%d WR:%.1f%% Consec:%d/%d",_Symbol,AccTypeName(),PhaseName(),g_brokerWait,g_hasPending?"WAITING":"none",bid-Limit_Offset_Pts*pt,bid+Limit_Offset_Pts*pt,dayLoss,g_limits.dailyLossAmt,dll,dll>70?"WARN":"ok",dd,g_limits.maxLossAmt,mll,mll>70?"WARN":"ok",MathMax(0,totalProfit),g_limits.profitTargetAmt,MathMax(0,tgt),g_targetReached?"TARGET HIT!":tgt>80?"CLOSE!":"",g_tradingDays,g_limits.minTradingDays,openPos,Max_Positions,pyInfo,s.smartSL,s.isBull?"LOW":"HIGH",s.smartTP,s.rrAchieved,s.htfOk?"ALIGNED":"against",s.str==STR_BULL?"UPTREND":s.str==STR_BEAR?"DOWNTREND":"RANGE",s.bos==BOS_BULL?"BULL BOS":s.bos==BOS_BEAR?"BEAR BOS":"none",s.atFib50?"50%":s.atFib618?"61.8%":"—",s.atOB?"IN OB":"—",PatName(s.pattern),s.rsiV,s.rsiOk?"ok":"—",s.adxV,s.score,Min_Score,fire,s.isBull?"LONG":"SHORT",g_wins,g_losses,WR(),g_consec,Risk_MaxConsec));}
void ShowMsg(string m){Comment("FUNDEDNEXT EA v2.02\n"+m);}
string AccTypeName(){switch(AccountType){case STELLAR_2STEP:return "2-Step";case STELLAR_1STEP:return "1-Step";case STELLAR_LITE:return "Lite";default:return "Custom";}}
string PhaseName(){switch(CurrentPhase){case PHASE_1:return "Phase1";case PHASE_2:return "Phase2";default:return "Funded";}}
string PatName(EPattern p){switch(p){case PAT_PINBAR_BULL:return "BULL PIN BAR";case PAT_PINBAR_BEAR:return "BEAR PIN BAR";case PAT_ENGULF_BULL:return "BULL ENGULF";case PAT_ENGULF_BEAR:return "BEAR ENGULF";case PAT_INSIDE_BULL:return "INSIDE▲";case PAT_INSIDE_BEAR:return "INSIDE▼";case PAT_MORNING_STAR:return "MORNING★";case PAT_EVENING_STAR:return "EVENING★";case PAT_HAMMER:return "HAMMER";case PAT_SHOOTING_STAR:return "SHOOTING";case PAT_DOJI_BULL:return "DRAGONFLY";case PAT_DOJI_BEAR:return "GRAVESTONE";case PAT_DOJI_NEU:return "DOJI";case PAT_HARAMI_BULL:return "BULL HARAMI";case PAT_HARAMI_BEAR:return "BEAR HARAMI";case PAT_TWEEZERS_BULL:return "TWEEZERS BTM";case PAT_TWEEZERS_BEAR:return "TWEEZERS TOP";default:return "scanning...";}}
double iO(int s){return iOpen(_Symbol,PERIOD_CURRENT,s);}double iC(int s){return iClose(_Symbol,PERIOD_CURRENT,s);}double iH(int s){return iHigh(_Symbol,PERIOD_CURRENT,s);}double iL(int s){return iLow(_Symbol,PERIOD_CURRENT,s);}
double Buf(int h,int b,int s){double a[];ArraySetAsSeries(a,true);if(CopyBuffer(h,b,s,1,a)<1)return 0;return a[0];}
double WR(){int t=g_wins+g_losses;return t>0?((double)g_wins/t)*100:0;}
double LotSize(double sl){double bal=AccountInfoDouble(ACCOUNT_BALANCE),risk=bal*(Risk_Pct/100.0);double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE),ls=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);if(ts==0||tv==0||sl==0)return 0;double vpl=(sl/ts)*tv;if(vpl==0)return 0;return NormalizeDouble(MathMax(mn,MathMin(mx,MathFloor((risk/vpl)/ls)*ls)),2);}
int CountOpenPositions(){int n=0;for(int i=PositionsTotal()-1;i>=0;i--)if(g_pos.SelectByIndex(i))if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic)n++;return n;}
int CountAllTrades(){int n=CountOpenPositions();for(int i=OrdersTotal()-1;i>=0;i--)if(g_order.SelectByIndex(i))if(g_order.Symbol()==_Symbol&&g_order.Magic()==g_magic)n++;return n;}
bool InSession(){MqlDateTime t;TimeToStruct(TimeGMT(),t);return(t.hour>=Sess_Start&&t.hour<Sess_End);}
void UpdateHighestBal(){double b=AccountInfoDouble(ACCOUNT_BALANCE);if(b>g_highestBal)g_highestBal=b;}
void ResetDaily(){static datetime l=0;MqlDateTime n;TimeToStruct(TimeCurrent(),n);MqlDateTime ld;TimeToStruct(l,ld);if(n.day!=ld.day||l==0){g_dayStartBal=AccountInfoDouble(ACCOUNT_BALANCE);g_dayProfit=0;g_consec=0;l=TimeCurrent();SetPropLimits();PrintFormat("Day reset Bal:%.2f DLL:$%.2f MLL:$%.2f Target:$%.2f",g_dayStartBal,g_limits.dailyLossAmt,g_limits.maxLossAmt,g_limits.profitTargetAmt);}}
