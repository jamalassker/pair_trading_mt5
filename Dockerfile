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
//|                                      LiquiditySweepScalper.mq5   |
//|                     Sweep + reclaim + reversal confirmation     |
//|                     High win rate scalping on M1                |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Sweep Scalper"
#property version   "1.0"
#property strict

// --- INPUTS --------------------------------------------------------+
input string   SymbolToTrade     = "EURUSD.vx";
input double   RiskPercent       = 1.0;            // % equity per trade
input int      SweepPips         = 5;              // How many pips beyond swing to qualify as sweep
input int      LookbackBars      = 20;             // Bars to detect swing highs/lows
input int      MinReclaimBars    = 3;              // Max candles to wait for reclaim after sweep
input double   StopLossPips      = 10;             // Fixed SL (pips)
input double   TakeProfitPips    = 15;             // Fixed TP (pips) – if using fixed
input bool     UseDynamicTP      = true;           // Use ATR-based TP
input double   ATR_MultiplierTP  = 1.5;            // TP = ATR * multiplier
input bool     UseDynamicSL      = false;          // Use ATR-based SL (otherwise fixed)
input double   ATR_MultiplierSL  = 1.0;
input int      ATR_Period        = 14;
input bool     UseTrendFilter    = true;           // VWAP or MA trend filter
input int      TrendMAPeriod     = 200;            // for trend filter (if no VWAP)
input bool     UseVolumeFilter   = true;           // Volume spike confirmation
input double   VolumeMultiplier  = 1.5;            // Sweep candle volume >= average * this
input bool     UseRSIFilter      = true;
input double   RSIOversold       = 25.0;           // For buy setup
input double   RSIOverbought     = 75.0;           // For sell setup
input int      RSI_Period        = 14;
input bool     CloseOnAnyProfit  = true;           // Fast out as soon as profit > 0
input int      MagicNumber       = 999333;
input int      StartHour         = 8;              // London open
input int      EndHour           = 16;             // NY close
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
datetime entryTime = 0;

// Indicator handles
int vwap_handle, ma_trend_handle, atr_handle, rsi_handle;
double atr_buf[], rsi_buf[], vwap_buf[], ma_buf[];
double point, pipsToPoints;

//+------------------------------------------------------------------+
//| Helper functions                                                |
//+------------------------------------------------------------------+
bool IsTradingTime() {
   MqlDateTime dt;
   TimeCurrent(dt);
   return (dt.hour >= StartHour && dt.hour < EndHour);
}

double GetPipSize() {
   double pip = 0.0001;
   if(StringFind(SymbolToTrade, "JPY") >= 0) pip = 0.01;
   if(StringFind(SymbolToTrade, "XAU") >= 0) pip = 0.01;
   if(StringFind(SymbolToTrade, "BTC") >= 0) pip = 1.0;
   return pip;
}

//+------------------------------------------------------------------+
//| Swing high / low detection                                      |
//+------------------------------------------------------------------+
double GetSwingLow() {
   double low = DBL_MAX;
   for(int i=1; i<=LookbackBars; i++) {
      double l = iLow(SymbolToTrade, PERIOD_M1, i);
      if(l < low) low = l;
   }
   return low;
}
double GetSwingHigh() {
   double high = -DBL_MAX;
   for(int i=1; i<=LookbackBars; i++) {
      double h = iHigh(SymbolToTrade, PERIOD_M1, i);
      if(h > high) high = h;
   }
   return high;
}

