//+------------------------------------------------------------------+
//|  EA2_ScalpElite.mq5                                             |
//|  FAST SCALPING — M1 / M5 — ALL MARKETS                        |
//|  RSI + BB + EMA cross + Pattern                                |
//|  Reports to BMPT backend server                                |
//+------------------------------------------------------------------+
#property copyright "DixonAfreh / BMPT"
#property version   "1.00"
#property strict
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

input group "=== SERVER ==="
input string Server_URL = "https://odkgh.com/api/trading";
input string API_Key    = "bmpt-your-secret-key-change-this";
input bool   Use_Server = true;

input group "=== RISK ==="
input double Risk_Pct       = 1.0;
input double Risk_DailyLoss = 5.0;
input double Risk_DailyProfit=10.0;
input int    Risk_MaxConsec = 4;

input group "=== SCALP ==="
input int    Max_Positions  = 2;
input double Pyramid_MinPts = 10.0;
input double Limit_Offset   = 8.0;
input int    Limit_Expiry   = 2;
input double ATR_SL         = 1.0;
input double ATR_TP         = 2.5;
input double MinRR          = 2.0;

input group "=== INDICATORS ==="
input int    RSI_Period = 7;
input double RSI_OB     = 72.0;
input double RSI_OS     = 28.0;
input int    EMA_Fast   = 8;
input int    EMA_Slow   = 21;
input int    BB_Period  = 14;
input double BB_Dev     = 2.0;
input int    ATR_Period = 7;
input int    Tick_Count = 2;
input int    Min_Score  = 2;

input group "=== EXECUTION ==="
input bool   AutoTrade = true;
input int    Slippage  = 50;
input bool   ShowDash  = true;

int h_rsi,h_emaF,h_emaS,h_bb,h_atr;
CTrade g_trade;CPositionInfo g_pos;COrderInfo g_order;
double g_dayBal,g_lastBid,g_profit;
int    g_upTicks,g_dnTicks,g_consec,g_wins,g_losses,g_magic,g_bwait;
datetime g_ppBar,g_loBar,g_lastDash;
long   g_minStop;bool g_hasPend;ulong g_pendTick;

int GenMagic(string s,ENUM_TIMEFRAMES tf){int h=0;for(int i=0;i<StringLen(s);i++)h=h*31+(int)StringGetCharacter(s,i);return MathAbs(h)%90000+10000+(int)tf+8888;}

int OnInit(){
   g_magic=GenMagic(_Symbol,Period());
   g_trade.SetExpertMagicNumber(g_magic);g_trade.SetDeviationInPoints(Slippage);g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_minStop=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   h_rsi =iRSI(_Symbol,PERIOD_CURRENT,RSI_Period,PRICE_CLOSE);
   h_emaF=iMA(_Symbol,PERIOD_CURRENT,EMA_Fast,0,MODE_EMA,PRICE_CLOSE);
   h_emaS=iMA(_Symbol,PERIOD_CURRENT,EMA_Slow,0,MODE_EMA,PRICE_CLOSE);
   h_bb  =iBands(_Symbol,PERIOD_CURRENT,BB_Period,0,BB_Dev,PRICE_CLOSE);
   h_atr =iATR(_Symbol,PERIOD_CURRENT,ATR_Period);
   if(h_rsi==INVALID_HANDLE||h_atr==INVALID_HANDLE){Print("Handle FAILED");return INIT_FAILED;}
   g_dayBal=AccountInfoDouble(ACCOUNT_BALANCE);g_lastBid=0;g_upTicks=g_dnTicks=0;
   g_consec=g_wins=g_losses=g_bwait=0;g_profit=0;g_hasPend=false;g_pendTick=0;
   g_ppBar=g_loBar=g_lastDash=0;
   ScanPend();
   if(Use_Server)ServerPost("/api/trading/ea/heartbeat",
      StringFormat("{\"ea_name\":\"ScalpElite\",\"symbol\":\"%s\",\"timeframe\":\"%s\",\"balance\":%.2f,\"equity\":%.2f,\"message\":\"OnInit\"}",
      _Symbol,EnumToString(Period()),AccountInfoDouble(ACCOUNT_BALANCE),AccountInfoDouble(ACCOUNT_EQUITY)));
   return INIT_SUCCEEDED;
}
void OnDeinit(const int r){IndicatorRelease(h_rsi);IndicatorRelease(h_emaF);IndicatorRelease(h_emaS);IndicatorRelease(h_bb);IndicatorRelease(h_atr);Comment("");}

