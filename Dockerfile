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
//|                 HYPER SCALP FAST-IN FAST-OUT                    |
//|              Opens aggressively / closes any profit             |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property strict
#property version "6.0"

input string SymbolToTrade = "EURUSD.vx";

input double FixedLot = 0.01;

input int LookbackBars = 5;
input double SweepPoints = 0.5;

input double CloseProfitUSD = 0.03;
input double EmergencyLossUSD = -4.0;

input bool AllowBuy = true;
input bool AllowSell = true;

input bool AllowMultiplePositions = true;
input int MaxPositions = 10;

input int CooldownMilliseconds = 800;

input int MaxSpreadPoints = 30;

input bool UseEMAFilter = false;
input int EMA_Period = 20;

input int MagicNumber = 999777;

input bool DebugPrint = false;

CTrade trade;

double point;
ulong lastTradeMs = 0;

//+------------------------------------------------------------------+
int CountPositions()
{
   int total = 0;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == SymbolToTrade)
         {
            total++;
         }
      }
   }

   return total;
}

//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
            continue;

         double profit =
            PositionGetDouble(POSITION_PROFIT);

         // CLOSE ANY PROFIT FAST
         if(profit >= CloseProfitUSD)
         {
            trade.PositionClose(ticket);

            if(DebugPrint)
               Print("💰 QUICK EXIT: ", profit);
         }

         // EMERGENCY EXIT
         if(profit <= EmergencyLossUSD)
         {
            trade.PositionClose(ticket);

            if(DebugPrint)
               Print("🛑 LOSS EXIT: ", profit);
         }
      }
   }
}

//+------------------------------------------------------------------+
double GetLowestLow()
{
   double low = DBL_MAX;

   for(int i=1; i<=LookbackBars; i++)
   {
      double l =
         iLow(SymbolToTrade, PERIOD_M1, i);

      if(l < low)
         low = l;
   }

   return low;
}

//+------------------------------------------------------------------+
double GetHighestHigh()
{
   double high = -DBL_MAX;

   for(int i=1; i<=LookbackBars; i++)
   {
      double h =
         iHigh(SymbolToTrade, PERIOD_M1, i);

      if(h > high)
         high = h;
   }

   return high;
}

//+------------------------------------------------------------------+
bool SpreadOK()
{
   double spread =
      (SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK)
      -
      SymbolInfoDouble(SymbolToTrade, SYMBOL_BID))
      / point;

   return spread <= MaxSpreadPoints;
}

//+------------------------------------------------------------------+
bool BuyTrendOK()
{
   if(!UseEMAFilter)
      return true;

   double ema =
      iMA(
         SymbolToTrade,
         PERIOD_M1,
         EMA_Period,
         0,
         MODE_EMA,
         PRICE_CLOSE
      );

   double price =
      SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);

   return price > ema;
}

//+------------------------------------------------------------------+
bool SellTrendOK()
{
   if(!UseEMAFilter)
      return true;

   double ema =
      iMA(
         SymbolToTrade,
         PERIOD_M1,
         EMA_Period,
         0,
         MODE_EMA,
         PRICE_CLOSE
      );

   double price =
      SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);

   return price < ema;
}

//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask =
      SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);

   bool ok =
      trade.Buy(
         FixedLot,
         SymbolToTrade,
         ask,
         0,
         0,
         "HYPER BUY"
      );

   if(ok)
   {
      lastTradeMs = GetTickCount64();

      if(DebugPrint)
         Print("🔥 BUY OPENED");
   }
   else
   {
      Print(
         "❌ BUY FAILED: ",
         trade.ResultRetcodeDescription()
      );
   }
}

//+------------------------------------------------------------------+
void OpenSell()
{
   double bid =
      SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);

   bool ok =
      trade.Sell(
         FixedLot,
         SymbolToTrade,
         bid,
         0,
         0,
         "HYPER SELL"
      );

   if(ok)
   {
      lastTradeMs = GetTickCount64();

      if(DebugPrint)
         Print("🔥 SELL OPENED");
   }
   else
   {
      Print(
         "❌ SELL FAILED: ",
         trade.ResultRetcodeDescription()
      );
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   trade.SetTypeFillingBySymbol(SymbolToTrade);

   SymbolSelect(SymbolToTrade, true);

   point =
      SymbolInfoDouble(
         SymbolToTrade,
         SYMBOL_POINT
      );

   Print("================================");
   Print("⚡ HYPER SCALPER STARTED");
   Print("================================");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManagePositions();

   if(!SpreadOK())
      return;

   if(!AllowMultiplePositions)
   {
      if(CountPositions() > 0)
         return;
   }

   if(CountPositions() >= MaxPositions)
      return;

   ulong nowMs = GetTickCount64();

   if(nowMs - lastTradeMs <
      (ulong)CooldownMilliseconds)
   {
      return;
   }

   double lowestLow =
      GetLowestLow();

   double highestHigh =
      GetHighestHigh();

   double currentLow =
      iLow(SymbolToTrade, PERIOD_M1, 0);

   double currentHigh =
      iHigh(SymbolToTrade, PERIOD_M1, 0);

   bool aggressiveBuy =
      currentLow
      <
      (lowestLow - SweepPoints * point);

   bool aggressiveSell =
      currentHigh
      >
      (highestHigh + SweepPoints * point);

   // BUY
   if(AllowBuy &&
      aggressiveBuy &&
      BuyTrendOK())
   {
      OpenBuy();
   }

   // SELL
   if(AllowSell &&
      aggressiveSell &&
      SellTrendOK())
   {
      OpenSell();
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
