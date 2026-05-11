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
//|                    AGGRESSIVE PROFITABLE SWEEP SCALPER          |
//|                    High win rate, positive expectancy          |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property strict
#property version "5.0"

// --- Inputs --------------------------------------------------------+
input string   SymbolToTrade       = "EURUSD.vx";
input double   FixedLot            = 0.01;          // Fixed lot (adjust)
input int      LookbackBars        = 8;
input double   SweepPoints         = 2;             // Points beyond swing to trigger sweep
input int      MinReclaimCandles   = 2;             // Reclaim within X candles
input double   RiskRewardRatio     = 1.5;           // TP = SL * this ratio
input double   ATRMultiplierSL     = 1.0;           // Stop loss = ATR * this
input int      ATRPeriod           = 14;
input bool     UseTrendFilter      = true;
input int      TrendMAPeriod       = 200;           // EMA for trend (M5)
input bool     UseVolumeFilter     = true;
input double   VolumeMultiplier    = 1.5;           // Sweep candle volume > avg * this
input bool     UseRSIFilter        = true;
input double   RSIOversold         = 30.0;
input double   RSIOverbought       = 70.0;
input int      BreakevenTriggerPips = 5;            // Move SL to BE after this profit (pips)
input double   TrailingStopPips    = 8;             // Trailing stop once profit > trigger
input double   MinProfitUSD        = 0.30;          // Minimum profit to close (if not trailing)
input bool     CloseOnProfit       = true;          // Close immediately when profit > MinProfitUSD
input int      MaxPositions        = 2;             // Max concurrent trades
input int      MaxDailyLossPercent = 5.0;
input int      MaxConsecutiveLosses = 3;
input int      CooldownSecondsAfterLoss = 30;       // Pause after a losing trade
input int      MagicNumber         = 777999;
input bool     DebugPrint          = true;

// --- Globals -------------------------------------------------------+
CTrade trade;
double point;
int atrHandle, trendMaHandle, rsiHandle;
double dailyStartEquity = 0;
datetime dayStart = 0;
int consecutiveLosses = 0;
datetime lastLossTime = 0;
bool tradingEnabled = true;

//+------------------------------------------------------------------+
int CountPositions()
{
   int total = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == SymbolToTrade)
            total++;
   }
   return total;
}

//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   // London open to NY close: 8-16 GMT
   return (dt.hour >= 8 && dt.hour < 16);
}

//+------------------------------------------------------------------+
bool IsTrendUp()
{
   if(!UseTrendFilter) return true;
   double ma[];
   ArraySetAsSeries(ma, true);
   if(CopyBuffer(trendMaHandle, 0, 0, 1, ma) < 1) return true;
   double price = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   return (price > ma[0]);
}
bool IsTrendDown()
{
   if(!UseTrendFilter) return true;
   double ma[];
   ArraySetAsSeries(ma, true);
   if(CopyBuffer(trendMaHandle, 0, 0, 1, ma) < 1) return true;
   double price = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   return (price < ma[0]);
}

//+------------------------------------------------------------------+
double GetATR()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) < 1) return 10 * point;
   return atr[0];
}

//+------------------------------------------------------------------+
bool IsVolumeSpike()
{
   if(!UseVolumeFilter) return true;
   long volume = iVolume(SymbolToTrade, PERIOD_M1, 0);
   double avgVol = 0;
   for(int i=1; i<=20; i++) avgVol += iVolume(SymbolToTrade, PERIOD_M1, i);
   avgVol /= 20;
   return (volume > avgVol * VolumeMultiplier);
}

bool IsRSIBuy()
{
   if(!UseRSIFilter) return true;
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsi) < 1) return true;
   return (rsi[0] < RSIOversold);
}
bool IsRSISell()
{
   if(!UseRSIFilter) return true;
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsi) < 1) return true;
   return (rsi[0] > RSIOverbought);
}

//+------------------------------------------------------------------+
double GetLowestLow()
{
   double low = DBL_MAX;
   for(int i=2; i<=LookbackBars; i++)
      low = MathMin(low, iLow(SymbolToTrade, PERIOD_M1, i));
   return low;
}
double GetHighestHigh()
{
   double high = -DBL_MAX;
   for(int i=2; i<=LookbackBars; i++)
      high = MathMax(high, iHigh(SymbolToTrade, PERIOD_M1, i));
   return high;
}

