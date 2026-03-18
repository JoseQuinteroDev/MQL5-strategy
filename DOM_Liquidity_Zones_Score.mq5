#property strict
#property indicator_chart_window
#property indicator_plots 0
#property version   "1.00"
#property description "DOM Liquidity Zones Score (visible DOM only, no trading)"

// ==============================================================
// DOM_Liquidity_Zones_Score.mq5
// --------------------------------------------------------------
// Indicador visual para MetaTrader 5 que lee el Depth of Market
// (DOM) del símbolo actual y destaca SOLO las zonas de mayor
// liquidez visible cercanas al precio.
//
// Importante:
// - NO detecta SL/TP reales del mercado.
// - Trabaja exclusivamente con liquidez visible del DOM del broker.
// - No abre operaciones. Solo detecta, puntúa y dibuja zonas.
// ==============================================================

input int      InpSnapshotsToKeep          = 30;            // Número de snapshots a conservar
input int      InpGroupTicks               = 2;             // Distancia máxima en ticks para agrupar niveles
input double   InpScoreMin                 = 55.0;          // Score mínimo para mostrar
input int      InpTopNZones                = 5;             // Top N zonas a mostrar
input double   InpWeightVolume             = 30.0;          // Peso volumen
input double   InpWeightDensity            = 20.0;          // Peso densidad
input double   InpWeightPersistence        = 20.0;          // Peso persistencia
input double   InpWeightProximity          = 20.0;          // Peso cercanía al precio
input double   InpWeightImbalance          = 10.0;          // Peso desequilibrio bid/ask
input int      InpMaxAnalysisRadiusTicks   = 80;            // Radio máximo de análisis alrededor del precio actual
input int      InpMinRefreshMs             = 350;           // Frecuencia mínima de refresco gráfico (ms)
input color    InpBidZoneColor             = clrLimeGreen;  // Color zonas BID
input color    InpAskZoneColor             = clrTomato;     // Color zonas ASK
input color    InpMixedZoneColor           = clrGold;       // Color zonas MIXTA
input bool     InpShowLabels               = true;          // Mostrar labels
input bool     InpShowNormalizedScore      = true;          // Mostrar score 0..100
input int      InpLineWidth                = 2;             // Grosor borde zona
input int      InpZoneAlpha                = 90;            // Transparencia base de zona (0..255)
input ENUM_BASE_CORNER InpPanelCorner      = CORNER_RIGHT_UPPER;
input int      InpPanelX                   = 12;
input int      InpPanelY                   = 14;

string   g_prefix = "DOM_LIQ_";
string   g_symbol = "";
double   g_point  = 0.0;
double   g_tickSize = 0.0;
uint     g_lastRefreshMs = 0;
int      g_snapshotId = 0;
bool     g_domSubscribed = false;
bool     g_domUsable = false;
string   g_statusMessage = "Inicializando DOM...";
int      g_lastDetectedZones = 0;
int      g_lastDrawnZones = 0;

// ==============================================================
// Estructuras internas
// ==============================================================
enum DOMSide
{
   DOM_SIDE_BID = 0,
   DOM_SIDE_ASK,
   DOM_SIDE_MIXED
};

struct LiquidityLevel
{
   double  price;
   double  volume;
   DOMSide side;
};

struct LiquidityZone
{
   double  priceMin;
   double  priceMax;
   double  priceMid;
   double  bidVolume;
   double  askVolume;
   double  totalVolume;
   int     levelCount;
   int     spanTicks;
   int     persistenceCount;
   DOMSide side;
   double  score;
   int     snapshotId;
};

struct HistoricalZone
{
   int     snapshotId;
   double  priceMid;
   double  totalVolume;
   DOMSide side;
};

HistoricalZone g_history[];

// ==============================================================
// Helpers base
// ==============================================================
string SideCode(const DOMSide side)
{
   if(side == DOM_SIDE_BID)
      return "BID";
   if(side == DOM_SIDE_ASK)
      return "ASK";
   return "MIX";
}

