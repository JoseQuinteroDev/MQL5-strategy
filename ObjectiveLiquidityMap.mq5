#property strict
#property indicator_chart_window
#property indicator_plots 0
#property version   "1.20"
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
input bool     InpShowSessionLevels        = false;         // Mostrar sesiones
input bool     InpShowSweeps               = true;         // Mostrar sweeps
input bool     InpShowLabels               = true;         // Mostrar etiquetas
input bool     InpShowScore                = true;         // Mostrar score en etiqueta

input int      InpMaxZonesPerType          = 8;            // Máximo de zonas por tipo
input ENUM_LINE_STYLE InpLineStyle         = STYLE_SOLID;  // Estilo de línea
input int      InpLineWidth                = 3;            // Grosor línea
input int      InpZoneTransparencyActive   = 95;           // Transparencia zonas intactas (0-255)
input int      InpZoneTransparencySwept    = 170;          // Transparencia zonas barridas
input bool     InpDrawZoneRectangles        = true;         // Dibujar rectángulo de zona
input int      InpLabelBarsRight            = 1;            // Barras a la derecha para etiqueta

// Filtro visual por cercanía
input bool     InpShowAllZones              = false;        // Mostrar todas las zonas (sin filtro de cercanía)
input int      InpNearestAboveCount         = 2;            // Zonas más cercanas por encima
input int      InpNearestBelowCount         = 2;            // Zonas más cercanas por debajo
input bool     InpEnableMaxDistanceFilter   = false;         // Limitar por distancia máxima
input int      InpMaxDistancePoints         = 350;          // Distancia máxima en puntos
input bool     InpUseATRDistance            = false;         // Usar distancia máxima por ATR
input double   InpMaxDistanceATR            = 1.50;         // Distancia máxima en ATR

// Panel debug visual
input bool     InpShowDebugPanel            = true;         // Mostrar panel de depuración
input ENUM_BASE_CORNER InpDebugCorner       = CORNER_RIGHT_UPPER;
input int      InpDebugX                    = 14;
input int      InpDebugY                    = 18;

// Modos de visualización
enum VisualMode
{
   VM_CLEAN = 0,
   VM_SESSION,
   VM_FULL
};
input VisualMode InpVisualMode              = VM_CLEAN;
input bool     InpSessionModeIncludeDaily   = true;         // En modo SESSION, incluir PDH/PDL

// Filtros por tipo (modo "solo")
input bool     InpOnlyPDH_PDL               = false;
input bool     InpOnlyPWH_PWL               = false;
input bool     InpOnlyEQH_EQL               = false;
input bool     InpOnlySessions              = false;
input bool     InpOnlyUntouched             = false;
input bool     InpHideTaken                 = true;
input bool     InpHideSimpleSwings          = true;

// ---------------------------
// Multi-timeframe
// ---------------------------
input bool             InpUseMTF            = false;         // Habilitar lectura MTF
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
input color    InpColorEQL                  = clrLimeGreen;
input color    InpColorSwingHigh            = clrOrange;
input color    InpColorSwingLow             = clrDeepSkyBlue;
input color    InpColorPDH                  = clrGold;
input color    InpColorPDL                  = clrKhaki;
input color    InpColorPWH                  = clrDarkOrange;
input color    InpColorPWL                  = clrSandyBrown;
input color    InpColorAsia                 = clrMediumPurple;
input color    InpColorLondon               = clrTurquoise;
input color    InpColorNewYork              = clrLightSkyBlue;
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

enum ZoneState
{
   ZS_UNTOUCHED = 0,
   ZS_TAKEN,
   ZS_REJECTION_SWEEP
};

