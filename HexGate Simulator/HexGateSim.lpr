program HexGateSim;

{ HexGate Simulator - opens, edits and saves "hexgate-graphics" files and
  simulates the HexGate fly-through with them (SDL3, GPU drawing, vsync).

    usimdata.pas        reads / writes the file: settings, game rules, atlas, images
    usimexport.pas      re-bakes the file's atlas, screen layers and reference frame
    usimui.pas          menu bar (File: Open, Save, Save As, Exit) and edit panel
    uhexbackground.pas  the HexGate engine: world, camera, sprites, draw list
    ugpuout.pas         GPU drawing of the draw list (RECIPE or ATLAS mode)

  RECIPE mode: every number and colour of the file drives the engine, which
  draws all sprites and layers itself. Changes in the edit panel show at
  once. ATLAS mode: the same frame drawn only with the images stored in the
  file. Save writes the edited values and re-bakes those images, so both
  modes and other programs see the same result.

  The autopilot flies through gates made with the file's game rules (also
  editable); hold the left mouse button over the picture to steer yourself.

  Keys: Ctrl+O open, Ctrl+S save, Ctrl+Shift+S save as, E edit panel,
        A recipe / atlas, R reload the file, G gates on / off,
        + / - level (speed, gap size, spacing), Space pause, I info,
        F11 fullscreen, Esc exit.

  Usage: HexGateSim [file.json]   (default: hexgate_graphics.json next to it)
  Needs SDL3.dll and SDL3_ttf.dll. }

{$mode objfpc}{$H+}
{$IFDEF WINDOWS}{$APPTYPE GUI}{$ENDIF}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF WINDOWS}MMSystem,{$ENDIF}
  SysUtils, Math, SDL3, SDL3_ttf, BGRABitmap, BGRABitmapTypes,
  UHexBackground, UGpuOut, USimData, USimExport, USimUI;

const
  AppName = 'HexGate Simulator';
  MaxLevel = 80;

type
  TGate = record
    Z, GX, GY, GR: single;
  end;

  // gives the GPU output the atlas lookup of the loaded file
  TAtlasAdapter = class
    function Find(Kind: integer; R, Blur: single; out X, Y, W: integer; out Rq: single): boolean;
  end;

var
  Window: PSDL_Window;
  Renderer: PSDL_Renderer;
  Data: TSimData;
  Hex: THexBackground;
  Gpu: TGpuOut;
  UI: TSimUI;
  Adapter: TAtlasAdapter;
  FontFile: string = '';
  Font: PTTF_Font = nil;
  InfoTex: array of PSDL_Texture;
  Running: boolean = True;
  Paused: boolean = False;
  FullScreen: boolean = False;
  GatesOn: boolean = True;
  ShowInfo: boolean = True;
  Steering: boolean = False;
  Level: integer = 0;
  LoadError: string = '';
  CamSpeed: single = 9;                // camera.speed of the file (the autopilot drives the engine's)
  MouseX, MouseY: single;
  // file dialogs answer from their own thread
  DialogLock: TRTLCriticalSection;
  DialogPath: string = '';
  DialogKind: integer = 0;             // 1 open, 2 save as
  DialogFilter: array[0..1] of TSDL_DialogFileFilter;
  // autopilot
  Gates: array of TGate;
  PX, PY, VX, VY, Speed, LastGateZ, LastGX, LastGY: single;
  Passed, Hits: integer;
  // timing
  Frames: integer = 0;
  Fps, BuildMs, GpuMs, ShowMs: double;
  LastTick, FpsStart: double;

function TAtlasAdapter.Find(Kind: integer; R, Blur: single; out X, Y, W: integer; out Rq: single): boolean;
var
  E: TAtlasEntry;
begin
  Result := Data.FindSprite(Kind, R, Blur, E);
  X := E.X;
  Y := E.Y;
  W := E.W;
  Rq := E.Rq;
end;

