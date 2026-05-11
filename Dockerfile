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
//|                    ULTRA AGGRESSIVE SWEEP SCALPER               |
//|                    Opens MANY trades on M1                      |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property strict
#property version "3.0"

input string   SymbolToTrade       = "EURUSD.vx";
input double   FixedLot            = 0.01;

input int      LookbackBars        = 8;
input double   SweepPoints         = 1;

input int      StopLossPoints      = 120;
input int      TakeProfitPoints    = 80;

input bool     CloseOnAnyProfit    = true;
input bool     AllowMultipleTrades = true;

input int      MaxPositions        = 5;

input int      MagicNumber         = 777999;

input bool     DebugPrint          = true;

CTrade trade;
double point;

//+------------------------------------------------------------------+
int CountPositions()
{
   int total = 0;

   for(int i=PositionsTotal()-1; i>=0; i--)
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
double GetLowestLow()
{
   double low = DBL_MAX;

   for(int i=2; i<=LookbackBars; i++)
   {
      double l = iLow(SymbolToTrade, PERIOD_M1, i);

      if(l < low)
         low = l;
   }

   return low;
}

//+------------------------------------------------------------------+
double GetHighestHigh()
{
   double high = -DBL_MAX;

   for(int i=2; i<=LookbackBars; i++)
   {
      double h = iHigh(SymbolToTrade, PERIOD_M1, i);

      if(h > high)
         high = h;
   }

   return high;
}

//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);

   double sl = ask - StopLossPoints * point;
   double tp = ask + TakeProfitPoints * point;

   bool ok = trade.Buy(
      FixedLot,
      SymbolToTrade,
      ask,
      sl,
      tp,
      "BUY SWEEP"
   );

   if(ok)
   {
      Print("🔥 BUY OPENED");
   }
   else
   {
      Print("❌ BUY FAILED: ", trade.ResultRetcode(),
            " | ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void OpenSell()
{
   double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);

   double sl = bid + StopLossPoints * point;
   double tp = bid - TakeProfitPoints * point;

   bool ok = trade.Sell(
      FixedLot,
      SymbolToTrade,
      bid,
      sl,
      tp,
      "SELL SWEEP"
   );

   if(ok)
   {
      Print("🔥 SELL OPENED");
   }
   else
   {
      Print("❌ SELL FAILED: ", trade.ResultRetcode(),
            " | ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
            continue;

         double profit = PositionGetDouble(POSITION_PROFIT);

         if(CloseOnAnyProfit && profit > 0)
         {
            trade.PositionClose(ticket);

            Print("💰 CLOSED PROFIT: ", profit);
         }
      }
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   trade.SetTypeFillingBySymbol(SymbolToTrade);

   SymbolSelect(SymbolToTrade, true);

   point = SymbolInfoDouble(SymbolToTrade, SYMBOL_POINT);

   Print("================================");
   Print("ULTRA SWEEP SCALPER STARTED");
   Print("Symbol: ", SymbolToTrade);
   Print("Point: ", point);
   Print("================================");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManagePositions();

   if(!AllowMultipleTrades)
   {
      if(CountPositions() > 0)
         return;
   }

   if(CountPositions() >= MaxPositions)
      return;

   double lowestLow = GetLowestLow();
   double highestHigh = GetHighestHigh();

   double bid = SymbolInfoDouble(SymbolToTrade, SYMBOL_BID);
   double ask = SymbolInfoDouble(SymbolToTrade, SYMBOL_ASK);

   double currentLow = iLow(SymbolToTrade, PERIOD_M1, 0);
   double currentHigh = iHigh(SymbolToTrade, PERIOD_M1, 0);

   // VERY AGGRESSIVE BUY
   bool buySweep =
      currentLow < (lowestLow - SweepPoints * point);

   // VERY AGGRESSIVE SELL
   bool sellSweep =
      currentHigh > (highestHigh + SweepPoints * point);

   if(DebugPrint)
   {
      Print(
         "LOW=", currentLow,
         " LL=", lowestLow,
         " HIGH=", currentHigh,
         " HH=", highestHigh
      );
   }

   if(buySweep)
   {
      OpenBuy();
   }

   if(sellSweep)
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
