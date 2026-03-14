#property strict
#property indicator_chart_window
#property indicator_plots 0
#property version   "1.00"
#property description "AMD Accumulation Visualizer V1 (M15)"

// ============================================================
// AMD Accumulation Visualizer V1
// - Fase 1: solo detección y visualización de acumulaciones
// - Timeframe base: M15
// - No ejecuta operaciones
// ============================================================

input ENUM_TIMEFRAMES InpBaseTF                 = PERIOD_M15;   // TF base de detección (V1: M15)
input int             InpWindowBars             = 16;           // Ventana de análisis (12..24)
input int             InpScanBars               = 180;          // Barras a escanear en M15
input int             InpMaxZonesOnChart        = 4;            // Máximo de zonas dibujadas

input int             InpATRPeriod              = 14;           // ATR periodo (M15)
input double          InpMaxRangeATRFactor      = 0.90;         // Rango de ventana <= ATR*factor
input double          InpMinInnerClosePct       = 70.0;         // % mínimo de cierres dentro del rango interno
input double          InpInnerMarginPct         = 10.0;         // Margen interno (% del rango)
input double          InpTouchTolerancePct      = 8.0;          // Tolerancia de toque (% del rango)
input int             InpMinTouchesPerSide      = 2;            // Toques mínimos arriba y abajo
input double          InpMaxDisplacementPct     = 40.0;         // Desplazamiento neto máximo (% del rango)
input double          InpMaxTrendATRFactor      = 0.80;         // Desplazamiento neto <= ATR*factor

input color           InpZoneColor              = clrSteelBlue; // Color base zona
input int             InpZoneTransparency       = 82;           // Transparencia 0..255 (más alto = más tenue)
input bool            InpZoneFill               = true;         // Relleno de rectángulo
input int             InpZoneLineWidth          = 1;            // Grosor borde
input int             InpLabelFontSize          = 8;            // Tamaño fuente etiqueta

string g_prefix = "AMD_ACC_V1_";
int    g_atrHandle = INVALID_HANDLE;

struct AccumulationZone
{
   datetime tStart;
   datetime tEnd;
   double   high;
   double   low;

   int      bars;
   int      touchesHigh;
   int      touchesLow;
   int      closesInside;

   double   range;
   double   rangePoints;
   double   atr;
   double   displacement;
   double   score;
};

int ClampWindow(int val)
{
   if(val < 12) return 12;
   if(val > 24) return 24;
   return val;
}

void ClearOldZones()
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; --i)
   {
      string name = ObjectName(0, i, -1, -1);
      if(StringFind(name, g_prefix) == 0)
         ObjectDelete(0, name);
   }
}

bool DetectAccumulation(const MqlRates &rates[], const int startShift, const int windowBars, const double atr, AccumulationZone &zone)
{
   if(atr <= 0.0)
      return false;

   double hi = -DBL_MAX;
   double lo =  DBL_MAX;

   for(int i = startShift; i < startShift + windowBars; ++i)
   {
      if(rates[i].high > hi) hi = rates[i].high;
      if(rates[i].low  < lo) lo = rates[i].low;
   }

   double range = hi - lo;
   if(range <= 0.0)
      return false;

   // 1) Rango pequeño relativo al ATR
   if(range > atr * InpMaxRangeATRFactor)
      return false;

   double innerMargin = range * (InpInnerMarginPct / 100.0);
   double innerTop    = hi - innerMargin;
   double innerBottom = lo + innerMargin;

   double touchTol = MathMax(range * (InpTouchTolerancePct / 100.0), _Point * 2.0);
   int closesInside = 0;
   int touchesHigh  = 0;
   int touchesLow   = 0;

   for(int i = startShift; i < startShift + windowBars; ++i)
   {
      double c = rates[i].close;
      if(c <= innerTop && c >= innerBottom)
         closesInside++;

      if(rates[i].high >= hi - touchTol)
         touchesHigh++;
      if(rates[i].low <= lo + touchTol)
         touchesLow++;
   }

   // 2) Mayoría de cierres dentro del rango interno
   double insidePct = 100.0 * (double)closesInside / (double)windowBars;
   if(insidePct < InpMinInnerClosePct)
      return false;

   // 3) Al menos 2 toques arriba y 2 abajo
   if(touchesHigh < InpMinTouchesPerSide || touchesLow < InpMinTouchesPerSide)
      return false;

   // 4) Sin desplazamiento tendencial fuerte
   double oldestClose = rates[startShift + windowBars - 1].close;
   double newestClose = rates[startShift].close;
   double displacement = MathAbs(newestClose - oldestClose);

   if(displacement > range * (InpMaxDisplacementPct / 100.0))
      return false;

   if(displacement > atr * InpMaxTrendATRFactor)
      return false;

   zone.tStart       = rates[startShift + windowBars - 1].time;
   zone.tEnd         = rates[startShift].time;
   zone.high         = hi;
   zone.low          = lo;
   zone.bars         = windowBars;
   zone.touchesHigh  = touchesHigh;
   zone.touchesLow   = touchesLow;
   zone.closesInside = closesInside;
   zone.range        = range;
   zone.rangePoints  = range / _Point;
   zone.atr          = atr;
   zone.displacement = displacement;

   return true;
}

