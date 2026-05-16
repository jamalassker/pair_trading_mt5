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
//|                     RSI_Divergence_Scalper_FINAL                 |
//|                     Fixed: 10016 invalid stops                   |
//|                     ForceTestTrade opens a guaranteed buy        |
//+------------------------------------------------------------------+
#property copyright "RSI Divergence Scalper FINAL"
#property version   "4.00"
#property strict
#include <Trade/Trade.mqh>

//==================== INPUTS ====================
input double   RiskPercent          = 1.0;
input double   FixedLot             = 0.01;
input bool     UseAutoLot           = false;

input int      RSI_Period           = 7;
input int      LookbackBars         = 10;
input int      MinSwingDistance     = 1;

input int      ATR_Period           = 7;
input double   ATR_SL_Multiplier    = 5.0;      // Increased to force larger stop
input double   ATR_TP_Multiplier    = 6.0;

input int      MaxSpreadPoints      = 100000;
input int      MaxOpenPositions     = 1;

input double   MaxDailyLossPercent  = 20.0;
input double   MaxDrawdownPercent   = 40.0;

input int      MagicNumber          = 99001;
input int      Slippage             = 100;

input bool     DebugMode            = true;
input bool     EnableMomentumTrades = true;
input bool     EnableRSIReversal    = true;

// ============ FORCE TEST TRADE (use large stop) ============
input bool     ForceTestTrade       = true;   // <- SET TO TRUE TO OPEN A BUY

//==================== GLOBALS ====================
string         symbol;
double         pointValue, tickValue, tickSize;
double         dailyStartBalance;
bool           tradingPaused = false;
bool           drawdownHit   = false;
bool           forceTradeDone = false;
datetime       lastBarTime = 0;

int            atr_handle;
int            rsi_handle;
CTrade         trade;

