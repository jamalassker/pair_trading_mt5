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
//|                              FIFO‑compliant position closing      |
//+------------------------------------------------------------------+
#property copyright "Aggressive Scalper EA"
#property version   "2.20"
#property strict

// --- Inputs (aggressive defaults) ---
input double   InpRiskPercent        = 2.0;      // Risk per trade (%)
input double   InpFixedLot           = 0.01;     // Fixed lot
input bool     InpUseAutoLot         = true;     // Auto lot sizing
input double   InpMaxDailyLoss       = 20.0;     // Max daily loss (%)
input double   InpMaxDrawdown        = 25.0;     // Max total drawdown (%)

input int      InpFastEMA            = 10;
input int      InpSlowEMA            = 30;
input int      InpRSIPeriod          = 7;
input int      InpRSIOverbought      = 65;
input int      InpRSIOversold        = 35;
input int      InpATRPeriod          = 10;

input double   InpATRMultiplierSL    = 1.0;
input double   InpATRMultiplierTP    = 1.5;
input bool     InpUseTrailing        = true;
input int      InpTrailingStart      = 10;
input int      InpTrailingStep       = 5;

input bool     InpUseSessionFilter   = false;
input int      InpSessionStartHour   = 0;
input int      InpSessionEndHour     = 24;
input bool     InpAvoidNews          = false;
input int      InpNewsMinutesBefore  = 0;
input int      InpNewsMinutesAfter   = 0;

input int      InpMagicNumber        = 20251001;
input int      InpSlippage           = 10;
input bool     InpPrintLog           = true;

input bool     InpAllowMultiplePerBar = true;
input bool     InpIgnoreTrendThreshold = true;

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
//| OnTick – main logic                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return;
   if(!SymbolInfoInteger(expertSymbol, SYMBOL_TRADE_MODE)) return;
   if(drawdownLimitHit) return;
   if(CheckDailyLossLimit()) return;
   if(CheckDrawdownLimit()) return;
   if(InpAvoidNews && IsNewsTime()) return;
   if(InpUseSessionFilter && !IsTradingSession()) return;
   
   datetime currentBarTime = iTime(expertSymbol, PERIOD_M5, 0);
   if(!InpAllowMultiplePerBar && currentBarTime == lastBarTime) return;
   if(currentBarTime != lastBarTime) lastBarTime = currentBarTime;
   
   if(!UpdateIndicatorData()) return;
   
   double fastEMA = emaFast[0];
   double slowEMA = emaSlow[0];
   double rsiValue = rsi[0];
   double atrValue = atr[0];
   
   int trend = DetermineTrendAggressive(fastEMA, slowEMA);
   bool buySignal = false, sellSignal = false;
   
   if(trend == 1 || (InpIgnoreTrendThreshold && fastEMA > slowEMA))
   {
      double price = SymbolInfoDouble(expertSymbol, SYMBOL_BID);
      double emaDistance = MathAbs(price - fastEMA) / pointValue;
      double maxDistance = InpIgnoreTrendThreshold ? 100 : (atrValue / pointValue);
      if(emaDistance <= maxDistance &&
         (rsiValue < InpRSIOverbought || rsiValue < 60) &&
         rsi[1] <= rsi[0])
         buySignal = true;
   }
   
   if(trend == -1 || (InpIgnoreTrendThreshold && fastEMA < slowEMA))
   {
      double price = SymbolInfoDouble(expertSymbol, SYMBOL_ASK);
      double emaDistance = MathAbs(price - fastEMA) / pointValue;
      double maxDistance = InpIgnoreTrendThreshold ? 100 : (atrValue / pointValue);
      if(emaDistance <= maxDistance &&
         (rsiValue > InpRSIOversold || rsiValue > 40) &&
         rsi[1] >= rsi[0])
         sellSignal = true;
   }
   
   if(buySignal && CountOpenPositions(ORDER_TYPE_BUY) < 2)
      OpenBuy(atrValue);
   if(sellSignal && CountOpenPositions(ORDER_TYPE_SELL) < 2)
      OpenSell(atrValue);
   
   if(InpUseTrailing) ManageTrailingStops();
}

