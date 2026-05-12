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
//|                                    Fixed for MT5 - Ready to trade|
//+------------------------------------------------------------------+
#property copyright "ScalperEA"
#property version   "1.10"
#property strict

#include <float.h>   // FIX: for DBL_MAX

// --- Inputs ---
input double   RiskPercent      = 2.0;
input int      StopLossPips     = 5;
input int      TakeProfitPips   = 6;
input int      SMAX_Length      = 10;
input int      EMAPeriod        = 20;
input int      MaxDailyLoss     = 6;
input bool     UseOnlyLondonNY  = true;
input int      SessionOffset    = 0;
input bool     EnableDebug      = false;

// --- Globals ---
double point, pipValue;
int    magicNumber = 20250310;
int    dailyLossCount = 0;
bool   sessionActive = false;

// FIX: EMA handle (MQL5 requirement)
int emaHandle;

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

   // FIX: create EMA indicator handle
   emaHandle = iMA(Symbol(), PERIOD_M1, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(emaHandle == INVALID_HANDLE)
   {
      Print("Failed to create EMA handle");
      return INIT_FAILED;
   }

   Print("EA started. Point=", point, " PipValue=", pipValue);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   static datetime lastDay = 0;
   datetime today = iTime(Symbol(), PERIOD_D1, 0);

   if(today != lastDay)
   {
      dailyLossCount = 0;
      lastDay = today;
      Print("New day. Loss counter reset.");
   }

   if(UseOnlyLondonNY)
   {
      datetime now = TimeCurrent();
      MqlDateTime tm;
      TimeToStruct(now, tm);

      int hour = tm.hour;
      int localHour = hour + SessionOffset;

      if(!((localHour >= 7 && localHour < 10) || (localHour >= 12 && localHour < 15)))
      {
         sessionActive = false;
         if(EnableDebug) Comment("Outside session");
         return;
      }
      sessionActive = true;
   }
   else sessionActive = true;

   if(dailyLossCount >= MaxDailyLoss)
   {
      if(EnableDebug) Comment("Daily loss limit reached");
      return;
   }

   static datetime lastBarTime = 0;
   datetime barTime = iTime(Symbol(), PERIOD_M1, 0);
   if(barTime == lastBarTime) return;
   lastBarTime = barTime;

   if(PositionSelect(Symbol())) return;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   if(CopyRates(Symbol(), PERIOD_M1, 0, SMAX_Length+5, rates) < SMAX_Length+2)
      return;

   double swingHigh = 0;
   for(int i=1; i<=SMAX_Length; i++)
      if(rates[i].high > swingHigh)
         swingHigh = rates[i].high;

   double swingLow = DBL_MAX;
   for(int i=1; i<=SMAX_Length; i++)
      if(rates[i].low < swingLow)
         swingLow = rates[i].low;

   // FIX: Correct EMA CopyBuffer usage
   double ema[2];
   if(CopyBuffer(emaHandle, 0, 0, 2, ema) < 2)
      return;

   double currentEMA = ema[0];
   double prevEMA = ema[1];

   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);

   bool sellSignal = false;
   double sweepHighLevel = swingHigh + 0.5 * pipValue;

   if(rates[0].high > sweepHighLevel)
   {
      if(rates[0].close < swingHigh && rates[0].close < rates[0].open)
      {
         if(bid < currentEMA && currentEMA <= prevEMA + 0.1*pipValue)
         {
            sellSignal = true;
            if(EnableDebug) Print("SELL signal at ", TimeToString(TimeCurrent()));
         }
      }
   }

   bool buySignal = false;
   double sweepLowLevel = swingLow - 0.5 * pipValue;

   if(rates[0].low < sweepLowLevel)
   {
      if(rates[0].close > swingLow && rates[0].close > rates[0].open)
      {
         if(ask > currentEMA && currentEMA >= prevEMA - 0.1*pipValue)
         {
            buySignal = true;
            if(EnableDebug) Print("BUY signal at ", TimeToString(TimeCurrent()));
         }
      }
   }

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
   else
   {
      if(EnableDebug)
      {
         Comment("No signal");
      }
   }
}

//+------------------------------------------------------------------+
//| Trade execution function                                         |
//+------------------------------------------------------------------+
void Trade(ENUM_ORDER_TYPE type, double riskAmount, double sl, double tp)
{
   string symbol = Symbol();
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                                           : SymbolInfoDouble(symbol, SYMBOL_BID);

   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   double slDistance = MathAbs(price - sl);
   if(slDistance < point) slDistance = point;

   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);

   double lossPerLot = slDistance / tickSize * tickValue;
   double lot = riskAmount / lossPerLot;

   lot = NormalizeDouble(lot, 2);
   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathRound(lot / step) * step;

   MqlTradeRequest req;
   MqlTradeResult res;
   ZeroMemory(req);
   ZeroMemory(res);

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
      Print("OrderSend failed. Error: ", GetLastError());
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
               Print("Loss recorded. Count: ", dailyLossCount);
            }
         }
      }
   }
}
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