struct LiquidityZone
{
   double          priceMid;
   double          priceUpper;
   double          priceLower;
   int             touches;
   ZoneType        type;
   ENUM_TIMEFRAMES sourceTF;
   ZoneState       state;
   int             score;
   datetime        firstTouchTime;
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

int g_totalZonesDetected = 0;
int g_totalZonesDrawn = 0;

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

bool CreateObjectChecked(const string name, const ENUM_OBJECT type,
                         const datetime t1, const double p1,
                         const datetime t2 = 0, const double p2 = 0.0)
{
   ResetLastError();
   bool ok;
   if(type == OBJ_HLINE)
      ok = ObjectCreate(0, name, type, 0, 0, p1);
   else if(type == OBJ_LABEL)
      ok = ObjectCreate(0, name, type, 0, 0, 0);
   else if(type == OBJ_TEXT || type == OBJ_ARROW)
      ok = ObjectCreate(0, name, type, 0, t1, p1);
   else
      ok = ObjectCreate(0, name, type, 0, t1, p1, t2, p2);

   if(!ok)
      Print("[ObjectiveLiquidityMap] ObjectCreate falló: ", name, " err=", GetLastError());
   return ok;
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

bool IsMergeCompatibleType(const ZoneType a, const ZoneType b)
{
   if(a == b)
      return true;

   if((a == ZT_SWING_HIGH && b == ZT_EQH) || (a == ZT_EQH && b == ZT_SWING_HIGH))
      return true;

   if((a == ZT_SWING_LOW && b == ZT_EQL) || (a == ZT_EQL && b == ZT_SWING_LOW))
      return true;

   return false;
}

int FindMergeCandidate(const ZoneType t, const ENUM_TIMEFRAMES sourceTf, const double price, const double tol)
{
   int n = ArraySize(g_zones);
   for(int i = 0; i < n; ++i)
   {
      if(!IsMergeCompatibleType(g_zones[i].type, t))
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
      z.state         = ZS_UNTOUCHED;
      z.score         = 0;
      z.firstTouchTime= barTime;
      z.lastTouchTime = barTime;
      z.lastSweepTime = 0;

      int n = ArraySize(g_zones);
      ArrayResize(g_zones, n + 1);
      g_zones[n] = z;

      if(InpShowEqualHighLow)
      {
         if(t == ZT_SWING_HIGH && g_zones[n].touches >= InpMinTouches)
            g_zones[n].type = ZT_EQH;
         else if(t == ZT_SWING_LOW && g_zones[n].touches >= InpMinTouches)
            g_zones[n].type = ZT_EQL;
      }
      return;
   }

   double weighted = (g_zones[idx].priceMid * g_zones[idx].touches + price * touchesToAdd) /
                     (double)(g_zones[idx].touches + touchesToAdd);
   g_zones[idx].priceMid = weighted;
   g_zones[idx].touches += touchesToAdd;

   if(barTime < g_zones[idx].firstTouchTime)
      g_zones[idx].firstTouchTime = barTime;

   if(barTime > g_zones[idx].lastTouchTime)
      g_zones[idx].lastTouchTime = barTime;

   if(price + tol > g_zones[idx].priceUpper)
      g_zones[idx].priceUpper = price + tol;
   if(price - tol < g_zones[idx].priceLower)
      g_zones[idx].priceLower = price - tol;

   if(InpShowEqualHighLow)
   {
      if(g_zones[idx].type == ZT_SWING_HIGH && g_zones[idx].touches >= InpMinTouches)
         g_zones[idx].type = ZT_EQH;
      else if(g_zones[idx].type == ZT_SWING_LOW && g_zones[idx].touches >= InpMinTouches)
         g_zones[idx].type = ZT_EQL;
   }
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
         // Regla anti-duplicidad:
         // 1 toque => SWING_HIGH, 2+ toques => EQH (si está habilitado).
         AddOrMergeZone(ZT_SWING_HIGH, sourceTf, rates[i].high, tol, rates[i].time, 1);
      }

      if(IsPivotLow(rates, i, InpPivotLength))
      {
         // Regla anti-duplicidad:
         // 1 toque => SWING_LOW, 2+ toques => EQL (si está habilitado).
         AddOrMergeZone(ZT_SWING_LOW, sourceTf, rates[i].low, tol, rates[i].time, 1);
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
      g_zones[z].state = ZS_UNTOUCHED;
      g_zones[z].lastSweepTime = 0;

      bool highSide = IsHighSideType(g_zones[z].type);

      // Arrays en serie: i=0 es la barra más reciente (normalmente en formación).
      // Empezamos en i=1 para usar barra cerrada y capturar la barrida más RECIENTE.
      for(int i = 1; i < nr - 1; ++i)
      {
         if(highSide)
         {
            if(rates[i].high > g_zones[z].priceUpper)
            {
               g_zones[z].lastSweepTime = rates[i].time;
               if(rates[i].close < g_zones[z].priceMid)
               {
                  g_zones[z].state = ZS_REJECTION_SWEEP;
                  if(InpShowSweeps)
                     AddSweepMark(rates[i].time, rates[i].high, g_zones[z].type, true);
               }
               else
               {
                  g_zones[z].state = ZS_TAKEN;
               }
               break;
            }
         }
         else
         {
            if(rates[i].low < g_zones[z].priceLower)
            {
               g_zones[z].lastSweepTime = rates[i].time;
               if(rates[i].close > g_zones[z].priceMid)
               {
                  g_zones[z].state = ZS_REJECTION_SWEEP;
                  if(InpShowSweeps)
                     AddSweepMark(rates[i].time, rates[i].low, g_zones[z].type, false);
               }
               else
               {
                  g_zones[z].state = ZS_TAKEN;
               }
               break;
            }
         }
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

         if(MathAbs(g_zones[j].priceMid - g_zones[i].priceMid) <= tol)
            conf++;
      }
      score += MathMin(20, conf * 4);

      // Recencia medida por último toque (más robusta que firstTouchTime)
      int ageBars = iBarShift(_Symbol, PERIOD_CURRENT, g_zones[i].lastTouchTime, false);
      if(ageBars < 0)
         ageBars = 1000;
      score += MathMax(0, 12 - ageBars / 120);

      // Zonas intactas tienen más relevancia
      if(g_zones[i].state == ZS_UNTOUCHED)
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
   double priceNow = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i = 0; i < n - 1; ++i)
   {
      int best = i;
      for(int j = i + 1; j < n; ++j)
      {
         int ia = idx[best];
         int ib = idx[j];

         int pA = ZonePriority(g_zones[ia]);
         int pB = ZonePriority(g_zones[ib]);
         int rankA = g_zones[ia].score + (g_zones[ia].state == ZS_UNTOUCHED ? 20 : 0);
         int rankB = g_zones[ib].score + (g_zones[ib].state == ZS_UNTOUCHED ? 20 : 0);

         if(pB < pA)
            best = j;
         else if(pB == pA && rankB > rankA)
            best = j;
         else if(pB == pA && rankB == rankA)
         {
            double da = MathAbs(g_zones[ia].priceMid - priceNow);
            double db = MathAbs(g_zones[ib].priceMid - priceNow);
            if(db < da)
               best = j;
         }
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
   int alpha = InpZoneTransparencyActive;
   if(z.state == ZS_TAKEN)
      alpha = InpZoneTransparencySwept;
   else if(z.state == ZS_REJECTION_SWEEP)
      alpha = (InpZoneTransparencyActive + InpZoneTransparencySwept) / 2;

   color cFill = ColorToARGB(c, alpha);

   datetime t1 = z.firstTouchTime;
   if(t1 <= 0)
      t1 = iTime(_Symbol, PERIOD_CURRENT, 200);

   datetime tLast = iTime(_Symbol, PERIOD_CURRENT, 0);
   datetime t2 = tLast + (datetime)(PeriodSeconds(PERIOD_CURRENT) * MathMax(1, InpLabelBarsRight));

   if(InpDrawZoneRectangles)
   {
      if(CreateObjectChecked(rect, OBJ_RECTANGLE, t1, z.priceUpper, t2, z.priceLower))
      {
         ObjectSetInteger(0, rect, OBJPROP_COLOR, cFill);
         ObjectSetInteger(0, rect, OBJPROP_FILL, true);
         ObjectSetInteger(0, rect, OBJPROP_BACK, true);
         ObjectSetInteger(0, rect, OBJPROP_STYLE, InpLineStyle);
         ObjectSetInteger(0, rect, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, rect, OBJPROP_SELECTABLE, false);
      }
   }

   if(CreateObjectChecked(line, OBJ_HLINE, 0, z.priceMid))
   {
      ObjectSetInteger(0, line, OBJPROP_COLOR, c);
      ObjectSetInteger(0, line, OBJPROP_STYLE, InpLineStyle);
      ObjectSetInteger(0, line, OBJPROP_WIDTH, InpLineWidth + (z.state == ZS_UNTOUCHED ? 1 : 0));
      ObjectSetInteger(0, line, OBJPROP_SELECTABLE, false);
   }

   if(InpShowLabels)
   {
      string status = "UNTOUCHED";
      if(z.state == ZS_TAKEN)
         status = "TAKEN";
      else if(z.state == ZS_REJECTION_SWEEP)
         status = "SWEEP";

      string text = ZoneTypeCode(z.type) + " " + tfCode;
      if(InpShowScore)
         text += " " + IntegerToString(z.score);
      text += " " + status;

      if(CreateObjectChecked(txt, OBJ_TEXT, t2, z.priceMid))
      {
         ObjectSetString(0, txt, OBJPROP_TEXT, text);
         ObjectSetInteger(0, txt, OBJPROP_COLOR, c);
         ObjectSetInteger(0, txt, OBJPROP_FONTSIZE, 9);
         ObjectSetInteger(0, txt, OBJPROP_ANCHOR, ANCHOR_LEFT);
         ObjectSetInteger(0, txt, OBJPROP_SELECTABLE, false);
      }
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
      if(CreateObjectChecked(name, OBJ_ARROW, g_sweeps[i].t, g_sweeps[i].price))
      {
         ObjectSetInteger(0, name, OBJPROP_ARROWCODE, g_sweeps[i].isHighSweep ? 234 : 233);
         ObjectSetInteger(0, name, OBJPROP_COLOR, InpColorSweepMarker);
         ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      }
   }
}

int ZonePriority(const LiquidityZone &z)
{
   // Menor valor = mayor prioridad de dibujo
   switch(z.type)
   {
      case ZT_PWH:
      case ZT_PWL: return 1;
      case ZT_PDH:
      case ZT_PDL: return 2;
      case ZT_EQH:
      case ZT_EQL: return 3;
      case ZT_ASIA_HIGH:
      case ZT_ASIA_LOW:
      case ZT_LONDON_HIGH:
      case ZT_LONDON_LOW:
      case ZT_NEWYORK_HIGH:
      case ZT_NEWYORK_LOW: return 4;
      case ZT_SWING_HIGH:
      case ZT_SWING_LOW: return 5;
   }
   return 6;
}

bool IsSessionType(const ZoneType t)
{
   return (t == ZT_ASIA_HIGH || t == ZT_ASIA_LOW ||
           t == ZT_LONDON_HIGH || t == ZT_LONDON_LOW ||
           t == ZT_NEWYORK_HIGH || t == ZT_NEWYORK_LOW);
}

bool IsNearHigherPriorityLevel(const LiquidityZone &z)
{
   int pz = ZonePriority(z);
   double tol = (double)InpEqualTolPoints * _Point * 1.2;

   for(int i=0;i<ArraySize(g_zones);++i)
   {
      if(g_zones[i].priceMid == z.priceMid && g_zones[i].type == z.type && g_zones[i].sourceTF == z.sourceTF)
         continue;
      if(ZonePriority(g_zones[i]) < pz && MathAbs(g_zones[i].priceMid - z.priceMid) <= tol)
         return true;
   }
   return false;
}

bool PassSoloFilters(const LiquidityZone &z)
{
   bool anySolo = (InpOnlyPDH_PDL || InpOnlyPWH_PWL || InpOnlyEQH_EQL || InpOnlySessions);
   if(!anySolo)
      return true;

   bool allow = false;
   if(InpOnlyPDH_PDL && (z.type == ZT_PDH || z.type == ZT_PDL)) allow = true;
   if(InpOnlyPWH_PWL && (z.type == ZT_PWH || z.type == ZT_PWL)) allow = true;
   if(InpOnlyEQH_EQL && (z.type == ZT_EQH || z.type == ZT_EQL)) allow = true;
   if(InpOnlySessions && IsSessionType(z.type)) allow = true;
   return allow;
}

bool PassVisualMode(const LiquidityZone &z)
{
   if(InpVisualMode == VM_FULL)
      return true;

   if(InpVisualMode == VM_SESSION)
   {
      if(IsSessionType(z.type))
         return true;
      if(InpSessionModeIncludeDaily && (z.type == ZT_PDH || z.type == ZT_PDL))
         return true;
      return false;
   }

   // VM_CLEAN
   bool isCurrentTF = (z.sourceTF == (ENUM_TIMEFRAMES)_Period);
   if(z.type == ZT_PWH || z.type == ZT_PWL || z.type == ZT_PDH || z.type == ZT_PDL)
      return true;
   if((z.type == ZT_EQH || z.type == ZT_EQL) && isCurrentTF)
      return true;
   if((z.type == ZT_SWING_HIGH || z.type == ZT_SWING_LOW) && isCurrentTF && !InpHideSimpleSwings)
      return true;
   return false;
}

void DrawDebugPanel(const bool filteredByDistance)
{
   if(!InpShowDebugPanel)
      return;

   string name = g_prefix + "DEBUG_PANEL";
   string vm = "CLEAN";
   if(InpVisualMode == VM_SESSION) vm = "SESSION";
   else if(InpVisualMode == VM_FULL) vm = "FULL";
   string mode = InpShowAllZones ? "ALL" : "NEAREST";
   string filterTxt = filteredByDistance ? "DIST=ON" : "DIST=OFF";
   double priceNow = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   string txt = "ObjectiveLiquidityMap\n" +
                "Detected: " + IntegerToString(g_totalZonesDetected) + "\n" +
                "Drawn: " + IntegerToString(g_totalZonesDrawn) + "\n" +
                "Sweeps: " + IntegerToString(ArraySize(g_sweeps)) + "\n" +
                "Price: " + DoubleToString(priceNow, _Digits) + "\n" +
                "View: " + vm + " | " + mode + " " + filterTxt;

   if(CreateObjectChecked(name, OBJ_LABEL, 0, 0))
   {
      ObjectSetInteger(0, name, OBJPROP_CORNER, InpDebugCorner);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpDebugX);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, InpDebugY);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, name, OBJPROP_TEXT, txt);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
   }
}