//+------------------------------------------------------------------+
//| Check if price swept below swing low and reclaimed              |
//+------------------------------------------------------------------+
bool IsBuySetup() {
   static datetime sweepBarTime = 0;
   static double swingLow = 0;
   static bool awaitingReclaim = false;
   
   // Update swing low on each new bar
   double newLow = GetSwingLow();
   if(newLow != swingLow) {
      swingLow = newLow;
      awaitingReclaim = false;
   }
   
   // Detect sweep: low of current bar < swingLow - SweepPips * point
   double currentLow = iLow(SymbolToTrade, PERIOD_M1, 0);
   double sweepThreshold = swingLow - SweepPips * point;
   if(!awaitingReclaim && currentLow < sweepThreshold) {
      awaitingReclaim = true;
      sweepBarTime = TimeCurrent();
      if(DebugPrint) Print("📉 Sweep below swing low at ", currentLow);
   }
   
   // Reclaim: close of any bar after sweep > swingLow within MinReclaimBars
   if(awaitingReclaim && (TimeCurrent() - sweepBarTime) <= MinReclaimBars * 60) {
      double close = iClose(SymbolToTrade, PERIOD_M1, 0);
      if(close > swingLow) {
         if(DebugPrint) Print("✅ Reclaim detected. Buy signal.");
         awaitingReclaim = false;
         return true;
      }
   }
   // Timeout: reset
   if(awaitingReclaim && (TimeCurrent() - sweepBarTime) > MinReclaimBars * 60) {
      awaitingReclaim = false;
   }
   return false;
}

bool IsSellSetup() {
   static datetime sweepBarTime = 0;
   static double swingHigh = 0;
   static bool awaitingReclaim = false;
   
   double newHigh = GetSwingHigh();
   if(newHigh != swingHigh) {
      swingHigh = newHigh;
      awaitingReclaim = false;
   }
   
   double currentHigh = iHigh(SymbolToTrade, PERIOD_M1, 0);
   double sweepThreshold = swingHigh + SweepPips * point;
   if(!awaitingReclaim && currentHigh > sweepThreshold) {
      awaitingReclaim = true;
      sweepBarTime = TimeCurrent();
      if(DebugPrint) Print("📈 Sweep above swing high at ", currentHigh);
   }
   
   if(awaitingReclaim && (TimeCurrent() - sweepBarTime) <= MinReclaimBars * 60) {
      double close = iClose(SymbolToTrade, PERIOD_M1, 0);
      if(close < swingHigh) {
         if(DebugPrint) Print("✅ Reclaim detected. Sell signal.");
         awaitingReclaim = false;
         return true;
      }
   }
   if(awaitingReclaim && (TimeCurrent() - sweepBarTime) > MinReclaimBars * 60) awaitingReclaim = false;
   return false;
}

//+------------------------------------------------------------------+
//| Filters                                                         |
//+------------------------------------------------------------------+
bool IsTrendBullish() {
   if(!UseTrendFilter) return true;
   // VWAP is preferred, but MT5 doesn't have built-in VWAP, so we use MA
   if(CopyBuffer(ma_trend_handle, 0, 0, 1, ma_buf) < 1) return true;
   double currentPrice = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   return (currentPrice > ma_buf[0]);
}
bool IsTrendBearish() {
   if(!UseTrendFilter) return true;
   if(CopyBuffer(ma_trend_handle, 0, 0, 1, ma_buf) < 1) return true;
   double currentPrice = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   return (currentPrice < ma_buf[0]);
}

bool IsVolumeSpike() {
   if(!UseVolumeFilter) return true;
   long volume = iVolume(SymbolToTrade, PERIOD_M1, 0);
   double avgVolume = 0;
   for(int i=1; i<=20; i++) avgVolume += iVolume(SymbolToTrade, PERIOD_M1, i);
   avgVolume /= 20;
   return (volume > avgVolume * VolumeMultiplier);
}

bool IsRSIBuy() {
   if(!UseRSIFilter) return true;
   if(CopyBuffer(rsi_handle, 0, 0, 1, rsi_buf) < 1) return true;
   return (rsi_buf[0] < RSIOversold);
}
bool IsRSISell() {
   if(!UseRSIFilter) return true;
   if(CopyBuffer(rsi_handle, 0, 0, 1, rsi_buf) < 1) return true;
   return (rsi_buf[0] > RSIOverbought);
}

//+------------------------------------------------------------------+
//| Trade management                                                |
//+------------------------------------------------------------------+
void CloseTrade() {
   if(currentTicket != 0 && PositionSelectByTicket(currentTicket)) {
      trade.PositionClose(currentTicket);
      Print("Closed trade, ticket: ", currentTicket);
      currentTicket = 0;
   }
}

double GetATR() {
   if(CopyBuffer(atr_handle, 0, 0, 1, atr_buf) < 1) return 10 * point;
   return atr_buf[0];
}

