unit USimUI;

{ HexGate Simulator user interface, drawn with SDL3 (text: SDL3_ttf).

    menu bar     File: Open... (Ctrl+O), Save (Ctrl+S), Save As... (Ctrl+Shift+S), Exit
    edit panel   (right side, E shows / hides it) every setting of the file,
                 one group at a time: a slider per number, four (R, G, B, A)
                 per colour, plus the autopilot's game rules. Changes apply
                 at once; values that feed a cache are rebuilt by the
                 program shortly after the last change (PendingFx).

  Mouse: click a group arrow to switch group, drag a slider, wheel over a
  row to step it (wheel elsewhere scrolls). Keys while the panel is shown:
  Up / Down row, Left / Right step (Shift: x10), PageUp / PageDown / Tab group.

  All coordinates are output pixels. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, SDL3, SDL3_ttf, BGRABitmapTypes, UHexBackground;

type
  TUIAction = (uaNone, uaOpen, uaSave, uaSaveAs, uaExit);

  TEdRow = record
    Group, Name, Hint: string;
    PValue: PSingle;
    PColor: PBGRAPixel;
    Channel: integer;                    // -1 number, 0..3 = R, G, B, A of PColor
    Min, Max: single;
    Decimals: integer;
    Effects: TInvalidateSet;
  end;

  { TSimUI }

  TSimUI = class
  private
    FRen: PSDL_Renderer;
    FFont, FSmall: PTTF_Font;
    FCache: TStringList;                 // text textures
    FRows: array of TEdRow;
    FGroups: TStringList;
    FGroup, FSel, FScroll, FDragRow, FHoverItem: integer;
    FMenuOpen: boolean;
    FW, FH: integer;
    function TextTex(const S: string; C: TSDL_Color; Small: boolean; Wrap: integer;
      out W, H: single): PSDL_Texture;
    procedure DrawText(const S: string; x, y: single; C: TSDL_Color; Small: boolean = False;
      Align: integer = 0; Wrap: integer = 0);
    procedure Fill(x, y, w, h: single; r, g, b, a: byte);
    function Visible: TFPList;           // row indices of the current group (caller frees)
    function RowValue(const R: TEdRow): single;
    procedure SetRowValue(Index: integer; V: single);
    procedure StepRow(Index: integer; Dir: single);
    function PanelX: single;
    function RowsTop: single;
    function RowsHeight: single;
    function RowAt(x, y: single): integer;
    procedure TrackSpan(out x0, x1: single);
    procedure SelectGroup(G: integer);
    procedure EnsureSelVisible;
    function MenuItemAt(x, y: single): integer;
  public
    PanelVisible: boolean;
    Notice: string;                      // shown in the middle while not empty
    Modified: boolean;                   // set by edits, cleared by the program
    PendingFx: TInvalidateSet;           // caches the edits want rebuilt
    LastEdit: QWord;
    constructor Create(ARenderer: PSDL_Renderer; const FontFile: string);
    destructor Destroy; override;
    procedure ClearRows;
    procedure AddRowsFromEngine(Hex: THexBackground);
    procedure AddNumberRow(const Group, Name, Hint: string; P: PSingle; AMin, AMax: single;
      ADecimals: integer);
    function InUI(x, y: single): boolean;
    function MouseDown(x, y: single; Right: boolean): TUIAction;
    procedure MouseMove(x, y: single);
    procedure MouseUp;
    procedure Wheel(x, y, dy: single);
    function KeyDown(Key: TSDL_Keycode; Mods: TSDL_Keymod; out Action: TUIAction): boolean;
    procedure Draw(W, H: integer; const FileTitle: string);
  end;

const
  MenuH = 30;

implementation

const
  PanelW = 430;
  HeaderH = 44;
  RowH = 26;
  HintH = 86;
  MenuItems: array[0..4] of string = ('Open...', 'Save', 'Save As...', '', 'Exit');
  MenuKeys: array[0..4] of string = ('Ctrl+O', 'Ctrl+S', 'Ctrl+Shift+S', '', 'Esc');
  MenuW = 280;
  ItemH = 30;
  ChannelNames: array[0..3] of string = ('R', 'G', 'B', 'A');

type
  TTextTex = class
    Tex: PSDL_Texture;
    W, H: single;
  end;

function Rgb(r, g, b: byte; a: byte = 255): TSDL_Color;
begin
  Result.r := r;
  Result.g := g;
  Result.b := b;
  Result.a := a;
end;

{ TSimUI }

constructor TSimUI.Create(ARenderer: PSDL_Renderer; const FontFile: string);
begin
  FRen := ARenderer;
  if FontFile <> '' then
  begin
    FFont := TTF_OpenFont(PAnsiChar(AnsiString(FontFile)), 16);
    FSmall := TTF_OpenFont(PAnsiChar(AnsiString(FontFile)), 14);
  end;
  FCache := TStringList.Create;
  FCache.Sorted := True;
  FCache.OwnsObjects := True;
  FGroups := TStringList.Create;
  FDragRow := -1;
  FHoverItem := -1;
  PanelVisible := True;
end;

destructor TSimUI.Destroy;
var
  i: integer;
begin
  for i := 0 to FCache.Count - 1 do
    SDL_DestroyTexture(TTextTex(FCache.Objects[i]).Tex);
  FCache.Free;
  FGroups.Free;
  if FFont <> nil then TTF_CloseFont(FFont);
  if FSmall <> nil then TTF_CloseFont(FSmall);
  inherited Destroy;
end;

function TSimUI.TextTex(const S: string; C: TSDL_Color; Small: boolean; Wrap: integer;
  out W, H: single): PSDL_Texture;
var
  Key: string;
  i: integer;
  F: PTTF_Font;
  Surf: PSDL_Surface;
  T: TTextTex;
begin
  Result := nil;
  W := 0;
  H := 0;
  if Small then F := FSmall else F := FFont;
  if (F = nil) or (S = '') then Exit;
  Key := Format('%d|%d|%d,%d,%d,%d|%s', [Ord(Small), Wrap, C.r, C.g, C.b, C.a, S]);
  if not FCache.Find(Key, i) then
  begin
    if FCache.Count > 600 then
    begin
      for i := 0 to FCache.Count - 1 do SDL_DestroyTexture(TTextTex(FCache.Objects[i]).Tex);
      FCache.Clear;
    end;
    if Wrap > 0 then
      Surf := TTF_RenderText_Blended_Wrapped(F, PAnsiChar(AnsiString(S)), 0, C, Wrap)
    else
      Surf := TTF_RenderText_Blended(F, PAnsiChar(AnsiString(S)), 0, C);
    T := TTextTex.Create;
    if Surf <> nil then
    begin
      T.Tex := SDL_CreateTextureFromSurface(FRen, Surf);
      T.W := Surf^.w;
      T.H := Surf^.h;
      SDL_DestroySurface(Surf);
    end;
    i := FCache.AddObject(Key, T);
  end;
  T := TTextTex(FCache.Objects[i]);
  W := T.W;
  H := T.H;
  Result := T.Tex;
end;

// Align: 0 left, 1 centre, 2 right
procedure TSimUI.DrawText(const S: string; x, y: single; C: TSDL_Color; Small: boolean;
  Align: integer; Wrap: integer);
var
  T: PSDL_Texture;
  Dst: TSDL_FRect;
  w, h: single;
begin
  T := TextTex(S, C, Small, Wrap, w, h);
  if T = nil then Exit;
  case Align of
    1: x := x - w / 2;
    2: x := x - w;
  end;
  Dst.x := Round(x);
  Dst.y := Round(y);
  Dst.w := w;
  Dst.h := h;
  SDL_RenderTexture(FRen, T, nil, @Dst);
end;

procedure TSimUI.Fill(x, y, w, h: single; r, g, b, a: byte);
var
  Rc: TSDL_FRect;
begin
  Rc.x := x;
  Rc.y := y;
  Rc.w := w;
  Rc.h := h;
  SDL_SetRenderDrawColor(FRen, r, g, b, a);
  SDL_RenderFillRect(FRen, @Rc);
end;

{ ----------------------------------------------------------------- rows }

procedure TSimUI.ClearRows;
begin
  FRows := nil;
  FGroups.Clear;
  FSel := 0;
  FScroll := 0;
  FDragRow := -1;
end;

procedure TSimUI.AddRowsFromEngine(Hex: THexBackground);
var
  i, c, n: integer;
  P: TParamInfo;
begin
  for i := 0 to High(Hex.Params) do
  begin
    P := Hex.Params[i];
    if FGroups.IndexOf(P.Group) < 0 then FGroups.Add(P.Group);
    if P.Kind = pkFloat then
    begin
      n := Length(FRows);
      SetLength(FRows, n + 1);
      FRows[n].Group := P.Group;
      FRows[n].Name := P.Name;
      FRows[n].Hint := P.Hint;
      FRows[n].PValue := P.PValue;
      FRows[n].PColor := nil;
      FRows[n].Channel := -1;
      FRows[n].Min := P.Min;
      FRows[n].Max := P.Max;
      FRows[n].Decimals := P.Decimals;
      FRows[n].Effects := P.Effects;
    end
    else
      for c := 0 to 3 do
      begin
        n := Length(FRows);
        SetLength(FRows, n + 1);
        FRows[n].Group := P.Group;
        FRows[n].Name := P.Name;
        FRows[n].Hint := P.Hint + ' (' + ChannelNames[c] + ' channel, 0..255)';
        FRows[n].PValue := nil;
        FRows[n].PColor := P.PColor;
        FRows[n].Channel := c;
        FRows[n].Min := 0;
        FRows[n].Max := 255;
        FRows[n].Decimals := 0;
        FRows[n].Effects := P.Effects;
      end;
  end;
  if FGroup >= FGroups.Count then FGroup := 0;
end;

procedure TSimUI.AddNumberRow(const Group, Name, Hint: string; P: PSingle; AMin, AMax: single;
  ADecimals: integer);
var
  n: integer;
begin
  if FGroups.IndexOf(Group) < 0 then FGroups.Add(Group);
  n := Length(FRows);
  SetLength(FRows, n + 1);
  FRows[n].Group := Group;
  FRows[n].Name := Name;
  FRows[n].Hint := Hint;
  FRows[n].PValue := P;
  FRows[n].PColor := nil;
  FRows[n].Channel := -1;
  FRows[n].Min := AMin;
  FRows[n].Max := AMax;
  FRows[n].Decimals := ADecimals;
  FRows[n].Effects := [];
end;

function TSimUI.Visible: TFPList;
var
  i: integer;
begin
  Result := TFPList.Create;
  if FGroups.Count = 0 then Exit;
  for i := 0 to High(FRows) do
    if FRows[i].Group = FGroups[FGroup] then Result.Add(Pointer(PtrInt(i)));
end;

function TSimUI.RowValue(const R: TEdRow): single;
begin
  if R.Channel < 0 then
    Result := R.PValue^
  else
    case R.Channel of
      0: Result := R.PColor^.red;
      1: Result := R.PColor^.green;
      2: Result := R.PColor^.blue;
    else
      Result := R.PColor^.alpha;
    end;
end;

procedure TSimUI.SetRowValue(Index: integer; V: single);
var
  b: byte;
begin
  with FRows[Index] do
  begin
    V := RoundTo(EnsureRange(V, Min, Max), -Decimals);
    if Abs(V - RowValue(FRows[Index])) < 1e-9 then Exit;
    if Channel < 0 then
      PValue^ := V
    else
    begin
      b := Round(V);
      case Channel of
        0: PColor^.red := b;
        1: PColor^.green := b;
        2: PColor^.blue := b;
      else
        PColor^.alpha := b;
      end;
    end;
    PendingFx := PendingFx + Effects;
  end;
  Modified := True;
  LastEdit := GetTickCount64;
end;

procedure TSimUI.StepRow(Index: integer; Dir: single);
begin
  with FRows[Index] do
    SetRowValue(Index, RowValue(FRows[Index]) + Dir * Power(10, -Decimals));
end;

{ --------------------------------------------------------------- layout }

function TSimUI.PanelX: single;
begin
  Result := FW - PanelW;
end;

function TSimUI.RowsTop: single;
begin
  Result := MenuH + HeaderH;
end;

function TSimUI.RowsHeight: single;
begin
  Result := Max(RowH, FH - RowsTop - HintH);
end;

procedure TSimUI.TrackSpan(out x0, x1: single);
begin
  x0 := PanelX + PanelW * 0.47;
  x1 := PanelX + PanelW - 74;
end;

function TSimUI.RowAt(x, y: single): integer;
var
  L: TFPList;
  k: integer;
begin
  Result := -1;
  if not PanelVisible or (x < PanelX) or (y < RowsTop) or (y >= RowsTop + RowsHeight) then Exit;
  L := Visible;
  try
    k := Trunc((y - RowsTop) / RowH) + FScroll;
    if (k >= 0) and (k < L.Count) then Result := PtrInt(L[k]);
  finally
    L.Free;
  end;
end;

procedure TSimUI.SelectGroup(G: integer);
begin
  if FGroups.Count = 0 then Exit;
  FGroup := (G + FGroups.Count) mod FGroups.Count;
  FScroll := 0;
  FSel := 0;
end;

procedure TSimUI.EnsureSelVisible;
var
  n: integer;
begin
  n := Max(1, Trunc(RowsHeight / RowH));
  if FSel < FScroll then FScroll := FSel;
  if FSel >= FScroll + n then FScroll := FSel - n + 1;
end;

function TSimUI.MenuItemAt(x, y: single): integer;
begin
  Result := -1;
  if not FMenuOpen or (x < 4) or (x > 4 + MenuW) or (y < MenuH) then Exit;
  Result := Trunc((y - MenuH - 4) / ItemH);
  if (Result < 0) or (Result > High(MenuItems)) or (MenuItems[Result] = '') then Result := -1;
end;

{ ---------------------------------------------------------------- input }

function TSimUI.InUI(x, y: single): boolean;
begin
  Result := (y < MenuH) or (FMenuOpen and (x <= 4 + MenuW) and (y < MenuH + 8 + Length(MenuItems) * ItemH)) or
    (PanelVisible and (x >= PanelX));
end;

function TSimUI.MouseDown(x, y: single; Right: boolean): TUIAction;
var
  i, k: integer;
  L: TFPList;
  t0, t1: single;
begin
  Result := uaNone;
  // ---- menu
  if FMenuOpen then
  begin
    i := MenuItemAt(x, y);
    FMenuOpen := False;
    case i of
      0: Result := uaOpen;
      1: Result := uaSave;
      2: Result := uaSaveAs;
      4: Result := uaExit;
    end;
    if (i >= 0) or ((y < MenuH) and (x < 70)) then Exit;
  end;
  if y < MenuH then
  begin
    if x < 70 then FMenuOpen := True;
    Exit;
  end;
  if not PanelVisible or (x < PanelX) then Exit;
  // ---- group selector
  if y < RowsTop then
  begin
    if x < PanelX + 50 then SelectGroup(FGroup - 1)
    else if x > PanelX + PanelW - 50 then SelectGroup(FGroup + 1);
    Exit;
  end;
  // ---- rows
  i := RowAt(x, y);
  if i < 0 then Exit;
  L := Visible;
  try
    for k := 0 to L.Count - 1 do
      if integer(PtrUInt(L[k])) = i then FSel := k;
  finally
    L.Free;
  end;
  TrackSpan(t0, t1);
  if (x >= t0 - 8) and (x <= t1 + 8) then
  begin
    FDragRow := i;
    with FRows[i] do SetRowValue(i, Min + (Max - Min) * EnsureRange((x - t0) / (t1 - t0), 0, 1));
  end;
end;

procedure TSimUI.MouseMove(x, y: single);
var
  t0, t1: single;
begin
  FHoverItem := MenuItemAt(x, y);
  if FDragRow >= 0 then
  begin
    TrackSpan(t0, t1);
    with FRows[FDragRow] do
      SetRowValue(FDragRow, Min + (Max - Min) * EnsureRange((x - t0) / (t1 - t0), 0, 1));
  end;
end;

procedure TSimUI.MouseUp;
begin
  FDragRow := -1;
end;

procedure TSimUI.Wheel(x, y, dy: single);
var
  i, n: integer;
  L: TFPList;
begin
  if not PanelVisible or (x < PanelX) then Exit;
  i := RowAt(x, y);
  if i >= 0 then
    StepRow(i, Sign(dy))
  else
  begin
    L := Visible;
    try
      n := Max(1, Trunc(RowsHeight / RowH));
      FScroll := EnsureRange(FScroll - Round(dy) * 3, 0, Max(0, L.Count - n));
    finally
      L.Free;
    end;
  end;
end;

function TSimUI.KeyDown(Key: TSDL_Keycode; Mods: TSDL_Keymod; out Action: TUIAction): boolean;
var
  L: TFPList;
  Mul: single;
begin
  Action := uaNone;
  Result := True;
  if (Mods and SDL_KMOD_CTRL) <> 0 then
  begin
    case Key of
      SDLK_O: Action := uaOpen;
      SDLK_S: if (Mods and SDL_KMOD_SHIFT) <> 0 then Action := uaSaveAs else Action := uaSave;
    else
      Result := False;
    end;
    Exit;
  end;
  if FMenuOpen and (Key = SDLK_ESCAPE) then
  begin
    FMenuOpen := False;
    Exit;
  end;
  if Key = SDLK_E then
  begin
    PanelVisible := not PanelVisible;
    Exit;
  end;
  Result := False;
  if not PanelVisible then Exit;
  Result := True;
  if (Mods and SDL_KMOD_SHIFT) <> 0 then Mul := 10 else Mul := 1;
  L := Visible;
  try
    case Key of
      SDLK_UP, SDLK_KP_8: FSel := Max(0, FSel - 1);
      SDLK_DOWN, SDLK_KP_2: FSel := Min(L.Count - 1, FSel + 1);
      SDLK_LEFT, SDLK_KP_4: if FSel < L.Count then StepRow(PtrInt(L[FSel]), -Mul);
      SDLK_RIGHT, SDLK_KP_6: if FSel < L.Count then StepRow(PtrInt(L[FSel]), Mul);
      SDLK_PAGEUP, SDLK_KP_9: SelectGroup(FGroup - 1);
      SDLK_PAGEDOWN, SDLK_KP_3, SDLK_TAB: SelectGroup(FGroup + 1);
    else
      Result := False;
    end;
  finally
    L.Free;
  end;
  EnsureSelVisible;
end;

{ ----------------------------------------------------------------- draw }

procedure TSimUI.Draw(W, H: integer; const FileTitle: string);
const
  Gold: TSDL_Color = (r: 255; g: 200; b: 110; a: 255);
var
  L: TFPList;
  i, k, n, Sel: integer;
  x0, y, t0, t1, v, frac: single;
  White, Soft, Dim: TSDL_Color;
  S: string;
begin
  FW := W;
  FH := H;
  White := Rgb(235, 240, 250);
  Soft := Rgb(170, 190, 220);
  Dim := Rgb(120, 135, 160);
  SDL_SetRenderScale(FRen, 1, 1);
  SDL_SetRenderDrawBlendMode(FRen, SDL_BLENDMODE_BLEND);

  // ---- edit panel
  if PanelVisible and (FGroups.Count > 0) then
  begin
    x0 := PanelX;
    Fill(x0, MenuH, PanelW, H - MenuH, 8, 12, 24, 215);
    Fill(x0, MenuH, 1, H - MenuH, 60, 80, 110, 255);
    // group selector
    DrawText('<', x0 + 18, MenuH + 10, Gold);
    DrawText('>', x0 + PanelW - 28, MenuH + 10, Gold);
    DrawText(Format('%s   (%d / %d)', [FGroups[FGroup], FGroup + 1, FGroups.Count]),
      x0 + PanelW / 2, MenuH + 11, White, False, 1);
    L := Visible;
    try
      if FSel >= L.Count then FSel := Max(0, L.Count - 1);
      n := Max(1, Trunc(RowsHeight / RowH));
      FScroll := EnsureRange(FScroll, 0, Max(0, L.Count - n));
      TrackSpan(t0, t1);
      for k := FScroll to Min(L.Count - 1, FScroll + n - 1) do
      begin
        i := PtrInt(L[k]);
        y := RowsTop + (k - FScroll) * RowH;
        if k = FSel then Fill(x0 + 2, y, PanelW - 4, RowH, 255, 200, 110, 38);
        with FRows[i] do
        begin
          if (Channel <= 0) then S := Name else S := '';
          if Channel >= 0 then S := S + '  ' + ChannelNames[Channel];
          if Channel < 0 then DrawText(S, x0 + 12, y + 4, White, True)
          else DrawText(S, x0 + 12, y + 4, Soft, True);
          // colour swatch on the first channel row
          if Channel = 0 then
          begin
            Fill(t0 - 26, y + 6, 16, 14, 30, 30, 40, 255);
            Fill(t0 - 25, y + 7, 14, 12, PColor^.red, PColor^.green, PColor^.blue, 255);
          end;
          v := RowValue(FRows[i]);
          frac := EnsureRange((v - Min) / Math.Max(1e-9, Max - Min), 0, 1);
          Fill(t0, y + RowH / 2 - 2, t1 - t0, 5, 40, 52, 75, 255);
          case Channel of
            0: Fill(t0, y + RowH / 2 - 2, (t1 - t0) * frac, 5, 230, 80, 80, 255);
            1: Fill(t0, y + RowH / 2 - 2, (t1 - t0) * frac, 5, 80, 210, 100, 255);
            2: Fill(t0, y + RowH / 2 - 2, (t1 - t0) * frac, 5, 90, 140, 255, 255);
            3: Fill(t0, y + RowH / 2 - 2, (t1 - t0) * frac, 5, 200, 200, 210, 255);
          else
            if k = FSel then Fill(t0, y + RowH / 2 - 2, (t1 - t0) * frac, 5, 255, 200, 110, 255)
            else Fill(t0, y + RowH / 2 - 2, (t1 - t0) * frac, 5, 110, 170, 230, 255);
          end;
          Fill(t0 + (t1 - t0) * frac - 2, y + RowH / 2 - 6, 4, 13, 235, 240, 250, 255);
          DrawText(FloatToStrF(v, ffFixed, 15, Decimals), x0 + PanelW - 12, y + 4, White, True, 2);
        end;
      end;
      if L.Count > n then
        DrawText(Format('%d-%d of %d  (wheel to scroll)', [FScroll + 1, Min(L.Count, FScroll + n), L.Count]),
          x0 + PanelW / 2, RowsTop + RowsHeight - 2, Dim, True, 1);
      // hint of the selected row
      Fill(x0, H - HintH, PanelW, 1, 60, 80, 110, 255);
      if FSel < L.Count then
      begin
        Sel := PtrInt(L[FSel]);
        with FRows[Sel] do
          S := Format('%s: %s  [%s .. %s]', [Name, Hint, FloatToStrF(Min, ffGeneral, 6, 0),
            FloatToStrF(Max, ffGeneral, 6, 0)]);
        DrawText(S, x0 + 12, H - HintH + 8, Soft, True, 0, PanelW - 24);
      end;
      DrawText('drag, wheel, Left Right (Shift x10)  Up Down  PgUp PgDn  E hide',
        x0 + PanelW / 2, H - 24, Dim, True, 1);
    finally
      L.Free;
    end;
  end;

  // ---- menu bar
  Fill(0, 0, W, MenuH, 16, 22, 38, 245);
  Fill(0, MenuH - 1, W, 1, 60, 80, 110, 255);
  if FMenuOpen then Fill(4, 3, 62, MenuH - 6, 255, 200, 110, 50);
  DrawText('File', 18, 6, White);
  DrawText(FileTitle, W / 2, 6, Soft, False, 1);
  if not PanelVisible then DrawText('E: edit panel', W - 12, 7, Dim, True, 2);

  if FMenuOpen then
  begin
    Fill(4, MenuH, MenuW, Length(MenuItems) * ItemH + 8, 22, 30, 50, 250);
    Fill(4, MenuH, MenuW, 1, 255, 200, 110, 200);
    for i := 0 to High(MenuItems) do
    begin
      y := MenuH + 4 + i * ItemH;
      if MenuItems[i] = '' then
      begin
        Fill(14, y + ItemH / 2, MenuW - 20, 1, 60, 80, 110, 255);
        Continue;
      end;
      if i = FHoverItem then Fill(6, y, MenuW - 4, ItemH, 255, 200, 110, 60);
      DrawText(MenuItems[i], 18, y + 5, White);
      DrawText(MenuKeys[i], MenuW - 8, y + 7, Dim, True, 2);
    end;
  end;

  if Notice <> '' then
  begin
    Fill(W / 2 - 220, H / 2 - 30, 440, 60, 8, 12, 24, 235);
    DrawText(Notice, W / 2, H / 2 - 11, Gold, False, 1);
  end;
end;

end.