void DrawAllZones()
{
   int n = ArraySize(g_zones);
   g_totalZonesDetected = n;
   g_totalZonesDrawn = 0;
   if(n <= 0)
   {
      DrawDebugPanel(false);
      return;
   }

   int idx[];
   ArrayResize(idx, n);
   for(int i = 0; i < n; ++i)
      idx[i] = i;

   SortIndicesByScore(idx);

   int countByType[14];
   ArrayInitialize(countByType, 0);

   double priceNow = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double maxDistPts = (double)InpMaxDistancePoints;
   if(InpUseATRDistance)
   {
      double atrNow = GetATRValue(_Symbol, PERIOD_CURRENT, InpATRPeriod, 1);
      if(atrNow > 0.0)
         maxDistPts = MathMin(maxDistPts, (atrNow / _Point) * InpMaxDistanceATR);
   }

   int drawnAbove = 0;
   int drawnBelow = 0;
   bool filteredByDistance = false;

   double drawnPrices[];
   ArrayResize(drawnPrices, 0);

   for(int k = 0; k < n; ++k)
   {
      LiquidityZone z = g_zones[idx[k]];
      int t = (int)z.type;

      if(countByType[t] >= InpMaxZonesPerType)
         continue;

      // filtros base por tipo
      if((z.type == ZT_EQH || z.type == ZT_EQL) && !InpShowEqualHighLow) continue;
      if((z.type == ZT_SWING_HIGH || z.type == ZT_SWING_LOW) && !InpShowSwingZones) continue;
      if((z.type == ZT_PDH || z.type == ZT_PDL) && !InpShowDailyLevels) continue;
      if((z.type == ZT_PWH || z.type == ZT_PWL) && !InpShowWeeklyLevels) continue;
      if(IsSessionType(z.type) && !InpShowSessionLevels && InpVisualMode != VM_SESSION && InpVisualMode != VM_FULL) continue;

      // modo visual
      if(!PassVisualMode(z))
         continue;

      // solo-filters
      if(!PassSoloFilters(z))
         continue;

      // estados
      if(InpOnlyUntouched && z.state != ZS_UNTOUCHED)
         continue;
      if(InpHideTaken && z.state == ZS_TAKEN)
         continue;

      // limpieza extra modo CLEAN
      if(InpVisualMode == VM_CLEAN)
      {
         if((z.type == ZT_SWING_HIGH || z.type == ZT_SWING_LOW) && InpHideSimpleSwings)
            continue;

         if(IsNearHigherPriorityLevel(z))
            continue;
      }

      if((z.type == ZT_EQH || z.type == ZT_EQL) && z.touches < InpMinTouches)
         continue;

      double distPts = MathAbs(z.priceMid - priceNow) / _Point;
      bool isAbove = (z.priceMid >= priceNow);

      if(!InpShowAllZones)
      {
         if(InpEnableMaxDistanceFilter && distPts > maxDistPts)
         {
            filteredByDistance = true;
            continue;
         }

         if(isAbove)
         {
            if(drawnAbove >= InpNearestAboveCount)
               continue;
         }
         else
         {
            if(drawnBelow >= InpNearestBelowCount)
               continue;
         }
      }

      // evitar saturación por niveles demasiado cercanos
      bool tooCloseToDrawn = false;
      double overlapTolPts = (double)InpEqualTolPoints * 0.8;
      for(int d=0; d<ArraySize(drawnPrices); ++d)
      {
         if(MathAbs(drawnPrices[d] - z.priceMid) / _Point <= overlapTolPts)
         {
            tooCloseToDrawn = true;
            break;
         }
      }
      if(tooCloseToDrawn)
         continue;

      DrawZone(z, g_totalZonesDrawn);
      int nn = ArraySize(drawnPrices);
      ArrayResize(drawnPrices, nn + 1);
      drawnPrices[nn] = z.priceMid;

      countByType[t]++;
      g_totalZonesDrawn++;
      if(isAbove) drawnAbove++; else drawnBelow++;
   }

   DrawSweeps();
   DrawDebugPanel(filteredByDistance);
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
   g_totalZonesDetected = 0;
   g_totalZonesDrawn = 0;

   // 1) Datos TF actual
   MqlRates ratesCur[];
   if(!LoadRates(_Symbol, PERIOD_CURRENT, InpBarsToAnalyze, ratesCur))
   {
      Print("[ObjectiveLiquidityMap] WARNING: LoadRates TF actual falló. No se pueden reconstruir zonas.");
      ClearObjectsByPrefix(g_prefix);
      DrawDebugPanel(false);
      ChartRedraw(0);
      return;
   }

   // Si falla ATR, NO abortar. Se usa tolerancia fija por puntos.
   double atrCur[];
   bool atrCurOk = LoadATRSeries(_Symbol, PERIOD_CURRENT, InpATRPeriod, ArraySize(ratesCur), atrCur);
   if(!atrCurOk)
      Print("[ObjectiveLiquidityMap] WARNING: ATR TF actual no disponible. Se usará tolerancia fija por puntos.");

   // 2) Pivots y equal highs/lows TF actual
   DetectPivotsAndEqual(ratesCur, atrCur, (ENUM_TIMEFRAMES)_Period);

   // 3) MTF opcional (cada TF con su ATR propio; si falla, continuar)
   if(InpUseMTF)
   {
      MqlRates r1[];
      if(LoadRates(_Symbol, InpMTF1, MathMax(600, InpBarsToAnalyze / 3), r1))
      {
         double atr1[];
         bool atr1Ok = LoadATRSeries(_Symbol, InpMTF1, InpATRPeriod, ArraySize(r1), atr1);
         if(!atr1Ok)
            Print("[ObjectiveLiquidityMap] WARNING: ATR MTF1 no disponible (", TFCode(InpMTF1), "). Se usará tolerancia fija por puntos.");

         DetectPivotsAndEqual(r1, atr1, InpMTF1);
      }
      else
      {
         Print("[ObjectiveLiquidityMap] WARNING: LoadRates MTF1 falló (", TFCode(InpMTF1), "). Se continúa con el resto.");
      }

      if(InpUseMTF2)
      {
         MqlRates r2[];
         if(LoadRates(_Symbol, InpMTF2, MathMax(400, InpBarsToAnalyze / 6), r2))
         {
            double atr2[];
            bool atr2Ok = LoadATRSeries(_Symbol, InpMTF2, InpATRPeriod, ArraySize(r2), atr2);
            if(!atr2Ok)
               Print("[ObjectiveLiquidityMap] WARNING: ATR MTF2 no disponible (", TFCode(InpMTF2), "). Se usará tolerancia fija por puntos.");

            DetectPivotsAndEqual(r2, atr2, InpMTF2);
         }
         else
         {
            Print("[ObjectiveLiquidityMap] WARNING: LoadRates MTF2 falló (", TFCode(InpMTF2), "). Se continúa con el resto.");
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

   Print("[ObjectiveLiquidityMap] Rebuild completado. detected=", g_totalZonesDetected,
         " drawn=", g_totalZonesDrawn,
         " sweeps=", ArraySize(g_sweeps));

   ChartRedraw(0);
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
