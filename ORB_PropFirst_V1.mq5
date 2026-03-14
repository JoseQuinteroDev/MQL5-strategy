#property strict
#property version   "1.00"
#property description "Prop-first Opening Range Breakout (V1)"

#include <Trade/Trade.mqh>

// ============================================================
// INPUTS
// ============================================================
input string   InpTradeSymbol             = "EURUSD"; // Símbolo a operar
input int      InpSessionStartHour        = 8;        // Inicio de sesión (hora servidor)
input int      InpSessionStartMinute      = 0;        // Inicio de sesión (minuto)
input int      InpORMinutes               = 15;       // Minutos de Opening Range
input int      InpTradeCutoffMin          = 90;       // Minutos máximo para ruptura tras inicio de sesión
input int      InpFlatHour                = 20;       // Hora forzar flat (sin overnight)
input int      InpFlatMinute              = 45;       // Minuto forzar flat

input int      InpMaxSpreadPoints         = 20;       // Spread máximo permitido (puntos)
input int      InpEntryBufferPoints       = 5;        // Buffer de entrada (puntos)
input int      InpSLBufferPoints          = 5;        // Buffer para SL fuera del OR (puntos)

input int      InpATRPeriod               = 14;       // ATR periodo (M15)
input int      InpATRMedianDays           = 20;       // Días para mediana ATR (M15)
input double   InpVolFactor               = 0.80;     // ATR actual >= mediana * factor

input bool     InpUseTrendFilter          = false;    // Tendencia opcional (M15)
input int      InpTrendMAPeriod           = 50;       // MA para tendencia opcional

input bool     InpUseNewsFilter           = true;     // Filtro noticias alto impacto
input int      InpNewsBlockBeforeMin      = 30;       // Minutos bloqueo antes noticia
input int      InpNewsBlockAfterMin       = 30;       // Minutos bloqueo después noticia

input double   InpRiskPerTradePct         = 0.25;     // Riesgo % por trade (equity)
input double   InpSoftDailyLossPct        = 1.50;     // Soft daily loss %
input double   InpHardDailyLossPct        = 3.00;     // Hard daily loss %
input double   InpHardTotalLossPct        = 8.00;     // Hard total loss %

input bool     InpEnableTrailing          = false;    // Trailing opcional (V1 off)
input int      InpTrailingPoints          = 80;       // Distancia trailing

input long     InpMagic                   = 20260314; // Magic number
input bool     InpVerboseLog              = true;     // Log detallado

// ============================================================
// ESTADO GLOBAL
// ============================================================
CTrade   g_trade;
string   g_symbol = "";
int      g_digits = 0;
double   g_point  = 0.0;

int      g_handleATR = INVALID_HANDLE;
int      g_handleMA  = INVALID_HANDLE;

bool     g_orFinalized = false;
bool     g_ordersPlaced = false;
bool     g_tradeDoneThisSession = false;
bool     g_partialTaken = false;
bool     g_blockTradingToday = false;
bool     g_blockTradingTotal = false;

ulong    g_buyStopTicket = 0;
ulong    g_sellStopTicket = 0;

// datos OR
MqlDateTime g_nowStruct;
datetime g_sessionStart = 0;
datetime g_orEnd = 0;
datetime g_tradeCutoff = 0;
datetime g_flatTime = 0;

double   g_orHigh = -DBL_MAX;
double   g_orLow  = DBL_MAX;

// riesgo y métricas de trade actual
double   g_entryPrice = 0.0;
double   g_slPrice = 0.0;
double   g_tp2Price = 0.0;
double   g_initialRiskPoints = 0.0;
double   g_initialRiskMoney = 0.0;
string   g_entryReason = "";

// control de pérdidas
double   g_initialEquity = 0.0;
double   g_dayStartEquity = 0.0;
int      g_dayOfYear = -1;

// métricas
int      g_closedTrades = 0;
int      g_wins = 0;
int      g_losses = 0;
double   g_sumWin = 0.0;
double   g_sumLoss = 0.0;
double   g_grossProfit = 0.0;
double   g_grossLoss = 0.0;
double   g_peakBalance = 0.0;
double   g_maxDrawdownPct = 0.0;

// ============================================================
// HELPERS
// ============================================================
void Log(const string msg)
{
   if(InpVerboseLog)
      Print("[ORB_PROP_V1] ", msg);
}

