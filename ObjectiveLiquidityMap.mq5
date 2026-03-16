#property strict
#property indicator_chart_window
#property indicator_plots 0
#property version   "1.10"
#property description "Objective Liquidity Map (price-inferred, no trading)"

// ==========================================================
// ObjectiveLiquidityMap.mq5
// Indicador custom para mapear liquidez objetiva inferida
// únicamente desde precio (sin SL/TP reales del mercado).
// ==========================================================

// ---------------------------
// Inputs principales
// ---------------------------
input int      InpBarsToAnalyze            = 2500;         // Barras históricas a analizar
input int      InpPivotLength              = 3;            // Longitud fractal/pivot
input int      InpEqualTolPoints           = 25;           // Tolerancia igualdad en puntos
input bool     InpUseATRTolerance          = true;         // Usar también tolerancia ATR
input int      InpATRPeriod                = 14;           // Periodo ATR para tolerancia
input double   InpATRToleranceFactor       = 0.10;         // Porción ATR usada como tolerancia
input int      InpMinTouches               = 2;            // Toques mínimos para validar EQH/EQL

input bool     InpShowEqualHighLow         = true;         // Mostrar EQH/EQL
input bool     InpShowSwingZones           = true;         // Mostrar Swing High/Low agrupados
input bool     InpShowDailyLevels          = true;         // Mostrar PDH/PDL
input bool     InpShowWeeklyLevels         = true;         // Mostrar PWH/PWL
input bool     InpShowSessionLevels        = true;         // Mostrar sesiones
input bool     InpShowSweeps               = true;         // Mostrar sweeps
input bool     InpShowLabels               = true;         // Mostrar etiquetas
input bool     InpShowScore                = true;         // Mostrar score en etiqueta

input int      InpMaxZonesPerType          = 8;            // Máximo de zonas por tipo
input ENUM_LINE_STYLE InpLineStyle         = STYLE_SOLID;  // Estilo de línea
input int      InpLineWidth                = 1;            // Grosor línea
input int      InpZoneTransparencyActive   = 35;           // Transparencia zonas intactas (0-255)
input int      InpZoneTransparencySwept    = 130;          // Transparencia zonas barridas

// ---------------------------
// Multi-timeframe
// ---------------------------
input bool             InpUseMTF            = true;         // Habilitar lectura MTF
input ENUM_TIMEFRAMES  InpMTF1              = PERIOD_H1;    // TF superior 1
input bool             InpUseMTF2           = true;         // Habilitar TF superior 2
input ENUM_TIMEFRAMES  InpMTF2              = PERIOD_H4;    // TF superior 2

// ---------------------------
// Sesiones (hora servidor)
// ---------------------------
input int      InpSessionDaysBack           = 3;            // Días atrás para sesiones

input int      InpAsiaStartHour             = 0;
input int      InpAsiaStartMinute           = 0;
input int      InpAsiaEndHour               = 8;
input int      InpAsiaEndMinute             = 0;

input int      InpLondonStartHour           = 8;
input int      InpLondonStartMinute         = 0;
input int      InpLondonEndHour             = 13;
input int      InpLondonEndMinute           = 0;

input int      InpNewYorkStartHour          = 13;
input int      InpNewYorkStartMinute        = 0;
input int      InpNewYorkEndHour            = 22;
input int      InpNewYorkEndMinute          = 0;

// ---------------------------
// Colores por tipo
// ---------------------------
input color    InpColorEQH                  = clrTomato;
input color    InpColorEQL                  = clrMediumSeaGreen;
input color    InpColorSwingHigh            = clrOrange;
input color    InpColorSwingLow             = clrDeepSkyBlue;
input color    InpColorPDH                  = clrGold;
input color    InpColorPDL                  = clrGold;
input color    InpColorPWH                  = clrDarkOrange;
input color    InpColorPWL                  = clrDarkOrange;
input color    InpColorAsia                 = clrSlateBlue;
input color    InpColorLondon               = clrCadetBlue;
input color    InpColorNewYork              = clrSandyBrown;
input color    InpColorSweepMarker          = clrWhite;