double ScoreAccumulation(const AccumulationZone &zone)
{
   // Score 0..100 basado en 4 bloques simples (25 cada uno)
   double sRange = 0.0;
   double sClose = 0.0;
   double sTouch = 0.0;
   double sTrend = 0.0;

   if(zone.atr > 0.0)
   {
      double ratio = zone.range / zone.atr; // cuanto menor mejor
      sRange = 25.0 * MathMax(0.0, MathMin(1.0, (InpMaxRangeATRFactor - ratio) / MathMax(0.01, InpMaxRangeATRFactor)));
   }

   if(zone.bars > 0)
   {
      double insidePct = 100.0 * (double)zone.closesInside / (double)zone.bars;
      sClose = 25.0 * MathMax(0.0, MathMin(1.0, insidePct / 100.0));

      double touchScoreHigh = MathMin(1.0, (double)zone.touchesHigh / (double)MathMax(2, InpMinTouchesPerSide + 1));
      double touchScoreLow  = MathMin(1.0, (double)zone.touchesLow  / (double)MathMax(2, InpMinTouchesPerSide + 1));
      sTouch = 25.0 * 0.5 * (touchScoreHigh + touchScoreLow);
   }

   if(zone.range > 0.0)
   {
      double dispRatio = zone.displacement / zone.range; // cuanto menor mejor
      double maxDispRatio = InpMaxDisplacementPct / 100.0;
      sTrend = 25.0 * MathMax(0.0, MathMin(1.0, (maxDispRatio - dispRatio) / MathMax(0.01, maxDispRatio)));
   }

   double score = sRange + sClose + sTouch + sTrend;
   return MathMax(0.0, MathMin(100.0, score));
}

void DrawAccumulationZone(const AccumulationZone &zone, const int index)
{
   string id = IntegerToString((int)zone.tStart) + "_" + IntegerToString(index);
   string rectName = g_prefix + "RECT_" + id;
   string textName = g_prefix + "TEXT_" + id;

   ObjectCreate(0, rectName, OBJ_RECTANGLE, 0, zone.tStart, zone.high, zone.tEnd, zone.low);
   ObjectSetInteger(0, rectName, OBJPROP_BACK, true);
   ObjectSetInteger(0, rectName, OBJPROP_FILL, InpZoneFill);
   ObjectSetInteger(0, rectName, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, rectName, OBJPROP_WIDTH, InpZoneLineWidth);
   ObjectSetInteger(0, rectName, OBJPROP_COLOR, ColorToARGB(InpZoneColor, InpZoneTransparency));
   ObjectSetInteger(0, rectName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, rectName, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, rectName, OBJPROP_HIDDEN, false);
   ObjectSetString(0, rectName, OBJPROP_TOOLTIP,
                   StringFormat("Accumulation | Score: %.1f | Range: %.1f pts", zone.score, zone.rangePoints));

   string label = StringFormat("Accumulation\nScore: %.1f\nRange: %.1f pts", zone.score, zone.rangePoints);
   ObjectCreate(0, textName, OBJ_TEXT, 0, zone.tEnd, zone.high);
   ObjectSetString(0, textName, OBJPROP_TEXT, label);
   ObjectSetInteger(0, textName, OBJPROP_COLOR, InpZoneColor);
   ObjectSetInteger(0, textName, OBJPROP_FONTSIZE, InpLabelFontSize);
   ObjectSetInteger(0, textName, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, textName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, textName, OBJPROP_HIDDEN, false);
}

int OnInit()
{
   if(InpBaseTF != PERIOD_M15)
      Print("[AMD_ACC_V1] Nota: V1 está diseñada para M15. Se forzará detección sobre M15 internamente.");

   g_atrHandle = iATR(_Symbol, PERIOD_M15, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("[AMD_ACC_V1] Error creando handle ATR.");
      return INIT_FAILED;
   }

   IndicatorSetString(INDICATOR_SHORTNAME, "AMD Accumulation V1 (M15)");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ClearOldZones();
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
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
   const int window = ClampWindow(InpWindowBars);
   const int needBars = MathMax(window + 5, InpScanBars + window + 5);

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, PERIOD_M15, 0, needBars, rates);
   if(copied <= window + 2)
      return prev_calculated;

   double atr[];
   ArraySetAsSeries(atr, true);
   int copiedAtr = CopyBuffer(g_atrHandle, 0, 0, copied, atr);
   if(copiedAtr <= window + 2)
      return prev_calculated;

   ClearOldZones();

   int drawn = 0;
   // empezamos en shift=1 para evitar usar vela actual no cerrada
   for(int shift = 1; shift + window - 1 < copied && drawn < InpMaxZonesOnChart; ++shift)
   {
      double atrNow = atr[shift];
      if(atrNow <= 0.0)
         continue;

      AccumulationZone zone;
      if(!DetectAccumulation(rates, shift, window, atrNow, zone))
         continue;

      zone.score = ScoreAccumulation(zone);

      // filtro mínimo de calidad para limpiar gráfico
      if(zone.score < 50.0)
         continue;

      DrawAccumulationZone(zone, drawn);
      drawn++;

      // salto de ventana para evitar solapes excesivos y mantener limpieza visual
      shift += (window / 2);
   }

   return rates_total;
}
