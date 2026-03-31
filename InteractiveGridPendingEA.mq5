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
string g_confirmOrdersPrefix = "";

bool   g_line1Fixed = false;
bool   g_line2Fixed = false;
double g_line1Price = 0.0;
double g_line2Price = 0.0;

int    g_selectedOrderCount = 0;

//====================== Money Manager integration ==========================
enum MM_SetMode
{
   MM_SET_MODE_NONE = 0,
   MM_SET_MODE_SL   = 1,
   MM_SET_MODE_TP   = 2
};

bool   MM_HandleControls(const int id, const long &lparam, const double &dparam, const string &sparam);
void   MM_CreateControls();
void   MM_DeleteControls();
void   MM_CreateInfoPanel();
void   MM_DeleteInfoPanel();
void   MM_UpdateInfoPanelForSymbol(const string symbol);
void   MM_StartSetMode(const MM_SetMode mode);
void   MM_CancelSetMode();
int    MM_AdjustPendingLimitVolumes_Recreate(const string symbol, const int direction);
int    MM_SetPendingLimitSL_All(const string symbol, const double sl_raw);
int    MM_SetPendingLimitTP_All(const string symbol, const double tp_raw);
int    MM_SetOpenPositionsSL_All_CurrentPrice(const string symbol, const double sl_raw);
int    MM_SetOpenPositionsTP_All_CurrentPrice(const string symbol, const double tp_raw);
double MM_NormalizePriceToTick(const string symbol, double price);
double MM_NormalizeVolumeToStep(const string symbol, double vol);

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
   const int totalObjects = ObjectsTotal(0, -1, -1);
   for(int i = totalObjects - 1; i >= 0; --i)
   {
      const string name = ObjectName(0, i, -1, -1);
      if(g_confirmOrdersPrefix != "" && StringFind(name, g_confirmOrdersPrefix) == 0)
         ObjectDelete(0, name);
   }

   g_line1Name  = "";
   g_line2Name  = "";
   g_confirmOrdersPrefix = "";
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
   g_confirmOrdersPrefix = MakeObjectName("ConfirmOrder_");
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