// ---------------------------
// Opcional DOM (separado)
// ---------------------------
input bool     InpEnableDOMModule           = false;        // Opcional, no requerido

string   g_prefix = "OLM_";
datetime g_lastCalcBarTime = 0;

// ---------- Tipos de zona ----------
enum ZoneType
{
   ZT_EQH = 0,
   ZT_EQL,
   ZT_SWING_HIGH,
   ZT_SWING_LOW,
   ZT_PDH,
   ZT_PDL,
   ZT_PWH,
   ZT_PWL,
   ZT_ASIA_HIGH,
   ZT_ASIA_LOW,
   ZT_LONDON_HIGH,
   ZT_LONDON_LOW,
   ZT_NEWYORK_HIGH,
   ZT_NEWYORK_LOW
};

struct LiquidityZone
{
   double          priceMid;
   double          priceUpper;
   double          priceLower;
   int             touches;
   ZoneType        type;
   ENUM_TIMEFRAMES sourceTF;
   bool            swept;
   int             score;
   datetime        createdTime;
   datetime        lastTouchTime;
   datetime        lastSweepTime;
};

struct SweepMark
{
   datetime  t;
   double    price;
   ZoneType  zoneType;
   bool      isHighSweep;
};

LiquidityZone g_zones[];
SweepMark     g_sweeps[];

// ==========================================================
// Utilidades generales
// ==========================================================
string ZoneTypeCode(const ZoneType t)
{
   switch(t)
   {
      case ZT_EQH:          return "EQH";
      case ZT_EQL:          return "EQL";
      case ZT_SWING_HIGH:   return "SH";
      case ZT_SWING_LOW:    return "SL";
      case ZT_PDH:          return "PDH";
      case ZT_PDL:          return "PDL";
      case ZT_PWH:          return "PWH";
      case ZT_PWL:          return "PWL";
      case ZT_ASIA_HIGH:    return "ASIA HIGH";
      case ZT_ASIA_LOW:     return "ASIA LOW";
      case ZT_LONDON_HIGH:  return "LON HIGH";
      case ZT_LONDON_LOW:   return "LON LOW";
      case ZT_NEWYORK_HIGH: return "NY HIGH";
      case ZT_NEWYORK_LOW:  return "NY LOW";
   }
   return "UNK";
}

string TFCode(const ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      default:         return IntegerToString((int)tf);
   }
}

bool IsHighSideType(const ZoneType t)
{
   return (t == ZT_EQH || t == ZT_SWING_HIGH || t == ZT_PDH || t == ZT_PWH ||
           t == ZT_ASIA_HIGH || t == ZT_LONDON_HIGH || t == ZT_NEWYORK_HIGH);
}

bool IsEquivalentPair(const ZoneType a, const ZoneType b)
{
   if((a == ZT_EQH && b == ZT_SWING_HIGH) || (a == ZT_SWING_HIGH && b == ZT_EQH))
      return true;
   if((a == ZT_EQL && b == ZT_SWING_LOW) || (a == ZT_SWING_LOW && b == ZT_EQL))
      return true;
   return false;
}

color ZoneColor(const ZoneType t)
{
   switch(t)
   {
      case ZT_EQH:          return InpColorEQH;
      case ZT_EQL:          return InpColorEQL;
      case ZT_SWING_HIGH:   return InpColorSwingHigh;
      case ZT_SWING_LOW:    return InpColorSwingLow;
      case ZT_PDH:          return InpColorPDH;
      case ZT_PDL:          return InpColorPDL;
      case ZT_PWH:          return InpColorPWH;
      case ZT_PWL:          return InpColorPWL;
      case ZT_ASIA_HIGH:
      case ZT_ASIA_LOW:     return InpColorAsia;
      case ZT_LONDON_HIGH:
      case ZT_LONDON_LOW:   return InpColorLondon;
      case ZT_NEWYORK_HIGH:
      case ZT_NEWYORK_LOW:  return InpColorNewYork;
   }
   return clrSilver;
}

