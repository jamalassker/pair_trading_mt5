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
//|                                      LiquiditySweep_CTrade.mq5   |
//|                     Uses CTrade - proven working on your broker  |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "LiquiditySweep"
#property version   "4.00"

// --- INPUTS (same as your original aggressive settings) ---
input double   RiskPercent       = 3.0;        // Risk per trade (3-5%)
input int      StopLossPips      = 4;          // Stop Loss in pips
input int      TakeProfitPips    = 5;          // Take Profit in pips
input int      LookbackBars      = 5;          // Previous bars for swing high/low
input int      EMAPeriod         = 20;
input int      MaxDailyLoss      = 8;
input bool     UseSessionFilter  = false;      // Change to true after testing
input int      SessionOffset     = 0;
input int      MaxOpenPositions  = 1;          // Only one position at a time

// --- GLOBALS ---
CTrade trade;
int    magic = 20250402;
int    dailyLoss = 0;
int    emaHandle;
double point, pipValue;
datetime lastTickThrottle = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   pipValue = (digits == 5 || digits == 3) ? point * 10 : point;
   
   emaHandle = iMA(_Symbol, PERIOD_M1, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandle == INVALID_HANDLE) return INIT_FAILED;
   
   trade.SetExpertMagicNumber(magic);
   trade.SetTypeFilling(ORDER_FILLING_IOC);   // Proven working on your broker
   trade.SetDeviationInPoints(10);
   
   Print("========================================");
   Print("LIQUIDITY SWEEP SCALPER - CTrade Edition");
   Print("Symbol: ", _Symbol);
   Print("StopLoss: ", StopLossPips, " pips, TP: ", TakeProfitPips, " pips");
   Print("========================================");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Throttle to avoid excessive checks (2x per second is enough)
   if(GetTickCount() - lastTickThrottle < 500) return;
   lastTickThrottle = GetTickCount();
   
   // --- Daily loss counter reset ---
   static datetime lastDay = 0;
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != lastDay) { dailyLoss = 0; lastDay = today; }
   if(dailyLoss >= MaxDailyLoss) return;
   
   // --- Optional session filter (London/NY) ---
   if(UseSessionFilter)
   {
      MqlDateTime tm; TimeToStruct(TimeCurrent(), tm);
      int hour = (tm.hour + SessionOffset) % 24;
      if(!((hour >= 7 && hour < 10) || (hour >= 12 && hour < 15))) return;
   }
   
   // --- Limit one position ---
   if(PositionsTotal() >= MaxOpenPositions) return;
   
   // --- Get rates for swing levels (closed bars only) ---
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M1, 0, LookbackBars+2, rates) < LookbackBars+1) return;
   
   double swingHigh = 0, swingLow = DBL_MAX;
   for(int i=1; i<=LookbackBars; i++)
   {
      if(rates[i].high > swingHigh) swingHigh = rates[i].high;
      if(rates[i].low  < swingLow)  swingLow  = rates[i].low;
   }
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   // --- EMA value ---
   double ema[1];
   if(CopyBuffer(emaHandle, 0, 0, 1, ema) < 1) return;
   double currentEMA = ema[0];
   
   // --- SIGNAL CONDITIONS (exactly as before) ---
   bool buySignal = false, sellSignal = false;
   
   // Buy: price swept below swingLow (current bar low < swingLow - 0.2 pips) AND ask returned above swingLow AND ask above EMA
   if(rates[0].low < swingLow - 0.2*pipValue && ask > swingLow && ask > currentEMA)
      buySignal = true;
   
   // Sell: price spiked above swingHigh AND bid returned below swingHigh AND bid below EMA
   if(rates[0].high > swingHigh + 0.2*pipValue && bid < swingHigh && bid < currentEMA)
      sellSignal = true;
   
   // --- Force trade fallback (every ~60 seconds if no trade) ---
   static int forceCounter = 0;
   forceCounter++;
   if(forceCounter >= 120 && !buySignal && !sellSignal)
   {
      forceCounter = 0;
      if(ask > currentEMA) buySignal = true;
      else sellSignal = true;
      Print("Force signal triggered");
   }
   
   // --- Debug output on chart ---
   string debug = StringFormat(
      "SwingH=%.5f SwingL=%.5f | BarH=%.5f BarL=%.5f | Bid=%.5f Ask=%.5f EMA=%.5f\n"
      "Sell: Sweep=%s Ret=%s EMA=%s | Buy: Sweep=%s Ret=%s EMA=%s\n"
      "SIGNAL: Sell=%s Buy=%s",
      swingHigh, swingLow, rates[0].high, rates[0].low, bid, ask, currentEMA,
      (rates[0].high > swingHigh+0.2*pipValue)?"Y":"N", (bid < swingHigh)?"Y":"N", (bid < currentEMA)?"Y":"N",
      (rates[0].low < swingLow-0.2*pipValue)?"Y":"N", (ask > swingLow)?"Y":"N", (ask > currentEMA)?"Y":"N",
      sellSignal?"★":"-", buySignal?"★":"-"
   );
   Comment(debug);
   
   if(!buySignal && !sellSignal) return;
   
   // --- TRADE EXECUTION using CTrade ---
   double point2pip = pipValue / point;   // points per pip (usually 10)
   double sl_points = StopLossPips * point2pip;
   double tp_points = TakeProfitPips * point2pip;
   
   double lot = NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   
   if(buySignal)
   {
      double sl = ask - sl_points * point;
      double tp = ask + tp_points * point;
      if(trade.Buy(lot, _Symbol, ask, sl, tp, "SweepBuy"))
         Print("🔥 BUY opened | Lot=", lot, " @ ", ask);
      else
         Print("❌ Buy failed. Error: ", GetLastError());
   }
   else if(sellSignal)
   {
      double sl = bid + sl_points * point;
      double tp = bid - tp_points * point;
      if(trade.Sell(lot, _Symbol, bid, sl, tp, "SweepSell"))
         Print("🔥 SELL opened | Lot=", lot, " @ ", bid);
      else
         Print("❌ Sell failed. Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Track daily losses (from closed trades)                          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong deal = trans.deal;
      if(HistoryDealSelect(deal) && HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         if(HistoryDealGetDouble(deal, DEAL_PROFIT) < 0) dailyLoss++;
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