bool IsOurPosition()
{
   if(!PositionSelect(g_symbol))
      return false;
   long mg = PositionGetInteger(POSITION_MAGIC);
   return (mg == InpMagic);
}

bool IsOurPendingOrder(const ulong ticket)
{
   if(ticket == 0)
      return false;
   if(!OrderSelect(ticket))
      return false;

   string sym = OrderGetString(ORDER_SYMBOL);
   long mg    = OrderGetInteger(ORDER_MAGIC);
   return (sym == g_symbol && mg == InpMagic);
}

void ResetSessionState()
{
   g_orFinalized = false;
   g_ordersPlaced = false;
   g_tradeDoneThisSession = false;
   g_partialTaken = false;

   g_buyStopTicket = 0;
   g_sellStopTicket = 0;

   g_orHigh = -DBL_MAX;
   g_orLow = DBL_MAX;

   g_entryPrice = 0.0;
   g_slPrice = 0.0;
   g_tp2Price = 0.0;
   g_initialRiskPoints = 0.0;
   g_initialRiskMoney = 0.0;
   g_entryReason = "";
}

void UpdateDayAnchors()
{
   datetime now = TimeCurrent();
   TimeToStruct(now, g_nowStruct);

   if(g_dayOfYear != g_nowStruct.day_of_year)
   {
      g_dayOfYear = g_nowStruct.day_of_year;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_blockTradingToday = false;
      ResetSessionState();
      Log("Nuevo día detectado: reinicio de estado diario.");
   }

   MqlDateTime t = g_nowStruct;
   t.hour = InpSessionStartHour;
   t.min  = InpSessionStartMinute;
   t.sec  = 0;
   g_sessionStart = StructToTime(t);

   g_orEnd = g_sessionStart + InpORMinutes * 60;
   g_tradeCutoff = g_sessionStart + InpTradeCutoffMin * 60;

   t.hour = InpFlatHour;
   t.min  = InpFlatMinute;
   t.sec  = 0;
   g_flatTime = StructToTime(t);
}

double Median(double &arr[])
{
   int n = ArraySize(arr);
   if(n <= 0)
      return 0.0;

   ArraySort(arr);
   if((n % 2) == 1)
      return arr[n / 2];

   return 0.5 * (arr[n / 2 - 1] + arr[n / 2]);
}

bool GetATRCurrentAndMedian(double &atrNow, double &atrMed)
{
   atrNow = 0.0;
   atrMed = 0.0;

   if(g_handleATR == INVALID_HANDLE)
      return false;

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);

   int needBars = InpATRMedianDays * 96 + 10; // 96 velas M15 por día
   int copied = CopyBuffer(g_handleATR, 0, 1, needBars, atrBuf);
   if(copied <= 0)
      return false;

   atrNow = atrBuf[0];

   int sample = MathMin(copied, InpATRMedianDays * 96);
   if(sample < 10)
      return false;

   double medArr[];
   ArrayResize(medArr, sample);
   for(int i = 0; i < sample; i++)
      medArr[i] = atrBuf[i];

   atrMed = Median(medArr);
   return (atrNow > 0.0 && atrMed > 0.0);
}

bool PassSpreadFilter(double &spreadPoints)
{
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);

   spreadPoints = (ask - bid) / g_point;
   return (spreadPoints <= InpMaxSpreadPoints);
}

bool PassVolatilityFilter(double &atrNow)
{
   double atrMed = 0.0;
   if(!GetATRCurrentAndMedian(atrNow, atrMed))
      return false;

   return (atrNow >= atrMed * InpVolFactor);
}

bool PassTrendFilter()
{
   if(!InpUseTrendFilter)
      return true;

   if(g_handleMA == INVALID_HANDLE)
      return false;

   double maBuf[];
   ArraySetAsSeries(maBuf, true);
   if(CopyBuffer(g_handleMA, 0, 1, 1, maBuf) <= 0)
      return false;

   MqlRates rates[];
   if(CopyRates(g_symbol, PERIOD_M15, 1, 1, rates) <= 0)
      return false;

   // Filtro muy simple: permitir solo si cierre no está extremadamente contra MA.
   // El sesgo final se decide en la ruptura del OR.
   double closeM15 = rates[0].close;
   double ma = maBuf[0];
   double dist = MathAbs(closeM15 - ma) / g_point;

   // evitar mercados ultra comprimidos alrededor de MA
   return (dist >= 2.0);
}