color SideColor(const DOMSide side)
{
   if(side == DOM_SIDE_BID)
      return InpBidZoneColor;
   if(side == DOM_SIDE_ASK)
      return InpAskZoneColor;
   return InpMixedZoneColor;
}

bool CreateObjectChecked(const string name,
                         const ENUM_OBJECT type,
                         const datetime t1,
                         const double p1,
                         const datetime t2 = 0,
                         const double p2 = 0.0)
{
   ResetLastError();
   bool ok = false;

   if(type == OBJ_HLINE)
      ok = ObjectCreate(0, name, type, 0, 0, p1);
   else if(type == OBJ_LABEL)
      ok = ObjectCreate(0, name, type, 0, 0, 0);
   else if(type == OBJ_TEXT || type == OBJ_ARROW)
      ok = ObjectCreate(0, name, type, 0, t1, p1);
   else
      ok = ObjectCreate(0, name, type, 0, t1, p1, t2, p2);

   if(!ok)
      Print("[DOM_LIQ] ObjectCreate falló: ", name, " err=", GetLastError());

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

bool NameExists(const string &names[], const string name)
{
   for(int i = 0; i < ArraySize(names); ++i)
   {
      if(names[i] == name)
         return true;
   }
   return false;
}

void AddName(string &names[], const string name)
{
   int n = ArraySize(names);
   ArrayResize(names, n + 1);
   names[n] = name;
}

void CleanupUnusedObjects(const string &activeNames[])
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; --i)
   {
      string name = ObjectName(0, i, -1, -1);
      if(StringFind(name, g_prefix) != 0)
         continue;
      if(!NameExists(activeNames, name))
         ObjectDelete(0, name);
   }
}

uint NowMs()
{
   return (uint)GetTickCount();
}

// ==============================================================
// Suscripción y lectura del DOM
// ==============================================================
bool SubscribeDOM()
{
   ResetLastError();
   if(!MarketBookAdd(g_symbol))
   {
      g_domSubscribed = false;
      g_domUsable = false;
      g_statusMessage = "Broker sin DOM o suscripción fallida";
      Print("[DOM_LIQ] MarketBookAdd falló para ", g_symbol, " err=", GetLastError());
      return false;
   }

   g_domSubscribed = true;
   g_statusMessage = "DOM suscrito, esperando snapshots...";
   return true;
}

void ReleaseDOM()
{
   if(!g_domSubscribed)
      return;
   MarketBookRelease(g_symbol);
   g_domSubscribed = false;
}

bool ReadBook(MqlBookInfo &book[])
{
   ArrayResize(book, 0);
   ResetLastError();
   if(!MarketBookGet(g_symbol, book))
   {
      g_domUsable = false;
      g_statusMessage = "MarketBookGet falló";
      Print("[DOM_LIQ] MarketBookGet falló para ", g_symbol, " err=", GetLastError());
      return false;
   }

   if(ArraySize(book) <= 0)
   {
      g_domUsable = false;
      g_statusMessage = "DOM vacío o no disponible";
      return false;
   }

   g_domUsable = true;
   g_statusMessage = "DOM activo";
   return true;
}

// ==============================================================
// Normalización y preprocesado de niveles
// ==============================================================
double BookVolume(const MqlBookInfo &entry)
{
   if(entry.volume_real > 0.0)
      return entry.volume_real;
   return (double)entry.volume;
}

bool IsBidBookType(const ENUM_BOOK_TYPE type)
{
   return (type == BOOK_TYPE_BUY || type == BOOK_TYPE_BUY_MARKET);
}

bool IsAskBookType(const ENUM_BOOK_TYPE type)
{
   return (type == BOOK_TYPE_SELL || type == BOOK_TYPE_SELL_MARKET);
}

void SortLevelsByPrice(LiquidityLevel &levels[])
{
   int n = ArraySize(levels);
   for(int i = 0; i < n - 1; ++i)
   {
      int best = i;
      for(int j = i + 1; j < n; ++j)
      {
         if(levels[j].price < levels[best].price)
            best = j;
      }
      if(best != i)
      {
         LiquidityLevel tmp = levels[i];
         levels[i] = levels[best];
         levels[best] = tmp;
      }
   }
}