void RenderOrderPreview()
{
   if(g_state != WAIT_CONFIRM || !g_line1Fixed || !g_line2Fixed)
      return;

   const int totalObjects = ObjectsTotal(0, -1, -1);
   for(int i = totalObjects - 1; i >= 0; --i)
   {
      const string name = ObjectName(0, i, -1, -1);
      if(g_confirmOrdersPrefix != "" && StringFind(name, g_confirmOrdersPrefix) == 0)
         ObjectDelete(0, name);
   }

   if(g_selectedOrderCount < 2)
      return;

   const double high = MathMax(g_line1Price, g_line2Price);
   const double low  = MathMin(g_line1Price, g_line2Price);
   const double step = (high - low) / (g_selectedOrderCount - 1);

   int validOrders = 0;

   for(int i = 0; i < g_selectedOrderCount; ++i)
   {
      const double rawPrice = low + (step * i);
      ENUM_ORDER_TYPE orderType;
      double finalPrice = 0.0;
      color previewColor = clrSilver;

      if(PreparePendingPrice(rawPrice, orderType, finalPrice))
      {
         ++validOrders;
         previewColor = (orderType == ORDER_TYPE_BUY_LIMIT) ? clrLime : clrRed;
      }
      else
      {
         finalPrice = NormalizePriceToTick(rawPrice);
      }

      const string previewName = g_confirmOrdersPrefix + IntegerToString(i + 1);
      if(!CreateOrMoveHLine(previewName, finalPrice, previewColor))
      {
         Print("Impossible d'afficher la preview #", i + 1);
      }
   }

   Comment("Confirmation grille\nOrdres: ", g_selectedOrderCount,
           " (valides: ", validOrders, ")\nVert=BUY_LIMIT Rouge=SELL_LIMIT Gris=non placable\nMolette: +/- ordres\nClic gauche: valider");
   ChartRedraw(0);
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

   Print("Ligne 2 fixee a ", DoubleToString(g_line2Price, SymbolDigits()),
         ". Etape de confirmation: molette pour ajuster le nombre d'ordres, clic gauche pour valider.");
   RenderOrderPreview();
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
   RenderOrderPreview();
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
   MM_CreateControls();
   MM_CreateInfoPanel();

   Print("EA initialise. Appuyez sur A pour lancer la procedure de grille.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   CleanupTemporaryObjects();
   MM_CancelSetMode();
   MM_DeleteControls();
   MM_DeleteInfoPanel();
}

void OnTick()
{
   MM_UpdateInfoPanelForSymbol(_Symbol);
}

void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(MM_HandleControls(id, lparam, dparam, sparam))
      return;

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

//====================== Money Manager module ===============================
#define MM_BTN_PLUS      "MM_BTN_PLUS"
#define MM_BTN_MINUS     "MM_BTN_MINUS"
#define MM_BTN_SL        "MM_BTN_SL"
#define MM_BTN_TP        "MM_BTN_TP"
#define MM_GUIDE_LINE    "MM_GUIDE_LINE"
#define MM_PANEL_BG      "MM_PANEL_BG"
#define MM_PANEL_TITLE   "MM_PANEL_TITLE"
#define MM_PANEL_LINE1   "MM_PANEL_LINE1"
#define MM_PANEL_LINE2   "MM_PANEL_LINE2"
#define MM_PANEL_LINE3   "MM_PANEL_LINE3"
#define MM_PANEL_LINE4   "MM_PANEL_LINE4"
#define MM_PANEL_LINE5   "MM_PANEL_LINE5"

input double stepModification = 0.1;

MM_SetMode g_mm_set_mode = MM_SET_MODE_NONE;
bool       g_mm_tracking = false;
int        g_mm_click_guard = 0;

bool MM_CreateButton(const long chart_id,const string name,const string text,int x_dist,int y_dist,int width=40,int height=24,color back=clrDimGray,color fore=clrWhite)
{
   if(ObjectFind(chart_id, name) >= 0) ObjectDelete(chart_id, name);
   if(!ObjectCreate(chart_id, name, OBJ_BUTTON, 0, 0, 0)) return false;
   ObjectSetInteger(chart_id, name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
   ObjectSetInteger(chart_id, name, OBJPROP_XDISTANCE, x_dist);
   ObjectSetInteger(chart_id, name, OBJPROP_YDISTANCE, y_dist);
   ObjectSetInteger(chart_id, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(chart_id, name, OBJPROP_YSIZE, height);
   ObjectSetString(chart_id, name, OBJPROP_TEXT, text);
   ObjectSetInteger(chart_id, name, OBJPROP_COLOR, fore);
   ObjectSetInteger(chart_id, name, OBJPROP_BGCOLOR, back);
   ObjectSetInteger(chart_id, name, OBJPROP_BORDER_COLOR, clrBlack);
   ObjectSetInteger(chart_id, name, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(chart_id, name, OBJPROP_HIDDEN, false);
   ObjectSetInteger(chart_id, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(chart_id, name, OBJPROP_BACK, false);
   ObjectSetInteger(chart_id, name, OBJPROP_ZORDER, 1000);
   return true;
}

bool MM_CreateHLine(const long chart_id, const string name, const double price, color clr)
{
   if(ObjectFind(chart_id, name) >= 0) ObjectDelete(chart_id, name);
   if(!ObjectCreate(chart_id, name, OBJ_HLINE, 0, 0, price)) return false;
   ObjectSetInteger(chart_id, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(chart_id, name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(chart_id, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(chart_id, name, OBJPROP_BACK, false);
   ObjectSetInteger(chart_id, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(chart_id, name, OBJPROP_HIDDEN, true);
   return true;
}

double MM_NormalizeVolumeToStep(const string symbol, double vol)
{
   const double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) return vol;
   const double k = MathRound(vol / step);
   const double v = k * step;
   const int digits = (int)MathMax(0, MathCeil(-MathLog10(step) + 1e-12));
   return NormalizeDouble(v, digits);
}

double MM_NormalizePriceToTick(const string symbol, double price)
{
   const double tick = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   const int digits  = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(tick <= 0.0) return NormalizeDouble(price, digits);
   const double p = MathRound(price / tick) * tick;
   return NormalizeDouble(p, digits);
}

void MM_CreateControls()
{
   const long chart_id = ChartID();
   MM_CreateButton(chart_id, MM_BTN_MINUS, "-", 10, 50, 40, 24, clrFireBrick, clrWhite);
   MM_CreateButton(chart_id, MM_BTN_PLUS,  "+", 55, 50, 40, 24, clrSeaGreen,  clrWhite);
   MM_CreateButton(chart_id, MM_BTN_SL,   "SL", 105, 50, 45, 24, clrDarkOrange, clrWhite);
   MM_CreateButton(chart_id, MM_BTN_TP,   "TP", 155, 50, 45, 24, clrRoyalBlue,  clrWhite);
}

void MM_DeleteControls()
{
   const long chart_id = ChartID();
   ObjectDelete(chart_id, MM_BTN_PLUS);
   ObjectDelete(chart_id, MM_BTN_MINUS);
   ObjectDelete(chart_id, MM_BTN_SL);
   ObjectDelete(chart_id, MM_BTN_TP);
   ObjectDelete(chart_id, MM_GUIDE_LINE);
}

void MM_StartSetMode(const MM_SetMode mode)
{
   g_mm_set_mode = mode;
   g_mm_tracking = true;
   g_mm_click_guard = 0;
   const color line_color = (mode == MM_SET_MODE_SL ? clrOrangeRed : clrDodgerBlue);
   MM_CreateHLine(ChartID(), MM_GUIDE_LINE, SymbolInfoDouble(_Symbol, SYMBOL_BID), line_color);
}

void MM_CancelSetMode()
{
   g_mm_set_mode = MM_SET_MODE_NONE;
   g_mm_tracking = false;
   ObjectDelete(ChartID(), MM_GUIDE_LINE);
}

void MM_UpdateGuideLineFromMouse(const int x, const int y)
{
   if(!g_mm_tracking) return;
   datetime t; double price; int subwin = 0;
   if(!ChartXYToTimePrice(ChartID(), x, y, subwin, t, price)) return;
   price = MM_NormalizePriceToTick(_Symbol, price);
   if(ObjectFind(ChartID(), MM_GUIDE_LINE) < 0)
      MM_CreateHLine(ChartID(), MM_GUIDE_LINE, price, (g_mm_set_mode == MM_SET_MODE_SL ? clrOrangeRed : clrDodgerBlue));
   else
      ObjectSetDouble(ChartID(), MM_GUIDE_LINE, OBJPROP_PRICE, price);
}

bool MM_DeletePendingOrder(const ulong ticket)
{
   MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
   req.action = TRADE_ACTION_REMOVE; req.order = ticket;
   if(!OrderSend(req, res)) return false;
   return (res.retcode == TRADE_RETCODE_DONE);
}

bool MM_RecreateLimitOrderWithVolume(const string symbol,const ENUM_ORDER_TYPE type,const double volume,const double price,const double sl,const double tp,const datetime expiration,const ENUM_ORDER_TYPE_TIME type_time,const ENUM_ORDER_TYPE_FILLING type_filling,const long magic,const string comment)
{
   MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
   req.action = TRADE_ACTION_PENDING; req.symbol = symbol; req.type = type; req.volume = volume; req.price = price; req.sl = sl; req.tp = tp; req.magic = magic; req.comment = comment; req.type_time = type_time; req.expiration = expiration; req.type_filling = type_filling;
   if(!OrderSend(req, res)) return false;
   return (res.retcode == TRADE_RETCODE_DONE);
}

int MM_AdjustPendingLimitVolumes_Recreate(const string symbol, const int direction)
{
   if(direction != 1 && direction != -1) return 0;
   const double step = stepModification;
   const double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0 || vmin <= 0.0 || vmax <= 0.0) return 0;
   ulong tickets[];
   for(int i = 0; i < OrdersTotal(); i++)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      const ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT) continue;
      ArrayResize(tickets, ArraySize(tickets) + 1);
      tickets[ArraySize(tickets) - 1] = ticket;
   }
   int modified = 0;
   for(int j = 0; j < ArraySize(tickets); j++)
   {
      const ulong ticket = tickets[j];
      if(!OrderSelect(ticket)) continue;
      const ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      const double cur_vol = OrderGetDouble(ORDER_VOLUME_CURRENT);
      const double price = OrderGetDouble(ORDER_PRICE_OPEN);
      const double sl = OrderGetDouble(ORDER_SL);
      const double tp = OrderGetDouble(ORDER_TP);
      const datetime expiration = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      const ENUM_ORDER_TYPE_TIME type_time = (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
      const ENUM_ORDER_TYPE_FILLING type_filling = (ENUM_ORDER_TYPE_FILLING)OrderGetInteger(ORDER_TYPE_FILLING);
      const long magic = (long)OrderGetInteger(ORDER_MAGIC);
      const string cmt = OrderGetString(ORDER_COMMENT);
      double new_vol = MM_NormalizeVolumeToStep(symbol, cur_vol + direction * step);
      if(new_vol < vmin) new_vol = vmin;
      if(new_vol > vmax) new_vol = vmax;
      if(MathAbs(new_vol - cur_vol) < (step * 0.5)) continue;
      if(!MM_DeletePendingOrder(ticket)) continue;
      if(MM_RecreateLimitOrderWithVolume(symbol, type, new_vol, price, sl, tp, expiration, type_time, type_filling, magic, cmt)) modified++;
      else MM_RecreateLimitOrderWithVolume(symbol, type, cur_vol, price, sl, tp, expiration, type_time, type_filling, magic, cmt);
   }
   return modified;
}

int MM_SetPendingLimitSL_All(const string symbol, const double sl_raw)
{
   const double new_sl = MM_NormalizePriceToTick(symbol, sl_raw);
   if(new_sl <= 0.0) return 0;
   int modified = 0;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      const ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT) continue;
      const double entry = OrderGetDouble(ORDER_PRICE_OPEN);
      const double tp = OrderGetDouble(ORDER_TP);
      if((type == ORDER_TYPE_BUY_LIMIT && new_sl >= entry) || (type == ORDER_TYPE_SELL_LIMIT && new_sl <= entry)) continue;
      MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
      req.action = TRADE_ACTION_MODIFY; req.order = ticket; req.symbol = symbol; req.price = entry; req.sl = new_sl; req.tp = tp;
      req.type_time = (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
      req.expiration = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE) modified++;
   }
   return modified;
}

int MM_SetPendingLimitTP_All(const string symbol, const double tp_raw)
{
   const double new_tp = MM_NormalizePriceToTick(symbol, tp_raw);
   if(new_tp <= 0.0) return 0;
   int modified = 0;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      const ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT) continue;
      const double entry = OrderGetDouble(ORDER_PRICE_OPEN);
      const double sl = OrderGetDouble(ORDER_SL);
      if((type == ORDER_TYPE_BUY_LIMIT && new_tp <= entry) || (type == ORDER_TYPE_SELL_LIMIT && new_tp >= entry)) continue;
      MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
      req.action = TRADE_ACTION_MODIFY; req.order = ticket; req.symbol = symbol; req.price = entry; req.sl = sl; req.tp = new_tp;
      req.type_time = (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
      req.expiration = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE) modified++;
   }
   return modified;
}

int MM_SetOpenPositionsSL_All_CurrentPrice(const string symbol, const double sl_raw)
{
   const double new_sl = MM_NormalizePriceToTick(symbol, sl_raw);
   if(new_sl <= 0.0) return 0;
   int modified = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      const long ptype = PositionGetInteger(POSITION_TYPE);
      const double tp = PositionGetDouble(POSITION_TP);
      const double current_price = (ptype == POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK);
      if((ptype == POSITION_TYPE_BUY && new_sl >= current_price) || (ptype == POSITION_TYPE_SELL && new_sl <= current_price)) continue;
      MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
      req.action = TRADE_ACTION_SLTP; req.symbol = symbol; req.position = ticket; req.sl = new_sl; req.tp = tp;
      if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE) modified++;
   }
   return modified;
}