bool CurrencyIsRelevant(const string eventCurrency)
{
   string ccyBase = SymbolInfoString(g_symbol, SYMBOL_CURRENCY_BASE);
   string ccyProf = SymbolInfoString(g_symbol, SYMBOL_CURRENCY_PROFIT);

   if(eventCurrency == ccyBase || eventCurrency == ccyProf)
      return true;

   // fallback prudente para majors
   if((ccyBase == "USD" || ccyProf == "USD") && eventCurrency == "USD")
      return true;

   return false;
}

bool PassNewsFilter(string &reason)
{
   reason = "";
   if(!InpUseNewsFilter)
      return true;

   datetime now = TimeTradeServer();
   datetime from = now - InpNewsBlockBeforeMin * 60;
   datetime to   = now + InpNewsBlockAfterMin * 60;

   MqlCalendarValue values[];
   int n = CalendarValueHistory(values, from, to);
   if(n < 0)
   {
      reason = "CalendarValueHistory error";
      return false;
   }

   for(int i = 0; i < n; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;

      if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
         continue;

      if(!CurrencyIsRelevant(ev.currency))
         continue;

      reason = "Bloqueo noticia HIGH: " + ev.currency + " / " + ev.name;
      return false;
   }

   return true;
}

bool BuildOpeningRange()
{
   if(TimeCurrent() < g_orEnd)
      return false;

   MqlRates rates[];
   int bars = CopyRates(g_symbol, PERIOD_M1, g_sessionStart, g_orEnd - 1, rates);
   if(bars <= 0)
      return false;

   double hi = -DBL_MAX;
   double lo = DBL_MAX;

   for(int i = 0; i < bars; i++)
   {
      if(rates[i].time < g_sessionStart || rates[i].time >= g_orEnd)
         continue;

      if(rates[i].high > hi)
         hi = rates[i].high;
      if(rates[i].low < lo)
         lo = rates[i].low;
   }

   if(hi <= lo || hi == -DBL_MAX || lo == DBL_MAX)
      return false;

   g_orHigh = hi;
   g_orLow = lo;
   g_orFinalized = true;

   Log(StringFormat("OR construido: High=%.5f Low=%.5f", g_orHigh, g_orLow));
   return true;
}

double CalcVolumeByRisk(const double entryPrice, const double slPrice, double &riskMoneyOut)
{
   riskMoneyOut = 0.0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (InpRiskPerTradePct / 100.0);

   double tickSize  = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;

   double slDist = MathAbs(entryPrice - slPrice);
   if(slDist <= 0.0)
      return 0.0;

   double moneyPerLot = (slDist / tickSize) * tickValue;
   if(moneyPerLot <= 0.0)
      return 0.0;

   double rawVol = riskMoney / moneyPerLot;

   double volMin  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);

   if(volStep <= 0.0)
      volStep = volMin;

   double vol = MathFloor(rawVol / volStep) * volStep;
   vol = MathMax(vol, volMin);
   vol = MathMin(vol, volMax);

   riskMoneyOut = moneyPerLot * vol;
   return NormalizeDouble(vol, 2);
}

bool CheckStopsDistance(const ENUM_ORDER_TYPE type, const double price, const double sl)
{
   int stopsLevel = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * g_point;

   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);

   if(type == ORDER_TYPE_BUY_STOP)
   {
      if((price - ask) < minDist)
         return false;
   }
   else if(type == ORDER_TYPE_SELL_STOP)
   {
      if((bid - price) < minDist)
         return false;
   }

   if(MathAbs(price - sl) < minDist)
      return false;

   return true;
}

bool CheckMarginAndOrder(const MqlTradeRequest &req, string &reason)
{
   reason = "";

   MqlTradeCheckResult check;
   ZeroMemory(check);
   if(!OrderCheck(req, check))
   {
      reason = "OrderCheck call failed";
      return false;
   }
   if(check.retcode != TRADE_RETCODE_DONE)
   {
      reason = "OrderCheck retcode=" + IntegerToString((int)check.retcode);
      return false;
   }

   double margin = 0.0;
   if(!OrderCalcMargin(req.type, g_symbol, req.volume, req.price, margin))
   {
      reason = "OrderCalcMargin failed";
      return false;
   }

   double freeMargin = AccountInfoDouble(ACCOUNT_FREEMARGIN);
   if(margin > freeMargin)
   {
      reason = StringFormat("Margen insuficiente. Requerido=%.2f Libre=%.2f", margin, freeMargin);
      return false;
   }

   return true;
}

