//+------------------------------------------------------------------+
//|  EA1_PropFirmElite.mq5                                          |
//|  PROP FIRM SPECIALIST — FundedNext / FTMO / E8                  |
//|  H4 trend → H1 confirm → M15 entry                             |
//|  Reports all trades to BMPT backend server                      |
//+------------------------------------------------------------------+
#property copyright "DixonAfreh / BMPT"
#property version   "1.00"
#property strict
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

input group "=== SERVER CONNECTION ==="
input string Server_URL    = "http://YOUR-SERVER-IP:7001"; // Your VPS IP
input string API_Key       = "bmpt-your-secret-key-change-this";
input bool   Use_Server    = true;   // false = run without server

input group "=== PROP FIRM RULES ==="
input double Daily_Loss_Pct   = 4.5;  // Stop at 4.5% daily loss
input double Max_DD_Pct       = 9.0;  // Stop at 9% max drawdown
input double Profit_Target    = 8.0;  // Phase 1 target %
input double Risk_Pct         = 0.5;  // 0.5% risk per trade (safe)
input int    Risk_MaxConsec   = 3;

input group "=== MULTI-TF ==="
input ENUM_TIMEFRAMES TF_Trend   = PERIOD_H4;
input ENUM_TIMEFRAMES TF_Confirm = PERIOD_H1;
input int    EMA_Trend    = 200;
input int    EMA_21       = 21;
input int    EMA_8        = 8;

input group "=== ENTRY ==="
input double Limit_Offset = 20.0;
input int    Limit_Expiry = 4;
input double MinRR        = 3.0;   // 1:3 for prop firm
input int    Swing_Bars   = 12;
input int    SR_Bars      = 60;
input double SL_Buffer    = 5.0;

input group "=== PATTERNS ==="
input double PinBar_Tail  = 0.58;
input double PinBar_Body  = 0.40;
input double Doji_Body    = 0.10;
input int    Min_Score    = 5;

input group "=== STRUCTURE ==="
input int    Swing_Look   = 8;
input int    Swing_Scan   = 60;
input int    Fib_Bars     = 40;
input double Fib_Zone     = 0.005;

input group "=== EXECUTION ==="
input bool   AutoTrade    = true;
input int    Slippage     = 20;
input bool   ShowDash     = true;

enum EPattern{PAT_NONE,PAT_PINBAR_BULL,PAT_PINBAR_BEAR,PAT_ENGULF_BULL,PAT_ENGULF_BEAR,
              PAT_HAMMER,PAT_SHOOTING,PAT_DOJI_BULL,PAT_DOJI_BEAR,
              PAT_MORNING,PAT_EVENING,PAT_HARAMI_BULL,PAT_HARAMI_BEAR,
              PAT_TWEEZ_BULL,PAT_TWEEZ_BEAR,PAT_INSIDE_BULL,PAT_INSIDE_BEAR};
enum EStr{STR_BULL,STR_BEAR,STR_RANGE,STR_NONE};
enum EBOS{BOS_BULL,BOS_BEAR,BOS_NONE};

struct SSignal{
   EStr str;EBOS bos;bool choch,atFib50,atFib618,atOB,atEMA21,htfOk,rsiOk;
   EPattern pattern;bool isBull;double rsiV,atr,smartSL,smartTP,rr;int score;string reason;
};

int h_emaT,h_ema21,h_ema8,h_htfT,h_htfC,h_rsi,h_atr;
CTrade g_trade;CPositionInfo g_pos;COrderInfo g_order;
double g_startBal,g_dayBal,g_highBal,g_profit;
int    g_consec,g_wins,g_losses,g_magic,g_bwait;
datetime g_lastBar,g_ppBar,g_loBar;
long   g_minStop;bool g_hasPend;ulong g_pendTick;
bool   g_partDone;

int GenMagic(string s,ENUM_TIMEFRAMES tf){int h=0;for(int i=0;i<StringLen(s);i++)h=h*31+(int)StringGetCharacter(s,i);return MathAbs(h)%90000+10000+(int)tf+4242;}