void NormalizeBookLevels(const MqlBookInfo &book[], LiquidityLevel &levels[])
{
   ArrayResize(levels, 0);

   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double mid = (bid > 0.0 && ask > 0.0 ? (bid + ask) * 0.5 : SymbolInfoDouble(g_symbol, SYMBOL_LAST));
   if(mid <= 0.0)
      mid = bid;

   double radius = InpMaxAnalysisRadiusTicks * g_tickSize;

   for(int i = 0; i < ArraySize(book); ++i)
   {
      double vol = BookVolume(book[i]);
      if(vol <= 0.0)
         continue;

      double price = book[i].price;
      if(price <= 0.0)
         continue;

      if(radius > 0.0 && MathAbs(price - mid) > radius)
         continue;

      LiquidityLevel lvl;
      lvl.price = price;
      lvl.volume = vol;
      lvl.side = DOM_SIDE_MIXED;

      if(IsBidBookType(book[i].type))
         lvl.side = DOM_SIDE_BID;
      else if(IsAskBookType(book[i].type))
         lvl.side = DOM_SIDE_ASK;
      else
         continue;

      int n = ArraySize(levels);
      ArrayResize(levels, n + 1);
      levels[n] = lvl;
   }

   SortLevelsByPrice(levels);
}

// ==============================================================
// Agrupación de niveles en zonas
// ==============================================================
void DetermineZoneSide(LiquidityZone &zone)
{
   if(zone.bidVolume > 0.0 && zone.askVolume <= 0.0)
      zone.side = DOM_SIDE_BID;
   else if(zone.askVolume > 0.0 && zone.bidVolume <= 0.0)
      zone.side = DOM_SIDE_ASK;
   else
      zone.side = DOM_SIDE_MIXED;
}

void GroupLevelsIntoZones(const LiquidityLevel &levels[], LiquidityZone &zones[])
{
   ArrayResize(zones, 0);
   if(ArraySize(levels) <= 0)
      return;

   double maxGap = MathMax(g_tickSize, InpGroupTicks * g_tickSize);
   LiquidityZone current;
   ZeroMemory(current);

   current.priceMin = levels[0].price;
   current.priceMax = levels[0].price;
   current.priceMid = levels[0].price;
   current.totalVolume = levels[0].volume;
   current.levelCount = 1;
   current.spanTicks = 1;
   current.snapshotId = g_snapshotId;
   if(levels[0].side == DOM_SIDE_BID)
      current.bidVolume = levels[0].volume;
   else
      current.askVolume = levels[0].volume;

   for(int i = 1; i < ArraySize(levels); ++i)
   {
      bool sameZone = ((levels[i].price - current.priceMax) <= maxGap + (g_tickSize * 0.25));
      if(sameZone)
      {
         if(levels[i].price < current.priceMin)
            current.priceMin = levels[i].price;
         if(levels[i].price > current.priceMax)
            current.priceMax = levels[i].price;
         current.totalVolume += levels[i].volume;
         current.levelCount++;
         if(levels[i].side == DOM_SIDE_BID)
            current.bidVolume += levels[i].volume;
         else
            current.askVolume += levels[i].volume;
      }
      else
      {
         current.priceMid = (current.priceMin + current.priceMax) * 0.5;
         current.spanTicks = (int)MathMax(1.0, MathRound((current.priceMax - current.priceMin) / g_tickSize) + 1.0);
         DetermineZoneSide(current);

         int n = ArraySize(zones);
         ArrayResize(zones, n + 1);
         zones[n] = current;

         ZeroMemory(current);
         current.priceMin = levels[i].price;
         current.priceMax = levels[i].price;
         current.priceMid = levels[i].price;
         current.totalVolume = levels[i].volume;
         current.levelCount = 1;
         current.spanTicks = 1;
         current.snapshotId = g_snapshotId;
         if(levels[i].side == DOM_SIDE_BID)
            current.bidVolume = levels[i].volume;
         else
            current.askVolume = levels[i].volume;
      }
   }

   current.priceMid = (current.priceMin + current.priceMax) * 0.5;
   current.spanTicks = (int)MathMax(1.0, MathRound((current.priceMax - current.priceMin) / g_tickSize) + 1.0);
   DetermineZoneSide(current);
   int n = ArraySize(zones);
   ArrayResize(zones, n + 1);
   zones[n] = current;
}