//+------------------------------------------------------------------+
// Sweep + Reclaim detection with state machines
bool SweepBuyConfirmed()
{
   static bool awaitingReclaim = false;
   static double sweepLow = 0;
   static datetime sweepTime = 0;
   
   double currentLow = iLow(SymbolToTrade, PERIOD_M1, 0);
   double lowestLow = GetLowestLow();
   
   if(!awaitingReclaim && currentLow <= lowestLow - SweepPoints * point)
   {
      awaitingReclaim = true;
      sweepLow = lowestLow;
      sweepTime = TimeCurrent();
      if(DebugPrint) Print("Sweep low at ", currentLow);
   }
   
   if(awaitingReclaim && (TimeCurrent() - sweepTime) <= MinReclaimCandles * 60)
   {
      double close = iClose(SymbolToTrade, PERIOD_M1, 0);
      if(close > sweepLow)
      {
         awaitingReclaim = false;
         if(DebugPrint) Print("Reclaim confirmed: Buy setup");
         return true;
      }
   }
   if(awaitingReclaim && (TimeCurrent() - sweepTime) > MinReclaimCandles * 60)
      awaitingReclaim = false;
   
   return false;
}

bool SweepSellConfirmed()
{
   static bool awaitingReclaim = false;
   static double sweepHigh = 0;
   static datetime sweepTime = 0;
   
   double currentHigh = iHigh(SymbolToTrade, PERIOD_M1, 0);
   double highestHigh = GetHighestHigh();
   
   if(!awaitingReclaim && currentHigh >= highestHigh + SweepPoints * point)
   {
      awaitingReclaim = true;
      sweepHigh = highestHigh;
      sweepTime = TimeCurrent();
      if(DebugPrint) Print("Sweep high at ", currentHigh);
   }
   
   if(awaitingReclaim && (TimeCurrent() - sweepTime) <= MinReclaimCandles * 60)
   {
      double close = iClose(SymbolToTrade, PERIOD_M1, 0);
      if(close < sweepHigh)
      {
         awaitingReclaim = false;
         if(DebugPrint) Print("Reclaim confirmed: Sell setup");
         return true;
      }
   }
   if(awaitingReclaim && (TimeCurrent() - sweepTime) > MinReclaimCandles * 60)
      awaitingReclaim = false;
   
   return false;
}

//+------------------------------------------------------------------+
void ManageTrailingStop(ulong ticket, double openPrice, int direction)
{
   double profitPips = 0;
   double currentPrice = (direction == 1) ? SymbolInfoDouble(SymbolToTrade, SYMBOL_BID)
                                          : SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   if(direction == 1) profitPips = (currentPrice - openPrice) / point;
   else profitPips = (openPrice - currentPrice) / point;
   
   if(profitPips > BreakevenTriggerPips)
   {
      // Move SL to breakeven if not already
      double sl = (direction == 1) ? openPrice : openPrice;
      if(PositionGetDouble(POSITION_SL) != sl)
      {
         trade.PositionModify(ticket, sl, PositionGetDouble(POSITION_TP));
         if(DebugPrint) Print("Breakeven triggered");
      }
      // Trailing stop
      if(TrailingStopPips > 0 && profitPips > TrailingStopPips)
      {
         double newSL = (direction == 1) ? currentPrice - TrailingStopPips * point
                                         : currentPrice + TrailingStopPips * point;
         if((direction == 1 && newSL > PositionGetDouble(POSITION_SL)) ||
            (direction == -1 && newSL < PositionGetDouble(POSITION_SL)))
         {
            trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            if(DebugPrint) Print("Trail updated: new SL=", newSL);
         }
      }
   }
}