//+------------------------------------------------------------------+
int OnInit()
{
   symbol = _Symbol;
   pointValue = SymbolInfoDouble(symbol, SYMBOL_POINT);
   tickValue  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   tickSize   = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFillingBySymbol(symbol);

   atr_handle = iATR(symbol, PERIOD_M5, ATR_Period);
   rsi_handle = iRSI(symbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);
   if(atr_handle == INVALID_HANDLE || rsi_handle == INVALID_HANDLE)
      return INIT_FAILED;

   Print("==========================================");
   Print("🚀 RSI DIVERGENCE SCALPER FINAL");
   Print("   Symbol: ", symbol, " | Timeframe: M5");
   Print("   ForceTestTrade = ", ForceTestTrade ? "ON (will open test BUY)" : "OFF");
   Print("==========================================");
   return INIT_SUCCEEDED;
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atr_handle != INVALID_HANDLE) IndicatorRelease(atr_handle);
   if(rsi_handle != INVALID_HANDLE) IndicatorRelease(rsi_handle);
}
//+------------------------------------------------------------------+
void OnTick()
{
   // Safety checks
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Comment("❌ AutoTrading disabled");
      return;
   }
   if(drawdownHit || tradingPaused) return;
   if(CheckDailyLoss() || CheckDrawdown()) return;
   if(GetSpreadPoints() > MaxSpreadPoints) return;
   if(CountPositions() >= MaxOpenPositions) return;

   // ========== FORCE TEST TRADE (with very large stop) ==========
   if(ForceTestTrade && !forceTradeDone)
   {
      forceTradeDone = true;
      Print("!!! FORCE TEST TRADE: placing one BUY order with large stop !!!");
      // Use a fixed huge stop distance: 15000 points = 150.0 price units
      double hugeStopPoints = 15000;   // 150.0 price difference
      double atrForTest = hugeStopPoints * pointValue;
      OpenOrder(ORDER_TYPE_BUY, atrForTest);
      return;   // skip signal logic on this tick
   }

   // Only on new M5 bar
   datetime curBar = iTime(symbol, PERIOD_M5, 0);
   if(curBar == lastBarTime) return;
   lastBarTime = curBar;

   // Get data
   double atrBuf[], rsiBuf[], closeBuf[];
   ArraySetAsSeries(atrBuf, true); ArraySetAsSeries(rsiBuf, true); ArraySetAsSeries(closeBuf, true);
   if(CopyBuffer(atr_handle, 0, 0, 3, atrBuf) < 3 ||
      CopyBuffer(rsi_handle, 0, 0, LookbackBars, rsiBuf) < LookbackBars ||
      CopyClose(symbol, PERIOD_M5, 0, LookbackBars, closeBuf) < LookbackBars)
      return;

   double atr = atrBuf[0];
   if(atr <= 0) atr = 500 * pointValue;

   // Signals (same as before)
   bool bullishSignal = false, bearishSignal = false;
   for(int i=2; i<LookbackBars-1; i++)
   {
      if(closeBuf[0] < closeBuf[i] && rsiBuf[0] >= rsiBuf[i]-5) { bullishSignal = true; break; }
      if(closeBuf[0] > closeBuf[i] && rsiBuf[0] <= rsiBuf[i]+5) { bearishSignal = true; break; }
   }
   if(EnableRSIReversal)
   {
      if(rsiBuf[0] < 40) bullishSignal = true;
      if(rsiBuf[0] > 60) bearishSignal = true;
   }
   if(EnableMomentumTrades && LookbackBars >= 3)
   {
      if(closeBuf[0] > closeBuf[1] && closeBuf[1] > closeBuf[2]) bullishSignal = true;
      if(closeBuf[0] < closeBuf[1] && closeBuf[1] < closeBuf[2]) bearishSignal = true;
   }

   if(bullishSignal && CountPositions() < MaxOpenPositions)
      OpenOrder(ORDER_TYPE_BUY, atr);
   else if(bearishSignal && CountPositions() < MaxOpenPositions)
      OpenOrder(ORDER_TYPE_SELL, atr);
}
//+------------------------------------------------------------------+
void OpenOrder(ENUM_ORDER_TYPE type, double atrVal)
{
   double lot = CalculateLot(atrVal);
   if(lot <= 0) return;

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                                           : SymbolInfoDouble(symbol, SYMBOL_BID);
   price = NormalizeDouble(price, digits);

   // === FORCE MINIMUM STOP DISTANCE (in points) ===
   // Broker minimum from settings
   long brokerMinPoints = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(brokerMinPoints < 2000) brokerMinPoints = 2000;   // Safety: at least 2000 points
   double minStopPrice = brokerMinPoints * pointValue;

   // Desired stop distance (ATR-based or fixed)
   double slDist = atrVal * ATR_SL_Multiplier;
   if(slDist < minStopPrice) slDist = minStopPrice + (500 * pointValue); // extra 500 points buffer
   double tpDist = slDist * (ATR_TP_Multiplier / ATR_SL_Multiplier);
   if(tpDist < minStopPrice) tpDist = minStopPrice;

   double sl = (type == ORDER_TYPE_BUY) ? price - slDist : price + slDist;
   double tp = (type == ORDER_TYPE_BUY) ? price + tpDist : price - tpDist;
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   Print("📊 ORDER PREP | Lot=", lot, " | Price=", price,
         " | SL dist=", (price-sl)/pointValue, " pts (broker min=", brokerMinPoints, ")",
         " | TP dist=", (tp-price)/pointValue, " pts");

   bool result = false;
   if(type == ORDER_TYPE_BUY)
      result = trade.Buy(lot, symbol, price, sl, tp, "[RSI_DIV] BUY");
   else
      result = trade.Sell(lot, symbol, price, sl, tp, "[RSI_DIV] SELL");

   if(result)
      Print("✅ ORDER SUCCESS");
   else
      Print("❌ ORDER FAILED | retcode=", trade.ResultRetcode(),
            " | ", trade.ResultRetcodeDescription());
}
//+------------------------------------------------------------------+
double CalculateLot(double atrVal)
{
   if(!UseAutoLot) return FixedLot;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * RiskPercent / 100.0;
   double stopPoints = (atrVal * ATR_SL_Multiplier) / pointValue;
   if(stopPoints <= 0) stopPoints = 2000;
   double riskPerLot = stopPoints * tickValue;
   if(riskPerLot <= 0) return FixedLot;
   double lot = riskMoney / riskPerLot;
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathFloor(lot / step) * step;
   if(lot < minLot) lot = minLot;
   return NormalizeDouble(lot, 2);
}
//+------------------------------------------------------------------+
int CountPositions()
{
   int cnt = 0;
   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         cnt++;
   }
   return cnt;
}
int GetSpreadPoints()
{
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   return (int)((ask - bid) / pointValue);
}
bool CheckDailyLoss()
{
   double curBal = AccountInfoDouble(ACCOUNT_BALANCE);
   double lossPct = (dailyStartBalance - curBal) / dailyStartBalance * 100.0;
   if(lossPct >= MaxDailyLossPercent && !tradingPaused)
   { tradingPaused = true; Print("Daily loss limit reached"); return true; }
   return false;
}
bool CheckDrawdown()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal <= 0) return false;
   double ddPct = (bal - eq) / bal * 100.0;
   if(ddPct >= MaxDrawdownPercent && !drawdownHit)
   { drawdownHit = true; Print("Max drawdown reached"); return true; }
   return false;
}
void ManageTrailing() {} // optional, not needed for test
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