// ==============================================================
// Persistencia temporal / snapshots
// ==============================================================
void TrimHistory()
{
   int minSnapshot = g_snapshotId - InpSnapshotsToKeep + 1;
   if(minSnapshot <= 0)
      return;

   HistoricalZone filtered[];
   ArrayResize(filtered, 0);

   for(int i = 0; i < ArraySize(g_history); ++i)
   {
      if(g_history[i].snapshotId < minSnapshot)
         continue;
      int n = ArraySize(filtered);
      ArrayResize(filtered, n + 1);
      filtered[n] = g_history[i];
   }

   g_history = filtered;
}

void SaveSnapshotHistory(const LiquidityZone &zones[])
{
   g_snapshotId++;
   for(int i = 0; i < ArraySize(zones); ++i)
   {
      HistoricalZone hz;
      hz.snapshotId = g_snapshotId;
      hz.priceMid = zones[i].priceMid;
      hz.totalVolume = zones[i].totalVolume;
      hz.side = zones[i].side;

      int n = ArraySize(g_history);
      ArrayResize(g_history, n + 1);
      g_history[n] = hz;
   }

   TrimHistory();
}

int ComputeZonePersistence(const LiquidityZone &zone)
{
   if(InpSnapshotsToKeep <= 1)
      return 1;

   int minSnapshot = g_snapshotId - InpSnapshotsToKeep + 1;
   if(minSnapshot < 1)
      minSnapshot = 1;

   int matchedSnapshots[];
   ArrayResize(matchedSnapshots, 0);
   double tol = MathMax(g_tickSize, InpGroupTicks * g_tickSize);

   for(int i = 0; i < ArraySize(g_history); ++i)
   {
      if(g_history[i].snapshotId < minSnapshot)
         continue;
      if(MathAbs(g_history[i].priceMid - zone.priceMid) > tol)
         continue;

      bool exists = false;
      for(int k = 0; k < ArraySize(matchedSnapshots); ++k)
      {
         if(matchedSnapshots[k] == g_history[i].snapshotId)
         {
            exists = true;
            break;
         }
      }
      if(!exists)
      {
         int n = ArraySize(matchedSnapshots);
         ArrayResize(matchedSnapshots, n + 1);
         matchedSnapshots[n] = g_history[i].snapshotId;
      }
   }

   return MathMax(1, ArraySize(matchedSnapshots));
}