int OnInit(){
   g_magic=GenMagic(_Symbol,Period());
   g_trade.SetExpertMagicNumber(g_magic);g_trade.SetDeviationInPoints(Slippage);g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_minStop=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   h_emaT =iMA(_Symbol,PERIOD_CURRENT,EMA_Trend,0,MODE_EMA,PRICE_CLOSE);
   h_ema21=iMA(_Symbol,PERIOD_CURRENT,EMA_21,0,MODE_EMA,PRICE_CLOSE);
   h_ema8 =iMA(_Symbol,PERIOD_CURRENT,EMA_8,0,MODE_EMA,PRICE_CLOSE);
   h_htfT =iMA(_Symbol,TF_Trend,EMA_Trend,0,MODE_EMA,PRICE_CLOSE);
   h_htfC =iMA(_Symbol,TF_Confirm,EMA_21,0,MODE_EMA,PRICE_CLOSE);
   h_rsi  =iRSI(_Symbol,PERIOD_CURRENT,14,PRICE_CLOSE);
   h_atr  =iATR(_Symbol,PERIOD_CURRENT,14);
   if(h_rsi==INVALID_HANDLE||h_atr==INVALID_HANDLE){Print("Handle FAILED");return INIT_FAILED;}
   g_startBal=g_dayBal=g_highBal=AccountInfoDouble(ACCOUNT_BALANCE);
   g_consec=g_wins=g_losses=g_bwait=0;g_profit=0;
   g_lastBar=g_ppBar=g_loBar=0;g_hasPend=false;g_pendTick=0;g_partDone=false;
   ScanPending();
   if(Use_Server) ServerHeartbeat("OnInit");
   PrintFormat("PropFirmElite | %s %s | Magic:%d",_Symbol,EnumToString(Period()),g_magic);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int r){
   int h[]={h_emaT,h_ema21,h_ema8,h_htfT,h_htfC,h_rsi,h_atr};
   for(int i=0;i<ArraySize(h);i++)IndicatorRelease(h[i]);Comment("");
}

void OnTick(){
   datetime bar=iTime(_Symbol,PERIOD_CURRENT,0);if(bar==g_lastBar)return;g_lastBar=bar;
   ResetDay();UpdateHigh();
   double eq=AccountInfoDouble(ACCOUNT_EQUITY),bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double ddDay=(g_dayBal-eq)/g_dayBal*100;
   double ddMax=(g_highBal-eq)/g_highBal*100;
   double profPct=(bal-g_startBal)/g_startBal*100;
   if(ddDay>=Daily_Loss_Pct*0.9){ShowMsg("DAILY LOSS LIMIT");return;}
   if(ddMax>=Max_DD_Pct*0.9)    {ShowMsg("MAX DRAWDOWN");return;}
   if(profPct>=Profit_Target)   {ShowMsg("TARGET HIT — submit!");return;}
   if(g_consec>=Risk_MaxConsec) {ShowMsg("MAX LOSSES");return;}
   MqlDateTime t;TimeToStruct(TimeGMT(),t);
   if(t.day_of_week==5&&t.hour>=20){ShowMsg("FRIDAY CUTOFF");return;}
   if(g_bwait>0){g_bwait--;return;}
   ManagePending();ManageActive();
   if(CountOpen()>0)CheckCHOCH();
   if(g_hasPend)return;
   if(g_loBar==iTime(_Symbol,PERIOD_CURRENT,0))return;
   if(CountAll()>=2)return;
   SSignal sig;BuildSignal(sig);
   if(ShowDash)Dash(sig,bal,eq,ddDay,ddMax,profPct);
   if(sig.pattern==PAT_NONE||sig.score<Min_Score||sig.rr<MinRR)return;
   int op=CountOpen();
   if(op==1){
      int dir=GetDir();double pp=GetProfPts();
      if(pp>=20){
         if(dir==1&&sig.isBull&&AutoTrade){MoveAllBE();PlaceOrder(ORDER_TYPE_BUY_LIMIT,sig,true);}
         if(dir==-1&&!sig.isBull&&AutoTrade){MoveAllBE();PlaceOrder(ORDER_TYPE_SELL_LIMIT,sig,true);}
      }return;
   }
   if(op==0){
      if(sig.isBull&&AutoTrade) PlaceOrder(ORDER_TYPE_BUY_LIMIT,sig,false);
      else if(!sig.isBull&&AutoTrade) PlaceOrder(ORDER_TYPE_SELL_LIMIT,sig,false);
   }
}

