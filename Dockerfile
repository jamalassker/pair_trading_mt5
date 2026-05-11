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
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# =========================================================
# V16.3 - PROFIT-MAX VELOCITY BOT (ULTRA PROFITABILITY)
# =========================================================
RUN cat > /root/VALETAX_TICK_BOT_V16.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                    BB_Squeeze_Scalper.mq5       |
//|                     Bollinger Bands squeeze + breakout          |
//|                     Fast in/out with profit                     |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Scalper"
#property version   "1.0"
#property strict

// --- INPUTS --------------------------------------------------------+
input string   SymbolToTrade     = "EURUSD.vx";
input double   RiskPercent       = 1.0;            // % equity per trade
input int      BB_Period         = 20;             // Bollinger Bands period
input double   BB_Deviation      = 2.0;            // Standard deviations
input int      ATR_Period        = 14;             // For dynamic SL/TP
input int      StopLossATR       = 1;              // Stop loss multiplier (e.g., 1 = 1x ATR)
input int      TakeProfitATR     = 2;              // Take profit multiplier
input bool     CloseOnAnyProfit  = true;           // Close as soon as profit > 0 (overrides TP)
input int      MagicNumber       = 999002;
input int      StartHour         = 8;
input int      EndHour           = 16;
input double   MaxDailyLossPercent = 5.0;
input bool     DebugPrint        = true;

// --- GLOBALS -------------------------------------------------------+
CTrade trade;
datetime lastBar = 0;
datetime dayStart = 0;
double dailyEquityStart = 0;
int consecutiveLosses = 0;
bool tradingEnabled = true;
ulong currentTicket = 0;
int bb_handle, atr_handle;
double bb_upper[], bb_lower[], atr_values[];

//+------------------------------------------------------------------+
bool IsTradingHours() {
   MqlDateTime dt;
   TimeCurrent(dt);
   return (dt.hour >= StartHour && dt.hour < EndHour);
}

//+------------------------------------------------------------------+
bool IsSqueeze() {
   double spread = bb_upper[0] - bb_lower[0];
   // Simple: bandwidth less than 20% of middle band? but easier: compare to recent range
   // For simplicity, we just check if current candle is inside bands (no breakout yet)
   // Actually we want to detect when bands are narrow, then wait for breakout.
   // We'll use a dynamic threshold: spread < 1.5 * ATR(14)
   if(CopyBuffer(atr_handle, 0, 0, 1, atr_values) < 1) return false;
   return (spread < atr_values[0] * 1.5);
}

//+------------------------------------------------------------------+
bool IsBreakoutUp() {
   double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   return (ask > bb_upper[0]);
}
bool IsBreakoutDown() {
   double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   return (bid < bb_lower[0]);
}

//+------------------------------------------------------------------+
void CloseTrade() {
   if(currentTicket != 0 && PositionSelectByTicket(currentTicket)) {
      trade.PositionClose(currentTicket);
      Print("Closed trade, ticket: ", currentTicket);
      currentTicket = 0;
   }
}

