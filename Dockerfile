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
//|                                      HFT_LiquiditySweep.mq5      |
//|                           Aggressive HFT - Multiple positions    |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "HFT Scalper"
#property version   "5.00"

// --- HFT AGGRESSIVE INPUTS ---
input double   RiskPercent       = 2.0;        // Per trade risk (lower because many trades)
input int      StopLossPips      = 3;          // Very tight SL
input int      TakeProfitPips    = 3;          // Very tight TP (1:1)
input int      LookbackBars      = 3;          // Shorter lookback = more signals
input int      EMAPeriod         = 20;
input int      MaxDailyLoss      = 20;         // High limit for aggressive trading
input bool     UseSessionFilter  = false;      // No session filter – trade anytime
input int      SessionOffset     = 0;
input int      MaxOpenPositions  = 10;         // Allow multiple positions

// --- GLOBALS ---
CTrade trade;
int    magic = 20250405;
int    dailyLoss = 0;
int    emaHandle;
double point, pipValue;
datetime lastTradeTime = 0;

// Retry mechanism
int    retryCount = 0;
datetime lastRetryTime = 0;

//+------------------------------------------------------------------+
//| Auto-adjust SL/TP to broker minimum                              |
//+------------------------------------------------------------------+
void AdjustStopLevel(double &sl, double &tp, double price, ENUM_ORDER_TYPE type)
{
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * point;
   if(minDist <= 0) minDist = 10 * point;
   
   if(type == ORDER_TYPE_BUY)
   {
      if(sl != 0 && price - sl < minDist) sl = price - minDist;
      if(tp != 0 && tp - price < minDist) tp = price + minDist;
   }
   else
   {
      if(sl != 0 && sl - price < minDist) sl = price + minDist;
      if(tp != 0 && price - tp < minDist) tp = price - minDist;
   }
}

//+------------------------------------------------------------------+
//| Trade with retry (4756 handling)                                 |
//+------------------------------------------------------------------+
bool TradeWithRetry(ENUM_ORDER_TYPE type, double volume, double price, double sl, double tp, string comment)
{
   if(retryCount >= 5)
   {
      retryCount = 0;
      return false;
   }
   if(GetTickCount() - lastRetryTime < 1000 && retryCount > 0)
      return false;
   
   bool res = (type == ORDER_TYPE_BUY) ? trade.Buy(volume, _Symbol, price, sl, tp, comment)
                                       : trade.Sell(volume, _Symbol, price, sl, tp, comment);
   if(!res)
   {
      retryCount++;
      lastRetryTime = GetTickCount();
      return false;
   }
   retryCount = 0;
   return true;
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   pipValue = (digits == 5 || digits == 3) ? point * 10 : point;
   
   emaHandle = iMA(_Symbol, PERIOD_M1, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandle == INVALID_HANDLE) return INIT_FAILED;
   
   // Detect filling mode
   int modes = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   int fillMode = ORDER_FILLING_IOC;
   if((modes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) fillMode = ORDER_FILLING_IOC;
   else if((modes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) fillMode = ORDER_FILLING_FOK;
   else fillMode = ORDER_FILLING_RETURN;
   
   trade.SetExpertMagicNumber(magic);
   trade.SetTypeFilling(fillMode);
   trade.SetDeviationInPoints(10);
   
   Print("========================================");
   Print("HFT LIQUIDITY SWEEP - AGGRESSIVE MODE");
   Print("Symbol: ", _Symbol);
   Print("Max positions: ", MaxOpenPositions);
   Print("StopLoss: ", StopLossPips, " pips, TP: ", TakeProfitPips, " pips");
   Print("========================================");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTick - HFT: no throttle, multiple positions                    |
//+------------------------------------------------------------------+
void OnTick()
{
   // Daily loss limit
   static datetime lastDay = 0;
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != lastDay) { dailyLoss = 0; lastDay = today; }
   if(dailyLoss >= MaxDailyLoss) return;
   
   // Session filter (optional)
   if(UseSessionFilter)
   {
      MqlDateTime tm; TimeToStruct(TimeCurrent(), tm);
      int hour = (tm.hour + SessionOffset) % 24;
      if(!((hour >= 7 && hour < 10) || (hour >= 12 && hour < 15))) return;
   }
   
   // Check position limit
   if(PositionsTotal() >= MaxOpenPositions) return;
   
   // Get rates (no throttle => check every tick)
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
   
   double ema[1];
   if(CopyBuffer(emaHandle, 0, 0, 1, ema) < 1) return;
   double currentEMA = ema[0];
   
   // --- HFT: LOOSENED SIGNALS (smaller buffers, no EMA condition on return) ---
   bool buySignal = false, sellSignal = false;
   
   // Buy: low swept below swingLow (any small sweep) AND price returned above swingLow
   if(rates[0].low < swingLow - 0.1*pipValue && ask > swingLow)
      buySignal = true;
   // Sell: high swept above swingHigh AND price returned below swingHigh
   if(rates[0].high > swingHigh + 0.1*pipValue && bid < swingHigh)
      sellSignal = true;
   
   // Force trade very aggressively (every 30 ticks ~ 15 seconds)
   static int forceCounter = 0;
   forceCounter++;
   if(forceCounter >= 30 && !buySignal && !sellSignal)
   {
      forceCounter = 0;
      if(ask > currentEMA) buySignal = true;
      else sellSignal = true;
   }
   
   // Debug (optional – comment out for performance)
   Comment(StringFormat("HFT Mode | SwingH=%.5f SwingL=%.5f | Buy=%s Sell=%s | Positions=%d",
         swingHigh, swingLow, buySignal?"★":"-", sellSignal?"★":"-", PositionsTotal()));
   
   if(!buySignal && !sellSignal) return;
   
   // --- Trade execution ---
   double point2pip = pipValue / point;
   double sl_points = StopLossPips * point2pip;
   double tp_points = TakeProfitPips * point2pip;
   
   double lot = NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   
   ENUM_ORDER_TYPE tradeType;
   double price, sl, tp;
   string comment;
   
   if(buySignal)
   {
      tradeType = ORDER_TYPE_BUY;
      price = ask;
      sl = ask - sl_points * point;
      tp = ask + tp_points * point;
      comment = "HFT_Buy";
   }
   else
   {
      tradeType = ORDER_TYPE_SELL;
      price = bid;
      sl = bid + sl_points * point;
      tp = bid - tp_points * point;
      comment = "HFT_Sell";
   }
   
   // Enforce broker minimum stop distance
   AdjustStopLevel(sl, tp, price, tradeType);
   
   // Execute with retry
   bool placed = false;
   for(int attempt=0; attempt<5 && !placed; attempt++)
   {
      placed = TradeWithRetry(tradeType, lot, price, sl, tp, comment);
      if(!placed && attempt<4) Sleep(50);
   }
   if(placed)
      Print("🔥 HFT Trade: ", EnumToString(tradeType), " Lot=", lot, " @ ", price);
}

//+------------------------------------------------------------------+
//| Track daily losses                                               |
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