void PlaceOrder(ENUM_ORDER_TYPE type,const SSignal &sig,bool isPyr){
   if(g_hasPend)return;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double off=Limit_Offset*pt,lp,sl=sig.smartSL,tp=sig.smartTP;
   if(type==ORDER_TYPE_BUY_LIMIT){lp=NormalizeDouble(bid-off,_Digits);if(sl>=lp)sl=NormalizeDouble(lp-(g_minStop+10)*pt,_Digits);}
   else{lp=NormalizeDouble(bid+off,_Digits);if(sl<=lp)sl=NormalizeDouble(lp+(g_minStop+10)*pt,_Digits);}
   double slPt=MathAbs(lp-sl)/pt,tpPt=MathAbs(lp-tp)/pt;
   if(slPt<g_minStop+5||tpPt<g_minStop+5)return;
   double lot=LotSize(MathAbs(lp-sl));if(lot<=0)return;
   bool ok=(type==ORDER_TYPE_BUY_LIMIT)
      ?g_trade.BuyLimit(lot,lp,_Symbol,sl,tp,ORDER_TIME_GTC,0,"PF|"+sig.reason)
      :g_trade.SellLimit(lot,lp,_Symbol,sl,tp,ORDER_TIME_GTC,0,"PF|"+sig.reason);
   if(ok){
      g_pendTick=g_trade.ResultOrder();g_hasPend=true;g_ppBar=iTime(_Symbol,PERIOD_CURRENT,0);
      g_loBar=g_ppBar;g_bwait=5;g_partDone=false;
      if(Use_Server)ServerSignal(sig,lp,sl,tp,tpPt/slPt);
      PrintFormat("PROP ORDER %s Lot:%.2f Limit:%.5f SL:%.5f TP:%.5f RR:1:%.1f Score:%d/7",
         (type==ORDER_TYPE_BUY_LIMIT)?"BUY":"SELL",lot,lp,sl,tp,tpPt/slPt,sig.score);
   }
}

void ManageActive(){
   double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   for(int i=PositionsTotal()-1;i>=0;i--){
      if(!g_pos.SelectByIndex(i))continue;
      if(g_pos.Symbol()!=_Symbol||g_pos.Magic()!=g_magic)continue;
      double e=g_pos.PriceOpen(),sl=g_pos.StopLoss(),tp=g_pos.TakeProfit(),cur=g_pos.PriceCurrent();
      double slD=MathAbs(e-sl);if(slD<=0)continue;
      bool buy=(g_pos.PositionType()==POSITION_TYPE_BUY);
      double profPts=buy?(cur-e)/pt:(e-cur)/pt,slPts=slD/pt;
      if(profPts>=slPts){
         double be=buy?NormalizeDouble(e+SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)*pt,_Digits):NormalizeDouble(e-SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)*pt,_Digits);
         if((buy&&be>sl)||(!buy&&(be<sl||sl==0)))g_trade.PositionModify(g_pos.Ticket(),be,tp);
      }
      if(!g_partDone&&profPts>=slPts){
         double half=NormalizeDouble(g_pos.Volume()*0.5,2);
         if(half>=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)){
            if(g_trade.PositionClosePartial(g_pos.Ticket(),half))g_partDone=true;
         }
      }
   }
}

void ManagePending(){
   if(!g_hasPend)return;
   for(int i=OrdersTotal()-1;i>=0;i--){
      if(g_order.SelectByIndex(i)&&g_order.Ticket()==g_pendTick){
         ENUM_ORDER_STATE st=(ENUM_ORDER_STATE)g_order.State();
         if(st==ORDER_STATE_FILLED||st==ORDER_STATE_CANCELED||st==ORDER_STATE_EXPIRED||st==ORDER_STATE_REJECTED){g_hasPend=false;g_pendTick=0;return;}
         goto expCheck;
      }
   }
   if(HistoryOrderSelect(g_pendTick)){
      ENUM_ORDER_STATE st=(ENUM_ORDER_STATE)HistoryOrderGetInteger(g_pendTick,ORDER_STATE);
      if(st==ORDER_STATE_FILLED||st==ORDER_STATE_CANCELED||st==ORDER_STATE_EXPIRED||st==ORDER_STATE_REJECTED){g_hasPend=false;g_pendTick=0;return;}
   }
   expCheck:
   int bp=0;for(int i=0;i<200;i++){if(iTime(_Symbol,PERIOD_CURRENT,i)<=g_ppBar){bp=i;break;}}
   if(bp>=Limit_Expiry){if(g_trade.OrderDelete(g_pendTick))Print("PENDING CANCELLED");g_hasPend=false;g_pendTick=0;}
}

void ScanPending(){for(int i=OrdersTotal()-1;i>=0;i--){if(g_order.SelectByIndex(i)){if(g_order.Symbol()==_Symbol&&g_order.Magic()==g_magic){g_hasPend=true;g_pendTick=g_order.Ticket();g_ppBar=iTime(_Symbol,PERIOD_CURRENT,0);g_loBar=g_ppBar;return;}}}}