procedure Fail(const What: string);
begin
  SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, AppName, PAnsiChar(AnsiString(What)), nil);
  SDL_Quit;
  Halt(1);
end;

procedure ShowError(const What: string);
begin
  SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, AppName, PAnsiChar(AnsiString(What)), Window);
end;

procedure UpdateTitle;
var
  S: string;
begin
  S := AppName + '  -  ' + ExtractFileName(Data.FileName);
  if UI.Modified then S := S + ' *';
  SDL_SetWindowTitle(Window, PAnsiChar(AnsiString(S)));
end;

{ ------------------------------------------------------------- file }

procedure ResetFlight;
begin
  Gates := nil;
  Hex.ClearGates;
  LastGateZ := Hex.CameraPos.Z + 20;
  LastGX := PX;
  LastGY := PY;
  Speed := Data.StartSpeed;
end;

procedure BuildRows;
const
  G = 'Game rules (autopilot)';
begin
  UI.ClearRows;
  UI.AddRowsFromEngine(Hex);
  UI.AddNumberRow(G, 'Start speed', 'Speed at level 0, units/s.', @Data.StartSpeed, 1, 60, 2);
  UI.AddNumberRow(G, 'Max speed', 'Highest speed, units/s.', @Data.MaxSpeed, 1, 120, 2);
  UI.AddNumberRow(G, 'Speed per gate', 'Speed added per level (gate).', @Data.SpeedPerGate, 0, 5, 3);
  UI.AddNumberRow(G, 'Start gap', 'Gap radius at level 0, units.', @Data.StartGap, 0.5, 10, 2);
  UI.AddNumberRow(G, 'Min gap', 'Smallest gap radius, units.', @Data.MinGap, 0.3, 10, 2);
  UI.AddNumberRow(G, 'Gap per gate', 'Gap radius taken away per level.', @Data.GapPerGate, 0, 1, 3);
  UI.AddNumberRow(G, 'Start spacing', 'Distance between gates at level 0, units.', @Data.StartSpacing, 4, 120, 1);
  UI.AddNumberRow(G, 'Min spacing', 'Smallest distance between gates, units.', @Data.MinSpacing, 2, 120, 1);
  UI.AddNumberRow(G, 'Spacing per gate', 'Spacing taken away per level.', @Data.SpacingPerGate, 0, 5, 3);
  UI.AddNumberRow(G, 'Lateral speed', 'How fast the ship moves sideways, units/s.', @Data.LateralSpeed, 1, 60, 2);
  UI.AddNumberRow(G, 'Player radius', 'Collision radius of the ship, units.', @Data.PlayerRadius, 0, 3, 2);
end;

procedure LoadFile(const FileName: string);
begin
  try
    Data.Load(FileName);
    Data.ApplyTo(Hex);
    CamSpeed := Hex.Settings^.Speed;
    Gpu.SetAtlasImages(Data.Atlas, Data.Background, Data.Vignette);
    LoadError := '';
  except
    on E: Exception do LoadError := E.Message;
  end;
  BuildRows;
  UI.Modified := False;
  UI.PendingFx := [];
  ResetFlight;
  UpdateTitle;
end;

procedure DrawScene; forward;

function DoSave(FileName: string): boolean;
var
  Spd: single;
begin
  Result := False;
  if ExtractFileExt(FileName) = '' then FileName := FileName + '.json';
  UI.Notice := 'Saving ' + ExtractFileName(FileName) + ' ...  (baking images)';
  DrawScene;                           // show the notice before the work starts
  try
    Spd := Hex.Settings^.Speed;
    Hex.Settings^.Speed := CamSpeed;   // the file keeps its own camera speed
    try
      Data.SaveTo(FileName, Hex);
    finally
      Hex.Settings^.Speed := Spd;
    end;
    Gpu.SetAtlasImages(Data.Atlas, Data.Background, Data.Vignette);
    UI.Modified := False;
    Result := True;
  except
    on E: Exception do ShowError('Cannot save ' + FileName + ':' + LineEnding + E.Message);
  end;
  UI.Notice := '';
  UpdateTitle;
