#property strict
#property indicator_chart_window
#property indicator_plots 0
#property version   "1.20"
#property description "AMD Accumulation + Manipulation Visualizer V1.2 (M15/M5)"

// ============================================================
// AMD Accumulation + Manipulation Visualizer V1.2
// - Fase 1: detección visual de acumulaciones (M15)
// - Fase 2: detección visual de manipulación post-acumulación (M5)
// - No ejecuta operaciones
// ============================================================

input ENUM_TIMEFRAMES InpBaseTF                 = PERIOD_M15;   // TF base de acumulación (V1: M15)
input int             InpWindowBars             = 16;           // Ventana de acumulación (12..24)
input int             InpScanBars               = 180;          // Barras M15 a escanear
input int             InpMaxZonesOnChart        = 4;            // Máximo de zonas dibujadas

input int             InpATRPeriod              = 14;           // ATR periodo (M15)
input double          InpMaxRangeATRFactor      = 0.90;         // Rango de ventana <= ATR*factor
input double          InpMinInnerClosePct       = 70.0;         // % mínimo cierres dentro rango interno
input double          InpInnerMarginPct         = 10.0;         // Margen interno (% del rango)
input double          InpTouchTolerancePct      = 8.0;          // Tolerancia de toque (% del rango)
input int             InpMinTouchesPerSide      = 2;            // Toques mínimos por lado
input double          InpMaxDisplacementPct     = 40.0;         // Desplazamiento neto máximo (% del rango)
input double          InpMaxTrendATRFactor      = 0.80;         // Desplazamiento neto <= ATR*factor

input int             InpManipLookaheadM5Bars   = 24;           // Barras M5 tras acumulación para buscar sweep
input double          InpMinSweepPctOfRange     = 12.0;         // Penetración mínima como % del rango de acumulación
input bool            InpUseM5ATRForSweep       = true;         // Combinar umbral con ATR M5
input int             InpM5ATRPeriod            = 14;           // ATR M5 periodo
input double          InpMinSweepATRMult        = 0.25;         // Penetración mínima como múltiplo ATR M5
input double          InpMinBodyPct             = 55.0;         // Cuerpo mínimo de vela de desplazamiento (% del rango vela)
input double          InpMinCloseNearExtremePct = 70.0;         // Cierre fuerte cerca del extremo (% del rango vela)
input bool            InpUseMicroSwingBreak     = false;        // Opcional: ruptura de micro swing M5
input int             InpMicroSwingBars         = 4;            // Barras para micro swing

input color           InpZoneColor              = clrSteelBlue; // Color zona acumulación
input int             InpZoneTransparency       = 82;           // Transparencia 0..255 (más alto = más tenue)
input bool            InpZoneFill               = true;         // Relleno de rectángulo
input int             InpZoneLineWidth          = 1;            // Grosor borde zona
input int             InpLabelFontSize          = 8;            // Tamaño etiqueta

input color           InpSweepHighColor         = clrTomato;    // Color sweep high
input color           InpSweepLowColor          = clrMediumSeaGreen; // Color sweep low
input int             InpMarkerArrowSize        = 2;            // Tamaño flecha sweep

string g_prefix = "AMD_ACC_V12_";
int    g_atrHandleM15 = INVALID_HANDLE;
int    g_atrHandleM5  = INVALID_HANDLE;

enum ManipulationType
{
   MANIP_NOISE = 0,
   MANIP_BREAKOUT_NORMAL,
   MANIP_SWEEP_WEAK,
   MANIP_SWEEP_VALID
};

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

struct SweepInfo
{
   bool            found;
   bool            sweepHigh;
   bool            sweepLow;
   datetime        sweepTime;
   double          sweepPrice;
   double          penetration;
   double          penetrationPoints;
   int             shiftM5;
   double          displacementScore;
   ManipulationType classification;
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
      double ratio = zone.range / zone.atr;
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
      double dispRatio = zone.displacement / zone.range;
      double maxDispRatio = InpMaxDisplacementPct / 100.0;
      sTrend = 25.0 * MathMax(0.0, MathMin(1.0, (maxDispRatio - dispRatio) / MathMax(0.01, maxDispRatio)));
   }

   return MathMax(0.0, MathMin(100.0, sRange + sClose + sTouch + sTrend));
}