//+------------------------------------------------------------------+
void OpenTrade(int direction) {
   double point = SymbolInfoDouble(SymbolToTrade, SYMBOL_POINT);
   double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lot = NormalizeDouble(equity / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   lot = MathMin(lot, SymbolInfoDouble(SymbolToTrade, SYMBOL_VOLUME_MAX));
   
   // Get current ATR value (in pips)
   if(CopyBuffer(atr_handle, 0, 0, 1, atr_values) < 1) {
      Print("ATR not ready");
      return;
   }
   double atr_pips = atr_values[0] / point;
   double sl_pips = atr_pips * StopLossATR;
   double tp_pips = atr_pips * TakeProfitATR;
   // Ensure minimum stop distance (to avoid "invalid stop" error)
   double min_dist = SymbolInfoInteger(SymbolToTrade, SYMBOL_TRADE_STOPS_LEVEL) * point;
   if(sl_pips * point < min_dist) sl_pips = min_dist / point;
   
   if(direction == 1) { // BUY
      double sl = ask - sl_pips * point;
      double tp = ask + tp_pips * point;
      if(trade.Buy(lot, SymbolToTrade, ask, sl, tp, "BB Squeeze Buy")) {
         currentTicket = trade.ResultOrder();
         Print("🔥 BUY | Lot=", lot, " SL=", sl, " TP=", tp);
      } else Print("❌ Buy failed. Error ", GetLastError());
   }
   else if(direction == -1) { // SELL
      double sl = bid + sl_pips * point;
      double tp = bid - tp_pips * point;
      if(trade.Sell(lot, SymbolToTrade, bid, sl, tp, "BB Squeeze Sell")) {
         currentTicket = trade.ResultOrder();
         Print("🔥 SELL | Lot=", lot, " SL=", sl, " TP=", tp);
      } else Print("❌ Sell failed. Error ", GetLastError());
   }
}

//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   SymbolSelect(SymbolToTrade, true);
   
   bb_handle = iBands(SymbolToTrade, PERIOD_M1, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   atr_handle = iATR(SymbolToTrade, PERIOD_M1, ATR_Period);
   if(bb_handle == INVALID_HANDLE || atr_handle == INVALID_HANDLE) return INIT_FAILED;
   
   ArraySetAsSeries(bb_upper, true);
   ArraySetAsSeries(bb_lower, true);
   ArraySetAsSeries(atr_values, true);
   
   dayStart = TimeCurrent();
   dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("==============================================");
   Print("⚡ BB SQUEEZE SCALPER (Fast profit exit)");
   Print("   Symbol: ", SymbolToTrade);
   Print("   Risk: ", RiskPercent, "%");
   Print("   Close on any profit: ", CloseOnAnyProfit);
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick() {
   if(!IsTradingHours()) {
      if(currentTicket != 0) CloseTrade();
      return;
   }
   
   datetime now = TimeCurrent();
   if(now - dayStart >= 86400) {
      dayStart = now;
      dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
      tradingEnabled = true;
      consecutiveLosses = 0;
      Print("✅ New trading day");
   }
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = (dailyEquityStart - equity) / dailyEquityStart * 100.0;
   if(lossPercent >= MaxDailyLossPercent) {
      if(tradingEnabled) Print("🚨 Daily loss limit reached");
      tradingEnabled = false;
      return;
   }
   if(!tradingEnabled && lossPercent < MaxDailyLossPercent-2) tradingEnabled = true;
   if(!tradingEnabled) return;
   
   // --- Manage open position ---
   if(currentTicket != 0 && PositionSelectByTicket(currentTicket)) {
      if(CloseOnAnyProfit) {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit > 0) {
            CloseTrade();
            Print("✅ Closed on profit: $", profit);
            consecutiveLosses = 0;
            return;
         }
      }
      return; // still open
   }
   // Clean up if position gone
   if(currentTicket != 0 && !PositionSelectByTicket(currentTicket)) currentTicket = 0;
   if(currentTicket != 0) return;
   
   // --- Cooldown and bar check ---
   static datetime lastTradeTime = 0;
   if(now - lastTradeTime < 3) return;  // 3 sec cooldown
   datetime currentBar = iTime(SymbolToTrade, PERIOD_M1, 0);
   if(currentBar == lastBar) return;
   lastBar = currentBar;
   
   // --- Get indicator data ---
   if(CopyBuffer(bb_handle, 1, 0, 1, bb_upper) < 1 ||
      CopyBuffer(bb_handle, 2, 0, 1, bb_lower) < 1) return;
   
   // --- Identify squeeze ---
   if(!IsSqueeze()) return;
   
   // --- Wait for breakout on next candle ---
   // Instead of checking on same bar, we'll check if current price breaks out after squeeze.
   if(IsBreakoutUp()) {
      OpenTrade(1);
      lastTradeTime = now;
   }
   else if(IsBreakoutDown()) {
      OpenTrade(-1);
      lastTradeTime = now;
   }
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   IndicatorRelease(bb_handle);
   IndicatorRelease(atr_handle);
   Print("EA removed.");
}
//+------------------------------------------------------------------+
EOF

# ============================================
# 3. INSTALLATION & ENTRYPOINT
# ============================================
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
[ ! -f "$MT5_EXE" ] && wine /root/mt5setup.exe /auto && sleep 90
wine "$MT5_EXE" &
sleep 30

DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)
[ -z "$DATA_DIR" ] && DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
mkdir -p "$DATA_DIR/Experts"
cp /root/VALETAX_TICK_BOT_V16.mq5 "$DATA_DIR/Experts/VALETAX_TICK_BOT_V16.mq5"
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe" /compile:"$DATA_DIR/Experts/VALETAX_TICK_BOT_V16.mq5" /log:"/root/compile.log"

python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