end;

// True when it is fine to drop the current edits (saved, discarded or none)
function ConfirmDiscard: boolean;
var
  Box: TSDL_MessageBoxData;
  Buttons: array[0..2] of TSDL_MessageBoxButtonData;
  Choice: longint;
  Msg: AnsiString;
begin
  Result := True;
  if not UI.Modified then Exit;
  Buttons[0].flags := SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT;
  Buttons[0].buttonID := 1;
  Buttons[0].Text := 'Save';
  Buttons[1].flags := 0;
  Buttons[1].buttonID := 2;
  Buttons[1].Text := 'Don''t Save';
  Buttons[2].flags := SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT;
  Buttons[2].buttonID := 0;
  Buttons[2].Text := 'Cancel';
  Msg := 'Save the changes to ' + ExtractFileName(Data.FileName) + '?';
  FillChar(Box, SizeOf(Box), 0);
  Box.flags := SDL_MESSAGEBOX_WARNING;
  Box.window := Window;
  Box.title := AppName;
  Box.message := PAnsiChar(Msg);
  Box.numbuttons := 3;
  Box.Buttons := @Buttons[0];
  Choice := 0;
  if not SDL_ShowMessageBox(@Box, @Choice) then Choice := 0;
  case Choice of
    1: Result := DoSave(Data.FileName);
    2: Result := True;
  else
    Result := False;
  end;
end;

procedure DialogCallback(userdata: pointer; filelist: PPAnsiChar; filter: longint); cdecl;
begin
  // nil = error, empty list = cancelled
  if (filelist = nil) or (filelist^ = nil) then Exit;
  EnterCriticalSection(DialogLock);
  DialogPath := string(filelist^);
  DialogKind := PtrInt(userdata);
  LeaveCriticalSection(DialogLock);
end;

procedure RequestExit;
begin
  if ConfirmDiscard then Running := False;
end;

procedure DoAction(A: TUIAction);
var
  Dir: AnsiString;
begin
  case A of
    uaOpen:
      if ConfirmDiscard then
      begin
        Dir := ExtractFilePath(Data.FileName);
        SDL_ShowOpenFileDialog(@DialogCallback, Pointer(1), Window, @DialogFilter[0], 2, PAnsiChar(Dir), False);
      end;
    uaSave:
      DoSave(Data.FileName);
    uaSaveAs:
      begin
        Dir := Data.FileName;
        SDL_ShowSaveFileDialog(@DialogCallback, Pointer(2), Window, @DialogFilter[0], 2, PAnsiChar(Dir));
      end;
    uaExit:
      RequestExit;
  end;
end;

procedure CheckDialog;
var
  Path: string;
  Kind: integer;
begin
  EnterCriticalSection(DialogLock);
  Path := DialogPath;
  Kind := DialogKind;
  DialogPath := '';
  DialogKind := 0;
  LeaveCriticalSection(DialogLock);
  case Kind of
    1:
      begin
        LoadFile(Path);
        if LoadError <> '' then ShowError('Cannot read ' + Path + ':' + LineEnding + LoadError);
      end;
    2: DoSave(Path);
  end;
end;

procedure FindFont;
var
  F, Dir: string;
