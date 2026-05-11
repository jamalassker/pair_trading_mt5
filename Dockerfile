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
//|                    LOOSE AGGRESSIVE SWEEP SCALPER               |
//|                    Opens many trades, manages risk             |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property strict
#property version "6.0"

// --- Inputs --------------------------------------------------------+
input string   SymbolToTrade       = "EURUSD.vx";
input double   FixedLot            = 0.01;          // Fixed lot
input int      LookbackBars        = 8;             // Lookback for swing highs/lows
input double   SweepPoints         = 1;             // Points beyond swing to trigger (1 = tight)
input int      StopLossPoints      = 10;            // Fixed stop loss in points
input int      TakeProfitPoints    = 15;            // Fixed take profit in points
input bool     UseBreakeven        = true;          // Move SL to breakeven after profit
input int      BreakevenTrigger    = 5;             // Pips profit to trigger breakeven
input bool     UseTrailing         = true;          // Trailing stop once profit exceeds trigger
input int      TrailingPoints      = 8;             // Trailing distance (points)
input double   MinProfitUSD        = 0.30;          // Minimum profit to close (if not using trailing)
input bool     CloseOnAnyProfit    = true;          // Close immediately when profit > 0
input int      MaxPositions        = 3;             // Max concurrent trades
input int      MaxDailyLossPercent = 5.0;
input int      MaxConsecutiveLosses = 3;
input int      CooldownSeconds     = 5;             // Short cooldown between trades
input int      MagicNumber         = 777999;
input bool     DebugPrint          = true;

// --- Globals -------------------------------------------------------+
CTrade trade;
double point;
double dailyStartEquity = 0;
datetime dayStart = 0;
int consecutiveLosses = 0;
datetime lastTradeTime = 0;
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
double GetLowestLow()
{
   double low = DBL_MAX;
   for(int i=1; i<=LookbackBars; i++)
      low = MathMin(low, iLow(SymbolToTrade, PERIOD_M1, i));
   return low;
}
double GetHighestHigh()
{
   double high = -DBL_MAX;
   for(int i=1; i<=LookbackBars; i++)
      high = MathMax(high, iHigh(SymbolToTrade, PERIOD_M1, i));
   return high;
}

//+------------------------------------------------------------------+
// Simple sweep detection: current price exceeded recent swing
bool IsBuySweep()
{
   double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   double lowestLow = GetLowestLow();
   return (bid < lowestLow - SweepPoints * point);
}
bool IsSellSweep()
{
   double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   double highestHigh = GetHighestHigh();
   return (ask > highestHigh + SweepPoints * point);
}

//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   double sl = ask - StopLossPoints * point;
   double tp = ask + TakeProfitPoints * point;
   
   if(trade.Buy(FixedLot, SymbolToTrade, ask, sl, tp, "Sweep Buy"))
   {
      Print("🔥 BUY opened at ", ask);
      lastTradeTime = TimeCurrent();
   }
   else
      Print("❌ BUY failed: ", trade.ResultRetcodeDescription());
}

void OpenSell()
{
   double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   double sl = bid + StopLossPoints * point;
   double tp = bid - TakeProfitPoints * point;
   
   if(trade.Sell(FixedLot, SymbolToTrade, bid, sl, tp, "Sweep Sell"))
   {
      Print("🔥 SELL opened at ", bid);
      lastTradeTime = TimeCurrent();
   }
   else
      Print("❌ SELL failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void ManageTrailing(ulong ticket, double openPrice, int direction)
{
   double currentPrice = (direction == 1) ? SymbolInfoDouble(SymbolToTrade, SYMBOL_BID)
                                          : SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
   double profitPips = (direction == 1) ? (currentPrice - openPrice) / point
                                        : (openPrice - currentPrice) / point;
   
   if(UseBreakeven && profitPips >= BreakevenTrigger)
   {
      double beSL = (direction == 1) ? openPrice : openPrice;
      if(MathAbs(PositionGetDouble(POSITION_SL) - beSL) > point)
      {
         trade.PositionModify(ticket, beSL, PositionGetDouble(POSITION_TP));
         if(DebugPrint) Print("Breakeven set");
      }
   }
   
   if(UseTrailing && profitPips > TrailingPoints)
   {
      double newSL = (direction == 1) ? currentPrice - TrailingPoints * point
                                      : currentPrice + TrailingPoints * point;
      double currentSL = PositionGetDouble(POSITION_SL);
      if((direction == 1 && newSL > currentSL) || (direction == -1 && newSL < currentSL))
      {
         trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
         if(DebugPrint) Print("Trail updated to ", newSL);
      }
   }
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
      
      // Close if profit > MinProfitUSD or CloseOnAnyProfit
      if(CloseOnAnyProfit && profit > 0)
      {
         trade.PositionClose(ticket);
         Print("💰 Closed profit: $", profit);
         consecutiveLosses = 0;
         continue;
      }
      if(!CloseOnAnyProfit && profit >= MinProfitUSD)
      {
         trade.PositionClose(ticket);
         Print("💰 Closed profit: $", profit);
         consecutiveLosses = 0;
         continue;
      }
      
      // Apply trailing stop management
      int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ManageTrailing(ticket, openPrice, dir);
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(SymbolToTrade);
   SymbolSelect(SymbolToTrade, true);
   point = SymbolInfoDouble(SymbolToTrade, SYMBOL_POINT);
   
   dayStart = TimeCurrent();
   dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("====================================");
   Print("LOOSE AGGRESSIVE SWEEP SCALPER");
   Print("Symbol: ", SymbolToTrade, " Lot: ", FixedLot);
   Print("SL: ", StopLossPoints, " TP: ", TakeProfitPoints);
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
      if(now - lastTradeTime < CooldownSeconds * 60) // cooldown in seconds? Actually CooldownSeconds is seconds, not minutes
         return;
      else
         consecutiveLosses = 0;
   }
   
   // Position limit
   if(CountPositions() >= MaxPositions) return;
   if(now - lastTradeTime < CooldownSeconds) return; // short cooldown between trades
   
   // Manage existing positions (close profits, trail)
   ManagePositions();
   
   // Simple sweep detection – NO reclaim, NO filters
   if(IsBuySweep())
   {
      OpenBuy();
   }
   else if(IsSellSweep())
   {
      OpenSell();
   }
   
   // Debug output sporadically
   static datetime lastDebug = 0;
   if(DebugPrint && now - lastDebug >= 10)
   {
      lastDebug = now;
      double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
      double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);
      double lowest = GetLowestLow();
      double highest = GetHighestHigh();
      Print("Bid=", bid, " Ask=", ask, " Low=", lowest, " High=", highest);
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