void ClearObjectsByPrefix(const string prefix)
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; --i)
   {
      string name = ObjectName(0, i, -1, -1);
      if(StringFind(name, prefix) == 0)
         ObjectDelete(0, name);
   }
}

bool LoadRates(const string symbol, const ENUM_TIMEFRAMES tf, const int bars, MqlRates &rates[])
{
   ArraySetAsSeries(rates, true);
   int got = CopyRates(symbol, tf, 0, bars, rates);
   return (got > 10);
}

bool LoadATRSeries(const string symbol, const ENUM_TIMEFRAMES tf, const int period, const int bars, double &atr[])
{
   ArraySetAsSeries(atr, true);
   int handle = iATR(symbol, tf, period);
   if(handle == INVALID_HANDLE)
      return false;

   int got = CopyBuffer(handle, 0, 0, bars, atr);
   IndicatorRelease(handle);
   return (got > 10);
}


double GetATRValue(const string symbol, const ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int handle = iATR(symbol, tf, period);
   if(handle == INVALID_HANDLE)
      return 0.0;

   double buf[];
   ArraySetAsSeries(buf, true);
   double v = 0.0;
   if(CopyBuffer(handle, 0, shift, 1, buf) > 0)
      v = buf[0];

   IndicatorRelease(handle);
   return v;
}

double ToleranceFromATR(const double atrValue)
{
   double tolPts = (double)InpEqualTolPoints;
   if(InpUseATRTolerance && atrValue > 0.0)
      tolPts = MathMax(tolPts, (atrValue / _Point) * InpATRToleranceFactor);
   return tolPts * _Point;
}

double DynamicTolerance(const double &atrSeries[], const int shift)
{
   if(shift < 0 || shift >= ArraySize(atrSeries))
      return (double)InpEqualTolPoints * _Point;

   return ToleranceFromATR(atrSeries[shift]);
}

// ==========================================================
// Gestión/agrupación de zonas
// ==========================================================
int FindMergeCandidate(const ZoneType t, const ENUM_TIMEFRAMES sourceTf, const double price, const double tol)
{
   int n = ArraySize(g_zones);
   for(int i = 0; i < n; ++i)
   {
      if(g_zones[i].type != t)
         continue;
      if(g_zones[i].sourceTF != sourceTf)
         continue;
      if(MathAbs(g_zones[i].priceMid - price) <= tol)
         return i;
   }
   return -1;
}

void AddOrMergeZone(const ZoneType t,
                    const ENUM_TIMEFRAMES sourceTf,
                    const double price,
                    const double tol,
                    const datetime barTime,
                    const int touchesToAdd)
{
   int idx = FindMergeCandidate(t, sourceTf, price, tol);

   if(idx < 0)
   {
      LiquidityZone z;
      z.priceMid      = price;
      z.priceUpper    = price + tol;
      z.priceLower    = price - tol;
      z.touches       = touchesToAdd;
      z.type          = t;
      z.sourceTF      = sourceTf;
      z.swept         = false;
      z.score         = 0;
      z.createdTime   = barTime;
      z.lastTouchTime = barTime;
      z.lastSweepTime = 0;

      int n = ArraySize(g_zones);
      ArrayResize(g_zones, n + 1);
      g_zones[n] = z;
      return;
   }

   double weighted = (g_zones[idx].priceMid * g_zones[idx].touches + price * touchesToAdd) /
                     (double)(g_zones[idx].touches + touchesToAdd);
   g_zones[idx].priceMid = weighted;
   g_zones[idx].touches += touchesToAdd;

   if(barTime > g_zones[idx].lastTouchTime)
      g_zones[idx].lastTouchTime = barTime;

   if(price + tol > g_zones[idx].priceUpper)
      g_zones[idx].priceUpper = price + tol;
   if(price - tol < g_zones[idx].priceLower)
      g_zones[idx].priceLower = price - tol;
}