// ==============================================================
// Scoring
// ==============================================================
void CalculateScores(LiquidityZone &zones[])
{
   if(ArraySize(zones) <= 0)
      return;

   double priceNow = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double bestAsk = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(priceNow <= 0.0 && bestAsk > 0.0)
      priceNow = bestAsk;
   if(bestAsk > 0.0 && priceNow > 0.0)
      priceNow = (priceNow + bestAsk) * 0.5;

   double maxVol = 0.0;
   double maxDensity = 0.0;
   double maxPersistence = 1.0;

   for(int i = 0; i < ArraySize(zones); ++i)
   {
      zones[i].persistenceCount = ComputeZonePersistence(zones[i]);
      double density = zones[i].totalVolume / MathMax(1.0, (double)zones[i].spanTicks);

      if(zones[i].totalVolume > maxVol)
         maxVol = zones[i].totalVolume;
      if(density > maxDensity)
         maxDensity = density;
      if(zones[i].persistenceCount > maxPersistence)
         maxPersistence = (double)zones[i].persistenceCount;
   }

   double weightSum = InpWeightVolume + InpWeightDensity + InpWeightPersistence +
                      InpWeightProximity + InpWeightImbalance;
   if(weightSum <= 0.0)
      weightSum = 1.0;

   double radius = MathMax(g_tickSize, InpMaxAnalysisRadiusTicks * g_tickSize);

   for(int i = 0; i < ArraySize(zones); ++i)
   {
      double volumeNorm = (maxVol > 0.0 ? zones[i].totalVolume / maxVol : 0.0);
      double density = zones[i].totalVolume / MathMax(1.0, (double)zones[i].spanTicks);
      double densityNorm = (maxDensity > 0.0 ? density / maxDensity : 0.0);
      double persistenceNorm = zones[i].persistenceCount / MathMax(1.0, maxPersistence);
      double proximityNorm = 1.0 - MathMin(1.0, MathAbs(zones[i].priceMid - priceNow) / radius);

      double imbalanceNorm = 0.0;
      if(zones[i].totalVolume > 0.0)
         imbalanceNorm = MathAbs(zones[i].bidVolume - zones[i].askVolume) / zones[i].totalVolume;
      if(zones[i].side != DOM_SIDE_MIXED)
         imbalanceNorm = MathMax(imbalanceNorm, 0.85);

      double weighted = volumeNorm * InpWeightVolume +
                        densityNorm * InpWeightDensity +
                        persistenceNorm * InpWeightPersistence +
                        proximityNorm * InpWeightProximity +
                        imbalanceNorm * InpWeightImbalance;

      zones[i].score = MathMax(0.0, MathMin(100.0, 100.0 * weighted / weightSum));
   }
}

// ==============================================================
// Ordenación y filtrado
// ==============================================================
void SortZonesByScore(LiquidityZone &zones[])
{
   int n = ArraySize(zones);
   double priceNow = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(ask > 0.0 && priceNow > 0.0)
      priceNow = (ask + priceNow) * 0.5;

   for(int i = 0; i < n - 1; ++i)
   {
      int best = i;
      for(int j = i + 1; j < n; ++j)
      {
         if(zones[j].score > zones[best].score)
            best = j;
         else if(zones[j].score == zones[best].score)
         {
            double dj = MathAbs(zones[j].priceMid - priceNow);
            double db = MathAbs(zones[best].priceMid - priceNow);
            if(dj < db)
               best = j;
         }
      }
      if(best != i)
      {
         LiquidityZone tmp = zones[i];
         zones[i] = zones[best];
         zones[best] = tmp;
      }
   }
}

void FilterStrongZones(const LiquidityZone &allZones[], LiquidityZone &outZones[])
{
   ArrayResize(outZones, 0);
   if(ArraySize(allZones) <= 0)
      return;

   LiquidityZone work[];
   ArrayResize(work, ArraySize(allZones));
   for(int i = 0; i < ArraySize(allZones); ++i)
      work[i] = allZones[i];

   SortZonesByScore(work);

   for(int i = 0; i < ArraySize(work); ++i)
   {
      if(work[i].score < InpScoreMin)
         continue;

      int n = ArraySize(outZones);
      ArrayResize(outZones, n + 1);
      outZones[n] = work[i];

      if(ArraySize(outZones) >= InpTopNZones)
         break;
   }
}

// ==============================================================
// Dibujo
// ==============================================================
datetime ChartLeftTime()
{
   long firstVisible = ChartGetInteger(0, CHART_FIRST_VISIBLE_BAR, 0);
   if(firstVisible < 0)
      firstVisible = 200;
   return iTime(g_symbol, PERIOD_CURRENT, (int)firstVisible);
}

datetime ChartRightTime()
{
   datetime t0 = iTime(g_symbol, PERIOD_CURRENT, 0);
   return t0 + (datetime)(PeriodSeconds(PERIOD_CURRENT) * 2);
}

string ZoneKey(const LiquidityZone &zone)
{
   long key = (long)MathRound(zone.priceMid / MathMax(_Point, g_point));
   return SideCode(zone.side) + "_" + LongToString(key);
}

