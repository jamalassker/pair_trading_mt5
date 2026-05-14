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
# AGGRESSIVE MICRO SCALPER EA – FIXED 4756
# ============================================================
RUN cat > /root/VALETAX_TICK_BOT_V16.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                     AggressiveMicroScalper_Final |
//|                              Opens trades reliably               |
//+------------------------------------------------------------------+
#property copyright "Aggressive Scalper EA"
#property version   "3.01"
#property strict

// --- Inputs (aggressive, adjustable) ---
input double   InpRiskPercent        = 2.0;
input double   InpFixedLot           = 0.01;
input bool     InpUseAutoLot         = true;
input double   InpMaxDailyLoss       = 20.0;
input double   InpMaxDrawdown        = 25.0;

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

input int      InpMagicNumber        = 20251001;
input int      InpSlippage           = 50;
input bool     InpPrintLog           = true;

input bool     InpAllowMultiplePerBar = true;
input bool     InpIgnoreTrendThreshold = true;

// --- Global ---
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
int OnInit()
{
   expertSymbol = Symbol();
   expertMagic = InpMagicNumber;

   pointValue = SymbolInfoDouble(expertSymbol, SYMBOL_POINT);
   tickSize   = SymbolInfoDouble(expertSymbol, SYMBOL_TRADE_TICK_SIZE);

   lastBarTime = iTime(expertSymbol, PERIOD_M1, 0);

   dailyStartingBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   emaFastHandle = iMA(expertSymbol, PERIOD_M1, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(expertSymbol, PERIOD_M1, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle     = iRSI(expertSymbol, PERIOD_M1, InpRSIPeriod, PRICE_CLOSE);
   atrHandle     = iATR(expertSymbol, PERIOD_M1, InpATRPeriod);

   if(emaFastHandle==INVALID_HANDLE ||
      emaSlowHandle==INVALID_HANDLE ||
      rsiHandle==INVALID_HANDLE ||
      atrHandle==INVALID_HANDLE)
      return INIT_FAILED;

   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);

   Print("EA started on ", expertSymbol);
   Print("Broker filling mode = ",
         SymbolInfoInteger(expertSymbol, SYMBOL_FILLING_MODE));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(emaFastHandle!=INVALID_HANDLE) IndicatorRelease(emaFastHandle);
   if(emaSlowHandle!=INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
   if(rsiHandle!=INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(atrHandle!=INVALID_HANDLE) IndicatorRelease(atrHandle);

   Print("EA removed");
}

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

   datetime currentBarTime = iTime(expertSymbol, PERIOD_M1, 0);

   if(!InpAllowMultiplePerBar &&
      currentBarTime == lastBarTime)
      return;

   if(currentBarTime != lastBarTime)
      lastBarTime = currentBarTime;

   if(!UpdateIndicatorData()) return;

   double fastEMA = emaFast[0];
   double slowEMA = emaSlow[0];
   double rsiValue = rsi[0];
   double atrValue = atr[0];

   int trend = DetermineTrend(fastEMA, slowEMA);

   bool buySignal = false;
   bool sellSignal = false;

   if(trend == 1 ||
      (InpIgnoreTrendThreshold && fastEMA > slowEMA))
   {
      double price = SymbolInfoDouble(expertSymbol, SYMBOL_BID);

      double emaDist =
         MathAbs(price - fastEMA) / pointValue;

      double maxDist =
         InpIgnoreTrendThreshold ?
         100 :
         (atrValue / pointValue);

      if(emaDist <= maxDist &&
         rsiValue < InpRSIOverbought)
         buySignal = true;
   }

   if(trend == -1 ||
      (InpIgnoreTrendThreshold && fastEMA < slowEMA))
   {
      double price = SymbolInfoDouble(expertSymbol, SYMBOL_ASK);

      double emaDist =
         MathAbs(price - fastEMA) / pointValue;

      double maxDist =
         InpIgnoreTrendThreshold ?
         100 :
         (atrValue / pointValue);

      if(emaDist <= maxDist &&
         rsiValue > InpRSIOversold)
         sellSignal = true;
   }

   if(buySignal &&
      CountOpenPositions(ORDER_TYPE_BUY) < 2)
      OpenBuy(atrValue);

   if(sellSignal &&
      CountOpenPositions(ORDER_TYPE_SELL) < 2)
      OpenSell(atrValue);

   if(InpUseTrailing)
      ManageTrailingStops();
}

//+------------------------------------------------------------------+
int DetermineTrend(double fast, double slow)
{
   double diff = fast - slow;
   double threshold = pointValue * 5;

   if(MathAbs(diff) < threshold)
      return 0;

   return (fast > slow) ? 1 : -1;
}

//+------------------------------------------------------------------+
void OpenBuy(double atrValue)
{
   double lotSize =
      CalculateLotSize(atrValue, ORDER_TYPE_BUY);

   double minLot =
      SymbolInfoDouble(expertSymbol, SYMBOL_VOLUME_MIN);

   if(lotSize < minLot || lotSize <= 0)
   {
      Print("BUY lot invalid: ", lotSize);
      return;
   }

   double entry =
      SymbolInfoDouble(expertSymbol, SYMBOL_ASK);

   double sl =
      entry - (atrValue * InpATRMultiplierSL);

   double tp =
      entry + (atrValue * InpATRMultiplierTP);

   long stopsLevel =
      SymbolInfoInteger(expertSymbol,
                        SYMBOL_TRADE_STOPS_LEVEL);

   long freezeLevel =
      SymbolInfoInteger(expertSymbol,
                        SYMBOL_TRADE_FREEZE_LEVEL);

   double minDist =
      MathMax(stopsLevel, freezeLevel)
      * pointValue
      + 3 * pointValue;

   if(entry - sl < minDist)
      sl = entry - minDist;

   if(tp - entry < minDist)
      tp = entry + minDist;

   // ===== FIXED FILLING MODE =====
   ENUM_ORDER_TYPE_FILLING fillMode;

   long brokerFillMode =
      SymbolInfoInteger(expertSymbol,
                        SYMBOL_FILLING_MODE);

   if(brokerFillMode == SYMBOL_FILLING_FOK)
      fillMode = ORDER_FILLING_FOK;
   else if(brokerFillMode == SYMBOL_FILLING_IOC)
      fillMode = ORDER_FILLING_IOC;
   else
      fillMode = ORDER_FILLING_RETURN;

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = expertSymbol;
   req.volume       = lotSize;
   req.type         = ORDER_TYPE_BUY;
   req.price        = entry;

   // TEMPORARY FIX FOR SOME BROKERS
   // REMOVE THESE IF NEEDED
   req.sl           = 0;
   req.tp           = 0;

   req.deviation    = InpSlippage;
   req.magic        = expertMagic;
   req.comment      = "Aggressive BUY";
   req.type_filling = fillMode;

   bool sent = OrderSend(req, res);

   Print("BUY | sent=", sent,
         " retcode=", res.retcode,
         " comment=", res.comment,
         " error=", GetLastError());

   if(sent &&
      (res.retcode == TRADE_RETCODE_DONE ||
       res.retcode == TRADE_RETCODE_PLACED))
   {
      Print("BUY OPENED");

      // Apply SL/TP after execution
      if(PositionSelect(expertSymbol))
      {
         ulong ticket =
            PositionGetInteger(POSITION_TICKET);

         ModifyPositionSLTP(ticket, sl, tp);
      }
   }
}

//+------------------------------------------------------------------+
void OpenSell(double atrValue)
{
   double lotSize =
      CalculateLotSize(atrValue, ORDER_TYPE_SELL);

   double minLot =
      SymbolInfoDouble(expertSymbol, SYMBOL_VOLUME_MIN);

   if(lotSize < minLot || lotSize <= 0)
   {
      Print("SELL lot invalid: ", lotSize);
      return;
   }

   double entry =
      SymbolInfoDouble(expertSymbol, SYMBOL_BID);

   double sl =
      entry + (atrValue * InpATRMultiplierSL);

   double tp =
      entry - (atrValue * InpATRMultiplierTP);

   long stopsLevel =
      SymbolInfoInteger(expertSymbol,
                        SYMBOL_TRADE_STOPS_LEVEL);

   long freezeLevel =
      SymbolInfoInteger(expertSymbol,
                        SYMBOL_TRADE_FREEZE_LEVEL);

   double minDist =
      MathMax(stopsLevel, freezeLevel)
      * pointValue
      + 3 * pointValue;

   if(sl - entry < minDist)
      sl = entry + minDist;

   if(entry - tp < minDist)
      tp = entry - minDist;

   // ===== FIXED FILLING MODE =====
   ENUM_ORDER_TYPE_FILLING fillMode;

   long brokerFillMode =
      SymbolInfoInteger(expertSymbol,
                        SYMBOL_FILLING_MODE);

   if(brokerFillMode == SYMBOL_FILLING_FOK)
      fillMode = ORDER_FILLING_FOK;
   else if(brokerFillMode == SYMBOL_FILLING_IOC)
      fillMode = ORDER_FILLING_IOC;
   else
      fillMode = ORDER_FILLING_RETURN;

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = expertSymbol;
   req.volume       = lotSize;
   req.type         = ORDER_TYPE_SELL;
   req.price        = entry;

   // TEMPORARY FIX FOR SOME BROKERS
   req.sl           = 0;
   req.tp           = 0;

   req.deviation    = InpSlippage;
   req.magic        = expertMagic;
   req.comment      = "Aggressive SELL";
   req.type_filling = fillMode;

   bool sent = OrderSend(req, res);

   Print("SELL | sent=", sent,
         " retcode=", res.retcode,
         " comment=", res.comment,
         " error=", GetLastError());

   if(sent &&
      (res.retcode == TRADE_RETCODE_DONE ||
       res.retcode == TRADE_RETCODE_PLACED))
   {
      Print("SELL OPENED");

      if(PositionSelect(expertSymbol))
      {
         ulong ticket =
            PositionGetInteger(POSITION_TICKET);

         ModifyPositionSLTP(ticket, sl, tp);
      }
   }
}

//+------------------------------------------------------------------+
void ModifyPositionSLTP(ulong ticket,
                        double sl,
                        double tp)
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action   = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol   = expertSymbol;
   req.sl       = sl;
   req.tp       = tp;

   OrderSend(req, res);

   Print("SLTP MODIFY | retcode=",
         res.retcode,
         " comment=",
         res.comment);
}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Lot size calculation – MANUAL LOT ONLY                          |
//+------------------------------------------------------------------+
double CalculateLotSize(double atrValue, int orderType)
{
   // use ONLY manual fixed lot
   double lotSize = InpFixedLot;

   double minLot = SymbolInfoDouble(expertSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(expertSymbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(expertSymbol, SYMBOL_VOLUME_STEP);

   // keep inside broker limits
   if(lotSize < minLot)
      lotSize = minLot;

   if(lotSize > maxLot)
      lotSize = maxLot;

   // normalize to broker step
   if(step > 0)
      lotSize = MathFloor(lotSize / step) * step;

   lotSize = NormalizeDouble(lotSize, 2);

   return lotSize;
}

//+------------------------------------------------------------------+
int CountOpenPositions(int type = -1)
{
   int count = 0;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);

      if(PositionSelectByTicket(t) &&
         PositionGetString(POSITION_SYMBOL) ==
         expertSymbol &&
         PositionGetInteger(POSITION_MAGIC) ==
         expertMagic)
      {
         if(type == -1 ||
            (int)PositionGetInteger(POSITION_TYPE)
            == type)
            count++;
      }
   }

   return count;
}

//+------------------------------------------------------------------+
void ManageTrailingStops(){}
bool UpdateIndicatorData()
{
   if(CopyBuffer(emaFastHandle,0,0,3,emaFast)<3)
      return false;

   if(CopyBuffer(emaSlowHandle,0,0,3,emaSlow)<3)
      return false;

   if(CopyBuffer(rsiHandle,0,0,3,rsi)<3)
      return false;

   if(CopyBuffer(atrHandle,0,0,3,atr)<3)
      return false;

   return true;
}

bool IsTradingSession(){ return true; }
bool IsNewsTime(){ return false; }
bool CheckDailyLossLimit(){ return false; }
bool CheckDrawdownLimit(){ return false; }

//+------------------------------------------------------------------+
EOF

# ============================================================
# ENTRYPOINT SCRIPT
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

cp /root/VALETAX_TICK_BOT_V16.mq5 \
   "$DATA_DIR/Experts/"

METAEDITOR="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"

if [ -f "$METAEDITOR" ]; then
    wine "$METAEDITOR" \
    /compile:"$DATA_DIR/Experts/VALETAX_TICK_BOT_V16.mq5" \
    /log:"/root/compile.log"

    echo "Compilation log:"
    cat /root/compile.log
else
    echo "metaeditor64.exe not found. EA not compiled."
fi

python3 -m mt5linux \
    --host 0.0.0.0 \
    --port 8001 &

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
