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
//|                                        FastScalper_ProfitOnly.mq5|
//|                     Enter on trend+RSI, exit as soon as profit>0|
//|                     No stop loss – pure fast scalping           |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Fast Scalper"
#property version   "2.0"
#property strict

// --- INPUTS --------------------------------------------------------+
input string   SymbolToTrade     = "EURUSD.vx";
input double   RiskPercent       = 1.0;            // Risk per trade (1% of equity)
input int      MaxHoldSeconds    = 30;             // Max seconds to hold trade
input int      EMA_TrendPeriod   = 200;            // 5-min trend EMA
input int      RSI_Period        = 14;
input double   RSI_Overbought    = 70.0;
input double   RSI_Oversold      = 30.0;
input int      ConsecutiveLossLimit = 3;
input int      StartHour         = 8;              // London open (GMT)
input int      EndHour           = 16;             // NY close (GMT)
input double   MaxDailyLossPercent = 5.0;
input int      MagicNumber       = 999001;
input bool     DebugPrint        = true;

// --- GLOBALS -------------------------------------------------------+
CTrade trade;
datetime lastBar = 0;
datetime lastDebug = 0;
datetime dayStart = 0;
datetime openTime = 0;
double dailyEquityStart = 0;
int consecutiveLosses = 0;
bool tradingEnabled = true;
ulong currentTicket = 0;

int ma_handle;
double trend_ema[];
int rsi_handle;
double rsi_buf[];

//+------------------------------------------------------------------+
bool IsTradingHours() {
   MqlDateTime dt;
   TimeCurrent(dt);
   return (dt.hour >= StartHour && dt.hour < EndHour);
}

//+------------------------------------------------------------------+
bool IsTrendUp() {
   double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   if(CopyBuffer(ma_handle, 0, 0, 1, trend_ema) < 1) return true;
   return (bid > trend_ema[0]);
}
bool IsTrendDown() {
   double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   if(CopyBuffer(ma_handle, 0, 0, 1, trend_ema) < 1) return false;
   return (ask < trend_ema[0]);
}

//+------------------------------------------------------------------+
bool IsRSIOversold() {
   if(CopyBuffer(rsi_handle, 0, 0, 1, rsi_buf) < 1) return false;
   return (rsi_buf[0] < RSI_Oversold);
}
bool IsRSIOverbought() {
   if(CopyBuffer(rsi_handle, 0, 0, 1, rsi_buf) < 1) return false;
   return (rsi_buf[0] > RSI_Overbought);
}

//+------------------------------------------------------------------+
// Entry signal: trend direction + RSI extreme + price touches EMA
bool GetSignal() {
   double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   if(CopyBuffer(ma_handle, 0, 0, 1, trend_ema) < 1) return false;
   double ema = trend_ema[0];
   double tolerance = ema * 0.0002; // 0.02% distance to EMA
   bool touch = (MathAbs(bid - ema) <= tolerance);
   
   if(IsTrendUp() && IsRSIOversold() && touch) return 1;   // Buy signal
   if(IsTrendDown() && IsRSIOverbought() && touch) return -1; // Sell signal
   return 0;
}

//+------------------------------------------------------------------+
void CloseCurrent(string reason) {
   if(currentTicket != 0 && PositionSelectByTicket(currentTicket)) {
      trade.PositionClose(currentTicket);
      Print("Closed: ", reason);
      currentTicket = 0;
      openTime = 0;
   }
}

//+------------------------------------------------------------------+
void OpenTrade(int signal) {
   double point = SymbolInfoDouble(SymbolToTrade, SYMBOL_POINT);
   double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lot = NormalizeDouble(equity / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   lot = MathMin(lot, SymbolInfoDouble(SymbolToTrade, SYMBOL_VOLUME_MAX));
   
   if(signal == 1) { // Buy: no stop loss, no take profit
      if(trade.Buy(lot, SymbolToTrade, ask, 0, 0, "Fast Buy")) {
         currentTicket = trade.ResultOrder();
         openTime = TimeCurrent();
         Print("🔥 Buy opened. Lot=", lot);
      } else Print("❌ Buy failed. Error ", GetLastError());
   }
   else if(signal == -1) { // Sell
      if(trade.Sell(lot, SymbolToTrade, bid, 0, 0, "Fast Sell")) {
         currentTicket = trade.ResultOrder();
         openTime = TimeCurrent();
         Print("🔥 Sell opened. Lot=", lot);
      } else Print("❌ Sell failed. Error ", GetLastError());
   }
}

//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   SymbolSelect(SymbolToTrade, true);
   
   ma_handle = iMA(SymbolToTrade, PERIOD_M5, EMA_TrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
   rsi_handle = iRSI(SymbolToTrade, PERIOD_M1, RSI_Period, PRICE_CLOSE);
   if(ma_handle == INVALID_HANDLE || rsi_handle == INVALID_HANDLE) return INIT_FAILED;
   
   ArraySetAsSeries(trend_ema, true);
   ArraySetAsSeries(rsi_buf, true);
   
   dayStart = TimeCurrent();
   dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("==============================================");
   Print("⚡ FAST SCALPER – Exit on any profit");
   Print("   Symbol: ", SymbolToTrade);
   Print("   MaxHoldSeconds: ", MaxHoldSeconds);
   Print("   Trading hours: ", StartHour, ":00-", EndHour, ":00 GMT");
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick() {
   if(!IsTradingHours()) {
      if(currentTicket != 0) CloseCurrent("Session ended");
      return;
   }
   
   datetime now = TimeCurrent();
   // Daily loss reset
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
   
   // Manage open position: close if profit > 0 OR max hold time reached
   if(currentTicket != 0 && PositionSelectByTicket(currentTicket)) {
      double profit = PositionGetDouble(POSITION_PROFIT);
      // Fast out: close as soon as profit positive
      if(profit > 0) {
         CloseCurrent("Profit > 0 ($" + DoubleToString(profit,2) + ")");
         consecutiveLosses = 0;
         return;
      }
      // Max holding time -> close even if losing, but record loss
      if(MaxHoldSeconds > 0 && openTime > 0 && (now - openTime) >= MaxHoldSeconds) {
         CloseCurrent("Max hold time reached (loss: $" + DoubleToString(profit,2) + ")");
         if(profit < 0) consecutiveLosses++;
         else consecutiveLosses = 0;
         return;
      }
      return; // still holding
   }
   
   // Clean up if ticket lost
   if(currentTicket != 0) currentTicket = 0;
   
   // Cooldown after a closed trade
   static datetime lastSignalTime = 0;
   if(now - lastSignalTime < 2) return;
   if(consecutiveLosses >= ConsecutiveLossLimit) {
      static int warn=0; if(warn++%50==0) Print("⛔ Paused due to losses");
      return;
   }
   
   // New signal on new 1-min bar
   datetime currentBar = iTime(SymbolToTrade, PERIOD_M1, 0);
   if(currentBar == lastBar) return;
   lastBar = currentBar;
   
   int signal = GetSignal();
   if(signal != 0) {
      OpenTrade(signal);
      if(currentTicket != 0) lastSignalTime = now;
   }
   
   if(DebugPrint && now - lastDebug >= 30) {
      lastDebug = now;
      Print("📊 Bid=", SymbolInfoDouble(SymbolToTrade, SYMBOL_BID),
            " Ask=", SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK),
            " Losses=", consecutiveLosses);
   }
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