int MM_SetOpenPositionsTP_All_CurrentPrice(const string symbol, const double tp_raw)
{
   const double new_tp = MM_NormalizePriceToTick(symbol, tp_raw);
   if(new_tp <= 0.0) return 0;
   int modified = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      const long ptype = PositionGetInteger(POSITION_TYPE);
      const double sl = PositionGetDouble(POSITION_SL);
      const double current_price = (ptype == POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK);
      if((ptype == POSITION_TYPE_BUY && new_tp <= current_price) || (ptype == POSITION_TYPE_SELL && new_tp >= current_price)) continue;
      MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
      req.action = TRADE_ACTION_SLTP; req.symbol = symbol; req.position = ticket; req.sl = sl; req.tp = new_tp;
      if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE) modified++;
   }
   return modified;
}

double MM_OpenPositionsProfit(const string symbol_filter, const bool all_symbols=false, const bool include_swap=true)
{
   double total_profit = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      const string sym = PositionGetString(POSITION_SYMBOL);
      if(!all_symbols && sym != symbol_filter) continue;
      double p = PositionGetDouble(POSITION_PROFIT);
      if(include_swap) p += PositionGetDouble(POSITION_SWAP);
      total_profit += p;
   }
   return total_profit;
}

double MM_PendingLimitRiskBySL(const string symbol)
{
   double total_risk = 0.0;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      const ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT) continue;
      const double volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
      const double entry = OrderGetDouble(ORDER_PRICE_OPEN);
      const double sl = OrderGetDouble(ORDER_SL);
      if(sl <= 0.0) continue;
      if((type == ORDER_TYPE_BUY_LIMIT && sl >= entry) || (type == ORDER_TYPE_SELL_LIMIT && sl <= entry)) continue;
      double profit = 0.0;
      const bool ok = (type == ORDER_TYPE_BUY_LIMIT) ? OrderCalcProfit(ORDER_TYPE_BUY, symbol, volume, entry, sl, profit) : OrderCalcProfit(ORDER_TYPE_SELL, symbol, volume, entry, sl, profit);
      if(ok) total_risk += MathAbs(profit);
   }
   return total_risk;
}