bool PlacePendingOrder(const ENUM_ORDER_TYPE type, const double volume, const double price, const double sl, const string comment, ulong &ticketOut)
{
   ticketOut = 0;

   if(!CheckStopsDistance(type, price, sl))
   {
      Log("StopsLevel inválido para la orden pendiente.");
      return false;
   }

   MqlTradeRequest req;
   MqlTradeResult res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_PENDING;
   req.symbol       = g_symbol;
   req.magic        = InpMagic;
   req.volume       = volume;
   req.type         = type;
   req.price        = NormalizeDouble(price, g_digits);
   req.sl           = NormalizeDouble(sl, g_digits);
   req.tp           = 0.0;
   req.type_time    = ORDER_TIME_DAY;
   req.type_filling = (ENUM_ORDER_TYPE_FILLING)SymbolInfoInteger(g_symbol, SYMBOL_FILLING_MODE);
   req.comment      = comment;

   string checkReason;
   if(!CheckMarginAndOrder(req, checkReason))
   {
      Log("Orden bloqueada por check/margen: " + checkReason);
      return false;
   }

   if(!OrderSend(req, res))
   {
      Log("OrderSend falló: " + IntegerToString(_LastError));
      return false;
   }

   if(res.retcode != TRADE_RETCODE_DONE)
   {
      Log("OrderSend retcode=" + IntegerToString((int)res.retcode));
      return false;
   }

   ticketOut = res.order;
   return true;
}

void CancelPending(ulong &ticket)
{
   if(ticket == 0)
      return;

   if(OrderSelect(ticket))
   {
      if(g_trade.OrderDelete(ticket))
         Log("Pendiente cancelada ticket=" + IntegerToString((int)ticket));
      else
         Log("Error cancelando pendiente ticket=" + IntegerToString((int)ticket));
   }
   ticket = 0;
}

void CancelAllOurPendings()
{
   CancelPending(g_buyStopTicket);
   CancelPending(g_sellStopTicket);
}

bool HasAnyPositionOrOrder()
{
   if(IsOurPosition())
      return true;

   if(IsOurPendingOrder(g_buyStopTicket) || IsOurPendingOrder(g_sellStopTicket))
      return true;

   return false;
}

void UpdateDrawdownMetrics()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal > g_peakBalance)
      g_peakBalance = bal;

   if(g_peakBalance > 0.0)
   {
      double ddPct = (g_peakBalance - bal) / g_peakBalance * 100.0;
      if(ddPct > g_maxDrawdownPct)
         g_maxDrawdownPct = ddPct;
   }
}

void ApplyDailyAndTotalLossGuards()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   double dailyLossPct = 0.0;
   if(g_dayStartEquity > 0.0)
      dailyLossPct = (g_dayStartEquity - eq) / g_dayStartEquity * 100.0;

   double totalLossPct = 0.0;
   if(g_initialEquity > 0.0)
      totalLossPct = (g_initialEquity - eq) / g_initialEquity * 100.0;

   if(dailyLossPct >= InpSoftDailyLossPct)
      g_blockTradingToday = true;

   if(dailyLossPct >= InpHardDailyLossPct)
   {
      g_blockTradingToday = true;
      if(IsOurPosition())
         g_trade.PositionClose(g_symbol);
      CancelAllOurPendings();
      Log("Hard daily loss alcanzado: bloqueo y cierre forzado.");
   }

   if(totalLossPct >= InpHardTotalLossPct)
   {
      g_blockTradingTotal = true;
      if(IsOurPosition())
         g_trade.PositionClose(g_symbol);
      CancelAllOurPendings();
      Log("Hard total loss alcanzado: bloqueo total.");
   }
}

bool ComplianceCanTrade(string &reason)
{
   reason = "";
   if(g_blockTradingTotal)
   {
      reason = "Bloqueado por hard total loss";
      return false;
   }

   if(g_blockTradingToday)
   {
      reason = "Bloqueado por daily loss";
      return false;
   }

   datetime now = TimeCurrent();

   if(now < g_sessionStart)
   {
      reason = "Antes de sesión";
      return false;
   }

   if(now >= g_flatTime)
   {
      reason = "Fuera de horario: flat time";
      return false;
   }

   if(now > g_tradeCutoff)
   {
      reason = "Cutoff alcanzado";
      return false;
   }

   if(g_tradeDoneThisSession)
   {
      reason = "Trade ya realizado en sesión";
      return false;
   }

   if(HasAnyPositionOrOrder())
   {
      reason = "Ya existe posición/orden activa";
      return false;
   }

   return true;
}