void CheckCHOCH(){
   int dir=GetDir();if(dir==0)return;
   double cur=iC(1),rH=0,rL=0;
   for(int i=2;i<Swing_Look*3;i++){if(iH(i)>rH)rH=iH(i);if(rL==0||iL(i)<rL)rL=iL(i);}
   double sH=0,sL=0;EStr str=DetStr(sH,sL);
   bool ch=(dir==1&&str==STR_BULL&&cur<rL)||(dir==-1&&str==STR_BEAR&&cur>rH);
   if(!ch)return;
   for(int i=PositionsTotal()-1;i>=0;i--){
      if(g_pos.SelectByIndex(i))if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic){
         if(g_trade.PositionClose(g_pos.Ticket())){
            if(Use_Server)ServerClose(g_pos.Ticket(),g_pos.Profit(),"CHOCH");
            Print("CHOCH EXIT:",g_pos.Ticket());
         }
      }
   }
   if(g_hasPend){if(g_trade.OrderDelete(g_pendTick))Print("PENDING CANCELLED");g_hasPend=false;g_pendTick=0;}
}

void BuildSignal(SSignal &s){
   double cur=iC(1),emaT=Buf(h_emaT,0,1),e21=Buf(h_ema21,0,1),e8=Buf(h_ema8,0,1);
   double htfT=Buf(h_htfT,0,1),htfC=Buf(h_htfC,0,1),rsi=Buf(h_rsi,0,1),atr=Buf(h_atr,0,1);
   if(rsi==0||atr==0||e21==0)return;
   s.atr=atr;s.rsiV=rsi;
   double sH=0,sL=0;s.str=DetStr(sH,sL);
   s.isBull=(s.str==STR_BULL||(s.str==STR_RANGE&&cur>htfT));
   bool ch=false;s.bos=DetBOS(s.str,ch);s.choch=ch;
   double f50=0,f618=0;bool at50=false,at618=false;CalcFib(s.str,f50,f618,at50,at618);
   s.atFib50=at50;s.atFib618=at618;s.atOB=DetOB(s.str);
   double eTol=atr*0.5;
   s.atEMA21=(MathAbs(cur-e21)<=eTol||MathAbs(iL(1)-e21)<=eTol||MathAbs(iH(1)-e21)<=eTol);
   s.htfOk=(s.isBull==(htfT>0&&cur>htfT))||(s.isBull==(htfC>0&&iClose(_Symbol,TF_Confirm,1)>htfC));
   s.rsiOk=s.isBull?(rsi>=35&&rsi<=65):(rsi>=35&&rsi<=65);
   s.pattern=DetPat(s.isBull);AdjDir(s);
   s.score=0;s.reason="";
   if(s.htfOk)                                              {s.score++;s.reason+="HTF ";}
   if(s.str!=STR_NONE)                                      {s.score++;s.reason+="Str ";}
   if((s.isBull&&s.bos==BOS_BULL)||(!s.isBull&&s.bos==BOS_BEAR)){s.score++;s.reason+="BOS ";}
   if(s.atFib50||s.atFib618)                                {s.score++;s.reason+=(s.atFib50?"Fib50 ":"Fib618 ");}
   if(s.atEMA21)                                            {s.score++;s.reason+="EMA21 ";}
   if(s.atOB)                                               {s.score++;s.reason+="OB ";}
   if(s.pattern!=PAT_NONE)                                  {s.score++;s.reason+=PatName(s.pattern)+" ";}
   s.smartSL=CalcSL(s.isBull,atr);s.smartTP=CalcTP(s.isBull,s.smartSL);
   double slD=MathAbs(cur-s.smartSL),tpD=MathAbs(cur-s.smartTP);
   s.rr=(slD>0)?tpD/slD:0;
}

