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
//|                                      LiquiditySweepScalperEA.mq5 |
//|                           Relaxed version - Guaranteed to trade  |
//+------------------------------------------------------------------+
#property copyright "ScalperEA"
#property version   "2.00"
#property strict

// --- Inputs (tweak these) ---
input double   RiskPercent      = 2.0;       // Risk per trade (% of balance)
input int      StopLossPips     = 5;         // Stop Loss in pips
input int      TakeProfitPips   = 6;         // Take Profit in pips
input int      SMAX_Length      = 10;        // Lookback for swing high/low (minutes on M1)
input bool     UseEMAFilter     = false;     // Set TRUE for extra filter, FALSE for pure sweep
input int      EMAPeriod        = 20;        // EMA period (only if UseEMAFilter=true)
input int      MaxDailyLosses   = 6;         // Max losing trades per day
input bool     UseOnlyLondonNY  = false;     // Set TRUE to trade only London/NY sessions
input int      SessionOffset    = 0;         // Hours to add to GMT (e.g., 2 for MT5 summer time)
input bool     EnableDebug      = true;      // Show debug on chart and prints

// --- Globals ---
double point, pipValue;
int    magicNumber = 20250315;
int    dailyLossCount = 0;
int    emaHandle = INVALID_HANDLE;
bool   sessionActive = false;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   if(digits == 5 || digits == 3)
      pipValue = point * 10;
   else
      pipValue = point;
   
   if(UseEMAFilter)
   {
      emaHandle = iMA(Symbol(), PERIOD_M1, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(emaHandle == INVALID_HANDLE)
      {
         Print("Failed to create EMA handle. Disabling EMA filter.");
         UseEMAFilter = false;
      }
   }
   
   Print("EA started. Point=", point, " PipValue=", pipValue, " UseEMAFilter=", UseEMAFilter);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(emaHandle != INVALID_HANDLE) IndicatorRelease(emaHandle);
   Comment(""); // clear chart debug
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // --- Reset daily loss counter at new day ---
   static datetime lastDay = 0;
   datetime today = iTime(Symbol(), PERIOD_D1, 0);
   if(today != lastDay)
   {
      dailyLossCount = 0;
      lastDay = today;
      Print("New day. Loss counter reset.");
   }
   
   // --- Session filter (optional) ---
   if(UseOnlyLondonNY)
   {
      datetime now = TimeCurrent();
      MqlDateTime tm;
      TimeToStruct(now, tm);
      int localHour = tm.hour + SessionOffset;
      if(!((localHour >= 7 && localHour < 10) || (localHour >= 12 && localHour < 15)))
      {
         if(EnableDebug) Comment("Outside session");
         return;
      }
   }
   
   // --- Stop if daily loss limit hit ---
   if(dailyLossCount >= MaxDailyLosses)
   {
      if(EnableDebug) Comment("Daily loss limit reached");
      return;
   }
   
   // --- Only trade on new M1 bar (reduce redundant checks) ---
   static datetime lastBarTime = 0;
   datetime barTime = iTime(Symbol(), PERIOD_M1, 0);
   if(barTime == lastBarTime) return;
   lastBarTime = barTime;
   
   // --- Check if already have a position (no pyramiding) ---
   if(PositionSelect(Symbol())) return;
   
   // --- Get M1 rates for swing high/low ---
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(Symbol(), PERIOD_M1, 0, SMAX_Length + 5, rates) < SMAX_Length + 2)
   {
      if(EnableDebug) Comment("Insufficient rate data");
      return;
   }
   
   // --- Compute swing high and low over last SMAX_Length bars (excluding current candle 0) ---
   double swingHigh = 0;
   for(int i = 1; i <= SMAX_Length; i++)
      if(rates[i].high > swingHigh)
         swingHigh = rates[i].high;
   
   double swingLow = DBL_MAX;
   for(int i = 1; i <= SMAX_Length; i++)
      if(rates[i].low < swingLow)
         swingLow = rates[i].low;
   
   // --- Optional: Get EMA values ---
   double currentEMA = 0, prevEMA = 0;
   if(UseEMAFilter && emaHandle != INVALID_HANDLE)
   {
      double emaBuf[2];
      if(CopyBuffer(emaHandle, 0, 0, 2, emaBuf) == 2)
      {
         currentEMA = emaBuf[0];
         prevEMA = emaBuf[1];
      }
   }
   
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   
   // --- RELAXED SIGNAL LOGIC ---
   // Sell: price spiked above swingHigh (liquidity sweep) and now bid is back below that high
   bool sellSignal = false;
   bool sellSweep = (rates[0].high > swingHigh + 0.5 * pipValue); // 0.5 pip buffer
   bool sellReturn = (bid < swingHigh);
   bool sellEMACond = (!UseEMAFilter) || (bid < currentEMA && currentEMA <= prevEMA + 0.1*pipValue);
   
   // Buy: price spiked below swingLow and now ask is back above that low
   bool buySignal = false;
   bool buySweep = (rates[0].low < swingLow - 0.5 * pipValue);
   bool buyReturn = (ask > swingLow);
   bool buyEMACond = (!UseEMAFilter) || (ask > currentEMA && currentEMA >= prevEMA - 0.1*pipValue);
   
   if(sellSweep && sellReturn && sellEMACond)
      sellSignal = true;
   if(buySweep && buyReturn && buyEMACond)
      buySignal = true;
   
   // --- Debug output on chart ---
   if(EnableDebug)
   {
      string dbg = StringFormat(
         "Swing High: %.5f   Swing Low: %.5f\n"
         "Curr High: %.5f (sweep? %s)   Curr Low: %.5f (sweep? %s)\n"
         "Bid: %.5f (return below high? %s)   Ask: %.5f (return above low? %s)\n"
         "EMA filter: %s\n"
         "Sell Signal: %s   Buy Signal: %s",
         swingHigh, swingLow,
         rates[0].high, sellSweep?"YES":"no",
         rates[0].low, buySweep?"YES":"no",
         bid, sellReturn?"YES":"no",
         ask, buyReturn?"YES":"no",
         UseEMAFilter ? (StringFormat("EMA=%.5f",currentEMA)) : "OFF",
         sellSignal?"★ ACTIVE ★":"---",
         buySignal?"★ ACTIVE ★":"---"
      );
      Comment(dbg);
   }
   
   // --- Execute trade if signal ---
   if(sellSignal || buySignal)
   {
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
}

