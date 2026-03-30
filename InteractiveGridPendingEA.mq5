#property strict
#property version   "1.00"
#property description "EA interactif: creation d'une grille d'ordres pending via touche A + clic souris"

#include <Trade/Trade.mqh>

input int    NumberOfOrders        = 10;
input double FixedLot              = 1.0;
input int    MinGridDistancePoints = 100;

enum ProcedureState
{
   IDLE = 0,
   WAIT_LINE1,
   WAIT_LINE2,
   WAIT_CONFIRM
};

CTrade g_trade;

ProcedureState g_state = IDLE;

string g_objPrefix = "GRID_TMP_";
string g_line1Name = "";
string g_line2Name = "";
string g_confirmLineName = "";

bool   g_line1Fixed = false;
bool   g_line2Fixed = false;
double g_line1Price = 0.0;
double g_line2Price = 0.0;

int    g_selectedOrderCount = 0;

//--- Helpers de symbole
int SymbolDigits()
{
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
}

double SymbolPoint()
{
   return SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

double SymbolTickSize()
{
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0)
      tick = SymbolPoint();
   return tick;
}

double NormalizePriceToTick(const double price)
{
   const double tick   = SymbolTickSize();
   const double snapped = MathRound(price / tick) * tick;
   return NormalizeDouble(snapped, SymbolDigits());
}

double NormalizeVolume(const double volume)
{
   const double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(volStep <= 0.0)
      return MathMax(volMin, MathMin(volMax, volume));

   double v = MathFloor(volume / volStep) * volStep;
   if(v < volMin)
      v = volMin;
   if(v > volMax)
      v = volMax;

   return v;
}

bool XYToPrice(const int x, const int y, double &price)
{
   datetime t = 0;
   int      subWindow = 0;
   if(!ChartXYToTimePrice(0, x, y, subWindow, t, price))
      return false;

   price = NormalizePriceToTick(price);
   return true;
}

string MakeObjectName(const string suffix)
{
   return g_objPrefix + IntegerToString((int)ChartID()) + "_" + suffix;
}

void CleanupTemporaryObjects()
{
   if(g_line1Name != "")
      ObjectDelete(0, g_line1Name);
   if(g_line2Name != "")
      ObjectDelete(0, g_line2Name);
   if(g_confirmLineName != "")
      ObjectDelete(0, g_confirmLineName);

   g_line1Name  = "";
   g_line2Name  = "";
   g_confirmLineName = "";
   g_line1Fixed = false;
   g_line2Fixed = false;
   g_line1Price = 0.0;
   g_line2Price = 0.0;
   g_selectedOrderCount = 0;

   Comment("");
   ChartRedraw(0);
}

void CancelProcedure(const string reason)
{
   Print("Procedure annulee: ", reason);
   CleanupTemporaryObjects();
   g_state = IDLE;
}

bool CreateOrMoveHLine(const string name, const double price, const color clr)
{
   if(ObjectFind(0, name) < 0)
   {
      if(!ObjectCreate(0, name, OBJ_HLINE, 0, 0, price))
      {
         Print("Echec creation ligne ", name, " err=", GetLastError());
         return false;
      }
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTED, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }

   if(!ObjectSetDouble(0, name, OBJPROP_PRICE, price))
   {
      Print("Echec mise a jour ligne ", name, " err=", GetLastError());
      return false;
   }

   return true;
}

void StartProcedure()
{
   if(g_state != IDLE)
      CancelProcedure("Redemarrage a la demande");

   CleanupTemporaryObjects();
   g_line1Name = MakeObjectName("TempLine1");
   g_line2Name = MakeObjectName("TempLine2");
   g_confirmLineName = MakeObjectName("ConfirmLine");
   g_selectedOrderCount = NumberOfOrders;

   g_state = WAIT_LINE1;
   Print("Procedure demarree: placez la ligne 1 avec clic gauche.");
}

void UpdateTemporaryLineWithMouse(const int x, const int y)
{
   if(g_state != WAIT_LINE1 && g_state != WAIT_LINE2)
      return;

   double mousePrice = 0.0;
   if(!XYToPrice(x, y, mousePrice))
      return;

   if(g_state == WAIT_LINE1)
   {
      g_line1Price = mousePrice;
      CreateOrMoveHLine(g_line1Name, g_line1Price, clrDodgerBlue);
   }
   else if(g_state == WAIT_LINE2)
   {
      g_line2Price = mousePrice;
      CreateOrMoveHLine(g_line2Name, g_line2Price, clrTomato);
   }

   ChartRedraw(0);
}