// Helpers
double CalcSL(bool bull,double atr){double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT),buf=SL_Buffer*pt,minD=(g_minStop+10)*pt,cur=iC(1);if(bull){double lo=99999999;for(int i=1;i<=Swing_Bars;i++)if(iL(i)<lo)lo=iL(i);double sl=lo-buf;if(cur-sl<minD)sl=cur-minD;return NormalizeDouble(sl,_Digits);}else{double hi=0;for(int i=1;i<=Swing_Bars;i++)if(iH(i)>hi)hi=iH(i);double sl=hi+buf;if(sl-cur<minD)sl=cur+minD;return NormalizeDouble(sl,_Digits);}}
double CalcTP(bool bull,double sl){double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT),cur=iC(1),slD=MathAbs(cur-sl),minTP=slD*MinRR,minD=(g_minStop+10)*pt;double best=0;if(bull){double cl=999999999;for(int i=3;i<=SR_Bars;i++){double h=iH(i),hP=iH(i-1),hN=iH(i+1);if(h>hP&&h>hN&&h>cur+minTP&&h<cl)cl=h;}best=(cl<999999999)?cl:cur+minTP;if(best-cur<minD*2)best=cur+minD*2;}else{double cl=-999999999;for(int i=3;i<=SR_Bars;i++){double l=iL(i),lP=iL(i-1),lN=iL(i+1);if(l<lP&&l<lN&&l<cur-minTP&&l>cl)cl=l;}best=(cl>-999999999)?cl:cur-minTP;if(cur-best<minD*2)best=cur-minD*2;}return NormalizeDouble(best,_Digits);}
EPattern DetPinBar(int i){double o=iO(i),c=iC(i),h=iH(i),l=iL(i),rng=h-l;if(rng<=0)return PAT_NONE;double body=MathAbs(c-o),upW=h-MathMax(o,c),loW=MathMin(o,c)-l;if(body/rng>PinBar_Body)return PAT_NONE;if(loW/rng>=PinBar_Tail&&loW>upW*2)return PAT_PINBAR_BULL;if(upW/rng>=PinBar_Tail&&upW>loW*2)return PAT_PINBAR_BEAR;return PAT_NONE;}
EPattern DetEngulf(int i){double o1=iO(i),c1=iC(i),o2=iO(i+1),c2=iC(i+1);if(MathAbs(c1-o1)==0||MathAbs(c2-o2)==0)return PAT_NONE;if(c1>o1&&c2<o2&&c1>=o2&&o1<=c2)return PAT_ENGULF_BULL;if(c1<o1&&c2>o2&&o1>=c2&&c1<=o2)return PAT_ENGULF_BEAR;return PAT_NONE;}
EPattern DetHamm(int i){double o=iO(i),c=iC(i),h=iH(i),l=iL(i),rng=h-l;if(rng<=0)return PAT_NONE;double body=MathAbs(c-o),loW=MathMin(o,c)-l,upW=h-MathMax(o,c);if(body/rng<=0.30&&loW/rng>=0.60&&loW>upW*2)return PAT_HAMMER;return PAT_NONE;}
EPattern DetShoot(int i){double o=iO(i),c=iC(i),h=iH(i),l=iL(i),rng=h-l;if(rng<=0)return PAT_NONE;double body=MathAbs(c-o),loW=MathMin(o,c)-l,upW=h-MathMax(o,c);if(body/rng<=0.30&&upW/rng>=0.60&&upW>loW*2)return PAT_SHOOTING;return PAT_NONE;}
EPattern DetDoji(int i){double o=iO(i),c=iC(i),h=iH(i),l=iL(i),rng=h-l;if(rng<=0)return PAT_NONE;double body=MathAbs(c-o);if(body/rng>Doji_Body)return PAT_NONE;double upW=h-MathMax(o,c),loW=MathMin(o,c)-l;if(loW/rng>=0.60&&upW<body*2)return PAT_DOJI_BULL;if(upW/rng>=0.60&&loW<body*2)return PAT_DOJI_BEAR;return PAT_NONE;}
EPattern DetMorn(int i){double o1=iO(i+2),c1=iC(i+2),o2=iO(i+1),c2=iC(i+1),o3=iO(i),c3=iC(i),r1=MathAbs(o1-c1),r2=MathAbs(o2-c2);if(r1==0)return PAT_NONE;if(c1<o1&&r2<r1*0.5&&c3>o3&&c3>(o1+c1)/2.0)return PAT_MORNING;return PAT_NONE;}
EPattern DetEve(int i){double o1=iO(i+2),c1=iC(i+2),o2=iO(i+1),c2=iC(i+1),o3=iO(i),c3=iC(i),r1=MathAbs(o1-c1),r2=MathAbs(o2-c2);if(r1==0)return PAT_NONE;if(c1>o1&&r2<r1*0.5&&c3<o3&&c3<(o1+c1)/2.0)return PAT_EVENING;return PAT_NONE;}
EPattern DetHaram(int i){double o1=iO(i),c1=iC(i),o2=iO(i+1),c2=iC(i+1);if(MathAbs(c2-o2)==0)return PAT_NONE;if(MathMax(o1,c1)<MathMax(o2,c2)&&MathMin(o1,c1)>MathMin(o2,c2)){if(c2<o2&&c1>o1)return PAT_HARAMI_BULL;if(c2>o2&&c1<o1)return PAT_HARAMI_BEAR;}return PAT_NONE;}
EPattern DetTweez(int i){double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT)*3;if(MathAbs(iL(i)-iL(i+1))<=pt&&iC(i+1)<iO(i+1)&&iC(i)>iO(i))return PAT_TWEEZ_BULL;if(MathAbs(iH(i)-iH(i+1))<=pt&&iC(i+1)>iO(i+1)&&iC(i)<iO(i))return PAT_TWEEZ_BEAR;return PAT_NONE;}
EPattern DetInside(int i,bool b){if(iH(i)<iH(i+1)&&iL(i)>iL(i+1))return b?PAT_INSIDE_BULL:PAT_INSIDE_BEAR;return PAT_NONE;}
EPattern DetPat(bool b){EPattern p;p=DetPinBar(1);if(p!=PAT_NONE)return p;p=DetEngulf(1);if(p!=PAT_NONE)return p;p=DetMorn(1);if(p!=PAT_NONE)return p;p=DetEve(1);if(p!=PAT_NONE)return p;p=DetHamm(1);if(p!=PAT_NONE)return p;p=DetShoot(1);if(p!=PAT_NONE)return p;p=DetDoji(1);if(p!=PAT_NONE)return p;p=DetTweez(1);if(p!=PAT_NONE)return p;p=DetHaram(1);if(p!=PAT_NONE)return p;p=DetInside(1,b);if(p!=PAT_NONE)return p;return PAT_NONE;}
void AdjDir(SSignal &s){if(s.pattern==PAT_PINBAR_BULL||s.pattern==PAT_ENGULF_BULL||s.pattern==PAT_INSIDE_BULL||s.pattern==PAT_MORNING||s.pattern==PAT_HAMMER||s.pattern==PAT_DOJI_BULL||s.pattern==PAT_HARAMI_BULL||s.pattern==PAT_TWEEZ_BULL)s.isBull=true;if(s.pattern==PAT_PINBAR_BEAR||s.pattern==PAT_ENGULF_BEAR||s.pattern==PAT_INSIDE_BEAR||s.pattern==PAT_EVENING||s.pattern==PAT_SHOOTING||s.pattern==PAT_DOJI_BEAR||s.pattern==PAT_HARAMI_BEAR||s.pattern==PAT_TWEEZ_BEAR)s.isBull=false;}
EStr DetStr(double &sH,double &sL){double sh[2]={0,0},sl2[2]={0,0};int shb[2]={0,0},slb[2]={0,0},shc=0,slc=0;for(int i=2;i<Swing_Scan-1&&(shc<2||slc<2);i++){if(iH(i)>iH(i-1)&&iH(i)>iH(i+1)&&shc<2)if(shc==0||i>shb[0]+Swing_Look){sh[shc]=iH(i);shb[shc]=i;shc++;}if(iL(i)<iL(i-1)&&iL(i)<iL(i+1)&&slc<2)if(slc==0||i>slb[0]+Swing_Look){sl2[slc]=iL(i);slb[slc]=i;slc++;}}sH=sh[0];sL=sl2[0];if(shc<2||slc<2)return STR_NONE;if(sh[0]>sh[1]&&sl2[0]>sl2[1])return STR_BULL;if(sh[0]<sh[1]&&sl2[0]<sl2[1])return STR_BEAR;return STR_RANGE;}
EBOS DetBOS(EStr str,bool &choch){choch=false;if(str==STR_NONE)return BOS_NONE;double cur=iC(1),rH=0,rL=0;for(int i=2;i<Swing_Look*3;i++){if(iH(i)>rH)rH=iH(i);if(rL==0||iL(i)<rL)rL=iL(i);}if(str==STR_BULL&&cur>rH)return BOS_BULL;if(str==STR_BEAR&&cur<rL)return BOS_BEAR;if(str==STR_BULL&&cur<rL)choch=true;if(str==STR_BEAR&&cur>rH)choch=true;return BOS_NONE;}
void CalcFib(EStr str,double &f50,double &f618,bool &at50,bool &at618){f50=0;f618=0;at50=false;at618=false;double swH=0,swL=0;for(int i=1;i<Fib_Bars;i++){if(iH(i)>swH)swH=iH(i);if(swL==0||iL(i)<swL)swL=iL(i);}if(swH==0||swL==0)return;double rng=swH-swL,cur=iC(1);f50=str==STR_BULL?swH-0.500*rng:swL+0.500*rng;f618=str==STR_BULL?swH-0.618*rng:swL+0.618*rng;double z=rng*Fib_Zone;at50=(MathAbs(cur-f50)<=z);at618=(MathAbs(cur-f618)<=z);}
bool DetOB(EStr str){double cur=iC(1),pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);for(int i=3;i<20;i++){double o=iO(i),c=iC(i),op=iO(i+1),cp=iC(i+1);if(str==STR_BULL&&c>o&&cp<op){double h=MathMax(op,cp),l=MathMin(op,cp),z=(h-l)*0.5+pt*5;if(cur>=l-z&&cur<=h+z)return true;break;}if(str==STR_BEAR&&c<o&&cp>op){double h=MathMax(op,cp),l=MathMin(op,cp),z=(h-l)*0.5+pt*5;if(cur>=l-z&&cur<=h+z)return true;break;}}return false;}

