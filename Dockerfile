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
//|                              Generated for $10 cent account usage|
//+------------------------------------------------------------------+
#property copyright "ScalperEA"
#property version   "1.00"
#property strict

input double   RiskPercent      = 2.0;       // Risk per trade (% of balance)
input int      StopLossPips     = 5;         // Stop Loss in pips
input int      TakeProfitPips   = 6;         // Take Profit in pips
input int      SMAX_Length      = 10;        // Lookback for swing high/low
input int      EMAPeriod        = 20;        // EMA period for trend filter
input int      MaxDailyLoss     = 6;         // Max daily losses before stopping
input bool     UseOnlyLondonNY  = true;      // Trade only London/NY session

double point, pipValue;
int    magicNumber = 20250310;
int    dailyLossCount = 0;
datetime lastTradeTime = 0;
bool   sessionActive = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   point = SymbolInfoInteger(Symbol(), SYMBOL_POINT);
   pipValue = (SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE)) * 10.0; // approx for 5-digit broker
   if(point == 0.00001) pipValue *= 10; // adjust for 5-digit
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Reset daily loss counter at new day
   static datetime lastDay = 0;
   datetime today = iTime(Symbol(), PERIOD_D1, 0);
   if(today != lastDay)
   {
      dailyLossCount = 0;
      lastDay = today;
   }
   
   // Check trading session
   if(UseOnlyLondonNY)
   {
      datetime now = TimeCurrent();
      MqlDateTime tm;
      TimeToStruct(now, tm);
      int hour = tm.hour;
      if(!((hour >= 7 && hour < 10) || (hour >= 12 && hour < 15))) // London 7-10 GMT, NY 12-15 GMT
      {
         sessionActive = false;
         return;
      }
      sessionActive = true;
   }
   else sessionActive = true;
   
   // Don't trade if daily loss limit reached
   if(dailyLossCount >= MaxDailyLoss) return;
   
   // Avoid trading every tick – only on new bar open (M1)
   static datetime lastBarTime = 0;
   datetime barTime = iTime(Symbol(), PERIOD_M1, 0);
   if(barTime == lastBarTime) return;
   lastBarTime = barTime;
   
   // Check for existing positions
   if(PositionSelect(Symbol())) return;
   
   // Get M1 rates
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   CopyRates(Symbol(), PERIOD_M1, 0, SMAX_Length+5, rates);
   
   // Compute swing high (last SMAX_Length bars, excluding current)
   double swingHigh = 0;
   int swingHighIdx = -1;
   for(int i=1; i<=SMAX_Length; i++)
   {
      if(rates[i].high > swingHigh)
      {
         swingHigh = rates[i].high;
         swingHighIdx = i;
      }
   }
   
   // Compute swing low
   double swingLow = DBL_MAX;
   for(int i=1; i<=SMAX_Length; i++)
   {
      if(rates[i].low < swingLow) swingLow = rates[i].low;
   }
   
   // Get EMA 20 on M1
   double ema[20];
   CopyBuffer(iMA(Symbol(), PERIOD_M1, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE), 0, 1, 2, ema);
   double currentEMA = ema[0];
   double prevEMA = ema[1];
   
   // Current price
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   
   // ---- SELL condition: sweep of swing high + rejection + price below EMA ----
   bool sellSignal = false;
   // Sweep: current high > swingHigh + 0.5 pip (to avoid noise)
   if(rates[0].high > swingHigh + 0.5*point*10)
   {
      // Rejection: current close < swingHigh and close < open (bearish rejection)
      if(rates[0].close < swingHigh && rates[0].close < rates[0].open)
      {
         // EMA filter: current price < EMA20 and EMA flat/sloping down
         if(bid < currentEMA && currentEMA <= prevEMA + 0.1*point*10)
         {
            sellSignal = true;
         }
      }
   }
   
   // ---- BUY condition: sweep of swing low + rejection + price above EMA ----
   bool buySignal = false;
   if(rates[0].low < swingLow - 0.5*point*10)
   {
      if(rates[0].close > swingLow && rates[0].close > rates[0].open)
      {
         if(ask > currentEMA && currentEMA >= prevEMA - 0.1*point*10)
         {
            buySignal = true;
         }
      }
   }
   
   // Execute trades
   double riskAmount = (AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent) / 100.0;
   double slPoints = StopLossPips * 10.0;  // convert to points (1 pip = 10 points for 5-digit)
   double tpPoints = TakeProfitPips * 10.0;
   
   if(sellSignal)
   {
      double sl = bid + slPoints * point;
      double tp = bid - tpPoints * point;
      Trade(Symbol(), OP_SELL, 0, riskAmount, sl, tp, "LiquiditySweep sell");
   }
   else if(buySignal)
   {
      double sl = ask - slPoints * point;
      double tp = ask + tpPoints * point;
      Trade(Symbol(), OP_BUY, 0, riskAmount, sl, tp, "LiquiditySweep buy");
   }
}

//+------------------------------------------------------------------+
//| Trade execution function                                         |
//+------------------------------------------------------------------+
void Trade(string sym, int cmd, double lot, double riskAmount, double sl, double tp)
{
   double price = (cmd == OP_BUY) ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   
   // Calculate lot size based on risk in account currency
   double slDistance = MathAbs(price - sl);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double lossPerLot = slDistance / tickSize * tickValue;
   lot = NormalizeDouble(riskAmount / lossPerLot, 2);
   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathRound(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = sym;
   req.volume = lot;
   req.type = (cmd == OP_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price = price;
   req.sl = sl;
   req.tp = tp;
   req.deviation = 10;
   req.type_filling = ORDER_FILLING_FOK;
   req.magic = magicNumber;
   req.comment = "ScalpEA";
   
   if(!OrderSend(req, res))
   {
      Print("OrderSend error: ", res.retcode);
      return;
   }
   
   // Track loss counter (will be updated on TradeTransaction)
   Print("Trade opened: ", (cmd==OP_BUY?"BUY":"SELL"), " lot=", lot, " sl=", sl, " tp=", tp);
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
      long dealEntry = 0;
      HistoryDealSelect(trans.deal);
      if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
      {
         double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
         if(profit < 0) dailyLossCount++;
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
