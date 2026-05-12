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
//|                                      LiquiditySweepAggressive.mq5|
//|                     Loosened rules - High frequency, aggressive  |
//+------------------------------------------------------------------+
#property copyright "ScalperEA"
#property version   "2.00"
#property strict

input double   RiskPercent      = 3.0;       // Higher risk for aggressive (3-5%)
input int      StopLossPips     = 4;         // Tighter SL for more trades
input int      TakeProfitPips   = 5;         // Tight TP for high win rate
input int      SMAX_Length      = 6;         // Shorter lookback = more signals
input int      EMAPeriod        = 20;        // EMA filter
input int      MaxDailyLoss     = 8;         // Allow more losses before stopping
input bool     UseOnlyLondonNY  = false;     // Set false to test anytime
input int      SessionOffset    = 0;
input bool     EnableDebug      = true;

double point, pipValue;
int    magicNumber = 20250330;
int    dailyLossCount = 0;
int    emaHandle;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   pipValue = (digits == 5 || digits == 3) ? point * 10 : point;
   
   emaHandle = iMA(Symbol(), PERIOD_M1, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandle == INVALID_HANDLE) return INIT_FAILED;
   
   Print("EA started | Point=", point, " PipValue=", pipValue);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(emaHandle != INVALID_HANDLE) IndicatorRelease(emaHandle);
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function - LOOSENED RULES                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // Reset daily loss counter at new day
   static datetime lastDay = 0;
   datetime today = iTime(Symbol(), PERIOD_D1, 0);
   if(today != lastDay) { dailyLossCount = 0; lastDay = today; }
   if(dailyLossCount >= MaxDailyLoss) return;
   
   // Session filter (optional)
   if(UseOnlyLondonNY)
   {
      MqlDateTime tm;
      TimeToStruct(TimeCurrent(), tm);
      int localHour = tm.hour + SessionOffset;
      if(!((localHour >= 7 && localHour < 10) || (localHour >= 12 && localHour < 15))) return;
   }
   
   // Trade only on new M1 bar
   static datetime lastBarTime = 0;
   datetime barTime = iTime(Symbol(), PERIOD_M1, 0);
   if(barTime == lastBarTime) return;
   lastBarTime = barTime;
   
   // Only one position at a time
   if(PositionSelect(Symbol())) return;
   
   // Get M1 rates
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(Symbol(), PERIOD_M1, 0, SMAX_Length+5, rates) < SMAX_Length+2) return;
   
   // Swing high/low (last SMAX_Length bars, excluding current)
   double swingHigh = 0;
   for(int i=1; i<=SMAX_Length; i++) if(rates[i].high > swingHigh) swingHigh = rates[i].high;
   double swingLow = DBL_MAX;
   for(int i=1; i<=SMAX_Length; i++) if(rates[i].low < swingLow) swingLow = rates[i].low;
   
   // EMA values
   double ema[2];
   if(CopyBuffer(emaHandle, 0, 0, 2, ema) < 2) return;
   double currentEMA = ema[0];
   
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   
   // --- LOOSENED SIGNAL CONDITIONS ---
   // Sell: price spiked above swingHigh (liquidity sweep) AND current bid is below that high (return)
   // No rejection candle required, no EMA slope check
   bool sellSweep = (rates[0].high > swingHigh + 0.3 * pipValue); // smaller buffer
   bool sellReturn = (bid < swingHigh);
   bool sellEMA = (bid < currentEMA); // only price below EMA, no slope condition
   bool sellSignal = sellSweep && sellReturn && sellEMA;
   
   // Buy: price spiked below swingLow AND current ask is above that low
   bool buySweep = (rates[0].low < swingLow - 0.3 * pipValue);
   bool buyReturn = (ask > swingLow);
   bool buyEMA = (ask > currentEMA);
   bool buySignal = buySweep && buyReturn && buyEMA;
   
   // --- FORCE TRADE FALLBACK (ensures trades in dead market) ---
   static int forceCounter = 0;
   forceCounter++;
   if(forceCounter >= 30 && !sellSignal && !buySignal)  // every 30 bars, force a trade
   {
      forceCounter = 0;
      // Force a trade in direction of EMA: if price above EMA -> buy, else sell
      if(ask > currentEMA) buySignal = true;
      else sellSignal = true;
      if(EnableDebug) Print("Force trade triggered");
   }
   
   // Debug on chart
   if(EnableDebug)
   {
      string dbg = StringFormat(
         "SwingHigh=%.5f SwingLow=%.5f\n"
         "Sweep Sell: high=%.5f > %.5f ? %s | Return: bid=%.5f < %.5f ? %s | EMA: bid<%.5f ? %s\n"
         "Sweep Buy: low=%.5f < %.5f ? %s | Return: ask=%.5f > %.5f ? %s | EMA: ask>%.5f ? %s\n"
         "Sell Signal: %s | Buy Signal: %s",
         swingHigh, swingLow,
         rates[0].high, swingHigh+pipValue*0.3, (rates[0].high > swingHigh+pipValue*0.3)?"YES":"no",
         bid, swingHigh, (bid < swingHigh)?"YES":"no",
         currentEMA, (bid < currentEMA)?"YES":"no",
         rates[0].low, swingLow-pipValue*0.3, (rates[0].low < swingLow-pipValue*0.3)?"YES":"no",
         ask, swingLow, (ask > swingLow)?"YES":"no",
         currentEMA, (ask > currentEMA)?"YES":"no",
         sellSignal?"★ACTIVE★":"---", buySignal?"★ACTIVE★":"---"
      );
      Comment(dbg);
   }
   
   if(!sellSignal && !buySignal) return;
   
   // Execute trade
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double slPoints = StopLossPips * pipValue / point;
   double tpPoints = TakeProfitPips * pipValue / point;
   
   if(sellSignal)
   {
      double sl = bid + slPoints * point;
      double tp = bid - tpPoints * point;
      Trade(ORDER_TYPE_SELL, riskAmount, sl, tp);
   }
   else if(buySignal)
   {
      double sl = ask - slPoints * point;
      double tp = ask + tpPoints * point;
      Trade(ORDER_TYPE_BUY, riskAmount, sl, tp);
   }
}

//+------------------------------------------------------------------+
//| Trade execution (MQL5 compatible)                                |
//+------------------------------------------------------------------+
void Trade(ENUM_ORDER_TYPE type, double riskAmount, double sl, double tp)
{
   string sym = Symbol();
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   
   // Calculate lot based on risk
   double slDist = MathAbs(price - sl);
   if(slDist < point) slDist = point;
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double lossPerLot = slDist / tickSize * tickValue;
   double lot = riskAmount / lossPerLot;
   lot = NormalizeDouble(lot, 2);
   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathRound(lot / step) * step;
   if(lot < minLot) lot = minLot;  // use minimum allowed if calculation too small
   
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = sym;
   req.volume = lot;
   req.type = type;
   req.price = price;
   req.sl = sl;
   req.tp = tp;
   req.deviation = 10;
   req.type_filling = ORDER_FILLING_FOK;
   req.magic = magicNumber;
   req.comment = "AggressiveSweep";
   
   if(OrderSend(req, res))
      Print("Trade opened: ", EnumToString(type), " lot=", lot, " entry=", price);
   else
      Print("OrderSend failed. Error: ", GetLastError(), " retcode=", res.retcode);
}

//+------------------------------------------------------------------+
//| Track daily loss count                                           |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong deal = trans.deal;
      if(HistoryDealSelect(deal))
      {
         if(HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         {
            double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
            if(profit < 0) dailyLossCount++;
         }
      }
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