//+------------------------------------------------------------------+
//| Trade execution function (MQL5 compatible)                       |
//+------------------------------------------------------------------+
void Trade(ENUM_ORDER_TYPE type, double riskAmount, double sl, double tp)
{
   string symbol = Symbol();
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                                           : SymbolInfoDouble(symbol, SYMBOL_BID);
   
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   
   // Calculate lot size based on risk amount
   double slDistance = MathAbs(price - sl);
   if(slDistance < point) slDistance = point; // safety
   
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double lossPerLot = slDistance / tickSize * tickValue;
   double lot = riskAmount / lossPerLot;
   
   lot = NormalizeDouble(lot, 2);
   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathRound(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   
   // Prepare and send order
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = symbol;
   req.volume = lot;
   req.type = type;
   req.price = price;
   req.sl = sl;
   req.tp = tp;
   req.deviation = 10;
   req.type_filling = ORDER_FILLING_FOK;
   req.magic = magicNumber;
   req.comment = "SweepScalper";
   
   if(!OrderSend(req, res))
   {
      Print("OrderSend failed. Error code: ", res.retcode, " - ", GetLastError());
      return;
   }
   
   Print("Trade opened: ", EnumToString(type),
         " lot=", lot,
         " entry=", price,
         " sl=", sl,
         " tp=", tp);
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
      ulong dealTicket = trans.deal;
      if(HistoryDealSelect(dealTicket))
      {
         long entryType = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(entryType == DEAL_ENTRY_OUT)
         {
            double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            if(profit < 0)
            {
               dailyLossCount++;
               Print("Loss recorded. Daily loss count: ", dailyLossCount);
            }
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