begin
  Dir := GetEnvironmentVariable('WINDIR');
  if Dir = '' then Dir := 'C:\Windows';
  for F in Data.HudFontFiles do
  begin
    if FileExists(ExtractFilePath(ParamStr(0)) + F) then FontFile := ExtractFilePath(ParamStr(0)) + F
    else if FileExists(Dir + '\Fonts\' + F) then FontFile := Dir + '\Fonts\' + F;
    if FontFile <> '' then Exit;
  end;
  if FileExists(Dir + '\Fonts\segoeui.ttf') then FontFile := Dir + '\Fonts\segoeui.ttf';
end;

{ ---------------------------------------------------------- autopilot }

// Gates follow the file's game rules (game.rules), at the chosen level.
procedure SpawnGates;
var
  spacing, gr, spd, maxShift, lim, a, rr, gx, gy, d: single;
  Tries, i: integer;
begin
  lim := Hex.Settings^.CorridorRadius - 1.5;
  while LastGateZ < Hex.CameraPos.Z + Hex.Settings^.FarClip + 6 do
  begin
    spacing := Max(Data.MinSpacing, Data.StartSpacing - Data.SpacingPerGate * Level);
    gr := Max(Data.MinGap, Data.StartGap - Data.GapPerGate * Level);
    spd := Min(Data.MaxSpeed, Data.StartSpeed + Data.SpeedPerGate * Level);
    maxShift := Data.LateralSpeed * spacing / spd * 0.7;
    Tries := 0;
    repeat
      a := Random * 2 * Pi;
      rr := Sqrt(Random) * lim;
      gx := rr * Cos(a);
      gy := rr * Sin(a);
      d := Sqrt(Sqr(gx - LastGX) + Sqr(gy - LastGY));
      Inc(Tries);
    until (d <= maxShift) or (Tries > 30);
    if d > maxShift then
    begin
      gx := LastGX + (gx - LastGX) * maxShift / d;
      gy := LastGY + (gy - LastGY) * maxShift / d;
    end;
    LastGateZ := LastGateZ + spacing;
    LastGX := gx;
    LastGY := gy;
    i := Length(Gates);
    SetLength(Gates, i + 1);
    Gates[i].Z := LastGateZ;
    Gates[i].GX := gx;
    Gates[i].GY := gy;
    Gates[i].GR := gr;
    Hex.AddGate(LastGateZ, gx, gy, gr);
  end;
end;

procedure Fly(dt: single);
var
  ox, oy, tx, ty, lim, l, step, z0, z1: single;
  i, g: integer;
begin
  if Paused then
  begin
    Hex.Animate(0);
    Exit;
  end;
  lim := Hex.Settings^.CorridorRadius - 1.5;
  // next gate
  g := -1;
  for i := 0 to High(Gates) do
    if Gates[i].Z > Hex.CameraPos.Z then
    begin
      g := i;
      Break;
    end;
  if Steering then
  begin
    tx := MouseX * lim;
    ty := MouseY * lim;
  end
  else if g >= 0 then
  begin
    tx := Gates[g].GX;
    ty := Gates[g].GY;
  end
  else
  begin
    tx := 0;
    ty := 0;
  end;
  ox := PX;
  oy := PY;
  l := Sqrt(Sqr(tx - PX) + Sqr(ty - PY));
  step := Data.LateralSpeed * dt;
  if l <= step then
  begin
    PX := tx;
    PY := ty;
  end
  else
  begin
    PX := PX + (tx - PX) / l * step;
    PY := PY + (ty - PY) / l * step;
  end;
  l := Sqrt(PX * PX + PY * PY);
  if l > lim then
  begin
    PX := PX * lim / l;
    PY := PY * lim / l;
  end;
  if dt > 0 then
  begin
    VX := VX + ((PX - ox) / dt - VX) * Min(1, dt * 8);
    VY := VY + ((PY - oy) / dt - VY) * Min(1, dt * 8);
  end;

  Speed := Speed + (Min(Data.MaxSpeed, Data.StartSpeed + Data.SpeedPerGate * Level) - Speed) * Min(1, dt * 2);
  Hex.Settings^.Speed := Speed;
  if GatesOn then SpawnGates;

  // gates reached in this step: count passes and hits
  z0 := Hex.CameraPos.Z;
  z1 := z0 + Speed * dt;
  for i := 0 to High(Gates) do
    with Gates[i] do
      if (Z > z0) and (Z <= z1) then
        if Sqrt(Sqr(PX - GX) + Sqr(PY - GY)) <= GR - Data.PlayerRadius then Inc(Passed) else Inc(Hits);
  while (Length(Gates) > 0) and (Gates[0].Z < z0 - 2) do
    Delete(Gates, 0, 1);

  // the camera is the ship (game.rules)
  Hex.SetManualCamera(PX, PY, VX * 0.012, -VY * 0.008, -VX * 0.02);
  if g >= 0 then Hex.FocusOverride := Max(2, Gates[g].Z - z0) else Hex.FocusOverride := 12;
  Hex.Animate(dt);
end;

{ --------------------------------------------------------------- info }

procedure BuildInfo;
var
  L: array of string;
  i: integer;
  Surf: PSDL_Surface;
  Col: TSDL_Color;
  Mode: string;

  procedure Add(const S: string);
  begin
    SetLength(L, Length(L) + 1);
    L[High(L)] := S;
  end;

begin
  L := nil;
  for i := 0 to High(InfoTex) do SDL_DestroyTexture(InfoTex[i]);
  InfoTex := nil;
  if (Font = nil) or not ShowInfo then Exit;
  if Gpu.UseAtlas then Mode := 'ATLAS (images from the file)' else Mode := 'RECIPE (engine draws from the file''s numbers)';
  if LoadError <> '' then Add('LOAD ERROR: ' + LoadError);
  Add(Format('mode: %s', [Mode]));
  Add(Format('%.0f fps   list %.1f ms   gpu %.1f ms (%d draws)   present+vsync %.1f ms',
    [Fps, BuildMs, GpuMs, Gpu.DrawCalls, ShowMs]));
  Add(Format('settings applied %d / %d   seed %d   atlas %d sprites   render scale %.2f',
    [Data.SettingsApplied, Data.SettingsTotal, Data.Seed, Length(Data.Entries), Hex.Settings^.RenderScale]));
  Add(Format('level %d   speed %.1f   gates %s   passed %d   hit %d   %s',
    [Level, Speed, BoolToStr(GatesOn, 'on', 'off'), Passed, Hits,
     BoolToStr(Steering, 'steering: mouse', 'autopilot')]));
  Add('A recipe/atlas   R reload   G gates   +/- level   Space pause   E edit panel   I info   F11   Esc');
  Col.r := 210;
  Col.g := 225;
  Col.b := 245;
  Col.a := 255;
  SetLength(InfoTex, Length(L));
  for i := 0 to High(L) do
  begin
    Surf := TTF_RenderText_Blended(Font, PAnsiChar(AnsiString(L[i])), 0, Col);
    if Surf = nil then Continue;
    InfoTex[i] := SDL_CreateTextureFromSurface(Renderer, Surf);
    SDL_DestroySurface(Surf);
  end;
end;

procedure DrawInfo;
var
  i: integer;
  w, h, y: single;
  Dst: TSDL_FRect;
begin
  if Length(InfoTex) = 0 then Exit;
  y := MenuH + 8;
  // dark plate behind the text
  SDL_SetRenderDrawBlendMode(Renderer, SDL_BLENDMODE_BLEND);
  SDL_SetRenderDrawColor(Renderer, 0, 0, 0, 150);
  Dst.x := 4;
  Dst.y := MenuH + 4;
  Dst.w := 860;
  Dst.h := Length(InfoTex) * 21 + 10;
  SDL_RenderFillRect(Renderer, @Dst);
  for i := 0 to High(InfoTex) do
    if InfoTex[i] <> nil then
    begin
      SDL_GetTextureSize(InfoTex[i], @w, @h);
      Dst.x := 12;
      Dst.y := y;
      Dst.w := w;
      Dst.h := h;
      SDL_RenderTexture(Renderer, InfoTex[i], nil, @Dst);
      y := y + 21;
    end;
end;

{ ---------------------------------------------------------------- loop }


// window coordinates -> output pixels (they differ on high-DPI screens)
procedure ToPixels(var x, y: single);
var
  ww, wh, pw, ph: longint;
begin
  ww := 0;
  wh := 0;
  pw := 0;
  ph := 0;
  SDL_GetWindowSize(Window, @ww, @wh);
  SDL_GetRenderOutputSize(Renderer, @pw, @ph);
  if (ww > 0) and (wh > 0) then
  begin
    x := x * pw / ww;
    y := y * ph / wh;
  end;
end;

procedure HandleEvents;
var
  E: TSDL_Event;
  W, H: longint;
  x, y: single;
  A: TUIAction;
begin
  FillChar(E, SizeOf(E), 0);
  while SDL_PollEvent(@E) do
    case E._type of
      SDL_EVENT_QUIT: RequestExit;
      SDL_EVENT_KEY_DOWN:
        if UI.KeyDown(E.key.key, E.key.mod_, A) then
          DoAction(A)
        else
          case E.key.key of
            SDLK_ESCAPE: RequestExit;
            SDLK_F11:
              begin
                FullScreen := not FullScreen;
                SDL_SetWindowFullscreen(Window, FullScreen);
              end;
            SDLK_A: Gpu.UseAtlas := not Gpu.UseAtlas;
            SDLK_R: if ConfirmDiscard then LoadFile(Data.FileName);
            SDLK_G:
              begin
                GatesOn := not GatesOn;
                ResetFlight;
              end;
            SDLK_I: ShowInfo := not ShowInfo;
            SDLK_SPACE: Paused := not Paused;
            SDLK_EQUALS, SDLK_PLUS, SDLK_KP_PLUS: Level := Min(MaxLevel, Level + 5);
            SDLK_MINUS, SDLK_KP_MINUS: Level := Max(0, Level - 5);
          end;
      SDL_EVENT_MOUSE_MOTION:
        begin
          W := 0;
          H := 0;
          SDL_GetWindowSize(Window, @W, @H);
          if (W > 0) and (H > 0) then
          begin
            MouseX := EnsureRange(E.motion.x / W * 2 - 1, -1, 1);
            MouseY := EnsureRange(E.motion.y / H * 2 - 1, -1, 1);
          end;
          x := E.motion.x;
          y := E.motion.y;
          ToPixels(x, y);
          UI.MouseMove(x, y);
        end;
      SDL_EVENT_MOUSE_BUTTON_DOWN:
        begin
          x := E.button.x;
          y := E.button.y;
          ToPixels(x, y);
          if UI.InUI(x, y) then
            DoAction(UI.MouseDown(x, y, E.button.button = SDL_BUTTON_RIGHT))
          else
          begin
            UI.MouseDown(x, y, E.button.button = SDL_BUTTON_RIGHT);   // closes an open menu
            if E.button.button = SDL_BUTTON_LEFT then Steering := True;
          end;
        end;
      SDL_EVENT_MOUSE_BUTTON_UP:
        begin
          UI.MouseUp;
          if E.button.button = SDL_BUTTON_LEFT then Steering := False;
        end;
      SDL_EVENT_MOUSE_WHEEL:
        begin
          x := E.wheel.mouse_x;
          y := E.wheel.mouse_y;
          ToPixels(x, y);
          UI.Wheel(x, y, E.wheel.y);
        end;
    end;
end;

procedure DrawScene;
var
  W, H, FW, FH: integer;
  t, t1, t2: double;
begin
  t := NowMs;
  W := 0;
  H := 0;
  SDL_GetRenderOutputSize(Renderer, @W, @H);
  W := Max(16, W);
  H := Max(16, H);
  FW := Max(16, Round(W * Hex.Settings^.RenderScale));
  FH := Max(16, Round(H * Hex.Settings^.RenderScale));
  Hex.BuildFrame(FW, FH, [0..PassCount - 1], True);
  t1 := NowMs;
  Gpu.Draw(Hex, FW, FH, nil);
  t2 := NowMs;
  DrawInfo;
  if UI.Modified then
    UI.Draw(W, H, ExtractFileName(Data.FileName) + '  *  (modified)')
  else
    UI.Draw(W, H, ExtractFileName(Data.FileName));
  SDL_RenderPresent(Renderer);
  BuildMs := BuildMs * 0.9 + (t1 - t) * 0.1;
  GpuMs := GpuMs * 0.9 + (t2 - t1) * 0.1;
  ShowMs := ShowMs * 0.9 + (NowMs - t2) * 0.1;
end;

procedure Frame;
const
  TitleModified: boolean = False;
var
  t: double;
begin
  t := NowMs;
  // caches are rebuilt once the user stops changing a value
  if (UI.PendingFx <> []) and (GetTickCount64 - UI.LastEdit > 150) then
  begin
    Hex.Invalidate(UI.PendingFx);
    UI.PendingFx := [];
  end;
  Fly(Min(0.1, (t - LastTick) / 1000));
  LastTick := t;
  DrawScene;
  if UI.Modified <> TitleModified then
  begin
    TitleModified := UI.Modified;
    UpdateTitle;
  end;

  Inc(Frames);
  if t - FpsStart >= 500 then
  begin
    Fps := Frames * 1000 / (t - FpsStart);
    Frames := 0;
    FpsStart := t;
    BuildInfo;
  end;
end;

var
  FileName: string;
begin
  FileName := ParamStr(1);
  if FileName = '' then FileName := ExtractFilePath(ParamStr(0)) + 'hexgate_graphics.json';
  UseNiceFloats;                       // saved numbers read 1.1, not 1.10000000000000E+000
  InitCriticalSection(DialogLock);
  DialogFilter[0].Name := 'HexGate graphics (*.json)';
  DialogFilter[0].pattern := 'json';
  DialogFilter[1].Name := 'All files';
  DialogFilter[1].pattern := '*';
  {$IFDEF WINDOWS}
  timeBeginPeriod(1);
  {$ENDIF}
  if not SDL_Init(SDL_INIT_VIDEO) then Fail('SDL_Init: ' + string(SDL_GetError));
  if not SDL_CreateWindowAndRenderer(AppName, 1280, 720,
    SDL_WINDOW_RESIZABLE or SDL_WINDOW_HIGH_PIXEL_DENSITY, @Window, @Renderer) then
    Fail('SDL_CreateWindowAndRenderer: ' + string(SDL_GetError));
  SDL_SetWindowMinimumSize(Window, 800, 480);
  SDL_SetRenderVSync(Renderer, 1);
  TTF_Init;

  Randomize;
  Data := TSimData.Create;
  Adapter := TAtlasAdapter.Create;
  Gpu := TGpuOut.Create(Renderer);
  Gpu.Lookup := @Adapter.Find;
  Hex := THexBackground.Create;
  Hex.AsyncSprites := True;
  if not FileExists(FileName) then
    Fail('File not found: ' + FileName + LineEnding + LineEnding +
      'Export it from HexGate SDL3 (F9 or --export-graphics) and pass it as the first parameter.');
  FindFont;
  if FontFile <> '' then Font := TTF_OpenFont(PAnsiChar(AnsiString(FontFile)), 15);
  UI := TSimUI.Create(Renderer, FontFile);
  LoadFile(FileName);
  if LoadError <> '' then Fail('Cannot read ' + FileName + ': ' + LoadError);
  LastTick := NowMs;
  FpsStart := LastTick;
  try
    while Running do
    begin
      HandleEvents;
      CheckDialog;
      if Running then Frame;
    end;
  finally
    ShowInfo := False;
    BuildInfo;                        // frees the info textures
    UI.Free;
    if Font <> nil then TTF_CloseFont(Font);
    TTF_Quit;
    Hex.Free;                         // its sprites release their GPU textures
    Gpu.Free;
    Adapter.Free;
    Data.Free;
    SDL_DestroyRenderer(Renderer);
    SDL_DestroyWindow(Window);
    SDL_Quit;
    {$IFDEF WINDOWS}
    timeEndPeriod(1);
    {$ENDIF}
    DoneCriticalSection(DialogLock);
  end;
end.