void DrawOrUpdateZone(const LiquidityZone &zone, string &activeNames[])
{
   string key = ZoneKey(zone);
   string rectName = g_prefix + "ZONE_" + key;
   string lineName = g_prefix + "LINE_" + key;
   string textName = g_prefix + "TEXT_" + key;

   datetime t1 = ChartLeftTime();
   datetime t2 = ChartRightTime();
   color zoneColor = SideColor(zone.side);
   color fillColor = ColorToARGB(zoneColor, InpZoneAlpha);

   if(ObjectFind(0, rectName) < 0)
   {
      if(CreateObjectChecked(rectName, OBJ_RECTANGLE, t1, zone.priceMax, t2, zone.priceMin))
      {
         ObjectSetInteger(0, rectName, OBJPROP_FILL, true);
         ObjectSetInteger(0, rectName, OBJPROP_BACK, true);
         ObjectSetInteger(0, rectName, OBJPROP_SELECTABLE, false);
      }
   }
   else
   {
      ObjectMove(0, rectName, 0, t1, zone.priceMax);
      ObjectMove(0, rectName, 1, t2, zone.priceMin);
   }
   if(ObjectFind(0, rectName) >= 0)
   {
      ObjectSetInteger(0, rectName, OBJPROP_COLOR, fillColor);
      ObjectSetInteger(0, rectName, OBJPROP_WIDTH, 1);
   }

   if(ObjectFind(0, lineName) < 0)
      CreateObjectChecked(lineName, OBJ_HLINE, 0, zone.priceMid);
   if(ObjectFind(0, lineName) >= 0)
   {
      ObjectSetDouble(0, lineName, OBJPROP_PRICE, zone.priceMid);
      ObjectSetInteger(0, lineName, OBJPROP_COLOR, zoneColor);
      ObjectSetInteger(0, lineName, OBJPROP_WIDTH, InpLineWidth);
      ObjectSetInteger(0, lineName, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, false);
   }

   if(InpShowLabels)
   {
      string txt = DoubleToString(zone.priceMid, _Digits) +
                   " | Vol " + DoubleToString(zone.totalVolume, 2) +
                   " | " + SideCode(zone.side);
      if(InpShowNormalizedScore)
         txt += " | S " + DoubleToString(zone.score, 0);

      datetime tLabel = iTime(g_symbol, PERIOD_CURRENT, 0) + (datetime)PeriodSeconds(PERIOD_CURRENT);
      if(ObjectFind(0, textName) < 0)
         CreateObjectChecked(textName, OBJ_TEXT, tLabel, zone.priceMid);
      if(ObjectFind(0, textName) >= 0)
      {
         ObjectMove(0, textName, 0, tLabel, zone.priceMid);
         ObjectSetString(0, textName, OBJPROP_TEXT, txt);
         ObjectSetInteger(0, textName, OBJPROP_COLOR, zoneColor);
         ObjectSetInteger(0, textName, OBJPROP_FONTSIZE, 8);
         ObjectSetInteger(0, textName, OBJPROP_ANCHOR, ANCHOR_LEFT);
         ObjectSetInteger(0, textName, OBJPROP_SELECTABLE, false);
      }
      AddName(activeNames, textName);
   }

   AddName(activeNames, rectName);
   AddName(activeNames, lineName);
}

void DrawStatusPanel()
{
   string panel = g_prefix + "PANEL";
   string text = "DOM Liquidity Zones\n" +
                 "Symbol: " + g_symbol + "\n" +
                 "Status: " + g_statusMessage + "\n" +
                 "Detected: " + IntegerToString(g_lastDetectedZones) + "\n" +
                 "Drawn: " + IntegerToString(g_lastDrawnZones) + "\n" +
                 "Snapshots: " + IntegerToString(MathMin(g_snapshotId, InpSnapshotsToKeep));

   if(ObjectFind(0, panel) < 0)
      CreateObjectChecked(panel, OBJ_LABEL, 0, 0);

   if(ObjectFind(0, panel) >= 0)
   {
      ObjectSetInteger(0, panel, OBJPROP_CORNER, InpPanelCorner);
      ObjectSetInteger(0, panel, OBJPROP_XDISTANCE, InpPanelX);
      ObjectSetInteger(0, panel, OBJPROP_YDISTANCE, InpPanelY);
      ObjectSetInteger(0, panel, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, panel, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, panel, OBJPROP_TEXT, text);
      ObjectSetInteger(0, panel, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, panel, OBJPROP_BACK, true);
   }
}