void OnTick(){
   ResetDay();
   static int hbCount=0; hbCount++; if(hbCount>=10){hbCount=0;if(Use_Server)ServerHeartbeat("running");}
   if(DailyLoss()){ShowMsg("DAILY LOSS");return;}
   if(DailyProfit()){ShowMsg("DAILY PROFIT");return;}
   if(g_consec>=Risk_MaxConsec){ShowMsg("MAX LOSSES");return;}
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(g_lastBid>0){if(bid>g_lastBid){g_upTicks++;g_dnTicks=0;}else if(bid<g_lastBid){g_dnTicks++;g_upTicks=0;}}
   g_lastBid=bid;
   if(g_bwait>0){g_bwait--;return;}
   ManagePend();
   if(g_hasPend)return;
   int op=CountOpen(),all=CountAll();
   if(all>=Max_Positions)return;
   double rsi=G(h_rsi,0,0),emaF=G(h_emaF,0,0),emaS=G(h_emaS,0,0);
   double bbU=G(h_bb,UPPER_BAND,0),bbL=G(h_bb,LOWER_BAND,0),atr=G(h_atr,0,1);
   if(rsi==0||emaF==0||atr==0)return;
   double slD=MathMax(atr*ATR_SL,(g_minStop+5)*pt),tpD=MathMax(slD*MinRR,(g_minStop+5)*pt*2);
   bool doBuy =(rsi<=RSI_OS&&bid<=bbL&&emaF>emaS&&g_upTicks>=Tick_Count)||(rsi<=RSI_OS+5&&emaF>emaS&&g_dnTicks>=Tick_Count+1);
   bool doSell=(rsi>=RSI_OB&&bid>=bbU&&emaF<emaS&&g_dnTicks>=Tick_Count)||(rsi>=RSI_OB-5&&emaF<emaS&&g_upTicks>=Tick_Count+1);
   int score=(doBuy||doSell)?1:0;
   if(emaF>emaS&&doBuy)score++;if(emaF<emaS&&doSell)score++;
   if(rsi<=RSI_OS&&doBuy)score++;if(rsi>=RSI_OB&&doSell)score++;
   datetime now=TimeCurrent();
   if(ShowDash&&now>g_lastDash){g_lastDash=now;
      Comment(StringFormat("SCALP ELITE v1.0\n%s %s\nBUY:%.5f SELL:%.5f\nRSI:%.1f EMA:%s\nScore:%d/%d UpTick:%d DnTick:%d\nPending:%s BrokerWait:%d\nP/L:%.2f W:%d L:%d WR:%.0f%%",
         _Symbol,EnumToString(Period()),bid-Limit_Offset*pt,bid+Limit_Offset*pt,rsi,emaF>emaS?"BULL":"BEAR",score,Min_Score,g_upTicks,g_dnTicks,g_hasPend?"YES":"no",g_bwait,g_profit,g_wins,g_losses,WR()));}
   if(score<Min_Score)return;
   if(op==1){
      int dir=GetDir();double pp=GetProf(pt);
      if(pp>=Pyramid_MinPts){
         if(dir==1&&doBuy&&AutoTrade)PlaceOrder(ORDER_TYPE_BUY_LIMIT,bid,slD,tpD,pt);
         if(dir==-1&&doSell&&AutoTrade)PlaceOrder(ORDER_TYPE_SELL_LIMIT,bid,slD,tpD,pt);
      }return;
   }
   if(op==0){
      if(doBuy&&!doSell&&AutoTrade)PlaceOrder(ORDER_TYPE_BUY_LIMIT,bid,slD,tpD,pt);
      else if(doSell&&!doBuy&&AutoTrade)PlaceOrder(ORDER_TYPE_SELL_LIMIT,bid,slD,tpD,pt);
   }
}