// ==========================================================
// Detección de pivots
// ==========================================================
bool IsPivotHigh(const MqlRates &rates[], const int i, const int len)
{
   if(i < len || i + len >= ArraySize(rates))
      return false;

   double p = rates[i].high;
   for(int k = 1; k <= len; ++k)
   {
      if(rates[i - k].high >= p) return false;
      if(rates[i + k].high > p)  return false;
   }
   return true;
}

bool IsPivotLow(const MqlRates &rates[], const int i, const int len)
{
   if(i < len || i + len >= ArraySize(rates))
      return false;

   double p = rates[i].low;
   for(int k = 1; k <= len; ++k)
   {
      if(rates[i - k].low <= p) return false;
      if(rates[i + k].low < p)  return false;
   }
   return true;
}

void DetectPivotsAndEqual(const MqlRates &rates[], const double &atrSeries[], const ENUM_TIMEFRAMES sourceTf)
{
   int n = ArraySize(rates);
   int maxBars = MathMin(n - InpPivotLength - 1, InpBarsToAnalyze);
   if(maxBars <= InpPivotLength * 2)
      return;

   for(int i = InpPivotLength + 1; i < maxBars; ++i)
   {
      double tol = DynamicTolerance(atrSeries, i);

      if(IsPivotHigh(rates, i, InpPivotLength))
      {
         if(InpShowSwingZones)
            AddOrMergeZone(ZT_SWING_HIGH, sourceTf, rates[i].high, tol, rates[i].time, 1);
         if(InpShowEqualHighLow)
            AddOrMergeZone(ZT_EQH, sourceTf, rates[i].high, tol, rates[i].time, 1);
      }

      if(IsPivotLow(rates, i, InpPivotLength))
      {
         if(InpShowSwingZones)
            AddOrMergeZone(ZT_SWING_LOW, sourceTf, rates[i].low, tol, rates[i].time, 1);
         if(InpShowEqualHighLow)
            AddOrMergeZone(ZT_EQL, sourceTf, rates[i].low, tol, rates[i].time, 1);
      }
   }
}

// ==========================================================
// Niveles diarios/semanales
// ==========================================================
void DetectPrevDayWeekLevels()
{
   if(InpShowDailyLevels)
   {
      double pdh = iHigh(_Symbol, PERIOD_D1, 1);
      double pdl = iLow(_Symbol, PERIOD_D1, 1);
      datetime d1 = iTime(_Symbol, PERIOD_D1, 1);
      if(pdh > 0.0 && pdl > 0.0)
      {
         double tol = ToleranceFromATR(GetATRValue(_Symbol, PERIOD_D1, InpATRPeriod, 1));
         AddOrMergeZone(ZT_PDH, PERIOD_D1, pdh, tol, d1, 2);
         AddOrMergeZone(ZT_PDL, PERIOD_D1, pdl, tol, d1, 2);
      }
   }

   if(InpShowWeeklyLevels)
   {
      double pwh = iHigh(_Symbol, PERIOD_W1, 1);
      double pwl = iLow(_Symbol, PERIOD_W1, 1);
      datetime w1 = iTime(_Symbol, PERIOD_W1, 1);
      if(pwh > 0.0 && pwl > 0.0)
      {
         double tol = ToleranceFromATR(GetATRValue(_Symbol, PERIOD_W1, InpATRPeriod, 1));
         AddOrMergeZone(ZT_PWH, PERIOD_W1, pwh, tol, w1, 3);
         AddOrMergeZone(ZT_PWL, PERIOD_W1, pwl, tol, w1, 3);
      }
   }
}

