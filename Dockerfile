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
//|                                        SimplifiedScalper_EA.mq5 |
//|                     Trend + MACD + Pullback + Breakout          |
//|                     Designed for frequent, high-probability trades |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Simplified Scalper"
#property version   "1.1"
#property strict

// --- INPUTS --------------------------------------------------------+
input string   SymbolToTrade     = "EURUSD.vx";
input double   RiskPercent       = 1.0;            // Risk per trade (1% of equity)
input int      StopLossPips      = 10;
input int      TakeProfitPips    = 15;
input int      EMA_TrendPeriod   = 200;            // 5-min trend EMA
input int      EMA_PullbackPeriod= 50;             // 1-min pullback EMA
input int      RSI_Period        = 14;
input double   RSI_LongThreshold = 55.0;           // Above this for long
input double   RSI_ShortThreshold= 45.0;           // Below this for short
input int      MACD_Fast         = 12;
input int      MACD_Slow         = 26;
input int      MACD_Signal       = 9;
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
double dailyEquityStart = 0;
int consecutiveLosses = 0;
bool tradingEnabled = true;
ulong currentTicket = 0;
datetime entryTime = 0;

// Indicator handles
int ma_trend_handle, ma_pullback_handle;
int macd_handle, rsi_handle;
double trend_ema[], pullback_ema[], macd_main[], macd_signal[], rsi_buf[];

//+------------------------------------------------------------------+
bool IsTradingHours() {
   MqlDateTime dt;
   TimeCurrent(dt);
   return (dt.hour >= StartHour && dt.hour < EndHour);
}

//+------------------------------------------------------------------+
// Trend direction using 200 EMA on 5-min
//+------------------------------------------------------------------+
bool IsTrendUp() {
   double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   if(CopyBuffer(ma_trend_handle, 0, 0, 1, trend_ema) < 1) return true;
   return (bid > trend_ema[0]);
}
bool IsTrendDown() {
   double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   if(CopyBuffer(ma_trend_handle, 0, 0, 1, trend_ema) < 1) return false;
   return (ask < trend_ema[0]);
}

//+------------------------------------------------------------------+
// MACD condition: histogram positive and rising (long) or negative and falling (short)
//+------------------------------------------------------------------+
bool IsMACDBullish() {
   if(CopyBuffer(macd_handle, 0, 0, 2, macd_main) < 2 ||
      CopyBuffer(macd_handle, 1, 0, 2, macd_signal) < 2)
      return false;
   double hist0 = macd_main[0] - macd_signal[0];
   double hist1 = macd_main[1] - macd_signal[1];
   return (hist0 > 0 && hist0 > hist1);
}
bool IsMACDBearish() {
   if(CopyBuffer(macd_handle, 0, 0, 2, macd_main) < 2 ||
      CopyBuffer(macd_handle, 1, 0, 2, macd_signal) < 2)
      return false;
   double hist0 = macd_main[0] - macd_signal[0];
   double hist1 = macd_main[1] - macd_signal[1];
   return (hist0 < 0 && hist0 < hist1);
}

//+------------------------------------------------------------------+
// Price pullback to 50 EMA (1-min) within 0.05% tolerance
//+------------------------------------------------------------------+
bool IsPullbackToEMA(bool buy) {
   double ema_val;
   if(CopyBuffer(ma_pullback_handle, 0, 0, 1, ema_val) < 1) return false;
   double current = buy ? SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK) : SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   double tolerance = ema_val * 0.0005;   // 0.05% tolerance
   return (MathAbs(current - ema_val) <= tolerance);
}

//+------------------------------------------------------------------+
// Breakout condition: current 1-min close > previous high (long) or < previous low (short)
//+------------------------------------------------------------------+
bool IsBreakout(bool buy) {
   MqlRates rates[2];
   if(CopyRates(SymbolToTrade, PERIOD_M1, 0, 2, rates) < 2) return false;
   if(buy) return (rates[0].close > rates[1].high);
   else    return (rates[0].close < rates[1].low);
}

//+------------------------------------------------------------------+
// RSI condition
//+------------------------------------------------------------------+
bool IsRSIBullish() {
   if(CopyBuffer(rsi_handle, 0, 0, 1, rsi_buf) < 1) return false;
   return (rsi_buf[0] > RSI_LongThreshold);
}
bool IsRSIBearish() {
   if(CopyBuffer(rsi_handle, 0, 0, 1, rsi_buf) < 1) return false;
   return (rsi_buf[0] < RSI_ShortThreshold);
}

