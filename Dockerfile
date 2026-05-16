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
//|                                               TrendScalper.mq5   |
//|                  Trend Following with ATR Trailing Stop          |
//|                     Works on high-spread crypto brokers          |
//+------------------------------------------------------------------+
#property copyright "TrendScalper"
#property version   "2.00"
#include <Trade/Trade.mqh>

//==================== INPUTS ====================
input double   RiskPercent          = 2.0;      // Risk per trade (% of equity)
input double   FixedLot             = 0.01;
input bool     UseAutoLot           = true;

input int      TrendFastEMA         = 20;       // Fast EMA (H1)
input int      TrendSlowEMA         = 50;       // Slow EMA (H1)
input int      EntryFastEMA         = 9;        // Fast EMA for pullback entry (M5)
input int      ATRPeriod            = 14;       // ATR period
input double   ATRStopMultiplier    = 2.5;      // ATR multiplier for stop loss

input int      MaxSpreadPoints      = 100000;   // Very high spread allowed
input int      MaxOpenPositions     = 1;

input double   MaxDailyLossPercent  = 8.0;
input double   MaxDrawdownPercent   = 15.0;

input int      MagicNumber          = 99001;
input int      Slippage             = 50;

input bool     DebugMode            = true;

//==================== GLOBALS ====================
string         symbol;
double         pointValue, tickValue, tickSize;
double         dailyStartBalance;
bool           tradingPaused = false;
bool           drawdownHit   = false;
datetime       lastDebugTime = 0;
datetime       lastBarTimeH1 = 0;
datetime       lastBarTimeM5 = 0;

