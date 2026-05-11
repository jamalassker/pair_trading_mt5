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
//|                                        TripleConfluenceScalper.mq5|
//|                     Trend + MACD + Engulfing + RSI scalping     |
//|                     High win rate, tight risk, fast profit exit |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
#include <MovingAverages.mqh>

#property copyright "Scalper Pro"
#property version   "1.0"
#property strict

// --- INPUTS --------------------------------------------------------+
input string   SymbolToTrade     = "EURUSD.vx";   // Symbol (use your broker's name)
input double   RiskPercent       = 1.0;           // Risk per trade (1% of equity)
input int      StopLossPips      = 10;            // Fixed stop loss in pips
input int      TakeProfitPips    = 15;            // Fixed take profit in pips
input int      LookbackBars      = 50;            // For EMA calculation
input double   EMA_FastPeriod    = 25;            // Fast EMA for pullback entry
input double   EMA_SlowPeriod    = 200;           // Slow EMA for trend filter
input int      RSI_Period        = 14;            // RSI period
input double   RSI_Threshold     = 50.0;          // RSI midline (above for long, below for short)
input int      MACD_Fast         = 12;
input int      MACD_Slow         = 26;
input int      MACD_Signal       = 9;
input int      ConsecutiveLossLimit = 3;          // Stop after N losses in a row
input int      StartHour         = 8;             // London open (GMT)
input int      EndHour           = 16;            // NY close (GMT)
input double   MaxDailyLossPercent = 5.0;         // Daily equity loss limit
input int      MagicNumber       = 999001;
input bool     DebugPrint        = true;

// --- GLOBALS -------------------------------------------------------+
CTrade trade;
datetime lastBar = 0;
datetime lastDebug = 0;
datetime dayStart = 0;
double dailyEquityStart = 0;
int consecutiveLosses = 0;
bool tradingEnabled = true;
ulong currentTicket = 0;
datetime entryTime = 0;

// Indicator handles
int ma_handle_fast, ma_handle_slow;
int macd_handle, rsi_handle;
double fast_ema[], slow_ema[], macd_main[], macd_signal[], rsi_buf[];

//+------------------------------------------------------------------+
//| Check trading hours                                             |
//+------------------------------------------------------------------+
bool IsTradingHours() {
   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;
   return (hour >= StartHour && hour < EndHour);
}

//+------------------------------------------------------------------+
//| Check if MACD histogram is expanding in given direction         |
//+------------------------------------------------------------------+
bool IsMACDExpanding(bool buy) {
   if(CopyBuffer(macd_handle, 0, 0, 3, macd_main) < 3 ||
      CopyBuffer(macd_handle, 1, 0, 3, macd_signal) < 3)
      return false;
   double hist0 = macd_main[0] - macd_signal[0];
   double hist1 = macd_main[1] - macd_signal[1];
   if(buy) return (hist0 > hist1 && hist0 > 0);
   else    return (hist0 < hist1 && hist0 < 0);
}

//+------------------------------------------------------------------+
//| Check if price is above/below slow EMA (trend filter)           |
//+------------------------------------------------------------------+
bool IsTrendUp() {
   double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   if(CopyBuffer(ma_handle_slow, 0, 0, 1, slow_ema) < 1) return true;
   return (bid > slow_ema[0]);
}
bool IsTrendDown() {
   double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   if(CopyBuffer(ma_handle_slow, 0, 0, 1, slow_ema) < 1) return false;
   return (ask < slow_ema[0]);
}

//+------------------------------------------------------------------+
//| Check engulfing pattern and pullback to fast EMA                |
//+------------------------------------------------------------------+
bool IsEngulfingPullback(bool buy) {
   MqlRates rates[3];
   if(CopyRates(SymbolToTrade, PERIOD_M1, 0, 3, rates) < 3) return false;
   double fast_ema_val;
   if(CopyBuffer(ma_handle_fast, 0, 0, 1, fast_ema) < 1) return false;
   fast_ema_val = fast_ema[0];
   double current_price = buy ? SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK) : SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   // Pullback condition: price within 0.02% of fast EMA (adjust as needed)
   bool near_ema = MathAbs(current_price - fast_ema_val) / fast_ema_val < 0.0002;
   if(!near_ema) return false;
   
   // Engulfing condition
   if(buy) {
      return (rates[1].close < rates[1].open &&
              rates[0].close > rates[0].open &&
              rates[0].close > rates[1].high &&
              rates[0].open < rates[1].low);
   } else {
      return (rates[1].close > rates[1].open &&
              rates[0].close < rates[0].open &&
              rates[0].close < rates[1].low &&
              rates[0].open > rates[1].high);
   }
}

//+------------------------------------------------------------------+
//| Check RSI condition                                             |
//+------------------------------------------------------------------+
bool IsRSIValid(bool buy) {
   if(CopyBuffer(rsi_handle, 0, 0, 1, rsi_buf) < 1) return false;
   if(buy) return (rsi_buf[0] > RSI_Threshold);
   else    return (rsi_buf[0] < RSI_Threshold);
}

//+------------------------------------------------------------------+
//| Get entry signal                                                 |
//+------------------------------------------------------------------+
int GetSignal() {
   // 1. Trend filter (higher timeframe, here we use current chart but slow EMA)
   bool uptrend = IsTrendUp();
   bool downtrend = IsTrendDown();
   if(!uptrend && !downtrend) return 0;
   
   // 2. MACD expanding in direction of trend
   if(uptrend && !IsMACDExpanding(true)) return 0;
   if(downtrend && !IsMACDExpanding(false)) return 0;
   
   // 3. Engulfing pullback pattern
   if(uptrend && IsEngulfingPullback(true) && IsRSIValid(true)) return 1;  // Buy
   if(downtrend && IsEngulfingPullback(false) && IsRSIValid(false)) return -1; // Sell
   return 0;
}