bool SignalEnginePrepareOrders(double &buyEntry, double &sellEntry, double &buySL, double &sellSL, double &atrNow, double &spreadPts, string &reason)
{
   reason = "";

   if(!g_orFinalized)
   {
      reason = "OR no finalizado";
      return false;
   }

   if(!PassSpreadFilter(spreadPts))
   {
      reason = "Spread fuera de rango";
      return false;
   }

   if(!PassVolatilityFilter(atrNow))
   {
      reason = "Filtro ATR no cumple";
      return false;
   }

   if(!PassTrendFilter())
   {
      reason = "Filtro tendencia no cumple";
      return false;
   }

   string newsReason;
   if(!PassNewsFilter(newsReason))
   {
      reason = newsReason;
      return false;
   }

   buyEntry = g_orHigh + InpEntryBufferPoints * g_point;
   sellEntry = g_orLow - InpEntryBufferPoints * g_point;

   buySL = g_orLow - InpSLBufferPoints * g_point;
   sellSL = g_orHigh + InpSLBufferPoints * g_point;

   if(buyEntry <= buySL || sellEntry >= sellSL)
   {
      reason = "Geometría OR inválida";
      return false;
   }

   return true;
}

void ManageOpenPosition()
{
   if(!IsOurPosition())
      return;

   long type = PositionGetInteger(POSITION_TYPE);
   double vol = PositionGetDouble(POSITION_VOLUME);
   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);

   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);

   double oneR = g_initialRiskPoints * g_point;
   if(oneR <= 0.0)
      return;

   double priceNow = (type == POSITION_TYPE_BUY ? bid : ask);

   bool reached1R = false;
   bool reached2R = false;

   if(type == POSITION_TYPE_BUY)
   {
      reached1R = (priceNow >= open + oneR);
      reached2R = (priceNow >= open + 2.0 * oneR);
   }
   else
   {
      reached1R = (priceNow <= open - oneR);
      reached2R = (priceNow <= open - 2.0 * oneR);
   }

   if(reached1R && !g_partialTaken)
   {
      double closeVol = MathMax(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN), vol * 0.5);
      closeVol = NormalizeDouble(closeVol, 2);

      if(g_trade.PositionClosePartial(g_symbol, closeVol))
      {
         g_partialTaken = true;
         // mover a break-even
         double be = open;
         g_trade.PositionModify(g_symbol, NormalizeDouble(be, g_digits), 0.0);
         Log("Parcial 50% en 1R y SL a break-even.");
      }
   }

   if(reached2R)
   {
      g_trade.PositionClose(g_symbol);
      Log("Cierre final en 2R.");
      return;
   }

   if(InpEnableTrailing && g_partialTaken)
   {
      double trail = InpTrailingPoints * g_point;
      if(type == POSITION_TYPE_BUY)
      {
         double newSL = priceNow - trail;
         if(newSL > sl && newSL < priceNow)
            g_trade.PositionModify(g_symbol, NormalizeDouble(newSL, g_digits), 0.0);
      }
      else
      {
         double newSL = priceNow + trail;
         if((sl == 0.0 || newSL < sl) && newSL > priceNow)
            g_trade.PositionModify(g_symbol, NormalizeDouble(newSL, g_digits), 0.0);
      }
   }
}

void EnforceFlatTime()
{
   datetime now = TimeCurrent();
   if(now < g_flatTime)
      return;

   if(IsOurPosition())
   {
      if(g_trade.PositionClose(g_symbol))
         Log("Posición cerrada por FlatTime.");
   }

   CancelAllOurPendings();
}