double MM_OpenPositionsRiskBySL_WithSwap(const string symbol_filter, const bool all_symbols=false)
{
   double total_risk = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      const string sym = PositionGetString(POSITION_SYMBOL);
      if(!all_symbols && sym != symbol_filter) continue;
      const long ptype = PositionGetInteger(POSITION_TYPE);
      const double vol = PositionGetDouble(POSITION_VOLUME);
      const double sl = PositionGetDouble(POSITION_SL);
      const double openp = PositionGetDouble(POSITION_PRICE_OPEN);
      const double swap = PositionGetDouble(POSITION_SWAP);
      if(sl <= 0.0) continue;
      if((ptype == POSITION_TYPE_BUY && sl >= openp) || (ptype == POSITION_TYPE_SELL && sl <= openp)) continue;
      double p = 0.0;
      const bool ok = (ptype == POSITION_TYPE_BUY) ? OrderCalcProfit(ORDER_TYPE_BUY, sym, vol, openp, sl, p) : OrderCalcProfit(ORDER_TYPE_SELL, sym, vol, openp, sl, p);
      if(ok && p + swap < 0.0) total_risk += -(p + swap);
   }
   return total_risk;
}

void MM_CreatePanelLine(const string name, const int y)
{
   const long chart_id = ChartID();
   ObjectCreate(chart_id, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(chart_id, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(chart_id, name, OBJPROP_XDISTANCE, 18);
   ObjectSetInteger(chart_id, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(chart_id, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(chart_id, name, OBJPROP_FONTSIZE, 9);
   ObjectSetString(chart_id, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(chart_id, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(chart_id, name, OBJPROP_HIDDEN, true);
}

void MM_CreateInfoPanel()
{
   const long chart_id = ChartID();
   ObjectDelete(chart_id, MM_PANEL_BG); ObjectDelete(chart_id, MM_PANEL_TITLE); ObjectDelete(chart_id, MM_PANEL_LINE1); ObjectDelete(chart_id, MM_PANEL_LINE2); ObjectDelete(chart_id, MM_PANEL_LINE3); ObjectDelete(chart_id, MM_PANEL_LINE4); ObjectDelete(chart_id, MM_PANEL_LINE5);
   ObjectCreate(chart_id, MM_PANEL_BG, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(chart_id, MM_PANEL_BG, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(chart_id, MM_PANEL_BG, OBJPROP_XDISTANCE, 8);
   ObjectSetInteger(chart_id, MM_PANEL_BG, OBJPROP_YDISTANCE, 18);
   ObjectSetInteger(chart_id, MM_PANEL_BG, OBJPROP_XSIZE, 430);
   ObjectSetInteger(chart_id, MM_PANEL_BG, OBJPROP_YSIZE, 110);
   ObjectSetInteger(chart_id, MM_PANEL_BG, OBJPROP_BGCOLOR, clrBlack);
   ObjectSetInteger(chart_id, MM_PANEL_BG, OBJPROP_BORDER_COLOR, clrGold);
   ObjectSetInteger(chart_id, MM_PANEL_BG, OBJPROP_HIDDEN, true);
   ObjectCreate(chart_id, MM_PANEL_TITLE, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(chart_id, MM_PANEL_TITLE, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(chart_id, MM_PANEL_TITLE, OBJPROP_XDISTANCE, 18);
   ObjectSetInteger(chart_id, MM_PANEL_TITLE, OBJPROP_YDISTANCE, 24);
   ObjectSetInteger(chart_id, MM_PANEL_TITLE, OBJPROP_COLOR, clrGold);
   ObjectSetInteger(chart_id, MM_PANEL_TITLE, OBJPROP_FONTSIZE, 10);
   ObjectSetString(chart_id, MM_PANEL_TITLE, OBJPROP_FONT, "Segoe UI Semibold");
   MM_CreatePanelLine(MM_PANEL_LINE1, 45);
   MM_CreatePanelLine(MM_PANEL_LINE2, 60);
   MM_CreatePanelLine(MM_PANEL_LINE3, 75);
   MM_CreatePanelLine(MM_PANEL_LINE4, 90);
   MM_CreatePanelLine(MM_PANEL_LINE5, 105);
}

void MM_DeleteInfoPanel()
{
   const long chart_id = ChartID();
   ObjectDelete(chart_id, MM_PANEL_BG); ObjectDelete(chart_id, MM_PANEL_TITLE); ObjectDelete(chart_id, MM_PANEL_LINE1); ObjectDelete(chart_id, MM_PANEL_LINE2); ObjectDelete(chart_id, MM_PANEL_LINE3); ObjectDelete(chart_id, MM_PANEL_LINE4); ObjectDelete(chart_id, MM_PANEL_LINE5);
}

void MM_UpdateInfoPanel(const string title,const string l1,const string l2,const string l3,const string l4,const string l5)
{
   const long chart_id = ChartID();
   ObjectSetString(chart_id, MM_PANEL_TITLE, OBJPROP_TEXT, title);
   ObjectSetString(chart_id, MM_PANEL_LINE1, OBJPROP_TEXT, l1);
   ObjectSetString(chart_id, MM_PANEL_LINE2, OBJPROP_TEXT, l2);
   ObjectSetString(chart_id, MM_PANEL_LINE3, OBJPROP_TEXT, l3);
   ObjectSetString(chart_id, MM_PANEL_LINE4, OBJPROP_TEXT, l4);
   ObjectSetString(chart_id, MM_PANEL_LINE5, OBJPROP_TEXT, l5);
}

void MM_UpdateInfoPanelForSymbol(const string symbol)
{
   const string ccy = AccountInfoString(ACCOUNT_CURRENCY);
   const double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   const double risk_symbol = MM_PendingLimitRiskBySL(symbol) + MM_OpenPositionsRiskBySL_WithSwap(symbol, false);
   const double risk_global = MM_OpenPositionsRiskBySL_WithSwap("", true);
   const double pct_symbol = (balance > 0.0) ? (risk_symbol / balance * 100.0) : 0.0;
   const double pct_global = (balance > 0.0) ? (risk_global / balance * 100.0) : 0.0;
   const double profit_symbol = MM_OpenPositionsProfit(symbol, false, true);
   const double profit_global = MM_OpenPositionsProfit("", true, true);
   MM_UpdateInfoPanel("Money Manager  " + symbol,
      StringFormat("%-10s : %10.2f%% | Global : %10.2f%%", "Risque", pct_symbol, pct_global),
      StringFormat("%-10s : %10.2f %s | Global : %10.2f %s", "Profit", profit_symbol, ccy, profit_global, ccy),
      StringFormat("%-10s : %10.2f %s", "Balance", balance, ccy),
      StringFormat("%-10s : %10.2f", "Pendings", (double)OrdersTotal()),
      StringFormat("%-10s : %10.2f", "Positions", (double)PositionsTotal()));
}

bool MM_HandleControls(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == MM_BTN_PLUS) { MM_CancelSetMode(); MM_AdjustPendingLimitVolumes_Recreate(_Symbol, +1); return true; }
      if(sparam == MM_BTN_MINUS) { MM_CancelSetMode(); MM_AdjustPendingLimitVolumes_Recreate(_Symbol, -1); return true; }
      if(sparam == MM_BTN_SL) { MM_StartSetMode(MM_SET_MODE_SL); return true; }
      if(sparam == MM_BTN_TP) { MM_StartSetMode(MM_SET_MODE_TP); return true; }
   }
   if(id == CHARTEVENT_MOUSE_MOVE && g_mm_tracking)
   {
      MM_UpdateGuideLineFromMouse((int)lparam, (int)dparam);
      return false;
   }
   if(id == CHARTEVENT_CLICK && g_mm_set_mode != MM_SET_MODE_NONE)
   {
      if(g_mm_click_guard == 0) { g_mm_click_guard++; return true; }
      datetime t; double price; int subwin = 0;
      if(!ChartXYToTimePrice(ChartID(), (int)lparam, (int)dparam, subwin, t, price)) return true;
      price = MM_NormalizePriceToTick(_Symbol, price);
      if(g_mm_set_mode == MM_SET_MODE_SL)
      {
         MM_SetPendingLimitSL_All(_Symbol, price);
         MM_SetOpenPositionsSL_All_CurrentPrice(_Symbol, price);
      }
      else if(g_mm_set_mode == MM_SET_MODE_TP)
      {
         MM_SetPendingLimitTP_All(_Symbol, price);
         MM_SetOpenPositionsTP_All_CurrentPrice(_Symbol, price);
      }
      MM_CancelSetMode();
      return true;
   }
   if(id == CHARTEVENT_KEYDOWN && g_mm_set_mode != MM_SET_MODE_NONE)
   {
      MM_CancelSetMode();
      return true;
   }
   return false;
}
