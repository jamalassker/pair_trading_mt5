FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir mt5linux rpyc

RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe \
    -O /root/mt5setup.exe

# ============================================================
# AGGRESSIVE MICRO SCALPER EA – fixed error 10016
# ============================================================
RUN cat > /root/VALETAX_TICK_BOT_V16.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                        AggressiveMicroScalper.mq5|
//|                              High-frequency scalper for small acc|
//+------------------------------------------------------------------+
#property copyright "Aggressive Scalper EA"
#property version   "2.01"
#property strict

// --- Inputs (aggressive defaults) ---
input double   InpRiskPercent        = 2.0;      // Risk per trade (%)
input double   InpFixedLot           = 0.01;     // Fixed lot
input bool     InpUseAutoLot         = true;     // Auto lot sizing
input double   InpMaxDailyLoss       = 20.0;     // Higher daily loss limit
input double   InpMaxDrawdown        = 25.0;     // Higher drawdown limit

input int      InpFastEMA            = 10;       // Faster MA
input int      InpSlowEMA            = 30;       // Faster MA
input int      InpRSIPeriod          = 7;        // Shorter RSI
input int      InpRSIOverbought      = 65;       // Lower overbought
input int      InpRSIOversold        = 35;       // Higher oversold
input int      InpATRPeriod          = 10;       // Shorter ATR

input double   InpATRMultiplierSL    = 1.0;      // Tighter SL
input double   InpATRMultiplierTP    = 1.5;      // Tighter TP
input bool     InpUseTrailing        = true;
input int      InpTrailingStart      = 10;       // Start trailing earlier
input int      InpTrailingStep       = 5;

input bool     InpUseSessionFilter   = false;    // NO session filter
input int      InpSessionStartHour   = 0;
input int      InpSessionEndHour     = 24;
input bool     InpAvoidNews          = false;    // Trade through news
input int      InpNewsMinutesBefore  = 0;
input int      InpNewsMinutesAfter   = 0;

input int      InpMagicNumber        = 20251001;
input int      InpSlippage           = 10;
input bool     InpPrintLog           = true;

// --- Additional aggressive parameters ---
input bool     InpAllowMultiplePerBar = true;   // Multiple trades per bar
input bool     InpIgnoreTrendThreshold = true;  // Trade any trend direction