void FixLine1(const int x, const int y)
{
   double price = 0.0;
   if(!XYToPrice(x, y, price))
   {
      Print("Impossible de fixer la ligne 1: conversion XY->prix echouee.");
      return;
   }

   g_line1Price = price;
   if(!CreateOrMoveHLine(g_line1Name, g_line1Price, clrDodgerBlue))
      return;

   g_line1Fixed = true;
   g_state = WAIT_LINE2;
   Print("Ligne 1 fixee a ", DoubleToString(g_line1Price, SymbolDigits()), ". Placez la ligne 2.");
}

void FixLine2(const int x, const int y)
{
   double price = 0.0;
   if(!XYToPrice(x, y, price))
   {
      Print("Impossible de fixer la ligne 2: conversion XY->prix echouee.");
      return;
   }

   g_line2Price = price;
   if(!CreateOrMoveHLine(g_line2Name, g_line2Price, clrTomato))
      return;

   g_line2Fixed = true;
   g_state = WAIT_CONFIRM;

   const double previewPrice = NormalizePriceToTick((g_line1Price + g_line2Price) * 0.5);
   if(!CreateOrMoveHLine(g_confirmLineName, previewPrice, clrSilver))
   {
      CancelProcedure("Impossible de creer la ligne de confirmation.");
      return;
   }

   Print("Ligne 2 fixee a ", DoubleToString(g_line2Price, SymbolDigits()),
         ". Etape de confirmation: molette pour ajuster le nombre d'ordres, clic gauche pour valider.");
   Comment("Confirmation grille\nOrdres: ", g_selectedOrderCount, "\nMolette: +/- ordres\nClic gauche: valider");
   ChartRedraw(0);
}

void AdjustOrderCountWithWheel(const int wheelDelta)
{
   if(g_state != WAIT_CONFIRM)
      return;

   if(wheelDelta == 0)
      return;

   const int minOrders = 2;
   const int maxOrders = 200;
   const int step = (wheelDelta > 0) ? 1 : -1;

   const int updated = (int)MathMax(minOrders, MathMin(maxOrders, g_selectedOrderCount + step));
   if(updated == g_selectedOrderCount)
      return;

   g_selectedOrderCount = updated;
   Print("Nombre d'ordres ajuste a ", g_selectedOrderCount, " (molette=", wheelDelta, ").");
   Comment("Confirmation grille\nOrdres: ", g_selectedOrderCount, "\nMolette: +/- ordres\nClic gauche: valider");
   ChartRedraw(0);
}

bool PreparePendingPrice(const double target,
                         ENUM_ORDER_TYPE &type,
                         double &preparedPrice)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("SymbolInfoTick echoue, impossible de preparer le pending.");
      return false;
   }

   const double tickSize   = SymbolTickSize();
   const double point      = SymbolPoint();
   const int stopsLevel    = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freezeLevel   = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   const int minDistPoints = MathMax(stopsLevel, freezeLevel);
   const double minDist    = minDistPoints * point;

   const double reference = (tick.bid + tick.ask) * 0.5;

   // Type selon la position du niveau vs prix courant.
   if(target < reference)
      type = ORDER_TYPE_BUY_LIMIT;
   else if(target > reference)
      type = ORDER_TYPE_SELL_LIMIT;
   else
   {
      // Cas egal: choisir le pending le plus proche mais valide.
      const double buyCandidate  = NormalizeDouble(MathFloor((tick.ask - minDist) / tickSize) * tickSize, SymbolDigits());
      const double sellCandidate = NormalizeDouble(MathCeil((tick.bid + minDist) / tickSize) * tickSize, SymbolDigits());

      if(MathAbs(target - buyCandidate) <= MathAbs(target - sellCandidate))
         type = ORDER_TYPE_BUY_LIMIT;
      else
         type = ORDER_TYPE_SELL_LIMIT;
   }

   preparedPrice = NormalizePriceToTick(target);

   // Ajustement pour respecter la distance mini.
   if(type == ORDER_TYPE_BUY_LIMIT)
   {
      const double maxAllowed = tick.ask - minDist;
      if(preparedPrice > maxAllowed)
         preparedPrice = NormalizeDouble(MathFloor(maxAllowed / tickSize) * tickSize, SymbolDigits());

      if(preparedPrice >= tick.ask)
         preparedPrice = NormalizeDouble(MathFloor((tick.ask - minDist) / tickSize) * tickSize, SymbolDigits());

      if(preparedPrice <= 0.0)
         return false;

      if((tick.ask - preparedPrice) + (point * 0.1) < minDist)
         return false;
   }
   else if(type == ORDER_TYPE_SELL_LIMIT)
   {
      const double minAllowed = tick.bid + minDist;
      if(preparedPrice < minAllowed)
         preparedPrice = NormalizeDouble(MathCeil(minAllowed / tickSize) * tickSize, SymbolDigits());

      if(preparedPrice <= tick.bid)
         preparedPrice = NormalizeDouble(MathCeil((tick.bid + minDist) / tickSize) * tickSize, SymbolDigits());

      if(preparedPrice <= 0.0)
         return false;

      if((preparedPrice - tick.bid) + (point * 0.1) < minDist)
         return false;
   }

   preparedPrice = NormalizePriceToTick(preparedPrice);
   return (preparedPrice > 0.0);
}