// ==========================================================
// Sesiones
// ==========================================================
void BuildSessionTimes(const datetime dayStart,
                       const int sh, const int sm,
                       const int eh, const int em,
                       datetime &sStart, datetime &sEnd)
{
   sStart = dayStart + sh * 3600 + sm * 60;
   sEnd   = dayStart + eh * 3600 + em * 60;
   if(sEnd <= sStart)
      sEnd += 24 * 3600;
}

bool SessionHighLow(const datetime sStart, const datetime sEnd, double &hi, double &lo)
{
   hi = -DBL_MAX;
   lo = DBL_MAX;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int got = CopyRates(_Symbol, PERIOD_M5, sStart, sEnd, r);
   if(got <= 0)
      return false;

   for(int i = 0; i < got; ++i)
   {
      if(r[i].time < sStart || r[i].time > sEnd)
         continue;
      if(r[i].high > hi) hi = r[i].high;
      if(r[i].low < lo)  lo = r[i].low;
   }

   return (hi > -DBL_MAX && lo < DBL_MAX && hi >= lo);
}

void DetectSessions()
{
   if(!InpShowSessionLevels)
      return;

   double tol = ToleranceFromATR(GetATRValue(_Symbol, PERIOD_M5, InpATRPeriod, 1));

   for(int d = 0; d < InpSessionDaysBack; ++d)
   {
      datetime dayStart = iTime(_Symbol, PERIOD_D1, d);
      if(dayStart <= 0)
         continue;

      datetime ss, se;
      double hi, lo;

      BuildSessionTimes(dayStart, InpAsiaStartHour, InpAsiaStartMinute, InpAsiaEndHour, InpAsiaEndMinute, ss, se);
      if(SessionHighLow(ss, se, hi, lo))
      {
         AddOrMergeZone(ZT_ASIA_HIGH, PERIOD_M5, hi, tol, dayStart, 2);
         AddOrMergeZone(ZT_ASIA_LOW, PERIOD_M5, lo, tol, dayStart, 2);
      }

      BuildSessionTimes(dayStart, InpLondonStartHour, InpLondonStartMinute, InpLondonEndHour, InpLondonEndMinute, ss, se);
      if(SessionHighLow(ss, se, hi, lo))
      {
         AddOrMergeZone(ZT_LONDON_HIGH, PERIOD_M5, hi, tol, dayStart, 1);
         AddOrMergeZone(ZT_LONDON_LOW, PERIOD_M5, lo, tol, dayStart, 1);
      }

      BuildSessionTimes(dayStart, InpNewYorkStartHour, InpNewYorkStartMinute, InpNewYorkEndHour, InpNewYorkEndMinute, ss, se);
      if(SessionHighLow(ss, se, hi, lo))
      {
         AddOrMergeZone(ZT_NEWYORK_HIGH, PERIOD_M5, hi, tol, dayStart, 1);
         AddOrMergeZone(ZT_NEWYORK_LOW, PERIOD_M5, lo, tol, dayStart, 1);
      }
   }
}

// ==========================================================
// Estado touched/swept + detección de sweep
// ==========================================================
void AddSweepMark(const datetime t, const double price, const ZoneType type, const bool isHighSweep)
{
   int n = ArraySize(g_sweeps);
   ArrayResize(g_sweeps, n + 1);
   g_sweeps[n].t = t;
   g_sweeps[n].price = price;
   g_sweeps[n].zoneType = type;
   g_sweeps[n].isHighSweep = isHighSweep;
}