void LogTradeCSV(const string direction, const double entry, const double sl, const double tp,
                 const double spreadPts, const double atr, const string entryReason,
                 const string exitReason, const double rResult)
{
   int h = FileOpen("ORB_PropFirst_Trades.csv", FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
   if(h == INVALID_HANDLE)
      return;

   if(FileSize(h) == 0)
   {
      FileWrite(h, "date", "symbol", "direction", "or_high", "or_low", "entry", "sl", "tp", "spread_pts", "atr", "entry_reason", "exit_reason", "R");
   }

   FileSeek(h, 0, SEEK_END);
   FileWrite(h,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             g_symbol,
             direction,
             DoubleToString(g_orHigh, g_digits),
             DoubleToString(g_orLow, g_digits),
             DoubleToString(entry, g_digits),
             DoubleToString(sl, g_digits),
             DoubleToString(tp, g_digits),
             DoubleToString(spreadPts, 1),
             DoubleToString(atr, g_digits),
             entryReason,
             exitReason,
             DoubleToString(rResult, 2));

   FileClose(h);
}

void UpdatePerformanceFromClosedDeal(const double pnl)
{
   g_closedTrades++;

   if(pnl >= 0.0)
   {
      g_wins++;
      g_sumWin += pnl;
      g_grossProfit += pnl;
   }
   else
   {
      g_losses++;
      g_sumLoss += MathAbs(pnl);
      g_grossLoss += MathAbs(pnl);
   }

   UpdateDrawdownMetrics();
}

void PrintSummaryMetrics()
{
   double winRate = (g_closedTrades > 0 ? (double)g_wins / g_closedTrades * 100.0 : 0.0);
   double avgWin = (g_wins > 0 ? g_sumWin / g_wins : 0.0);
   double avgLoss = (g_losses > 0 ? g_sumLoss / g_losses : 0.0);
   double expectancy = (g_closedTrades > 0 ? (g_grossProfit - g_grossLoss) / g_closedTrades : 0.0);
   double pf = (g_grossLoss > 0.0 ? g_grossProfit / g_grossLoss : 0.0);

   Print("========== ORB PROP-FIRST V1 METRICS ==========");
   Print("Trades: ", g_closedTrades);
   Print("WinRate(%): ", DoubleToString(winRate, 2));
   Print("AvgWin: ", DoubleToString(avgWin, 2));
   Print("AvgLoss: ", DoubleToString(avgLoss, 2));
   Print("Expectancy: ", DoubleToString(expectancy, 2));
   Print("MaxDrawdown(%): ", DoubleToString(g_maxDrawdownPct, 2));
   Print("ProfitFactor: ", DoubleToString(pf, 2));
   Print("===============================================");
}

// ============================================================
// CICLO PRINCIPAL
// ============================================================
int OnInit()
{
   g_symbol = (InpTradeSymbol == "" ? _Symbol : InpTradeSymbol);
   g_digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   g_point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);

   if(g_point <= 0.0)
      return INIT_FAILED;

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetTypeFillingBySymbol(g_symbol);

   g_handleATR = iATR(g_symbol, PERIOD_M15, InpATRPeriod);
   if(g_handleATR == INVALID_HANDLE)
      return INIT_FAILED;

   if(InpUseTrendFilter)
   {
      g_handleMA = iMA(g_symbol, PERIOD_M15, InpTrendMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(g_handleMA == INVALID_HANDLE)
         return INIT_FAILED;
   }

   g_initialEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStartEquity = g_initialEquity;
   g_peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   UpdateDayAnchors();

   Log("EA inicializado correctamente.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   CancelAllOurPendings();
   if(g_handleATR != INVALID_HANDLE)
      IndicatorRelease(g_handleATR);
   if(g_handleMA != INVALID_HANDLE)
      IndicatorRelease(g_handleMA);

   PrintSummaryMetrics();
}

void OnTick()
{
   UpdateDayAnchors();
   ApplyDailyAndTotalLossGuards();
   EnforceFlatTime();
   ManageOpenPosition();

   // si ya tenemos posición, solo gestionar
   if(IsOurPosition())
      return;

   // si se activó una orden, cancelar la opuesta (OCO)
   if(g_ordersPlaced)
   {
      if(!IsOurPendingOrder(g_buyStopTicket) || !IsOurPendingOrder(g_sellStopTicket))
      {
         if(IsOurPendingOrder(g_buyStopTicket) && !IsOurPendingOrder(g_sellStopTicket))
            CancelPending(g_buyStopTicket);

         if(IsOurPendingOrder(g_sellStopTicket) && !IsOurPendingOrder(g_buyStopTicket))
            CancelPending(g_sellStopTicket);
      }
   }

   datetime now = TimeCurrent();
   if(now > g_tradeCutoff && g_ordersPlaced)
   {
      CancelAllOurPendings();
      g_ordersPlaced = false;
      Log("Cutoff alcanzado: oportunidad cancelada.");
      return;
   }

   if(!g_orFinalized)
      BuildOpeningRange();

   if(!g_orFinalized || g_ordersPlaced)
      return;

   string complianceReason;
   if(!ComplianceCanTrade(complianceReason))
      return;

   double buyEntry, sellEntry, buySL, sellSL, atrNow, spreadPts;
   string sigReason;
   if(!SignalEnginePrepareOrders(buyEntry, sellEntry, buySL, sellSL, atrNow, spreadPts, sigReason))
   {
      Log("Signal bloqueado: " + sigReason);
      return;
   }

   // volumen simétrico usando el peor riesgo monetario de ambos lados
   double riskBuy = 0.0;
   double volBuy = CalcVolumeByRisk(buyEntry, buySL, riskBuy);

   double riskSell = 0.0;
   double volSell = CalcVolumeByRisk(sellEntry, sellSL, riskSell);

   double vol = MathMin(volBuy, volSell);
   if(vol <= 0.0)
   {
      Log("Volumen calculado inválido.");
      return;
   }

   bool okBuy = PlacePendingOrder(ORDER_TYPE_BUY_STOP, vol, buyEntry, buySL, "ORB_BUY", g_buyStopTicket);
   bool okSell = PlacePendingOrder(ORDER_TYPE_SELL_STOP, vol, sellEntry, sellSL, "ORB_SELL", g_sellStopTicket);

   if(!okBuy || !okSell)
   {
      CancelAllOurPendings();
      Log("No se pudo montar OCO completo.");
      return;
   }

   g_ordersPlaced = true;
   g_entryReason = "ORB breakout + filtros spread/ATR/news";

   Log(StringFormat("OCO colocada. BuyStop=%.5f SellStop=%.5f Vol=%.2f ATR=%.5f SpreadPts=%.1f",
                    buyEntry, sellEntry, vol, atrNow, spreadPts));
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.symbol != g_symbol)
      return;

   // detectar activación de entrada
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong dealTicket = trans.deal;
      if(!HistoryDealSelect(dealTicket))
         return;

      long mg = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      if(mg != InpMagic)
         return;

      long entryType = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      double price   = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      double profit  = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
                       HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
                       HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

      if(entryType == DEAL_ENTRY_IN)
      {
         // activó una pata del OCO
         g_tradeDoneThisSession = true;
         g_ordersPlaced = false;

         if(IsOurPendingOrder(g_buyStopTicket))
            CancelPending(g_buyStopTicket);
         if(IsOurPendingOrder(g_sellStopTicket))
            CancelPending(g_sellStopTicket);

         if(PositionSelect(g_symbol))
         {
            long pType = PositionGetInteger(POSITION_TYPE);
            double pOpen = PositionGetDouble(POSITION_PRICE_OPEN);
            double pSL = PositionGetDouble(POSITION_SL);

            g_entryPrice = pOpen;
            g_slPrice = pSL;
            g_initialRiskPoints = MathAbs(pOpen - pSL) / g_point;
            g_initialRiskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * (InpRiskPerTradePct / 100.0);

            if(pType == POSITION_TYPE_BUY)
               g_tp2Price = pOpen + 2.0 * (g_initialRiskPoints * g_point);
            else
               g_tp2Price = pOpen - 2.0 * (g_initialRiskPoints * g_point);

            Log("Entrada ejecutada. RiskPoints=" + DoubleToString(g_initialRiskPoints, 1));
         }
      }
      else if(entryType == DEAL_ENTRY_OUT)
      {
         // cierre total o parcial
         if(!PositionSelect(g_symbol))
         {
            // posición completamente cerrada => registrar métricas por trade
            double rResult = 0.0;
            if(g_initialRiskMoney > 0.0)
               rResult = profit / g_initialRiskMoney;

            UpdatePerformanceFromClosedDeal(profit);

            double spreadPts = (SymbolInfoDouble(g_symbol, SYMBOL_ASK) - SymbolInfoDouble(g_symbol, SYMBOL_BID)) / g_point;
            double atrNow = 0.0, atrMed = 0.0;
            GetATRCurrentAndMedian(atrNow, atrMed);

            string dir = (g_entryPrice >= g_slPrice ? "BUY" : "SELL");
            LogTradeCSV(dir, g_entryPrice, g_slPrice, g_tp2Price, spreadPts, atrNow,
                        g_entryReason, "Exit deal", rResult);

            g_partialTaken = false;
         }
      }
   }
}