int            h1_fast_handle, h1_slow_handle;
int            m5_fast_handle;
int            atr_handle;
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

   h1_fast_handle = iMA(symbol, PERIOD_H1, TrendFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   h1_slow_handle = iMA(symbol, PERIOD_H1, TrendSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   m5_fast_handle = iMA(symbol, PERIOD_M5, EntryFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   atr_handle     = iATR(symbol, PERIOD_M5, ATRPeriod);

   if(h1_fast_handle == INVALID_HANDLE || h1_slow_handle == INVALID_HANDLE ||
      m5_fast_handle == INVALID_HANDLE || atr_handle == INVALID_HANDLE)
   {
      Print("Indicator creation failed");
      return INIT_FAILED;
   }

   Print("==============================================");
   Print("✅ TrendScalper started on ", symbol);
   Print("   H1 Trend EMA: ", TrendFastEMA, "/", TrendSlowEMA);
   Print("   ATR stop multiplier: ", ATRStopMultiplier);
   Print("==============================================");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(h1_fast_handle != INVALID_HANDLE) IndicatorRelease(h1_fast_handle);
   if(h1_slow_handle != INVALID_HANDLE) IndicatorRelease(h1_slow_handle);
   if(m5_fast_handle != INVALID_HANDLE) IndicatorRelease(m5_fast_handle);
   if(atr_handle != INVALID_HANDLE) IndicatorRelease(atr_handle);
   Print("EA removed");
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) return;
   if(drawdownHit || tradingPaused) return;
   if(CheckDailyLoss()) return;
   if(CheckDrawdown()) return;
   if(GetSpreadPoints() > MaxSpreadPoints) return;
   if(CountPositions() >= MaxOpenPositions) return;

   // ---------- H1 trend update (once per hour) ----------
   datetime curBarH1 = iTime(symbol, PERIOD_H1, 0);
   if(curBarH1 != lastBarTimeH1)
   {
      lastBarTimeH1 = curBarH1;
      double h1_fast[], h1_slow[];
      ArraySetAsSeries(h1_fast, true); ArraySetAsSeries(h1_slow, true);
      if(CopyBuffer(h1_fast_handle, 0, 0, 2, h1_fast) >= 2 &&
         CopyBuffer(h1_slow_handle, 0, 0, 2, h1_slow) >= 2)
      {
         bool uptrend_h1 = (h1_fast[0] > h1_slow[0]);
         bool downtrend_h1 = (h1_fast[0] < h1_slow[0]);
         GlobalVariableSet("Trend_H1", uptrend_h1 ? 1 : (downtrend_h1 ? -1 : 0));
         if(DebugMode) Print("H1 Trend updated: ", uptrend_h1 ? "UP" : (downtrend_h1 ? "DOWN" : "FLAT"));
      }
   }

   // ---------- M5 entry check (on each new M5 bar) ----------
   datetime curBarM5 = iTime(symbol, PERIOD_M5, 0);
   if(curBarM5 == lastBarTimeM5) return;
   lastBarTimeM5 = curBarM5;

   double trendH1 = GlobalVariableGet("Trend_H1");
   if(trendH1 == 0) return;

   // Get M5 fast EMA
   double m5_fast[];
   ArraySetAsSeries(m5_fast, true);
   if(CopyBuffer(m5_fast_handle, 0, 0, 2, m5_fast) < 2) return;

   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double price = (trendH1 == 1) ? ask : bid;
   double fastEMA = m5_fast[0];

   // Entry condition: pullback to EMA in trend direction
   bool buySignal = (trendH1 == 1 && bid <= fastEMA);
   bool sellSignal = (trendH1 == -1 && ask >= fastEMA);

   // Debug print every 10 seconds
   if(DebugMode && TimeCurrent() - lastDebugTime >= 10)
   {
      lastDebugTime = TimeCurrent();
      Print("DEBUG | H1 trend: ", (trendH1==1?"UP":(trendH1==-1?"DOWN":"FLAT")),
            " | M5 FastEMA=", DoubleToString(fastEMA,2),
            " | Ask=", ask, " | Bid=", bid,
            " | Spread=", GetSpreadPoints());
   }

   if(buySignal)
   {
      Print("🔥 BUY SIGNAL | Price=", ask, " | FastEMA=", fastEMA);
      OpenOrder(ORDER_TYPE_BUY);
   }
   else if(sellSignal)
   {
      Print("🔥 SELL SIGNAL | Price=", bid, " | FastEMA=", fastEMA);
      OpenOrder(ORDER_TYPE_SELL);
   }

   // Manage trailing stops for open positions
   ManageTrailingStops();
}

//+------------------------------------------------------------------+
void OpenOrder(ENUM_ORDER_TYPE type)
{
   double lot = CalculateLot();
   if(lot <= 0) return;

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                                           : SymbolInfoDouble(symbol, SYMBOL_BID);
   price = NormalizeDouble(price, digits);

   // Get current ATR value (M5)
   double atrVal = 0;
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(atr_handle, 0, 0, 1, atrBuf) == 1)
      atrVal = atrBuf[0];
   else
      atrVal = 50 * pointValue;   // fallback 50 points

   double stopDist = atrVal * ATRStopMultiplier;
   double tpDist = stopDist * 1.2;   // 1.2:1 risk-reward

   // Enforce broker minimum stop distance (convert to price distance)
   long stopsLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopPrice = stopsLevel * pointValue;
   if(stopDist < minStopPrice) stopDist = minStopPrice;
   if(tpDist < minStopPrice) tpDist = minStopPrice;

   double sl = (type == ORDER_TYPE_BUY) ? price - stopDist : price + stopDist;
   double tp = (type == ORDER_TYPE_BUY) ? price + tpDist : price - tpDist;
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   Print("📊 ORDER | Lot=", lot, " Price=", price, " SL=", sl, " TP=", tp,
         " | StopDist=", stopDist/pointValue, " pts");

   bool result = false;
   if(type == ORDER_TYPE_BUY)
      result = trade.Buy(lot, symbol, price, sl, tp, "TrendScalper BUY");
   else
      result = trade.Sell(lot, symbol, price, sl, tp, "TrendScalper SELL");

   if(result)
      Print("✅ ORDER SUCCESS");
   else
      Print("❌ ORDER FAILED | retcode=", trade.ResultRetcode(), " | ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
double CalculateLot()
{
   if(!UseAutoLot) return FixedLot;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * RiskPercent / 100.0;
   double atrVal = 0;
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(atr_handle, 0, 0, 1, atrBuf) == 1)
      atrVal = atrBuf[0];
   else
      atrVal = 50 * pointValue;
   double stopDist = atrVal * ATRStopMultiplier;
   long stopsLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopPrice = stopsLevel * pointValue;
   if(stopDist < minStopPrice) stopDist = minStopPrice;
   double stopPoints = stopDist / pointValue;
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
void ManageTrailingStops()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID)
                                                 : SymbolInfoDouble(symbol, SYMBOL_ASK);

      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(atr_handle, 0, 0, 1, atrBuf) < 1) continue;
      double trailDist = atrBuf[0] * ATRStopMultiplier;

      double newSL = (type == POSITION_TYPE_BUY) ? price - trailDist : price + trailDist;
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      newSL = NormalizeDouble(newSL, digits);
      if((type == POSITION_TYPE_BUY && newSL > currentSL) ||
         (type == POSITION_TYPE_SELL && (newSL < currentSL || currentSL == 0)))
         trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
   }
}

//+------------------------------------------------------------------+
int CountPositions()
{
   int cnt = 0;
   for(int i = 0; i < PositionsTotal(); i++)
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
   {
      Print("Daily loss limit (", MaxDailyLossPercent, "%) reached.");
      tradingPaused = true;
      return true;
   }
   MqlDateTime dt;
   TimeCurrent(dt);
   static int lastDay = dt.day;
   if(dt.day != lastDay)
   {
      dailyStartBalance = curBal;
      lastDay = dt.day;
      tradingPaused = false;
   }
   return false;
}

bool CheckDrawdown()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal <= 0) return false;
   double ddPct = (bal - eq) / bal * 100.0;
   if(ddPct >= MaxDrawdownPercent && !drawdownHit)
   {
      Print("Max drawdown (", MaxDrawdownPercent, "%) reached. Closing all.");
      drawdownHit = true;
      for(int i = PositionsTotal()-1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            trade.PositionClose(t);
      }
      return true;
   }
   return false;
}
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