void DetectSweepsAndState(const MqlRates &rates[])
{
   int nz = ArraySize(g_zones);
   int nr = ArraySize(rates);

   for(int z = 0; z < nz; ++z)
   {
      g_zones[z].swept = false;
      g_zones[z].lastSweepTime = 0;

      bool highSide = IsHighSideType(g_zones[z].type);
      bool sawBreakout = false;

      for(int i = nr - 2; i >= 1; --i)
      {
         if(highSide)
         {
            if(rates[i].high > g_zones[z].priceUpper)
            {
               sawBreakout = true;
               if(rates[i].close < g_zones[z].priceMid)
               {
                  g_zones[z].swept = true;
                  g_zones[z].lastSweepTime = rates[i].time;
                  if(InpShowSweeps)
                     AddSweepMark(rates[i].time, rates[i].high, g_zones[z].type, true);
               }
               else
               {
                  g_zones[z].swept = true;
                  g_zones[z].lastSweepTime = rates[i].time;
               }
               break;
            }
         }
         else
         {
            if(rates[i].low < g_zones[z].priceLower)
            {
               sawBreakout = true;
               if(rates[i].close > g_zones[z].priceMid)
               {
                  g_zones[z].swept = true;
                  g_zones[z].lastSweepTime = rates[i].time;
                  if(InpShowSweeps)
                     AddSweepMark(rates[i].time, rates[i].low, g_zones[z].type, false);
               }
               else
               {
                  g_zones[z].swept = true;
                  g_zones[z].lastSweepTime = rates[i].time;
               }
               break;
            }
         }
      }

      if(!sawBreakout)
      {
         g_zones[z].swept = false;
         g_zones[z].lastSweepTime = 0;
      }
   }
}

// ==========================================================
// Scoring
// ==========================================================
int TypeBaseScore(const ZoneType t)
{
   switch(t)
   {
      case ZT_PWH:
      case ZT_PWL: return 28;
      case ZT_PDH:
      case ZT_PDL: return 22;
      case ZT_ASIA_HIGH:
      case ZT_ASIA_LOW:
      case ZT_LONDON_HIGH:
      case ZT_LONDON_LOW:
      case ZT_NEWYORK_HIGH:
      case ZT_NEWYORK_LOW: return 18;
      case ZT_SWING_HIGH:
      case ZT_SWING_LOW: return 14;
      case ZT_EQH:
      case ZT_EQL: return 12;
   }
   return 10;
}

void ScoreZones()
{
   int n = ArraySize(g_zones);

   for(int i = 0; i < n; ++i)
   {
      int score = TypeBaseScore(g_zones[i].type);
      score += MathMin(35, g_zones[i].touches * 7);

      // Confluencia sin inflar por duplicidad EQH<->SH o EQL<->SL del mismo TF
      int conf = 0;
      double tol = (double)InpEqualTolPoints * _Point * 1.5;
      for(int j = 0; j < n; ++j)
      {
         if(i == j)
            continue;

         if(g_zones[i].sourceTF == g_zones[j].sourceTF && IsEquivalentPair(g_zones[i].type, g_zones[j].type))
            continue;

         if(MathAbs(g_zones[j].priceMid - g_zones[i].priceMid) <= tol)
            conf++;
      }
      score += MathMin(20, conf * 4);

      // Recencia medida por último toque (más robusta que createdTime)
      int ageBars = iBarShift(_Symbol, PERIOD_CURRENT, g_zones[i].lastTouchTime, false);
      if(ageBars < 0)
         ageBars = 1000;
      score += MathMax(0, 12 - ageBars / 120);

      // Zonas intactas tienen más relevancia
      if(!g_zones[i].swept)
         score += 12;
      else
         score -= 8;

      if(score < 0) score = 0;
      if(score > 100) score = 100;
      g_zones[i].score = score;
   }
}

// ==========================================================
// Dibujo
// ==========================================================
void SortIndicesByScore(int &idx[])
{
   int n = ArraySize(idx);
   for(int i = 0; i < n - 1; ++i)
   {
      int best = i;
      for(int j = i + 1; j < n; ++j)
      {
         if(g_zones[idx[j]].score > g_zones[idx[best]].score)
            best = j;
      }
      if(best != i)
      {
         int tmp = idx[i];
         idx[i] = idx[best];
         idx[best] = tmp;
      }
   }
}

