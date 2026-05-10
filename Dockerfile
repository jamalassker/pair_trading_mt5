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
//|                                    Carry_Scalper_Optimized.mq5   |
//|                     Quick in/out – close as soon as profit > 0  |
//|                     Max hold time to cut losers                |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Scalper Carry"
#property version   "3.0"
#property strict

// --- INPUTS --------------------------------------------------------+
input string   TradeSymbol      = "AUDJPY.vx";    // Your symbol
input double   RiskPercent      = 2.0;            // Reduced from 5% for safety
input int      MaxHoldSeconds   = 300;            // Max hold time in seconds (5 minutes)
input int      MaxOpenPositions = 1;
input int      MagicNumber      = 999555;
input bool     UseAutoDirection = true;           // true = pick higher swap
input bool     ManualLong       = false;
input double   MinSwapToTrade   = -999.0;         // Allow any swap
input int      StartHour        = 0;
input int      EndHour          = 24;
input double   MaxDailyLossPercent = 10.0;
input bool     CloseOnAnyProfit = true;           // NEW: close immediately when profit > 0
input double   MinProfitUSD     = 0.01;           // Tiny profit target (0.01$)

// --- GLOBALS -------------------------------------------------------+
CTrade trade;
datetime lastDebug = 0;
datetime dayStart = 0;
datetime openTime = 0;
double dailyEquityStart = 0;
bool tradingEnabled = true;
ulong carryTicket = 0;

//+------------------------------------------------------------------+
bool IsTradingTime() {
   MqlDateTime dt;
   TimeCurrent(dt);
   return (dt.hour >= StartHour && dt.hour < EndHour);
}

double GetSwapLong() { return SymbolInfoDouble(TradeSymbol, SYMBOL_SWAP_LONG); }
double GetSwapShort() { return SymbolInfoDouble(TradeSymbol, SYMBOL_SWAP_SHORT); }

void CloseTrade(string reason) {
   if(carryTicket != 0 && PositionSelectByTicket(carryTicket)) {
      trade.PositionClose(carryTicket);
      Print("Closed trade: ", reason, " Ticket: ", carryTicket);
      carryTicket = 0;
      openTime = 0;
   }
}

//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   SymbolSelect(TradeSymbol, true);
   dayStart = TimeCurrent();
   dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("==============================================");
   Print("⚡ CARRY SCALPER (Optimized)");
   Print("   Symbol: ", TradeSymbol);
   Print("   Long swap: ", GetSwapLong(), " | Short swap: ", GetSwapShort());
   Print("   Max hold seconds: ", MaxHoldSeconds);
   Print("   Close on any profit: ", CloseOnAnyProfit);
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick() {
   datetime now = TimeCurrent();
   
   // Daily reset & loss limit
   if(now - dayStart >= 86400) {
      dayStart = now;
      dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
      tradingEnabled = true;
      Print("✅ New trading day");
   }
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = (dailyEquityStart - equity) / dailyEquityStart * 100.0;
   if(lossPercent >= MaxDailyLossPercent) {
      if(tradingEnabled) Print("🚨 Daily loss limit reached");
      tradingEnabled = false;
      return;
   }
   if(!tradingEnabled && lossPercent < MaxDailyLossPercent-2) tradingEnabled = true;
   if(!tradingEnabled) return;
   
   // --- Manage open position ---
   if(carryTicket != 0 && PositionSelectByTicket(carryTicket)) {
      double profit = PositionGetDouble(POSITION_PROFIT);
      
      // Fast exit: close on any profit (or when profit >= MinProfitUSD)
      if(CloseOnAnyProfit && profit > 0) {
         CloseTrade("Profit > 0 ($" + DoubleToString(profit,2) + ")");
         return;
      }
      if(!CloseOnAnyProfit && profit >= MinProfitUSD) {
         CloseTrade("Profit target $" + DoubleToString(MinProfitUSD));
         return;
      }
      // Max hold time – force close to prevent drawdown
      if(MaxHoldSeconds > 0 && openTime > 0 && (now - openTime) >= MaxHoldSeconds) {
         CloseTrade("Max hold time reached");
         return;
      }
      return; // still holding
   }
   
   // --- No open trade – check for entry ---
   if(!IsTradingTime()) return;
   if(PositionsTotal() >= MaxOpenPositions) return;
   
   // Determine direction based on swap (or manual)
   bool doBuy = false, doSell = false;
   double swapLong = GetSwapLong();
   double swapShort = GetSwapShort();
   
   if(UseAutoDirection) {
      if(swapLong >= swapShort) {
         if(swapLong >= MinSwapToTrade) doBuy = true;
      } else {
         if(swapShort >= MinSwapToTrade) doSell = true;
      }
   } else {
      doBuy = ManualLong;
      doSell = !ManualLong;
   }
   
   // Debug every 30 sec
   if(now - lastDebug >= 30) {
      lastDebug = now;
      Print("📊 Swap L=", swapLong, " S=", swapShort, " Buy=", doBuy, " Sell=", doSell);
   }
   if(!doBuy && !doSell) return;
   
   // Position sizing
   double lot = NormalizeDouble(equity / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, MathMin(lot, SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MAX)));
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   
   // Open trade WITHOUT stop loss or take profit (we close manually on profit/time)
   if(doBuy) {
      if(trade.Buy(lot, TradeSymbol, ask, 0, 0, "Scalp Long")) {
         carryTicket = trade.ResultOrder();
         openTime = now;
         Print("🔥 BUY opened. Lot=", lot, " SwapLong=", swapLong);
      } else Print("❌ Buy failed. Error ", GetLastError());
   } else if(doSell) {
      if(trade.Sell(lot, TradeSymbol, bid, 0, 0, "Scalp Short")) {
         carryTicket = trade.ResultOrder();
         openTime = now;
         Print("🔥 SELL opened. Lot=", lot, " SwapShort=", swapShort);
      } else Print("❌ Sell failed. Error ", GetLastError());
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