void BuildGridOrders(const int orderCount)
{
   if(!g_line1Fixed || !g_line2Fixed)
   {
      Print("Grid non construite: lignes non fixees.");
      CancelProcedure("Etat invalide");
      return;
   }

   if(orderCount < 2)
   {
      Print("Le nombre d'ordres doit etre >= 2 (actuel=", orderCount, ").");
      CancelProcedure("Configuration invalide");
      return;
   }

   const double high = MathMax(g_line1Price, g_line2Price);
   const double low  = MathMin(g_line1Price, g_line2Price);

   const double distance = MathAbs(high - low);
   const double minDistance = MinGridDistancePoints * SymbolPoint();

   if(distance < minDistance)
   {
      Print("Ecart insuffisant entre lignes. Distance=", DoubleToString(distance, SymbolDigits()),
            " min requise=", DoubleToString(minDistance, SymbolDigits()));
      CancelProcedure("Distance minimale non respectee");
      return;
   }

   const double volume = NormalizeVolume(FixedLot);
   if(volume <= 0.0)
   {
      Print("Volume invalide apres normalisation.");
      CancelProcedure("Volume invalide");
      return;
   }

   const double step = (high - low) / (orderCount - 1);

   int placed = 0;
   int failed = 0;

   for(int i = 0; i < orderCount; ++i)
   {
      const double rawPrice = low + (step * i);
      ENUM_ORDER_TYPE orderType;
      double finalPrice = 0.0;

      if(!PreparePendingPrice(rawPrice, orderType, finalPrice))
      {
         ++failed;
         Print("[", i + 1, "/", orderCount, "] Niveau ignore (prix non preparable): ",
               DoubleToString(rawPrice, SymbolDigits()));
         continue;
      }

      bool sent = false;
      ResetLastError();

      if(orderType == ORDER_TYPE_BUY_LIMIT)
         sent = g_trade.BuyLimit(volume, finalPrice, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "");
      else if(orderType == ORDER_TYPE_SELL_LIMIT)
         sent = g_trade.SellLimit(volume, finalPrice, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "");

      if(!sent)
      {
         ++failed;
         Print("[", i + 1, "/", orderCount, "] Echec envoi ", EnumToString(orderType),
               " @ ", DoubleToString(finalPrice, SymbolDigits()),
               " retcode=", g_trade.ResultRetcode(),
               " desc=", g_trade.ResultRetcodeDescription(),
               " err=", GetLastError());
      }
      else
      {
         ++placed;
         Print("[", i + 1, "/", orderCount, "] OK ", EnumToString(orderType),
               " @ ", DoubleToString(finalPrice, SymbolDigits()),
               " ticket=", g_trade.ResultOrder());
      }
   }

   Print("Grille terminee. Ordres demandes=", orderCount, " Placed=", placed, " Failed=", failed);

   CleanupTemporaryObjects();
   g_state = IDLE;
}

int OnInit()
{
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   ChartSetInteger(0, CHART_EVENT_MOUSE_WHEEL, true);

   Print("EA initialise. Appuyez sur A pour lancer la procedure de grille.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   CleanupTemporaryObjects();
}

void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(id == CHARTEVENT_KEYDOWN)
   {
      const int keyCode = (int)lparam;

      if(g_state == IDLE)
      {
         if(keyCode == 65 || keyCode == 97) // A / a
            StartProcedure();
      }
      else
      {
         CancelProcedure("Touche clavier detectee en cours de procedure");
      }
      return;
   }

   if(id == CHARTEVENT_MOUSE_MOVE)
   {
      UpdateTemporaryLineWithMouse((int)lparam, (int)dparam);
      return;
   }

   if(id == CHARTEVENT_MOUSE_WHEEL)
   {
      AdjustOrderCountWithWheel((int)dparam);
      return;
   }

   if(id == CHARTEVENT_CLICK)
   {
      if(g_state == WAIT_LINE1)
      {
         FixLine1((int)lparam, (int)dparam);
      }
      else if(g_state == WAIT_LINE2)
      {
         FixLine2((int)lparam, (int)dparam);
      }
      else if(g_state == WAIT_CONFIRM)
      {
         Print("Validation utilisateur. Envoi de la grille...");
         BuildGridOrders(g_selectedOrderCount);
      }
   }
}
