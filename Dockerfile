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
//|                                    LiquiditySweep_Simple.mq5    |
//|                     Only sweep + reclaim, no extra filters      |
//|                     Designed to open trades on M1 quickly       |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Simple Sweep Scalper"
#property version   "2.0"
#property strict

// --- INPUTS --------------------------------------------------------+
input string   SymbolToTrade     = "EURUSD.vx";
input double   RiskPercent       = 1.0;
input int      LookbackBars      = 20;             // Bars to find swing low/high
input double   SweepPoints       = 3;              // Points beyond swing to qualify as sweep (in points, not pips)
input int      MaxReclaimBars    = 2;              // Reclaim must happen within this many bars
input int      StopLossPoints    = 10;             // Fixed stop loss in points
input int      TakeProfitPoints  = 15;             // Fixed take profit in points
input bool     CloseOnAnyProfit  = true;           // Close as soon as profit > 0
input int      MagicNumber       = 999333;
input int      StartHour         = 0;              // 0 = all day, set 8-16 for session
input int      EndHour           = 24;
input double   MaxDailyLossPercent = 5.0;
input int      ConsecutiveLossLimit = 3;
input bool     DebugPrint        = true;

// --- GLOBALS -------------------------------------------------------+
CTrade trade;
datetime lastBar = 0;
datetime dayStart = 0;
double dailyEquityStart = 0;
int consecutiveLosses = 0;
bool tradingEnabled = true;
ulong currentTicket = 0;
double point;

//+------------------------------------------------------------------+
bool IsTradingTime() {
   MqlDateTime dt;
   TimeCurrent(dt);
   return (dt.hour >= StartHour && dt.hour < EndHour);
}

double GetSwingLow() {
   double low = DBL_MAX;
   for(int i=2; i<=LookbackBars+1; i++) {
      double l = iLow(SymbolToTrade, PERIOD_M1, i);
      if(l < low) low = l;
   }
   return low;
}
double GetSwingHigh() {
   double high = -DBL_MAX;
   for(int i=2; i<=LookbackBars+1; i++) {
      double h = iHigh(SymbolToTrade, PERIOD_M1, i);
      if(h > high) high = h;
   }
   return high;
}

void CloseTrade() {
   if(currentTicket != 0 && PositionSelectByTicket(currentTicket)) {
      trade.PositionClose(currentTicket);
      Print("Closed trade, ticket: ", currentTicket);
      currentTicket = 0;
   }
}

void OpenTrade(int direction) {
   double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lot = NormalizeDouble(equity / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   lot = MathMin(lot, SymbolInfoDouble(SymbolToTrade, SYMBOL_VOLUME_MAX));
   
   // Ensure stop loss > broker minimum
   int stopsLevel = (int)SymbolInfoInteger(SymbolToTrade, SYMBOL_TRADE_STOPS_LEVEL);
   double minStop = stopsLevel * point;
   double slPoints = MathMax(StopLossPoints, minStop + point);
   double tpPoints = TakeProfitPoints;
   
   if(direction == 1) {
      double sl = ask - slPoints * point;
      double tp = ask + tpPoints * point;
      if(trade.Buy(lot, SymbolToTrade, ask, sl, tp, "Sweep Buy")) {
         currentTicket = trade.ResultOrder();
         Print("🔥 BUY opened, lot=", lot);
      } else Print("❌ Buy failed, error ", GetLastError());
   } else if(direction == -1) {
      double sl = bid + slPoints * point;
      double tp = bid - tpPoints * point;
      if(trade.Sell(lot, SymbolToTrade, bid, sl, tp, "Sweep Sell")) {
         currentTicket = trade.ResultOrder();
         Print("🔥 SELL opened, lot=", lot);
      } else Print("❌ Sell failed, error ", GetLastError());
   }
}

//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(SymbolToTrade);
   SymbolSelect(SymbolToTrade, true);
   point = SymbolInfoDouble(SymbolToTrade, SYMBOL_POINT);
   if(point <= 0) point = 0.00001;
   dayStart = TimeCurrent();
   dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("==============================================");
   Print("⚡ SIMPLE LIQUIDITY SWEEP SCALPER");
   Print("   Symbol: ", SymbolToTrade);
   Print("   Sweep threshold: ", SweepPoints, " points");
   Print("   Max reclaim bars: ", MaxReclaimBars);
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick() {
   if(!IsTradingTime()) {
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
   
   // Manage open position
   if(currentTicket != 0 && PositionSelectByTicket(currentTicket)) {
      if(CloseOnAnyProfit) {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit > 0) {
            CloseTrade();
            Print("✅ Closed with profit: $", profit);
            consecutiveLosses = 0;
            return;
         }
      }
      return;
   }
   if(currentTicket != 0 && !PositionSelectByTicket(currentTicket)) currentTicket = 0;
   if(currentTicket != 0) return;
   
   // Cooldown after trade
   static datetime lastTrade = 0;
   if(now - lastTrade < 5) return;
   
   // Only check on new bar
   datetime currentBar = iTime(SymbolToTrade, PERIOD_M1, 0);
   if(currentBar == lastBar) return;
   lastBar = currentBar;
   
   // Get swing levels from previous bars (excluding current bar)
   double swingLow = GetSwingLow();
   double swingHigh = GetSwingHigh();
   
   // Check BUY condition: previous bar closed below swingLow - SweepPoints, and current bar closed above swingLow
   double prevLow = iLow(SymbolToTrade, PERIOD_M1, 1);
   double prevClose = iClose(SymbolToTrade, PERIOD_M1, 1);
   double currClose = iClose(SymbolToTrade, PERIOD_M1, 0);
   
   bool sweptBelow = (prevLow < swingLow - SweepPoints * point);
   bool reclaimed = (currClose > swingLow);
   
   if(sweptBelow && reclaimed && consecutiveLosses < ConsecutiveLossLimit) {
      if(DebugPrint) Print("📢 BUY signal: swept at ", prevLow, ", reclaim at ", currClose);
      OpenTrade(1);
      lastTrade = now;
   }
   else {
      // SELL condition: previous bar high above swingHigh + SweepPoints, and current bar close below swingHigh
      double prevHigh = iHigh(SymbolToTrade, PERIOD_M1, 1);
      double prevCloseSell = iClose(SymbolToTrade, PERIOD_M1, 1);
      double currCloseSell = iClose(SymbolToTrade, PERIOD_M1, 0);
      bool sweptAbove = (prevHigh > swingHigh + SweepPoints * point);
      bool reclaimedSell = (currCloseSell < swingHigh);
      if(sweptAbove && reclaimedSell && consecutiveLosses < ConsecutiveLossLimit) {
         if(DebugPrint) Print("📢 SELL signal: swept at ", prevHigh, ", reclaim at ", currCloseSell);
         OpenTrade(-1);
         lastTrade = now;
      }
   }
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
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