//+------------------------------------------------------------------+
int GetSignal() {
   bool uptrend = IsTrendUp();
   bool downtrend = IsTrendDown();
   if(!uptrend && !downtrend) return 0;
   
   if(uptrend && IsMACDBullish() && IsPullbackToEMA(true) && IsBreakout(true) && IsRSIBullish())
      return 1;   // Buy
   if(downtrend && IsMACDBearish() && IsPullbackToEMA(false) && IsBreakout(false) && IsRSIBearish())
      return -1;  // Sell
   return 0;
}

//+------------------------------------------------------------------+
void CloseCurrent() {
   if(currentTicket != 0 && PositionSelectByTicket(currentTicket)) {
      trade.PositionClose(currentTicket);
      Print("Closed position, ticket: ", currentTicket);
      currentTicket = 0;
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
   
   if(signal == 1) {
      double sl = ask - StopLossPips * point;
      double tp = ask + TakeProfitPips * point;
      if(trade.Buy(lot, SymbolToTrade, ask, sl, tp, "Scalp Buy")) {
         currentTicket = trade.ResultOrder();
         entryTime = TimeCurrent();
         Print("🔥 BUY opened. Lot=", lot, " SL=", sl, " TP=", tp);
      } else Print("❌ Buy failed. Error ", GetLastError());
   }
   else if(signal == -1) {
      double sl = bid + StopLossPips * point;
      double tp = bid - TakeProfitPips * point;
      if(trade.Sell(lot, SymbolToTrade, bid, sl, tp, "Scalp Sell")) {
         currentTicket = trade.ResultOrder();
         entryTime = TimeCurrent();
         Print("🔥 SELL opened. Lot=", lot, " SL=", sl, " TP=", tp);
      } else Print("❌ Sell failed. Error ", GetLastError());
   }
}

//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   SymbolSelect(SymbolToTrade, true);
   
   ma_trend_handle = iMA(SymbolToTrade, PERIOD_M5, EMA_TrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
   ma_pullback_handle = iMA(SymbolToTrade, PERIOD_M1, EMA_PullbackPeriod, 0, MODE_EMA, PRICE_CLOSE);
   macd_handle = iMACD(SymbolToTrade, PERIOD_M1, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   rsi_handle = iRSI(SymbolToTrade, PERIOD_M1, RSI_Period, PRICE_CLOSE);
   
   if(ma_trend_handle == INVALID_HANDLE || ma_pullback_handle == INVALID_HANDLE ||
      macd_handle == INVALID_HANDLE || rsi_handle == INVALID_HANDLE)
      return INIT_FAILED;
   
   ArraySetAsSeries(trend_ema, true);
   ArraySetAsSeries(pullback_ema, true);
   ArraySetAsSeries(macd_main, true);
   ArraySetAsSeries(macd_signal, true);
   ArraySetAsSeries(rsi_buf, true);
   
   dayStart = TimeCurrent();
   dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("==============================================");
   Print("⚡ SIMPLIFIED TRIPLE CONFLUENCE SCALPER");
   Print("   Symbol: ", SymbolToTrade);
   Print("   Risk: ", RiskPercent, "% | SL: ", StopLossPips, " | TP: ", TakeProfitPips);
   Print("   Trading hours: ", StartHour, ":00-", EndHour, ":00 GMT");
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick() {
   if(!IsTradingHours()) {
      if(currentTicket != 0) CloseCurrent();
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
   
   // Manage existing position
   if(currentTicket != 0 && PositionSelectByTicket(currentTicket)) {
      // SL/TP already set; just wait
      return;
   }
   // Sync if ticket lost
   if(currentTicket == 0 && PositionsTotal() > 0) {
      for(int i=PositionsTotal()-1; i>=0; i--) {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            currentTicket = ticket;
            break;
         }
      }
   }
   
   if(currentTicket != 0) return;
   
   // Cooldown after a trade close (wait 5 seconds)
   static datetime lastSignalTime = 0;
   if(now - lastSignalTime < 5) return;
   
   // One signal per minute bar
   datetime currentBar = iTime(SymbolToTrade, PERIOD_M1, 0);
   if(currentBar == lastBar) return;
   lastBar = currentBar;
   
   int signal = GetSignal();
   if(signal != 0 && consecutiveLosses < ConsecutiveLossLimit) {
      OpenTrade(signal);
      if(currentTicket != 0) {
         lastSignalTime = now;
      }
   }
   
   if(DebugPrint && now - lastDebug >= 60) {
      lastDebug = now;
      Print("📊 Bid=", SymbolInfoDouble(SymbolToTrade, SYMBOL_BID),
            " Ask=", SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK),
            " Losses=", consecutiveLosses);
   }
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   IndicatorRelease(ma_trend_handle);
   IndicatorRelease(ma_pullback_handle);
   IndicatorRelease(macd_handle);
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