void PlaceOrder(ENUM_ORDER_TYPE type,double bid,double slD,double tpD,double pt){
   if(g_hasPend)return;
   double off=Limit_Offset*pt,lp,sl,tp;
   if(type==ORDER_TYPE_BUY_LIMIT){lp=NormalizeDouble(bid-off,_Digits);sl=NormalizeDouble(lp-slD,_Digits);tp=NormalizeDouble(lp+tpD,_Digits);}
   else{lp=NormalizeDouble(bid+off,_Digits);sl=NormalizeDouble(lp+slD,_Digits);tp=NormalizeDouble(lp-tpD,_Digits);}
   double slPt=MathAbs(lp-sl)/pt,tpPt=MathAbs(lp-tp)/pt;
   if(slPt<g_minStop+3||tpPt<g_minStop+3)return;
   double lot=LotSize(slD);if(lot<=0)return;
   bool ok=(type==ORDER_TYPE_BUY_LIMIT)?g_trade.BuyLimit(lot,lp,_Symbol,sl,tp,ORDER_TIME_GTC,0,"SCALP"):g_trade.SellLimit(lot,lp,_Symbol,sl,tp,ORDER_TIME_GTC,0,"SCALP");
   if(ok){g_pendTick=g_trade.ResultOrder();g_hasPend=true;g_ppBar=iTime(_Symbol,PERIOD_CURRENT,0);g_loBar=g_ppBar;g_bwait=5;
      if(Use_Server)ServerPost("/api/trading/ea/signal",StringFormat("{\"ea_name\":\"ScalpElite\",\"symbol\":\"%s\",\"direction\":\"%s\",\"entry\":%.5f,\"sl\":%.5f,\"tp\":%.5f,\"rr\":%.1f}",_Symbol,type==ORDER_TYPE_BUY_LIMIT?"BUY":"SELL",lp,sl,tp,tpPt/slPt));if(Use_Server)ServerPost("/api/trading/trades/open",StringFormat("{\"ea_name\":\"ScalpElite\",\"ticket\":%d,\"symbol\":\"%s\",\"direction\":\"%s\",\"lot_size\":%.2f,\"entry_price\":%.5f,\"sl\":%.5f,\"tp\":%.5f}",g_pendTick,_Symbol,type==ORDER_TYPE_BUY_LIMIT?"BUY":"SELL",lot,lp,sl,tp));}
}