void DrawZone(const LiquidityZone &z, const int id)
{
   string tfCode = TFCode(z.sourceTF);
   string base = g_prefix + ZoneTypeCode(z.type) + "_" + tfCode + "_" + IntegerToString(id);
   string rect = base + "_R";
   string line = base + "_L";
   string txt  = base + "_T";

   color c = ZoneColor(z.type);
   color cFill = ColorToARGB(c, z.swept ? InpZoneTransparencySwept : InpZoneTransparencyActive);

   datetime t1 = z.createdTime;
   if(t1 <= 0)
      t1 = iTime(_Symbol, PERIOD_CURRENT, 200);
   datetime t2 = TimeCurrent() + (datetime)(PeriodSeconds(PERIOD_CURRENT) * 25);

   ObjectCreate(0, rect, OBJ_RECTANGLE, 0, t1, z.priceUpper, t2, z.priceLower);
   ObjectSetInteger(0, rect, OBJPROP_COLOR, cFill);
   ObjectSetInteger(0, rect, OBJPROP_FILL, true);
   ObjectSetInteger(0, rect, OBJPROP_BACK, true);
   ObjectSetInteger(0, rect, OBJPROP_STYLE, InpLineStyle);
   ObjectSetInteger(0, rect, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, rect, OBJPROP_SELECTABLE, false);

   ObjectCreate(0, line, OBJ_HLINE, 0, 0, z.priceMid);
   ObjectSetInteger(0, line, OBJPROP_COLOR, c);
   ObjectSetInteger(0, line, OBJPROP_STYLE, InpLineStyle);
   ObjectSetInteger(0, line, OBJPROP_WIDTH, InpLineWidth);
   ObjectSetInteger(0, line, OBJPROP_SELECTABLE, false);

   if(InpShowLabels)
   {
      string status = z.swept ? "SWEPT" : "UNTOUCHED";
      string text = ZoneTypeCode(z.type) + " " + tfCode + " " + status;
      if(InpShowScore)
         text += " " + IntegerToString(z.score);

      ObjectCreate(0, txt, OBJ_TEXT, 0, t2, z.priceMid);
      ObjectSetString(0, txt, OBJPROP_TEXT, text);
      ObjectSetInteger(0, txt, OBJPROP_COLOR, c);
      ObjectSetInteger(0, txt, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, txt, OBJPROP_ANCHOR, ANCHOR_LEFT);
      ObjectSetInteger(0, txt, OBJPROP_SELECTABLE, false);
   }
}

void DrawSweeps()
{
   if(!InpShowSweeps)
      return;

   int n = ArraySize(g_sweeps);
   for(int i = 0; i < n; ++i)
   {
      string name = g_prefix + "SWEEP_" + IntegerToString((int)g_sweeps[i].t) + "_" + IntegerToString(i);
      ObjectCreate(0, name, OBJ_ARROW, 0, g_sweeps[i].t, g_sweeps[i].price);
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, g_sweeps[i].isHighSweep ? 234 : 233);
      ObjectSetInteger(0, name, OBJPROP_COLOR, InpColorSweepMarker);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   }
}

void DrawAllZones()
{
   int n = ArraySize(g_zones);
   if(n <= 0)
      return;

   int idx[];
   ArrayResize(idx, n);
   for(int i = 0; i < n; ++i)
      idx[i] = i;

   SortIndicesByScore(idx);

   int countByType[14];
   ArrayInitialize(countByType, 0);

   int drawn = 0;
   for(int k = 0; k < n; ++k)
   {
      LiquidityZone z = g_zones[idx[k]];
      int t = (int)z.type;

      if(countByType[t] >= InpMaxZonesPerType)
         continue;

      if((z.type == ZT_EQH || z.type == ZT_EQL) && !InpShowEqualHighLow) continue;
      if((z.type == ZT_SWING_HIGH || z.type == ZT_SWING_LOW) && !InpShowSwingZones) continue;
      if((z.type == ZT_PDH || z.type == ZT_PDL) && !InpShowDailyLevels) continue;
      if((z.type == ZT_PWH || z.type == ZT_PWL) && !InpShowWeeklyLevels) continue;
      if((z.type == ZT_ASIA_HIGH || z.type == ZT_ASIA_LOW ||
          z.type == ZT_LONDON_HIGH || z.type == ZT_LONDON_LOW ||
          z.type == ZT_NEWYORK_HIGH || z.type == ZT_NEWYORK_LOW) && !InpShowSessionLevels) continue;

      if((z.type == ZT_EQH || z.type == ZT_EQL) && z.touches < InpMinTouches)
         continue;

      DrawZone(z, drawn);
      countByType[t]++;
      drawn++;
   }

   DrawSweeps();
}

