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
//|                                      UltraSensitiveSweepEA.mq5   |
//|                          Opens trades on ANY wick + return       |
//+------------------------------------------------------------------+
#property copyright "ScalperEA"
#property version   "3.00"

input double   RiskPercent = 2.0;
input int      StopLossPips = 5;
input int      TakeProfitPips = 6;
input int      LookbackBars = 5;      // How many bars back for swing high/low
input bool     UseEMA = false;         // Keep false for max sensitivity
input bool     EnableDebug = true;

double point, pipValue;
int magic = 20250320;
int dailyLoss = 0;
int emaHandle;

int OnInit()
{
   point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   pipValue = (digits == 5 || digits == 3) ? point * 10 : point;
   
   if(UseEMA) emaHandle = iMA(Symbol(), PERIOD_M1, 20, 0, MODE_EMA, PRICE_CLOSE);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   // Daily loss limit
   static datetime lastDay = 0;
   datetime today = iTime(Symbol(), PERIOD_D1, 0);
   if(today != lastDay) { dailyLoss = 0; lastDay = today; }
   if(dailyLoss >= 3) return;
   
   // New M1 bar only
   static datetime lastBar = 0;
   datetime barTime = iTime(Symbol(), PERIOD_M1, 0);
   if(barTime == lastBar) return;
   lastBar = barTime;
   
   if(PositionSelect(Symbol())) return;
   
   // Get rates
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(Symbol(), PERIOD_M1, 0, LookbackBars+2, rates) < LookbackBars+1) return;
   
   // Swing high/low over last N bars (excluding current bar 0)
   double swingHigh = 0, swingLow = DBL_MAX;
   for(int i=1; i<=LookbackBars; i++)
   {
      if(rates[i].high > swingHigh) swingHigh = rates[i].high;
      if(rates[i].low < swingLow) swingLow = rates[i].low;
   }
   
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   
   // SUPER SENSITIVE CONDITIONS:
   // Sell if current high > swingHigh (any spike) AND current bid is below that swingHigh
   // (Does NOT require candle close, does NOT require rejection pattern)
   bool sellSignal = (rates[0].high > swingHigh + 0.2*pipValue) && (bid < swingHigh);
   bool buySignal = (rates[0].low < swingLow - 0.2*pipValue) && (ask > swingLow);
   
   // Optional EMA filter (disabled by default)
   if(UseEMA && emaHandle != INVALID_HANDLE)
   {
      double ema[2];
      if(CopyBuffer(emaHandle, 0, 0, 2, ema) == 2)
      {
         if(sellSignal && bid > ema[0]) sellSignal = false;
         if(buySignal && ask < ema[0]) buySignal = false;
      }
   }
   
   // Debug on chart
   if(EnableDebug)
   {
      string dbg = StringFormat(
         "SwingHigh=%.5f SwingLow=%.5f\nHigh=%.5f Low=%.5f\nBid=%.5f Ask=%.5f\nSweepSell=%s SweepBuy=%s\nSellSignal=%s BuySignal=%s",
         swingHigh, swingLow, rates[0].high, rates[0].low, bid, ask,
         (rates[0].high > swingHigh+0.2*pipValue)?"YES":"no",
         (rates[0].low < swingLow-0.2*pipValue)?"YES":"no",
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

void Trade(ENUM_ORDER_TYPE type, double riskAmount, double sl, double tp)
{
   string sym = Symbol();
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   
   double slDist = MathAbs(price - sl);
   if(slDist < point) slDist = point;
   double tickVal = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double lossPerLot = slDist / tickSize * tickVal;
   double lot = riskAmount / lossPerLot;
   lot = NormalizeDouble(lot, 2);
   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathRound(lot / step) * step;
   if(lot < minLot) lot = minLot;
   
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
   req.magic = magic;
   req.comment = "UltraSweep";
   
   if(OrderSend(req, res))
      Print("Trade opened: ", EnumToString(type), " lot=", lot, " entry=", price);
   else
      Print("OrderSend FAILED. Error: ", GetLastError(), " retcode=", res.retcode);
}

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