bool DetectSweep(const AccumulationZone &zone,
                 const MqlRates &m5Rates[],
                 const double &m5Atr[],
                 SweepInfo &sweep)
{
   sweep.found = false;
   sweep.sweepHigh = false;
   sweep.sweepLow = false;
   sweep.sweepTime = 0;
   sweep.sweepPrice = 0.0;
   sweep.penetration = 0.0;
   sweep.penetrationPoints = 0.0;
   sweep.shiftM5 = -1;
   sweep.displacementScore = 0.0;
   sweep.classification = MANIP_NOISE;

   int shiftEnd = iBarShift(_Symbol, PERIOD_M5, zone.tEnd, false);
   if(shiftEnd < 0)
      return false;

   int startShift = shiftEnd - InpManipLookaheadM5Bars;
   if(startShift < 1)
      startShift = 1;

   double penetrationByRange = zone.range * (InpMinSweepPctOfRange / 100.0);

   for(int i = shiftEnd; i >= startShift; --i)
   {
      double atrM5 = 0.0;
      if(i < ArraySize(m5Atr))
         atrM5 = m5Atr[i];

      double penetrationByATR = (InpUseM5ATRForSweep && atrM5 > 0.0) ? (atrM5 * InpMinSweepATRMult) : 0.0;
      double minPen = MathMax(penetrationByRange, penetrationByATR);

      double highPen = m5Rates[i].high - zone.high;
      if(highPen >= minPen)
      {
         sweep.found = true;
         sweep.sweepHigh = true;
         sweep.sweepLow = false;
         sweep.sweepTime = m5Rates[i].time;
         sweep.sweepPrice = m5Rates[i].high;
         sweep.penetration = highPen;
         sweep.penetrationPoints = highPen / _Point;
         sweep.shiftM5 = i;
         return true;
      }

      double lowPen = zone.low - m5Rates[i].low;
      if(lowPen >= minPen)
      {
         sweep.found = true;
         sweep.sweepHigh = false;
         sweep.sweepLow = true;
         sweep.sweepTime = m5Rates[i].time;
         sweep.sweepPrice = m5Rates[i].low;
         sweep.penetration = lowPen;
         sweep.penetrationPoints = lowPen / _Point;
         sweep.shiftM5 = i;
         return true;
      }
   }

   return false;
}

double MeasureDisplacementStrength(const MqlRates &m5Rates[], const int sweepShift, const bool afterSweep, const bool bullishExpected)
{
   // Mide fuerza objetiva en la vela siguiente al sweep:
   // - cuerpo grande relativo al rango de vela
   // - cierre cerca del extremo de desplazamiento
   int i = (afterSweep ? sweepShift - 1 : sweepShift);
   if(i < 1 || i >= ArraySize(m5Rates))
      return 0.0;

   double h = m5Rates[i].high;
   double l = m5Rates[i].low;
   double o = m5Rates[i].open;
   double c = m5Rates[i].close;
   double r = h - l;
   if(r <= 0.0)
      return 0.0;

   double body = MathAbs(c - o);
   double bodyPct = 100.0 * body / r;

   double closeStrength = 0.0;
   if(bullishExpected)
      closeStrength = 100.0 * (c - l) / r;     // cerca del high => fuerte al alza
   else
      closeStrength = 100.0 * (h - c) / r;     // cerca del low => fuerte a la baja

   // Score simple 0..100 (50 cuerpo + 50 cierre)
   double sBody = 50.0 * MathMax(0.0, MathMin(1.0, bodyPct / MathMax(1.0, InpMinBodyPct)));
   double sClose = 50.0 * MathMax(0.0, MathMin(1.0, closeStrength / MathMax(1.0, InpMinCloseNearExtremePct)));

   return MathMax(0.0, MathMin(100.0, sBody + sClose));
}