// ==========================================================
// Módulo opcional DOM (separado y no obligatorio)
// ==========================================================
void InitOptionalDOMModule()
{
   if(!InpEnableDOMModule)
      return;
   MarketBookAdd(_Symbol);
}

void ReleaseOptionalDOMModule()
{
   if(!InpEnableDOMModule)
      return;
   MarketBookRelease(_Symbol);
}

void OnBookEvent(const string &symbol)
{
   if(!InpEnableDOMModule || symbol != _Symbol)
      return;

   MqlBookInfo book[];
   if(MarketBookGet(_Symbol, book))
   {
      // Placeholder opcional: sin impacto en la detección principal.
   }
}

// ==========================================================
// Orquestación principal
// ==========================================================
void RebuildLiquidityMap()
{
   ArrayResize(g_zones, 0);
   ArrayResize(g_sweeps, 0);

   // 1) Datos TF actual
   MqlRates ratesCur[];
   if(!LoadRates(_Symbol, PERIOD_CURRENT, InpBarsToAnalyze, ratesCur))
      return;

   double atrCur[];
   if(!LoadATRSeries(_Symbol, PERIOD_CURRENT, InpATRPeriod, ArraySize(ratesCur), atrCur))
      return;

   // 2) Pivots y equal highs/lows TF actual
   DetectPivotsAndEqual(ratesCur, atrCur, PERIOD_CURRENT);

   // 3) MTF opcional (cada TF con su ATR propio)
   if(InpUseMTF)
   {
      MqlRates r1[];
      if(LoadRates(_Symbol, InpMTF1, MathMax(600, InpBarsToAnalyze / 3), r1))
      {
         double atr1[];
         if(LoadATRSeries(_Symbol, InpMTF1, InpATRPeriod, ArraySize(r1), atr1))
            DetectPivotsAndEqual(r1, atr1, InpMTF1);
      }

      if(InpUseMTF2)
      {
         MqlRates r2[];
         if(LoadRates(_Symbol, InpMTF2, MathMax(400, InpBarsToAnalyze / 6), r2))
         {
            double atr2[];
            if(LoadATRSeries(_Symbol, InpMTF2, InpATRPeriod, ArraySize(r2), atr2))
               DetectPivotsAndEqual(r2, atr2, InpMTF2);
         }
      }
   }

   // 4) Niveles diarios/semanales
   DetectPrevDayWeekLevels();

   // 5) Niveles de sesión
   DetectSessions();

   // 6) Estado untouched/swept + sweep markers
   DetectSweepsAndState(ratesCur);

   // 7) Scoring
   ScoreZones();

   // 8) Dibujo
   ClearObjectsByPrefix(g_prefix);
   DrawAllZones();
}

// ==========================================================
// Eventos estándar del indicador
// ==========================================================
int OnInit()
{
   IndicatorSetString(INDICATOR_SHORTNAME, "ObjectiveLiquidityMap");
   InitOptionalDOMModule();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ClearObjectsByPrefix(g_prefix);
   ReleaseOptionalDOMModule();
}

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   if(rates_total < 200)
      return prev_calculated;

   // No recalcular en cada tick: solo al abrir una barra nueva
   if(prev_calculated > 0 && time[0] == g_lastCalcBarTime)
      return rates_total;

   g_lastCalcBarTime = time[0];
   RebuildLiquidityMap();

   return rates_total;
}