void OpenTrade(int direction) {
   double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lot = NormalizeDouble(equity / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   lot = MathMin(lot, SymbolInfoDouble(SymbolToTrade, SYMBOL_VOLUME_MAX));
   
   double sl_pips = StopLossPips;
   double tp_pips = TakeProfitPips;
   if(UseDynamicSL) sl_pips = GetATR() / point * ATR_MultiplierSL;
   if(UseDynamicTP) tp_pips = GetATR() / point * ATR_MultiplierTP;
   
   // Ensure minimum distance
   int stopsLevel = (int)SymbolInfoInteger(SymbolToTrade, SYMBOL_TRADE_STOPS_LEVEL);
   double minSL = (stopsLevel + 1) * point;
   if(sl_pips * point < minSL) sl_pips = minSL / point;
   
   if(direction == 1) { // BUY
      double sl = ask - sl_pips * point;
      double tp = ask + tp_pips * point;
      if(trade.Buy(lot, SymbolToTrade, ask, sl, tp, "Liquidity Buy")) {
         currentTicket = trade.ResultOrder();
         entryTime = TimeCurrent();
         Print("🔥 BUY | Lot=", lot, " SL=", sl, " TP=", tp);
      } else Print("❌ Buy failed. Error ", GetLastError());
   }
   else if(direction == -1) { // SELL
      double sl = bid + sl_pips * point;
      double tp = bid - tp_pips * point;
      if(trade.Sell(lot, SymbolToTrade, bid, sl, tp, "Liquidity Sell")) {
         currentTicket = trade.ResultOrder();
         entryTime = TimeCurrent();
         Print("🔥 SELL | Lot=", lot, " SL=", sl, " TP=", tp);
      } else Print("❌ Sell failed. Error ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(SymbolToTrade);
   SymbolSelect(SymbolToTrade, true);
   point = SymbolInfoDouble(SymbolToTrade, SYMBOL_POINT);
   pipsToPoints = GetPipSize() / point;
   
   // Create indicators
   ma_trend_handle = iMA(SymbolToTrade, PERIOD_M1, TrendMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   atr_handle = iATR(SymbolToTrade, PERIOD_M1, ATR_Period);
   rsi_handle = iRSI(SymbolToTrade, PERIOD_M1, RSI_Period, PRICE_CLOSE);
   if(ma_trend_handle == INVALID_HANDLE || atr_handle == INVALID_HANDLE || rsi_handle == INVALID_HANDLE)
      return INIT_FAILED;
   
   ArraySetAsSeries(atr_buf, true);
   ArraySetAsSeries(rsi_buf, true);
   ArraySetAsSeries(ma_buf, true);
   
   dayStart = TimeCurrent();
   dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("==============================================");
   Print("⚡ LIQUIDITY SWEEP SCALPER");
   Print("   Symbol: ", SymbolToTrade);
   Print("   Sweep pips: ", SweepPips, " | Risk: ", RiskPercent, "%");
   Print("   Session: ", StartHour, "h - ", EndHour, "h");
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Tick handler                                                    |
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
   
   // Manage open trade
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
      return;
   }
   if(currentTicket != 0 && !PositionSelectByTicket(currentTicket)) currentTicket = 0;
   if(currentTicket != 0) return;
   
   // Cooldown after trade close
   static datetime lastTrade = 0;
   if(now - lastTrade < 5) return;
   
   // Only check on new 1-minute bar
   datetime currentBar = iTime(SymbolToTrade, PERIOD_M1, 0);
   if(currentBar == lastBar) return;
   lastBar = currentBar;
   
   // Get signal + filters
   bool buySignal = IsBuySetup();
   bool sellSignal = IsSellSetup();
   if(buySignal && IsTrendBullish() && IsVolumeSpike() && IsRSIBuy()) {
      OpenTrade(1);
      lastTrade = now;
   }
   else if(sellSignal && IsTrendBearish() && IsVolumeSpike() && IsRSISell()) {
      OpenTrade(-1);
      lastTrade = now;
   }
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   IndicatorRelease(ma_trend_handle);
   IndicatorRelease(atr_handle);
   IndicatorRelease(rsi_handle);
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