ManipulationType ValidateManipulation(const AccumulationZone &zone,
                                      const MqlRates &m5Rates[],
                                      const SweepInfo &sweep,
                                      const double displacementScore)
{
   if(!sweep.found)
      return MANIP_NOISE;

   bool bullishDisp = sweep.sweepLow;  // tras sweep low esperamos desplazamiento alcista
   bool bearishDisp = sweep.sweepHigh; // tras sweep high esperamos desplazamiento bajista

   int dShift = sweep.shiftM5 - 1;
   if(dShift < 1 || dShift >= ArraySize(m5Rates))
      return MANIP_SWEEP_WEAK;

   double o = m5Rates[dShift].open;
   double c = m5Rates[dShift].close;

   bool dirOk = (bullishDisp && c > o) || (bearishDisp && c < o);

   bool swingOk = true;
   if(InpUseMicroSwingBreak)
   {
      int from = dShift + 1;
      int to = MathMin(ArraySize(m5Rates) - 1, dShift + InpMicroSwingBars);
      if(from >= to)
         swingOk = false;
      else
      {
         double prevHi = -DBL_MAX;
         double prevLo = DBL_MAX;
         for(int i = from; i <= to; ++i)
         {
            if(m5Rates[i].high > prevHi) prevHi = m5Rates[i].high;
            if(m5Rates[i].low < prevLo) prevLo = m5Rates[i].low;
         }

         if(bullishDisp)
            swingOk = (m5Rates[dShift].close > prevHi);
         else if(bearishDisp)
            swingOk = (m5Rates[dShift].close < prevLo);
      }
   }

   if(displacementScore >= 75.0 && dirOk && swingOk)
      return MANIP_SWEEP_VALID;

   if(displacementScore >= 45.0 && dirOk)
      return MANIP_SWEEP_WEAK;

   // hubo ruptura con penetración, pero sin desplazamiento de rechazo: breakout normal
   if(!dirOk && displacementScore >= 35.0)
      return MANIP_BREAKOUT_NORMAL;

   return MANIP_NOISE;
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

   string label = StringFormat("Accumulation\nScore: %.1f\nRange: %.1f pts", zone.score, zone.rangePoints);
   ObjectCreate(0, textName, OBJ_TEXT, 0, zone.tEnd, zone.high);
   ObjectSetString(0, textName, OBJPROP_TEXT, label);
   ObjectSetInteger(0, textName, OBJPROP_COLOR, InpZoneColor);
   ObjectSetInteger(0, textName, OBJPROP_FONTSIZE, InpLabelFontSize);
   ObjectSetInteger(0, textName, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, textName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, textName, OBJPROP_HIDDEN, false);
}

void DrawManipulationMarker(const SweepInfo &sweep, const int index)
{
   if(!sweep.found)
      return;

   string id = IntegerToString((int)sweep.sweepTime) + "_" + IntegerToString(index);
   string arrName = g_prefix + "SWP_ARR_" + id;
   string txtName = g_prefix + "SWP_TXT_" + id;

   color c = (sweep.sweepHigh ? InpSweepHighColor : InpSweepLowColor);
   int arrowCode = (sweep.sweepHigh ? 234 : 233); // wingdings down/up

   ObjectCreate(0, arrName, OBJ_ARROW, 0, sweep.sweepTime, sweep.sweepPrice);
   ObjectSetInteger(0, arrName, OBJPROP_ARROWCODE, arrowCode);
   ObjectSetInteger(0, arrName, OBJPROP_COLOR, c);
   ObjectSetInteger(0, arrName, OBJPROP_WIDTH, InpMarkerArrowSize);
   ObjectSetInteger(0, arrName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, arrName, OBJPROP_HIDDEN, false);

   string cls = "Noise";
   if(sweep.classification == MANIP_SWEEP_VALID) cls = "Sweep Valid";
   else if(sweep.classification == MANIP_SWEEP_WEAK) cls = "Sweep Weak";
   else if(sweep.classification == MANIP_BREAKOUT_NORMAL) cls = "Breakout Normal";

   string title = (sweep.sweepHigh ? "Sweep High" : "Sweep Low");
   string text = StringFormat("%s\nDispScore: %.1f\nPen: %.1f pts\n%s",
                              title, sweep.displacementScore, sweep.penetrationPoints, cls);

   ObjectCreate(0, txtName, OBJ_TEXT, 0, sweep.sweepTime, sweep.sweepPrice);
   ObjectSetString(0, txtName, OBJPROP_TEXT, text);
   ObjectSetInteger(0, txtName, OBJPROP_COLOR, c);
   ObjectSetInteger(0, txtName, OBJPROP_FONTSIZE, InpLabelFontSize);
   ObjectSetInteger(0, txtName, OBJPROP_ANCHOR, (sweep.sweepHigh ? ANCHOR_RIGHT_UPPER : ANCHOR_RIGHT_LOWER));
   ObjectSetInteger(0, txtName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, txtName, OBJPROP_HIDDEN, false);
}