//+------------------------------------------------------------------+
//| Trend detection                                                  |
//+------------------------------------------------------------------+
int DetermineTrendAggressive(double fast, double slow)
{
   double diff = fast - slow;
   double threshold = pointValue * 2;
   if(MathAbs(diff) < threshold) return 0;
   return (fast > slow) ? 1 : -1;
}

//+------------------------------------------------------------------+
//| Open Buy (IOC, lot validation)                                  |
//+------------------------------------------------------------------+
void OpenBuy(double atrValue)
{
   double lotSize = CalculateLotSize(atrValue, ORDER_TYPE_BUY);
   double minLot = SymbolInfoDouble(expertSymbol, SYMBOL_VOLUME_MIN);
   if(lotSize < minLot || lotSize <= 0)
   {
      Print("Invalid BUY lot: ", lotSize, " (min=", minLot, ")");
      return;
   }
   
   double entry = SymbolInfoDouble(expertSymbol, SYMBOL_ASK);
   double sl = entry - (atrValue * InpATRMultiplierSL);
   double tp = entry + (atrValue * InpATRMultiplierTP);
   
   long stopsLevel = SymbolInfoInteger(expertSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * pointValue + 2 * pointValue;
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
   req.type_filling = ORDER_FILLING_IOC;
   
   if(OrderSend(req, res))
      if(InpPrintLog) Print("BUY | Lot: ", lotSize, " Entry: ", entry);
   else
      Print("BUY failed: ", res.retcode);
}

//+------------------------------------------------------------------+
//| Open Sell (IOC, lot validation)                                 |
//+------------------------------------------------------------------+
void OpenSell(double atrValue)
{
   double lotSize = CalculateLotSize(atrValue, ORDER_TYPE_SELL);
   double minLot = SymbolInfoDouble(expertSymbol, SYMBOL_VOLUME_MIN);
   if(lotSize < minLot || lotSize <= 0)
   {
      Print("Invalid SELL lot: ", lotSize, " (min=", minLot, ")");
      return;
   }
   
   double entry = SymbolInfoDouble(expertSymbol, SYMBOL_BID);
   double sl = entry + (atrValue * InpATRMultiplierSL);
   double tp = entry - (atrValue * InpATRMultiplierTP);
   
   long stopsLevel = SymbolInfoInteger(expertSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * pointValue + 2 * pointValue;
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
   req.type_filling = ORDER_FILLING_IOC;
   
   if(OrderSend(req, res))
      if(InpPrintLog) Print("SELL | Lot: ", lotSize, " Entry: ", entry);
   else
      Print("SELL failed: ", res.retcode);
}

//+------------------------------------------------------------------+
//| Calculate lot size – guaranteed valid (never zero)              |
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
      if(slDistance > 0 && tickSiz > 0 && tickVal > 0)
      {
         double slTicks = slDistance / tickSiz;
         lotSize = riskAmount / (slTicks * tickVal);
         double step = SymbolInfoDouble(expertSymbol, SYMBOL_VOLUME_STEP);
         if(step > 0) lotSize = MathFloor(lotSize / step) * step;
      }
   }
   
   double minLot = SymbolInfoDouble(expertSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(expertSymbol, SYMBOL_VOLUME_MAX);
   if(lotSize < minLot || lotSize <= 0) lotSize = minLot;
   if(lotSize > maxLot) lotSize = maxLot;
   
   double maxAllowed = AccountInfoDouble(ACCOUNT_BALANCE) / 200.0;
   if(lotSize > maxAllowed) lotSize = maxAllowed;
   
   double step = SymbolInfoDouble(expertSymbol, SYMBOL_VOLUME_STEP);
   if(step > 0) lotSize = MathRound(lotSize / step) * step;
   if(lotSize < minLot) lotSize = minLot;
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Count open positions for this EA                                |
//+------------------------------------------------------------------+
int CountOpenPositions(int type = -1)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) &&
         PositionGetString(POSITION_SYMBOL) == expertSymbol &&
         PositionGetInteger(POSITION_MAGIC) == expertMagic)
      {
         if(type == -1 || (int)PositionGetInteger(POSITION_TYPE) == type)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Trailing stop management                                        |
//+------------------------------------------------------------------+
void ManageTrailingStops()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != expertSymbol ||
         PositionGetInteger(POSITION_MAGIC) != expertMagic) continue;
      
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      int typ = (int)PositionGetInteger(POSITION_TYPE);
      double price, newSL;
      
      if(typ == POSITION_TYPE_BUY)
      {
         price = SymbolInfoDouble(expertSymbol, SYMBOL_BID);
         double profitPips = (price - open) / pointValue;
         if(profitPips >= InpTrailingStart)
         {
            newSL = price - InpTrailingStep * pointValue;
            if(newSL > sl) ModifyStopLoss(t, newSL);
         }
      }
      else
      {
         price = SymbolInfoDouble(expertSymbol, SYMBOL_ASK);
         double profitPips = (open - price) / pointValue;
         if(profitPips >= InpTrailingStart)
         {
            newSL = price + InpTrailingStep * pointValue;
            if(newSL < sl || sl == 0) ModifyStopLoss(t, newSL);
         }
      }
   }
}