void DrawNoDOMMessage()
{
   string panel = g_prefix + "NODOM";
   if(ObjectFind(0, panel) < 0)
      CreateObjectChecked(panel, OBJ_LABEL, 0, 0);

   if(ObjectFind(0, panel) >= 0)
   {
      ObjectSetInteger(0, panel, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, panel, OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(0, panel, OBJPROP_YDISTANCE, 18);
      ObjectSetInteger(0, panel, OBJPROP_COLOR, clrTomato);
      ObjectSetInteger(0, panel, OBJPROP_FONTSIZE, 10);
      ObjectSetString(0, panel, OBJPROP_TEXT,
                      "DOM no disponible o sin datos útiles del broker");
      ObjectSetInteger(0, panel, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, panel, OBJPROP_BACK, true);
   }
}

void DrawZones(const LiquidityZone &zones[])
{
   string activeNames[];
   ArrayResize(activeNames, 0);

   for(int i = 0; i < ArraySize(zones); ++i)
      DrawOrUpdateZone(zones[i], activeNames);

   AddName(activeNames, g_prefix + "PANEL");
   AddName(activeNames, g_prefix + "NODOM");

   CleanupUnusedObjects(activeNames);
   DrawStatusPanel();
   if(!g_domUsable)
      DrawNoDOMMessage();
   else if(ObjectFind(0, g_prefix + "NODOM") >= 0)
      ObjectDelete(0, g_prefix + "NODOM");
}

// ==============================================================
// Pipeline principal
// ==============================================================
void RefreshDOMView(const bool force)
{
   uint nowMs = NowMs();
   if(!force && (nowMs - g_lastRefreshMs) < (uint)MathMax(50, InpMinRefreshMs))
      return;
   g_lastRefreshMs = nowMs;

   MqlBookInfo book[];
   if(!ReadBook(book))
   {
      g_lastDetectedZones = 0;
      g_lastDrawnZones = 0;
      ClearObjectsByPrefix(g_prefix + "ZONE_");
      ClearObjectsByPrefix(g_prefix + "LINE_");
      ClearObjectsByPrefix(g_prefix + "TEXT_");
      DrawStatusPanel();
      DrawNoDOMMessage();
      ChartRedraw(0);
      return;
   }

   LiquidityLevel levels[];
   NormalizeBookLevels(book, levels);

   LiquidityZone zones[];
   GroupLevelsIntoZones(levels, zones);
   g_lastDetectedZones = ArraySize(zones);

   SaveSnapshotHistory(zones);
   CalculateScores(zones);

   LiquidityZone filtered[];
   FilterStrongZones(zones, filtered);
   g_lastDrawnZones = ArraySize(filtered);

   DrawZones(filtered);
   ChartRedraw(0);
}

// ==============================================================
// Eventos estándar del indicador
// ==============================================================
int OnInit()
{
   g_symbol = _Symbol;
   g_point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   g_tickSize = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_tickSize <= 0.0)
      g_tickSize = g_point;

   IndicatorSetString(INDICATOR_SHORTNAME, "DOM Liquidity Zones Score");

   SubscribeDOM();
   RefreshDOMView(true);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ReleaseDOM();
   ClearObjectsByPrefix(g_prefix);
}

void OnBookEvent(const string &symbol)
{
   if(symbol != g_symbol)
      return;
   RefreshDOMView(false);
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
   DrawStatusPanel();
   if(!g_domUsable)
      DrawNoDOMMessage();
   return rates_total;
}