void OnTradeTransaction(const MqlTradeTransaction &t,const MqlTradeRequest &req,const MqlTradeResult &res){
   if(t.type!=TRADE_TRANSACTION_DEAL_ADD)return;
   if(!HistoryDealSelect(t.deal))return;
   if(HistoryDealGetInteger(t.deal,DEAL_MAGIC)!=g_magic)return;
   if(HistoryDealGetInteger(t.deal,DEAL_ENTRY)==DEAL_ENTRY_IN){g_hasPend=false;g_bwait=0;g_partDone=false;return;}
   if(HistoryDealGetInteger(t.deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT)return;
   double p=HistoryDealGetDouble(t.deal,DEAL_PROFIT);g_profit+=p;
   if(p>=0){g_wins++;g_consec=0;}else{g_losses++;g_consec++;}
   if(Use_Server)ServerClose(t.deal,p,"TP/SL");
   PrintFormat("%s %.2f W:%d L:%d WR:%.0f%%",p>=0?"WIN":"LOSS",p,g_wins,g_losses,WR());
   g_partDone=false;
}

// ── Server communication ─────────────────────────────────────
void ServerPost(string endpoint,string json){
   if(!Use_Server)return;
   char post[];string result,headers="Content-Type: application/json\r\nX-Api-Key: "+API_Key+"\r\n";
   StringToCharArray(json,post,0,StringLen(json));
   int ret=WebRequest("POST",Server_URL+endpoint,headers,3000,post,result,headers);
   if(ret<0)PrintFormat("Server error %d on %s",GetLastError(),endpoint);
}

void ServerHeartbeat(string msg){
   ServerPost("/api/trading/ea/heartbeat",StringFormat(
      "{\"ea_name\":\"PropFirmElite\",\"symbol\":\"%s\",\"timeframe\":\"%s\",\"balance\":%.2f,\"equity\":%.2f,\"message\":\"%s\"}",
      _Symbol,EnumToString(Period()),AccountInfoDouble(ACCOUNT_BALANCE),AccountInfoDouble(ACCOUNT_EQUITY),msg));
}

void ServerSignal(const SSignal &sig,double entry,double sl,double tp,double rr){
   ServerPost("/api/trading/ea/signal",StringFormat(
      "{\"ea_name\":\"PropFirmElite\",\"symbol\":\"%s\",\"direction\":\"%s\",\"score\":%d,\"pattern\":\"%s\",\"reason\":\"%s\",\"entry\":%.5f,\"sl\":%.5f,\"tp\":%.5f,\"rr\":%.2f}",
      _Symbol,sig.isBull?"BUY":"SELL",sig.score,PatName(sig.pattern),sig.reason,entry,sl,tp,rr));
}

void ServerClose(long ticket,double profit,string reason){
   ServerPost("/api/trading/trades/close",StringFormat(
      "{\"ea_name\":\"PropFirmElite\",\"ticket\":%d,\"profit\":%.2f,\"reason\":\"%s\"}",ticket,profit,reason));
}

void Dash(const SSignal &s,double bal,double eq,double ddD,double ddM,double prof){
   string fire=(s.score>=Min_Score&&s.pattern!=PAT_NONE&&s.rr>=MinRR)?(s.isBull?"  ★ BUY LIMIT READY":"  ★ SELL LIMIT READY"):"  waiting...";
   Comment(StringFormat(
      "╔══ PROP FIRM ELITE EA ══╗\n  %s %s | Score:%d/7\n  Balance:$%.2f Equity:$%.2f\n  DailyDD:%.1f%% MaxDD:%.1f%%\n  Profit:%.1f%% | Target:%.1f%%\n  SL:%.5f←swing TP:%.5f←SR RR:1:%.1f\n  Str:%s BOS:%s\n  Fib:%s OB:%s EMA21:%s\n  Pat:%s Dir:%s\n  Reason:%s\n  %s\n  W:%d L:%d WR:%.0f%%",
      _Symbol,EnumToString(Period()),s.score,bal,eq,ddD,ddM,prof,Profit_Target,
      s.smartSL,s.smartTP,s.rr,
      s.str==STR_BULL?"UP":s.str==STR_BEAR?"DOWN":"RANGE",
      s.bos==BOS_BULL?"BULL":s.bos==BOS_BEAR?"BEAR":"none",
      s.atFib50?"50%":s.atFib618?"61.8%":"—",s.atOB?"OB✓":"—",s.atEMA21?"✓":"—",
      PatName(s.pattern),s.isBull?"LONG":"SHORT",s.reason==""?"scanning...":s.reason,
      fire,g_wins,g_losses,WR()));
}

void ShowMsg(string m){Comment("PROP FIRM ELITE\n"+m);}
double iO(int i){return iOpen(_Symbol,PERIOD_CURRENT,i);}
double iC(int i){return iClose(_Symbol,PERIOD_CURRENT,i);}
double iH(int i){return iHigh(_Symbol,PERIOD_CURRENT,i);}
double iL(int i){return iLow(_Symbol,PERIOD_CURRENT,i);}
double Buf(int h,int b,int s){double a[];ArraySetAsSeries(a,true);if(CopyBuffer(h,b,s,1,a)<1)return 0;return a[0];}
double WR(){int t=g_wins+g_losses;return t>0?((double)g_wins/t)*100:0;}
string PatName(EPattern p){switch(p){case PAT_PINBAR_BULL:return"BULL PIN BAR";case PAT_PINBAR_BEAR:return"BEAR PIN BAR";case PAT_ENGULF_BULL:return"BULL ENGULF";case PAT_ENGULF_BEAR:return"BEAR ENGULF";case PAT_HAMMER:return"HAMMER";case PAT_SHOOTING:return"SHOOTING";case PAT_DOJI_BULL:return"DOJI BULL";case PAT_DOJI_BEAR:return"DOJI BEAR";case PAT_MORNING:return"MORNING★";case PAT_EVENING:return"EVENING★";case PAT_HARAMI_BULL:return"HARAMI BULL";case PAT_HARAMI_BEAR:return"HARAMI BEAR";case PAT_TWEEZ_BULL:return"TWEEZERS BTM";case PAT_TWEEZ_BEAR:return"TWEEZERS TOP";case PAT_INSIDE_BULL:return"INSIDE▲";case PAT_INSIDE_BEAR:return"INSIDE▼";default:return"scanning...";}}
double LotSize(double sl){double bal=AccountInfoDouble(ACCOUNT_BALANCE),risk=bal*(Risk_Pct/100.0);double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE),ls=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);if(ts==0||tv==0||sl==0)return 0;double vpl=(sl/ts)*tv;if(vpl==0)return 0;return NormalizeDouble(MathMax(mn,MathMin(mx,MathFloor((risk/vpl)/ls)*ls)),2);}
int CountOpen(){int n=0;for(int i=PositionsTotal()-1;i>=0;i--)if(g_pos.SelectByIndex(i))if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic)n++;return n;}
int CountAll(){int n=CountOpen();for(int i=OrdersTotal()-1;i>=0;i--)if(g_order.SelectByIndex(i))if(g_order.Symbol()==_Symbol&&g_order.Magic()==g_magic)n++;return n;}
int GetDir(){for(int i=PositionsTotal()-1;i>=0;i--){if(g_pos.SelectByIndex(i)){if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic){return(g_pos.PositionType()==POSITION_TYPE_BUY)?1:-1;}}}return 0;}
double GetProfPts(){double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);for(int i=PositionsTotal()-1;i>=0;i--){if(g_pos.SelectByIndex(i)){if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic){double e=g_pos.PriceOpen(),c=g_pos.PriceCurrent();return(g_pos.PositionType()==POSITION_TYPE_BUY)?(c-e)/pt:(e-c)/pt;}}}return 0;}
void MoveAllBE(){double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);for(int i=PositionsTotal()-1;i>=0;i--){if(g_pos.SelectByIndex(i)){if(g_pos.Symbol()==_Symbol&&g_pos.Magic()==g_magic){double e=g_pos.PriceOpen(),sp=SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)*pt,sl=0;if(g_pos.PositionType()==POSITION_TYPE_BUY){sl=NormalizeDouble(e+sp,_Digits);if(sl>g_pos.StopLoss())g_trade.PositionModify(g_pos.Ticket(),sl,g_pos.TakeProfit());}else{sl=NormalizeDouble(e-sp,_Digits);if(sl<g_pos.StopLoss()||g_pos.StopLoss()==0)g_trade.PositionModify(g_pos.Ticket(),sl,g_pos.TakeProfit());}}}}}
void UpdateHigh(){double b=AccountInfoDouble(ACCOUNT_BALANCE);if(b>g_highBal)g_highBal=b;}
bool DailyLoss(){return((g_dayBal-AccountInfoDouble(ACCOUNT_EQUITY))/g_dayBal*100>=Daily_Loss_Pct);}
void ResetDay(){static datetime l=0;MqlDateTime n;TimeToStruct(TimeCurrent(),n);MqlDateTime ld;TimeToStruct(l,ld);if(n.day!=ld.day||l==0){g_dayBal=AccountInfoDouble(ACCOUNT_BALANCE);g_profit=0;g_consec=0;l=TimeCurrent();if(Use_Server)ServerHeartbeat("DayReset");}}