// --- Global variables ---
int            emaFastHandle, emaSlowHandle, rsiHandle, atrHandle;
double         emaFast[], emaSlow[], rsi[], atr[];
int            expertMagic;
string         expertSymbol;
double         pointValue, tickSize;
datetime       lastBarTime;
double         dailyStartingBalance;
bool           isTradingPaused = false;
bool           drawdownLimitHit = false;
datetime       lastTradeTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   expertSymbol = Symbol();
   expertMagic = InpMagicNumber;
   pointValue = SymbolInfoDouble(expertSymbol, SYMBOL_POINT);
   tickSize = SymbolInfoDouble(expertSymbol, SYMBOL_TRADE_TICK_SIZE);
   lastBarTime = iTime(expertSymbol, PERIOD_M5, 0);
   dailyStartingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   emaFastHandle = iMA(expertSymbol, PERIOD_M5, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(expertSymbol, PERIOD_M5, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle = iRSI(expertSymbol, PERIOD_M5, InpRSIPeriod, PRICE_CLOSE);
   atrHandle = iATR(expertSymbol, PERIOD_M5, InpATRPeriod);
   
   if(emaFastHandle==INVALID_HANDLE || emaSlowHandle==INVALID_HANDLE ||
      rsiHandle==INVALID_HANDLE || atrHandle==INVALID_HANDLE)
      return INIT_FAILED;
   
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);
   
   if(InpPrintLog) Print("Aggressive EA started on ", expertSymbol);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(emaFastHandle!=INVALID_HANDLE) IndicatorRelease(emaFastHandle);
   if(emaSlowHandle!=INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
   if(rsiHandle!=INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(atrHandle!=INVALID_HANDLE) IndicatorRelease(atrHandle);
   Print("EA removed.");
}

//+------------------------------------------------------------------+
//| OnTick – aggressive trading logic                               |
//+------------------------------------------------------------------+
void OnTick()
{
   // --- safety & limits ---
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return;
   if(!SymbolInfoInteger(expertSymbol, SYMBOL_TRADE_MODE)) return;
   if(drawdownLimitHit) return;
   if(CheckDailyLossLimit()) return;
   if(CheckDrawdownLimit()) return;
   if(InpAvoidNews && IsNewsTime()) return;
   if(InpUseSessionFilter && !IsTradingSession()) return;
   
   // --- new bar check (optional) ---
   datetime currentBarTime = iTime(expertSymbol, PERIOD_M5, 0);
   if(!InpAllowMultiplePerBar && currentBarTime == lastBarTime) return;
   if(currentBarTime != lastBarTime) lastBarTime = currentBarTime;
   
   // --- update indicators ---
   if(!UpdateIndicatorData()) return;
   
   double fastEMA = emaFast[0];
   double slowEMA = emaSlow[0];
   double rsiValue = rsi[0];
   double atrValue = atr[0];
   
   // --- trend detection (loosened) ---
   int trend = DetermineTrendAggressive(fastEMA, slowEMA);
   
   // --- signal generation (very relaxed) ---
   bool buySignal = false, sellSignal = false;
   
   if(trend == 1 || (InpIgnoreTrendThreshold && fastEMA > slowEMA))
   {
      double price = SymbolInfoDouble(expertSymbol, SYMBOL_BID);
      double emaDistance = MathAbs(price - fastEMA) / pointValue;
      double maxDistance = InpIgnoreTrendThreshold ? 100 : (atrValue / pointValue);
      
      if(emaDistance <= maxDistance &&
         (rsiValue < InpRSIOverbought || rsiValue < 60) &&
         rsi[1] <= rsi[0])
      {
         buySignal = true;
      }
   }
   
   if(trend == -1 || (InpIgnoreTrendThreshold && fastEMA < slowEMA))
   {
      double price = SymbolInfoDouble(expertSymbol, SYMBOL_ASK);
      double emaDistance = MathAbs(price - fastEMA) / pointValue;
      double maxDistance = InpIgnoreTrendThreshold ? 100 : (atrValue / pointValue);
      
      if(emaDistance <= maxDistance &&
         (rsiValue > InpRSIOversold || rsiValue > 40) &&
         rsi[1] >= rsi[0])
      {
         sellSignal = true;
      }
   }
   
   // --- execute trades ---
   if(buySignal && CountOpenPositions(ORDER_TYPE_BUY) < 2)
      OpenBuy(atrValue);
   if(sellSignal && CountOpenPositions(ORDER_TYPE_SELL) < 2)
      OpenSell(atrValue);
   
   // --- trailing stops ---
   if(InpUseTrailing) ManageTrailingStops();
}

//+------------------------------------------------------------------+
//| Loosened trend detection                                         |
//+------------------------------------------------------------------+
int DetermineTrendAggressive(double fast, double slow)
{
   double diff = fast - slow;
   double threshold = pointValue * 2;
   if(MathAbs(diff) < threshold) return 0;
   return (fast > slow) ? 1 : -1;
}

//+------------------------------------------------------------------+
//| Open Buy – fixed: IOC filling, extra buffer for min distance    |
//+------------------------------------------------------------------+
void OpenBuy(double atrValue)
{
   double lotSize = CalculateLotSize(atrValue, ORDER_TYPE_BUY);
   if(lotSize <= 0) return;
   double entry = SymbolInfoDouble(expertSymbol, SYMBOL_ASK);
   double sl = entry - (atrValue * InpATRMultiplierSL);
   double tp = entry + (atrValue * InpATRMultiplierTP);
   
   long stopsLevel = SymbolInfoInteger(expertSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * pointValue + 2 * pointValue;  // +2 points buffer
   if(entry - sl < minDist) sl = entry - minDist;
   if(tp - entry < minDist) tp = entry + minDist;
   
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = expertSymbol;
   req.volume = lotSize;
   req.type = ORDER_TYPE_BUY;
   req.price = entry;
   req.sl = sl;
   req.tp = tp;
   req.deviation = InpSlippage;
   req.magic = expertMagic;
   req.comment = "Aggressive BUY";
   req.type_filling = ORDER_FILLING_IOC;   // changed from FOK to IOC
   
   if(OrderSend(req, res))
   {
      if(InpPrintLog) Print("BUY | Lot: ", lotSize, " Entry: ", entry);
   }
   else Print("BUY failed: ", res.retcode);
}

//+------------------------------------------------------------------+
//| Open Sell – fixed: IOC filling, extra buffer for min distance   |
//+------------------------------------------------------------------+
void OpenSell(double atrValue)
{
   double lotSize = CalculateLotSize(atrValue, ORDER_TYPE_SELL);
   if(lotSize <= 0) return;
   double entry = SymbolInfoDouble(expertSymbol, SYMBOL_BID);
   double sl = entry + (atrValue * InpATRMultiplierSL);
   double tp = entry - (atrValue * InpATRMultiplierTP);
   
   long stopsLevel = SymbolInfoInteger(expertSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * pointValue + 2 * pointValue;  // +2 points buffer
   if(sl - entry < minDist) sl = entry + minDist;
   if(entry - tp < minDist) tp = entry - minDist;
   
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = expertSymbol;
   req.volume = lotSize;
   req.type = ORDER_TYPE_SELL;
   req.price = entry;
   req.sl = sl;
   req.tp = tp;
   req.deviation = InpSlippage;
   req.magic = expertMagic;
   req.comment = "Aggressive SELL";
   req.type_filling = ORDER_FILLING_IOC;   // changed from FOK to IOC
   
   if(OrderSend(req, res))
   {
      if(InpPrintLog) Print("SELL | Lot: ", lotSize, " Entry: ", entry);
   }
   else Print("SELL failed: ", res.retcode);
}

//+------------------------------------------------------------------+
//| Calculate lot size (unchanged)                                  |
//+------------------------------------------------------------------+
double CalculateLotSize(double atrValue, int orderType)
{
   double lotSize = InpFixedLot;
   if(InpUseAutoLot && InpRiskPercent > 0)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskAmount = balance * InpRiskPercent / 100.0;
      double slDistance = atrValue * InpATRMultiplierSL;
      double tickVal = SymbolInfoDouble(expertSymbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSiz = SymbolInfoDouble(expertSymbol, SYMBOL_TRADE_TICK_SIZE);
      double slTicks = slDistance / tickSiz;
      if(slTicks > 0 && tickVal > 0)
      {
         lotSize = riskAmount / (slTicks * tickVal);
         double step = SymbolInfoDouble(expertSymbol, SYMBOL_VOLUME_STEP);
         lotSize = MathFloor(lotSize / step) * step;
      }
   }
   double minLot = SymbolInfoDouble(expertSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(expertSymbol, SYMBOL_VOLUME_MAX);
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   double maxAllowed = AccountInfoDouble(ACCOUNT_BALANCE) / 500.0;
   lotSize = MathMin(lotSize, maxAllowed);
   return lotSize;
}

//+------------------------------------------------------------------+
//| Count open positions                                            |
//+------------------------------------------------------------------+
int CountOpenPositions(int type = -1)
{
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t))
      {
         if(PositionGetString(POSITION_SYMBOL)==expertSymbol && PositionGetInteger(POSITION_MAGIC)==expertMagic)
         {
            if(type==-1 || (int)PositionGetInteger(POSITION_TYPE)==type) count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Trailing stop – unchanged, works fine                           |
//+------------------------------------------------------------------+
void ManageTrailingStops()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=expertSymbol || PositionGetInteger(POSITION_MAGIC)!=expertMagic) continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      int typ = (int)PositionGetInteger(POSITION_TYPE);
      double price, newSL;
      if(typ==POSITION_TYPE_BUY)
      {
         price = SymbolInfoDouble(expertSymbol, SYMBOL_BID);
         double profit = (price - open)/pointValue;
         if(profit >= InpTrailingStart)
         {
            newSL = price - InpTrailingStep*pointValue;
            if(newSL > sl) ModifyStopLoss(t, newSL);
         }
      }
      else
      {
         price = SymbolInfoDouble(expertSymbol, SYMBOL_ASK);
         double profit = (open - price)/pointValue;
         if(profit >= InpTrailingStart)
         {
            newSL = price + InpTrailingStep*pointValue;
            if(newSL < sl || sl==0) ModifyStopLoss(t, newSL);
         }
      }
   }
}
void ModifyStopLoss(ulong ticket, double newSL)
{
   MqlTradeRequest req={};
   MqlTradeResult res={};
   req.action=TRADE_ACTION_SLTP;
   req.position=ticket;
   req.symbol=expertSymbol;
   req.sl=newSL;
   req.tp=PositionGetDouble(POSITION_TP);
   req.magic=expertMagic;
   if(!OrderSend(req,res)) Print("Trail modify error: ",res.retcode);
}

//+------------------------------------------------------------------+
//| Helper functions (shortened)                                    |
//+------------------------------------------------------------------+
bool UpdateIndicatorData()
{
   if(CopyBuffer(emaFastHandle,0,0,3,emaFast)<3) return false;
   if(CopyBuffer(emaSlowHandle,0,0,3,emaSlow)<3) return false;
   if(CopyBuffer(rsiHandle,0,0,3,rsi)<3) return false;
   if(CopyBuffer(atrHandle,0,0,3,atr)<3) return false;
   return true;
}
bool IsTradingSession()
{
   MqlDateTime dt; TimeCurrent(dt);
   int cur = dt.hour*60+dt.min;
   int start = InpSessionStartHour*60;
   int end = InpSessionEndHour*60;
   if(start<=end) return (cur>=start && cur<end);
   else return (cur>=start || cur<end);
}
bool IsNewsTime() { return false; }
bool CheckDailyLossLimit()
{
   double curBal = AccountInfoDouble(ACCOUNT_BALANCE);
   double loss = (dailyStartingBalance - curBal)/dailyStartingBalance*100;
   if(loss >= InpMaxDailyLoss)
   {
      if(!isTradingPaused) Print("Daily loss limit hit");
      isTradingPaused=true;
      return true;
   }
   MqlDateTime dt; TimeCurrent(dt);
   static int lastDay = dt.day;
   if(dt.day != lastDay)
   {
      dailyStartingBalance = curBal;
      lastDay = dt.day;
      isTradingPaused=false;
   }
   return false;
}
bool CheckDrawdownLimit()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd = (bal - eq)/bal*100;
   if(dd >= InpMaxDrawdown && !drawdownLimitHit)
   {
      Print("Drawdown limit hit, closing all");
      drawdownLimitHit = true;
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(PositionSelectByTicket(t) && PositionGetString(POSITION_SYMBOL)==expertSymbol && PositionGetInteger(POSITION_MAGIC)==expertMagic)
            ClosePosition(t);
      }
      return true;
   }
   return false;
}
void ClosePosition(ulong ticket)
{
   MqlTradeRequest req={};
   MqlTradeResult res={};
   req.action = TRADE_ACTION_DEAL;
   req.position = ticket;
   req.symbol = expertSymbol;
   req.volume = PositionGetDouble(POSITION_VOLUME);
   req.deviation = InpSlippage;
   req.magic = expertMagic;
   req.comment = "Close DD limit";
   if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) req.type = ORDER_TYPE_SELL;
   else req.type = ORDER_TYPE_BUY;
   req.price = (req.type==ORDER_TYPE_BUY) ? SymbolInfoDouble(expertSymbol,SYMBOL_ASK) : SymbolInfoDouble(expertSymbol,SYMBOL_BID);
   if(!OrderSend(req,res)) Print("Close error: ",res.retcode);
}
//+------------------------------------------------------------------+
EOF

# ============================================================
# ENTRYPOINT SCRIPT (unchanged)
# ============================================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e
rm -rf /tmp/.X*
Xvfb :1 -screen 0 1280x1024x24 -ac &
sleep 2
fluxbox &
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 0.0.0.0:5900 &
wineboot --init
sleep 5

MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
if [ ! -f "$MT5_EXE" ]; then
    wine /root/mt5setup.exe /auto
    sleep 90
fi

wine "$MT5_EXE" &
sleep 30

DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)
if [ -z "$DATA_DIR" ]; then
    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi
mkdir -p "$DATA_DIR/Experts"
cp /root/VALETAX_TICK_BOT_V16.mq5 "$DATA_DIR/Experts/"

METAEDITOR="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
if [ -f "$METAEDITOR" ]; then
    wine "$METAEDITOR" /compile:"$DATA_DIR/Experts/VALETAX_TICK_BOT_V16.mq5" /log:"/root/compile.log"
    echo "Compilation log:"
    cat /root/compile.log
else
    echo "metaeditor64.exe not found. EA not compiled."
fi

python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