//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   double atr = GetATR();
   double sl_pips = atr / point * ATRMultiplierSL;
   double tp_pips = sl_pips * RiskRewardRatio;
   
   int stopsLevel = (int)SymbolInfoInteger(SymbolToTrade, SYMBOL_TRADE_STOPS_LEVEL);
   double minSL = (stopsLevel + 2) * point;
   if(sl_pips * point < minSL) sl_pips = minSL / point;
   if(tp_pips * point < minSL) tp_pips = minSL / point;
   
   double sl = ask - sl_pips * point;
   double tp = ask + tp_pips * point;
   
   if(trade.Buy(FixedLot, SymbolToTrade, ask, sl, tp, "Sweep Buy"))
   {
      Print("🔥 BUY opened | SL=", sl, " TP=", tp);
   }
   else
      Print("❌ BUY failed: ", trade.ResultRetcodeDescription());
}

void OpenSell()
{
   double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   double atr = GetATR();
   double sl_pips = atr / point * ATRMultiplierSL;
   double tp_pips = sl_pips * RiskRewardRatio;
   
   int stopsLevel = (int)SymbolInfoInteger(SymbolToTrade, SYMBOL_TRADE_STOPS_LEVEL);
   double minSL = (stopsLevel + 2) * point;
   if(sl_pips * point < minSL) sl_pips = minSL / point;
   if(tp_pips * point < minSL) tp_pips = minSL / point;
   
   double sl = bid + sl_pips * point;
   double tp = bid - tp_pips * point;
   
   if(trade.Sell(FixedLot, SymbolToTrade, bid, sl, tp, "Sweep Sell"))
   {
      Print("🔥 SELL opened | SL=", sl, " TP=", tp);
   }
   else
      Print("❌ SELL failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      double profit = PositionGetDouble(POSITION_PROFIT);
      // Close if profit > MinProfitUSD and CloseOnProfit is true
      if(CloseOnProfit && profit >= MinProfitUSD)
      {
         trade.PositionClose(ticket);
         Print("💰 Closed profit: $", profit);
         consecutiveLosses = 0;
         continue;
      }
      // For remaining positions, apply trailing stop management
      int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ManageTrailingStop(ticket, openPrice, dir);
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(SymbolToTrade);
   SymbolSelect(SymbolToTrade, true);
   point = SymbolInfoDouble(SymbolToTrade, SYMBOL_POINT);
   
   atrHandle = iATR(SymbolToTrade, PERIOD_M1, ATRPeriod);
   trendMaHandle = iMA(SymbolToTrade, PERIOD_M5, TrendMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle = iRSI(SymbolToTrade, PERIOD_M1, 14, PRICE_CLOSE);
   if(atrHandle == INVALID_HANDLE || trendMaHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE)
      return INIT_FAILED;
   
   dayStart = TimeCurrent();
   dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("====================================");
   Print("AGGRESSIVE PROFITABLE SWEEP SCALPER");
   Print("Symbol: ", SymbolToTrade, " Lot: ", FixedLot);
   Print("Risk/Reward: 1:", RiskRewardRatio);
   Print("====================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Daily loss reset
   datetime now = TimeCurrent();
   if(now - dayStart >= 86400)
   {
      dayStart = now;
      dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      tradingEnabled = true;
      consecutiveLosses = 0;
   }
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = (dailyStartEquity - equity) / dailyStartEquity * 100.0;
   if(lossPercent >= MaxDailyLossPercent)
      tradingEnabled = false;
   else if(lossPercent < MaxDailyLossPercent-2)
      tradingEnabled = true;
   if(!tradingEnabled) return;
   
   // Cooldown after consecutive losses
   if(consecutiveLosses >= MaxConsecutiveLosses)
   {
      if(now - lastLossTime < CooldownSecondsAfterLoss)
         return;
      else
         consecutiveLosses = 0; // reset after cooldown
   }
   
   if(!IsTradingTime()) return;
   if(CountPositions() >= MaxPositions) return;
   
   // Manage existing positions (close profits, trail)
   ManagePositions();
   
   // Quick check: if we still have max positions, skip new entries
   if(CountPositions() >= MaxPositions) return;
   
   // Volume and RSI filters applied after signal
   if(SweepBuyConfirmed() && IsTrendUp() && IsVolumeSpike() && IsRSIBuy())
      OpenBuy();
   else if(SweepSellConfirmed() && IsTrendDown() && IsVolumeSpike() && IsRSISell())
      OpenSell();
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