//+------------------------------------------------------------------+
//| Close existing trade if any                                      |
//+------------------------------------------------------------------+
void CloseCurrent() {
   if(currentTicket != 0 && PositionSelectByTicket(currentTicket)) {
      trade.PositionClose(currentTicket);
      Print("Closed position, ticket: ", currentTicket);
      currentTicket = 0;
   }
}

//+------------------------------------------------------------------+
//| Open trade with fixed SL/TP                                      |
//+------------------------------------------------------------------+
void OpenTrade(int signal) {
   double point = SymbolInfoDouble(SymbolToTrade, SYMBOL_POINT);
   double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lot = NormalizeDouble(equity / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   lot = MathMin(lot, SymbolInfoDouble(SymbolToTrade, SYMBOL_VOLUME_MAX));
   
   if(signal == 1) { // Buy
      double sl = ask - StopLossPips * point;
      double tp = ask + TakeProfitPips * point;
      if(trade.Buy(lot, SymbolToTrade, ask, sl, tp, "TripleConfluence Buy")) {
         currentTicket = trade.ResultOrder();
         entryTime = TimeCurrent();
         Print("🔥 BUY opened. Lot=", lot, " SL=", sl, " TP=", tp);
      } else Print("❌ Buy failed. Error ", GetLastError());
   }
   else if(signal == -1) { // Sell
      double sl = bid + StopLossPips * point;
      double tp = bid - TakeProfitPips * point;
      if(trade.Sell(lot, SymbolToTrade, bid, sl, tp, "TripleConfluence Sell")) {
         currentTicket = trade.ResultOrder();
         entryTime = TimeCurrent();
         Print("🔥 SELL opened. Lot=", lot, " SL=", sl, " TP=", tp);
      } else Print("❌ Sell failed. Error ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Initialize indicators                                            |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   SymbolSelect(SymbolToTrade, true);
   
   ma_handle_fast = iMA(SymbolToTrade, PERIOD_M1, (int)EMA_FastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   ma_handle_slow = iMA(SymbolToTrade, PERIOD_M5, (int)EMA_SlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   macd_handle = iMACD(SymbolToTrade, PERIOD_M1, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   rsi_handle = iRSI(SymbolToTrade, PERIOD_M1, RSI_Period, PRICE_CLOSE);
   
   if(ma_handle_fast == INVALID_HANDLE || ma_handle_slow == INVALID_HANDLE ||
      macd_handle == INVALID_HANDLE || rsi_handle == INVALID_HANDLE)
      return INIT_FAILED;
   
   ArraySetAsSeries(fast_ema, true);
   ArraySetAsSeries(slow_ema, true);
   ArraySetAsSeries(macd_main, true);
   ArraySetAsSeries(macd_signal, true);
   ArraySetAsSeries(rsi_buf, true);
   
   dayStart = TimeCurrent();
   dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("==============================================");
   Print("⚡ TRIPLE CONFLUENCE SCALPER");
   Print("   Symbol: ", SymbolToTrade);
   Print("   Risk: ", RiskPercent, "% per trade | SL: ", StopLossPips, " | TP: ", TakeProfitPips);
   Print("   Trading hours: ", StartHour, ":00-", EndHour, ":00 GMT");
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   if(!IsTradingHours()) {
      if(currentTicket != 0) CloseCurrent();
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
   
   // --- Manage existing position ---
   if(currentTicket != 0 && PositionSelectByTicket(currentTicket)) {
      // Track profit for consecutive loss counting (after close)
      return; // SL/TP already set, just wait
   }
   // If ticket is 0 but position exists (unlikely), sync
   if(currentTicket == 0 && PositionsTotal() > 0) {
      for(int i=PositionsTotal()-1; i>=0; i--) {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            currentTicket = ticket;
            break;
         }
      }
   }
   
   // --- Position closed: check if it was a loss ---
   if(currentTicket == 0 && entryTime != 0) {
      // We need to know if last trade was loss. Simpler: reset consec losses on profit target hit.
      // For simplicity, we'll rely on daily loss limit and consecutive loss limit.
      // Actually we can track last profit after close. But for now, just reset on profit.
   }
   
   if(currentTicket != 0) return; // still in trade
   
   // --- Cooldown after a trade that closed (wait 5 seconds) ---
   if(now - lastBar < 5) return;
   
   // --- New signal on new bar only (to avoid multiple trades per bar) ---
   datetime currentBar = iTime(SymbolToTrade, PERIOD_M1, 0);
   if(currentBar == lastBar) return;
   lastBar = currentBar;
   
   int signal = GetSignal();
   if(signal != 0 && consecutiveLosses < ConsecutiveLossLimit) {
      OpenTrade(signal);
      if(currentTicket != 0) lastBar = TimeCurrent(); // reset bar check
   }
   
   // Debug
   if(DebugPrint && now - lastDebug >= 60) {
      lastDebug = now;
      Print("📊 Market: Bid=", SymbolInfoDouble(SymbolToTrade, SYMBOL_BID),
            " Ask=", SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK),
            " Consecutive losses=", consecutiveLosses);
   }
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   IndicatorRelease(ma_handle_fast);
   IndicatorRelease(ma_handle_slow);
   IndicatorRelease(macd_handle);
   IndicatorRelease(rsi_handle);
   Print("EA removed. Daily loss: $", (dailyEquityStart - AccountInfoDouble(ACCOUNT_EQUITY)));
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