void ManagePend(){
   if(!g_hasPend)return;
   bool found=false;
   for(int i=OrdersTotal()-1;i>=0;i--){
      if(g_order.SelectByIndex(i)&&g_order.Ticket()==g_pendTick){
         found=true;
         ENUM_ORDER_STATE st=(ENUM_ORDER_STATE)g_order.State();
         if(st==ORDER_STATE_FILLED||st==ORDER_STATE_CANCELED||st==ORDER_STATE_EXPIRED||st==ORDER_STATE_REJECTED){g_hasPend=false;g_pendTick=0;return;}
         break;
      }
   }
   if(!found&&HistoryOrderSelect(g_pendTick)){
      ENUM_ORDER_STATE st=(ENUM_ORDER_STATE)HistoryOrderGetInteger(g_pendTick,ORDER_STATE);
      if(st==ORDER_STATE_FILLED||st==ORDER_STATE_CANCELED||st==ORDER_STATE_EXPIRED||st==ORDER_STATE_REJECTED){g_hasPend=false;g_pendTick=0;return;}
   }
   int bp=0;
   for(int i=0;i<100;i++){if(iTime(_Symbol,PERIOD_CURRENT,i)<=g_ppBar){bp=i;break;}}
   if(bp>=Limit_Expiry){if(g_trade.OrderDelete(g_pendTick))Print("CANCELLED");g_hasPend=false;g_pendTick=0;}
}
void ScanPend(){for(int i=OrdersTotal()-1;i>=0;i--){if(g_order.SelectByIndex(i)){if(g_order.Symbol()==_Symbol&&g_order.Magic()==g_magic){g_hasPend=true;g_pendTick=g_order.Ticket();g_ppBar=iTime(_Symbol,PERIOD_CURRENT,0);g_loBar=g_ppBar;return;}}}}
void OnTradeTransaction(const MqlTradeTransaction &t,const MqlTradeRequest &req,const MqlTradeResult &res){if(t.type!=TRADE_TRANSACTION_DEAL_ADD)return;if(!HistoryDealSelect(t.deal))return;if(HistoryDealGetInteger(t.deal,DEAL_MAGIC)!=g_magic)return;if(HistoryDealGetInteger(t.deal,DEAL_ENTRY)==DEAL_ENTRY_IN){g_hasPend=false;g_bwait=0;return;}if(HistoryDealGetInteger(t.deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT)return;double p=HistoryDealGetDouble(t.deal,DEAL_PROFIT);g_profit+=p;if(p>=0){g_wins++;g_consec=0;}else{g_losses++;g_consec++;}if(Use_Server)ServerPost("/api/trading/trades/close",StringFormat("{\"ea_name\":\"ScalpElite\",\"profit\":%.2f}",p));PrintFormat("%s %.2f W:%d L:%d",p>=0?"WIN":"LOSS",p,g_wins,g_losses);}
void ServerPost(string ep,string json){if(!Use_Server)return;char post[];uchar res[];string resHdr;string hdr="Content-Type: application/json\r\nX-Api-Key: "+API_Key+"\r\n";StringToCharArray(json,post,0,StringLen(json));int r=WebRequest("POST",Server_URL+ep,hdr,3000,post,res,resHdr);if(r<0)PrintFormat("Server err %d",GetLastError());}
void ShowMsg(string m){Comment("SCALP ELITE\n"+m);}
double G(int h,int b,int s){double a[];ArraySetAsSeries(a,true);if(CopyBuffer(h,b,s,1,a)<1)return 0;return a[0];}
double WR(){int t=g_wins+g_losses;return t>0?((double)g_wins/t)*100:0;}
double LotSize(double sl){double bal=AccountInfoDouble(ACCOUNT_BALANCE),risk=bal*(Risk_Pct/100.0);double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE),ls=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);if(ts==0||tv==0||sl==0)return 0;double vpl=(sl/ts)*tv;if(vpl==0)return 0;return NormalizeDouble(MathMax(mn,MathMin(mx,MathFloor((risk/vpl)/ls)*ls)),2);}
int CountOpen(){int n=0;for(int i=PositionsTotal()-1;i>=0;i--)if(g_pos.SelectByIndex(i))if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic)n++;return n;}
int CountAll(){int n=CountOpen();for(int i=OrdersTotal()-1;i>=0;i--)if(g_order.SelectByIndex(i))if(g_order.Symbol()==_Symbol&&g_order.Magic()==g_magic)n++;return n;}
int GetDir(){for(int i=PositionsTotal()-1;i>=0;i--){if(g_pos.SelectByIndex(i)){if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic){return(g_pos.PositionType()==POSITION_TYPE_BUY)?1:-1;}}}return 0;}
double GetProf(double pt){for(int i=PositionsTotal()-1;i>=0;i--){if(g_pos.SelectByIndex(i)){if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic){double e=g_pos.PriceOpen(),c=g_pos.PriceCurrent();return(g_pos.PositionType()==POSITION_TYPE_BUY)?(c-e)/pt:(e-c)/pt;}}}return 0;}
bool DailyLoss(){return(((g_dayBal-AccountInfoDouble(ACCOUNT_BALANCE))/g_dayBal)*100>=Risk_DailyLoss);}
bool DailyProfit(){return(g_profit>0&&(g_profit/g_dayBal)*100>=Risk_DailyProfit);}
void ResetDay(){static datetime l=0;MqlDateTime n;TimeToStruct(TimeCurrent(),n);MqlDateTime ld;TimeToStruct(l,ld);if(n.day!=ld.day||l==0){g_dayBal=AccountInfoDouble(ACCOUNT_BALANCE);g_profit=0;g_consec=0;l=TimeCurrent();}}
