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
//|                                            ImmediateTrade.mq5    |
//|                                    Opens ONE trade immediately   |
//+------------------------------------------------------------------+
#property copyright "Test"
#property version "1.00"

input double LotSize = 0.01;
int magic = 999;
bool tradeSent = false;

void OnTick()
{
   if(tradeSent) return;
   
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double sl = ask - 5 * point * 10;
   double tp = ask + 6 * point * 10;
   
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = Symbol();
   req.volume = LotSize;
   req.type = ORDER_TYPE_BUY;
   req.price = ask;
   req.sl = sl;
   req.tp = tp;
   req.deviation = 10;
   req.type_filling = ORDER_FILLING_FOK;
   req.magic = magic;
   req.comment = "Immediate";
   
   if(OrderSend(req, res))
   {
      Print("Trade OPENED successfully. Volume: ", LotSize, " Ask: ", ask);
      tradeSent = true;
   }
   else
   {
      Print("OrderSend FAILED. Error: ", GetLastError(), " retcode: ", res.retcode);
      // Print more details
      Print("Balance: ", AccountInfoDouble(ACCOUNT_BALANCE));
      Print("Min lot: ", SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN));
      Print("Max lot: ", SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX));
      Print("Step: ", SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP));
      Print("Free margin: ", AccountInfoDouble(ACCOUNT_MARGIN_FREE));
      Print("Symbol: ", Symbol());
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