int OnInit()
{
   if(InpBaseTF != PERIOD_M15)
      Print("[AMD_ACC_V12] Nota: V1/V2 está diseñada para acumulación M15.");

   g_atrHandleM15 = iATR(_Symbol, PERIOD_M15, InpATRPeriod);
   g_atrHandleM5  = iATR(_Symbol, PERIOD_M5, InpM5ATRPeriod);

   if(g_atrHandleM15 == INVALID_HANDLE || g_atrHandleM5 == INVALID_HANDLE)
   {
      Print("[AMD_ACC_V12] Error creando handles ATR.");
      return INIT_FAILED;
   }

   IndicatorSetString(INDICATOR_SHORTNAME, "AMD Accumulation+Manipulation V1.2 (M15/M5)");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ClearOldZones();
   if(g_atrHandleM15 != INVALID_HANDLE)
      IndicatorRelease(g_atrHandleM15);
   if(g_atrHandleM5 != INVALID_HANDLE)
      IndicatorRelease(g_atrHandleM5);
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
   const int needM15 = MathMax(window + 5, InpScanBars + window + 5);

   MqlRates ratesM15[];
   ArraySetAsSeries(ratesM15, true);
   int copiedM15 = CopyRates(_Symbol, PERIOD_M15, 0, needM15, ratesM15);
   if(copiedM15 <= window + 2)
      return prev_calculated;

   double atrM15[];
   ArraySetAsSeries(atrM15, true);
   int copiedATR15 = CopyBuffer(g_atrHandleM15, 0, 0, copiedM15, atrM15);
   if(copiedATR15 <= window + 2)
      return prev_calculated;

   int needM5 = InpScanBars * 3 + InpManipLookaheadM5Bars + 200;
   MqlRates ratesM5[];
   ArraySetAsSeries(ratesM5, true);
   int copiedM5 = CopyRates(_Symbol, PERIOD_M5, 0, needM5, ratesM5);
   if(copiedM5 <= InpManipLookaheadM5Bars + 5)
      return prev_calculated;

   double atrM5[];
   ArraySetAsSeries(atrM5, true);
   int copiedATR5 = CopyBuffer(g_atrHandleM5, 0, 0, copiedM5, atrM5);
   if(copiedATR5 <= InpManipLookaheadM5Bars + 5)
      return prev_calculated;

   ClearOldZones();

   int drawn = 0;
   for(int shift = 1; shift + window - 1 < copiedM15 && drawn < InpMaxZonesOnChart; ++shift)
   {
      double atrNow = atrM15[shift];
      if(atrNow <= 0.0)
         continue;

      AccumulationZone zone;
      if(!DetectAccumulation(ratesM15, shift, window, atrNow, zone))
         continue;

      zone.score = ScoreAccumulation(zone);
      if(zone.score < 50.0)
         continue;

      DrawAccumulationZone(zone, drawn);

      SweepInfo sweep;
      if(DetectSweep(zone, ratesM5, atrM5, sweep))
      {
         bool bullishExpected = sweep.sweepLow;
         sweep.displacementScore = MeasureDisplacementStrength(ratesM5, sweep.shiftM5, true, bullishExpected);
         sweep.classification = ValidateManipulation(zone, ratesM5, sweep, sweep.displacementScore);
         DrawManipulationMarker(sweep, drawn);
      }

      drawn++;
      shift += (window / 2);
   }

   return rates_total;
}