void ModifyStopLoss(ulong ticket, double newSL)
{
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol = expertSymbol;
   req.sl = newSL;
   req.tp = PositionGetDouble(POSITION_TP);
   req.magic = expertMagic;
   if(!OrderSend(req, res))
      Print("Trail modify error: ", res.retcode);
}

//+------------------------------------------------------------------+
//| FIFO‑safe close all positions (oldest first)                    |
//+------------------------------------------------------------------+
void CloseAllPositionsFIFO()
{
   // Collect all tickets for this EA
   ulong tickets[];
   int total = PositionsTotal();
   ArrayResize(tickets, total);
   int count = 0;
   
   for(int i = 0; i < total; i++)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) &&
         PositionGetString(POSITION_SYMBOL) == expertSymbol &&
         PositionGetInteger(POSITION_MAGIC) == expertMagic)
      {
         tickets[count] = t;
         count++;
      }
   }
   ArrayResize(tickets, count);
   
   // Sort by opening time (oldest first)
   for(int i = 0; i < count - 1; i++)
   {
      for(int j = i + 1; j < count; j++)
      {
         PositionSelectByTicket(tickets[i]);
         datetime time_i = (datetime)PositionGetInteger(POSITION_TIME);
         PositionSelectByTicket(tickets[j]);
         datetime time_j = (datetime)PositionGetInteger(POSITION_TIME);
         if(time_i > time_j)
         {
            ulong temp = tickets[i];
            tickets[i] = tickets[j];
            tickets[j] = temp;
         }
      }
   }
   
   // Close oldest first
   for(int i = 0; i < count; i++)
      ClosePosition(tickets[i]);
}

//+------------------------------------------------------------------+
//| Close a single position (used by FIFO)                          |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.position = ticket;
   req.symbol = expertSymbol;
   req.volume = PositionGetDouble(POSITION_VOLUME);
   req.deviation = InpSlippage;
   req.magic = expertMagic;
   req.comment = "Close FIFO";
   
   if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      req.type = ORDER_TYPE_SELL;
   else
      req.type = ORDER_TYPE_BUY;
   
   req.price = (req.type == ORDER_TYPE_BUY) ?
               SymbolInfoDouble(expertSymbol, SYMBOL_ASK) :
               SymbolInfoDouble(expertSymbol, SYMBOL_BID);
   
   if(!OrderSend(req, res))
      Print("Close error on ticket ", ticket, ": ", res.retcode);
   else
      if(InpPrintLog) Print("Closed position ", ticket);
}

//+------------------------------------------------------------------+
//| Helper functions                                                |
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
      isTradingPaused = true;
      return true;
   }
   MqlDateTime dt; TimeCurrent(dt);
   static int lastDay = dt.day;
   if(dt.day != lastDay)
   {
      dailyStartingBalance = curBal;
      lastDay = dt.day;
      isTradingPaused = false;
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
      Print("MAX DRAWDOWN: ", DoubleToString(dd,2), "%. Closing all positions (FIFO).");
      drawdownLimitHit = true;
      CloseAllPositionsFIFO();   // ✅ uses FIFO order
      return true;
   }
   return false;
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
