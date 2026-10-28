unit UGateGame;

{ HexGate - game rules, menus and HUD on top of the hexagon fly-through.

  You are the camera, flying down a corridor lined with hexagons. Every
  18..28 units a honeycomb wall (gate) blocks the corridor; it has one round
  gap. Steer so you are inside the gap when you reach the wall.

    pass a gate      +1   (inside the inner 35 % of the gap: PERFECT, +1 per
                           perfect in a row)
    boost (Space)    x1.5 speed, x2 points, drains the energy bar
    hit a wall       lose a life, 1 s of protection

  Every gate passed makes the flight faster, the gates closer together and
  the gaps smaller. A new gap is never further from the previous one than
  you can steer in the time between them (even when boosting).

  Screens: main menu (PLAY / OPTIONS / EXIT, the autopilot flies behind it)
  -> options -> playing <-> paused -> game over.
  Options (music, sound effects, difficulty, graphics quality, fullscreen,
  FPS counter) and the best score of each difficulty are kept in the ini
  file. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, IniFiles, fpjson, Graphics, LCLType, BGRABitmap, BGRABitmapTypes,
  UHexBackground, UGateAudio;

type
  TGameState = (gsTitle, gsPlaying, gsPaused, gsGameOver);
  TMenuScreen = (scMain, scOptions);

  TGameOptions = record
    MusicVol, SfxVol: integer;           // 0..10
    Difficulty: integer;                 // 0 easy, 1 normal, 2 hard
    Quality: integer;                    // 0 low .. 3 ultra
    Fullscreen, ShowFps: boolean;
  end;

  TGateInfo = record
    Z, GX, GY, GR: single;
    Resolved: boolean;
  end;

  TItemRect = record
    X0, Y0, X1, Y1: single;              // 0..1 of the view
  end;

  { TGateGame }

  TGateGame = class
  private
    FHex: THexBackground;
    FAudio: TGateAudio;
    FIniFile: string;
    FState: TGameState;
    FScreen: TMenuScreen;
    FSel: integer;
    FItems: array of TItemRect;
    FOptions: TGameOptions;
    FGates: array of TGateInfo;
    FPX, FPY, FVX, FVY: single;          // ship position in the corridor, smoothed velocity
    FSpeed, FEnergy: single;
    FScore, FLives, FMaxLives, FPassed, FSpawned, FCombo: integer;
    FBest: array[0..2] of integer;
    FGapAdd, FSpeedMul: single;
    FBoosting, FNewBest: boolean;
    FFlash, FShake, FInvuln, FMsgTime, FTime, FStateTime: single;
    FMsg: string;
    FMsgColor: TBGRAPixel;
    FLastGateZ, FLastGX, FLastGY: single;
    FLastMouseX, FLastMouseY: single;
    FBarX0, FBarX1: single;              // volume bars, 0..1 of the view
    procedure ResetRun;
    procedure SpawnGates;
    function NextGate: integer;
    procedure Say(const S: string; C: TBGRAPixel);
    procedure GameOver;
    procedure ToMenu;
    procedure LoadOptions;
    procedure SaveOptions;
    procedure ApplyOptions;
    procedure Sound(S: TSfx; Volume: single = 1; Pitch: single = 1);
    function ItemAt(nx, ny: single): integer;
    procedure Activate(Dir: integer);
    procedure MoveSel(Delta: integer);
    procedure DrawMenu(Bmp: TBGRABitmap);
  public
    // input, filled in by the form
    MouseX, MouseY: single;              // -1..1 over the view
    MouseActive: boolean;
    KeyLeft, KeyRight, KeyUp, KeyDown, KeyBoost: boolean;
    Fps: single;                         // measured by the form
    FpsDetail: string;                   // frame time breakdown, from the form
    RequestExit: boolean;                // EXIT chosen: the form closes
    constructor Create(AHex: THexBackground; AAudio: TGateAudio; const AIniFile: string);
    procedure Start;
    procedure TogglePause;
    procedure Escape;
    procedure MenuKey(Key: Word);
    procedure Click(Right: boolean);
    procedure SetFullscreen(Value: boolean);
    procedure Notify(const Msg: string);      // short message in the middle of the screen
    // game rules, difficulty / quality tables and the HUD layout, for exports
    function SpecJSON: TJSONObject;
    procedure Update(dt: single);        // call before Hex.Animate
    procedure DrawHud(Bmp: TBGRABitmap); // call after Hex.Render
    property State: TGameState read FState;
    property Options: TGameOptions read FOptions;
  end;

implementation

const
  PlayerR = 0.3;          // collision radius of the ship, units
  LatSpeed = 11;          // max sideways speed, units/s
  StartSpeed = 9;
  MaxSpeed = 26;
  SpeedPerGate = 0.25;
  StartGap = 3.0;         // gap radius, units (a hexagon is 1 unit)
  MinGap = 1.5;
  GapPerGate = 0.05;
  StartSpacing = 28;      // distance between gates, units
  MinSpacing = 18;
  SpacingPerGate = 0.35;
  BoostFactor = 1.5;

  DifficultyNames: array[0..2] of string = ('EASY', 'NORMAL', 'HARD');
  DiffGapAdd: array[0..2] of single = (0.7, 0, -0.4);
  DiffSpeedMul: array[0..2] of single = (0.85, 1, 1.15);
  DiffLives: array[0..2] of integer = (5, 3, 2);
  QualityNames: array[0..3] of string = ('LOW', 'MEDIUM', 'HIGH', 'ULTRA');
  QualityScale: array[0..3] of single = (0.5, 0.6, 0.7, 0.85);

  MainItems: array[0..2] of string = ('PLAY', 'OPTIONS', 'EXIT');
  OptMusic = 0;
  OptSfx = 1;
  OptDifficulty = 2;
  OptQuality = 3;
  OptFullscreen = 4;
  OptFps = 5;
  OptBack = 6;
  OptCount = 7;

function Rgba(r, g, b: byte; a: single = 255): TBGRAPixel;
begin
  Result := BGRA(r, g, b, EnsureRange(Round(a), 0, 255));
end;

function ColWhite: TBGRAPixel;
begin
  Result := BGRA(255, 255, 255);
end;

function ColGold(a: single = 255): TBGRAPixel;
begin
  Result := Rgba(255, 200, 110, a);
end;

function ColSoft(a: single = 255): TBGRAPixel;
begin
  Result := Rgba(170, 190, 220, a);
end;

function HexPolygon(cx, cy, r: single): ArrayOfTPointF;
var
  i: integer;
begin
  SetLength(Result, 6);
  for i := 0 to 5 do
    Result[i] := PointF(cx + r * Cos(i * Pi / 3), cy + r * Sin(i * Pi / 3));
end;

var
  TextCache: TStringList = nil;          // rendered strings (with shadow), see DrawText

// Text is rendered once per (string, size, colour) into a small bitmap and
// then only copied: BGRABitmap's antialiased text is far too slow to redraw
// every frame (the menu ran at 20 fps). Opacity (blinking, fading) is applied
// when copying, so it does not create new entries.
function CachedText(const S: string; C: TBGRAPixel; Size: single): TBGRABitmap;
var
  Key: string;
  i, Sh: integer;
  Sz: TSize;
begin
  Key := Format('%d|%d|%d|%d|%s', [Round(Size), C.red, C.green, C.blue, S]);
  if TextCache = nil then
  begin
    TextCache := TStringList.Create;
    TextCache.Sorted := True;
    TextCache.OwnsObjects := True;
  end;
  if TextCache.Find(Key, i) then
    Exit(TBGRABitmap(TextCache.Objects[i]));
  if TextCache.Count > 400 then TextCache.Clear;     // scores and speeds keep changing
  Result := TBGRABitmap.Create(1, 1);
  Result.FontName := 'Segoe UI';
  Result.FontStyle := [fsBold];
  Result.FontQuality := fqFineAntialiasing;
  Result.FontHeight := Max(8, Round(Size));
  Sz := Result.TextSize(S);
  Sh := Max(1, Round(Size * 0.06));
  Result.SetSize(Sz.cx + Sh + 2, Sz.cy + Sh + 2);
  Result.FillTransparent;
  // soft shadow keeps the text readable over bright hexagons
  Result.TextOut(Sh, Sh, S, BGRA(0, 0, 0, 180), taLeftJustify);
  Result.TextOut(0, 0, S, BGRA(C.red, C.green, C.blue), taLeftJustify);
  TextCache.AddObject(Key, Result);
end;

procedure DrawText(Bmp: TBGRABitmap; x, y: single; const S: string; C: TBGRAPixel;
  Size: single; Align: TAlignment);
var
  T: TBGRABitmap;
  w: single;
begin
  if (S = '') or (C.alpha = 0) then Exit;
  T := CachedText(S, C, Size);
  w := T.Width - Max(1, Round(Size * 0.06)) - 2;
  case Align of
    taCenter: x := x - w / 2;
    taRightJustify: x := x - w;
  end;
  Bmp.PutImage(Round(x), Round(y), T, dmDrawWithTransparency, C.alpha);
end;

{ TGateGame }

constructor TGateGame.Create(AHex: THexBackground; AAudio: TGateAudio; const AIniFile: string);
begin
  FHex := AHex;
  FAudio := AAudio;
  FIniFile := AIniFile;
  // the look of the game: a hexagon tunnel around a clear corridor
  with FHex.Settings^ do
  begin
    CorridorRadius := 10;
    EdgeOffset := -20;          // hexagons all around, not only lower right
    FadeStart := -1;
    Density := 0.35;
    LooseChance := 0;
    FocusPullAmp := 0;          // the game focuses on the next gate
    Aperture := 0.9;
    LookYaw := 4;               // the field must cover the ship's lean
    LookPitch := 3;
    SparkFieldBias := 0;
    DustCount := 70;
  end;
  if FileExists(FIniFile) then FHex.LoadFromIni(FIniFile);
  FHex.Invalidate([ivField, ivDust, ivSparks, ivSprites]);
  LoadOptions;
  ApplyOptions;
  FState := gsTitle;
  FScreen := scMain;
  FSpeed := StartSpeed;
  ResetRun;
end;

{ ---------------------------------------------------------------- options }

procedure TGateGame.LoadOptions;
var
  Ini: TIniFile;
  i: integer;
begin
  Ini := TIniFile.Create(FIniFile);
  try
    FOptions.MusicVol := EnsureRange(Ini.ReadInteger('Options', 'Music', 7), 0, 10);
    FOptions.SfxVol := EnsureRange(Ini.ReadInteger('Options', 'Sound', 8), 0, 10);
    FOptions.Difficulty := EnsureRange(Ini.ReadInteger('Options', 'Difficulty', 1), 0, 2);
    FOptions.Quality := EnsureRange(Ini.ReadInteger('Options', 'Quality', 2), 0, 3);
    FOptions.Fullscreen := Ini.ReadBool('Options', 'Fullscreen', False);
    FOptions.ShowFps := Ini.ReadBool('Options', 'ShowFps', False);
    for i := 0 to 2 do
      FBest[i] := Ini.ReadInteger('Game', 'Best' + IntToStr(i), 0);
    // best score of the first version (single difficulty) counts as Normal
    FBest[1] := Max(FBest[1], Ini.ReadInteger('Game', 'Best', 0));
  finally
    Ini.Free;
  end;
end;

procedure TGateGame.SaveOptions;
var
  Ini: TIniFile;
  i: integer;
begin
  try
    Ini := TIniFile.Create(FIniFile);
    try
      Ini.WriteInteger('Options', 'Music', FOptions.MusicVol);
      Ini.WriteInteger('Options', 'Sound', FOptions.SfxVol);
      Ini.WriteInteger('Options', 'Difficulty', FOptions.Difficulty);
      Ini.WriteInteger('Options', 'Quality', FOptions.Quality);
      Ini.WriteBool('Options', 'Fullscreen', FOptions.Fullscreen);
      Ini.WriteBool('Options', 'ShowFps', FOptions.ShowFps);
      for i := 0 to 2 do
        Ini.WriteInteger('Game', 'Best' + IntToStr(i), FBest[i]);
    finally
      Ini.Free;
    end;
  except
    // a read-only folder must not end the game
  end;
end;

procedure TGateGame.ApplyOptions;
begin
  if FAudio <> nil then
  begin
    FAudio.MusicVolume := FOptions.MusicVol / 10;
    FAudio.SfxVolume := FOptions.SfxVol / 10;
  end;
  FHex.Settings^.RenderScale := QualityScale[FOptions.Quality];
end;

procedure TGateGame.SetFullscreen(Value: boolean);
begin
  if FOptions.Fullscreen = Value then Exit;
  FOptions.Fullscreen := Value;
  SaveOptions;
end;

procedure TGateGame.Sound(S: TSfx; Volume: single; Pitch: single);
begin
  if FAudio <> nil then FAudio.Play(S, Volume, Pitch);
end;

{ ---------------------------------------------------------------- flow }

procedure TGateGame.ResetRun;
begin
  FGapAdd := DiffGapAdd[FOptions.Difficulty];
  FSpeedMul := DiffSpeedMul[FOptions.Difficulty];
  FMaxLives := DiffLives[FOptions.Difficulty];
  FScore := 0;
  FLives := FMaxLives;
  FPassed := 0;
  FSpawned := 0;
  FCombo := 0;
  FEnergy := 1;
  FInvuln := 0;
  FFlash := 0;
  FShake := 0;
  FGates := nil;
  FHex.ClearGates;
  FLastGateZ := FHex.CameraPos.Z + 20;
  FLastGX := FPX;
  FLastGY := FPY;
end;

procedure TGateGame.Start;
begin
  case FState of
    gsTitle: ;
    gsGameOver: if FStateTime < 0.8 then Exit;    // no accidental restart
  else
    Exit;
  end;
  ResetRun;
  FState := gsPlaying;
  FStateTime := 0;
  Sound(sfxStart);
  Say('GO!', Rgba(130, 215, 255));
end;

procedure TGateGame.ToMenu;
begin
  FState := gsTitle;
  FScreen := scMain;
  FSel := 0;
  FItems := nil;
  FStateTime := 0;
  ResetRun;
end;

procedure TGateGame.TogglePause;
begin
  if FState = gsPlaying then FState := gsPaused
  else if FState = gsPaused then FState := gsPlaying
  else Exit;
  Sound(sfxMenuMove);
end;

procedure TGateGame.Escape;
begin
  case FState of
    gsTitle:
      if FScreen = scOptions then
      begin
        FScreen := scMain;
        FSel := 1;
        FItems := nil;              // the old screen's rows must not catch the mouse
        Sound(sfxMenuMove);
      end
      else
        RequestExit := True;
    gsPlaying: TogglePause;
    gsPaused, gsGameOver:
      begin
        Sound(sfxMenuMove);
        ToMenu;
      end;
  end;
end;

procedure TGateGame.Say(const S: string; C: TBGRAPixel);
begin
  FMsg := S;
  FMsgColor := C;
  FMsgTime := 1.2;
end;

procedure TGateGame.GameOver;
begin
  FState := gsGameOver;
  FStateTime := 0;
  Sound(sfxGameOver);
  FNewBest := FScore > FBest[FOptions.Difficulty];
  if FNewBest then
  begin
    FBest[FOptions.Difficulty] := FScore;
    SaveOptions;
  end;
end;

{ ------------------------------------------------------------------ menus }

function TGateGame.ItemAt(nx, ny: single): integer;
var
  i: integer;
begin
  for i := 0 to High(FItems) do
    with FItems[i] do
      if (nx >= X0) and (nx <= X1) and (ny >= Y0) and (ny <= Y1) then
        Exit(i);
  Result := -1;
end;

procedure TGateGame.MoveSel(Delta: integer);
var
  n: integer;
begin
  if FScreen = scMain then n := Length(MainItems) else n := OptCount;
  FSel := (FSel + Delta + n) mod n;
  Sound(sfxMenuMove);
end;

// Dir: +1 select / next value, -1 previous value
procedure TGateGame.Activate(Dir: integer);
begin
  if FScreen = scMain then
  begin
    if Dir < 0 then Exit;
    Sound(sfxMenuSelect);
    case FSel of
      0: Start;
      1:
        begin
          FScreen := scOptions;
          FSel := 0;
          FItems := nil;
        end;
      2: RequestExit := True;
    end;
    Exit;
  end;

  case FSel of
    OptMusic: FOptions.MusicVol := EnsureRange(FOptions.MusicVol + Dir, 0, 10);
    OptSfx: FOptions.SfxVol := EnsureRange(FOptions.SfxVol + Dir, 0, 10);
    OptDifficulty: FOptions.Difficulty := (FOptions.Difficulty + Dir + 3) mod 3;
    OptQuality: FOptions.Quality := (FOptions.Quality + Dir + 4) mod 4;
    OptFullscreen: FOptions.Fullscreen := not FOptions.Fullscreen;
    OptFps: FOptions.ShowFps := not FOptions.ShowFps;
    OptBack:
      begin
        if Dir < 0 then Exit;
        FScreen := scMain;
        FSel := 1;
        FItems := nil;
        Sound(sfxMenuSelect);
        Exit;
      end;
  end;
  ApplyOptions;
  SaveOptions;
  Sound(sfxMenuSelect);         // played at the new volume: you hear the change
end;

procedure TGateGame.Notify(const Msg: string);
begin
  Say(Msg, Rgba(130, 215, 255));
end;

function TGateGame.SpecJSON: TJSONObject;

  function Col(c: TBGRAPixel): TJSONArray;
  begin
    Result := TJSONArray.Create([c.red, c.green, c.blue, c.alpha]);
  end;

var
  i: integer;
  A: TJSONArray;
  O, Hud, Pal: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('units', 'world units: hexagon radius = 1 (setting hexagon_field.hex_radius); speeds in units/s');
  Result.Add('player_radius', PlayerR);
  Result.Add('lateral_speed', LatSpeed);
  Result.Add('start_speed', StartSpeed);
  Result.Add('max_speed', MaxSpeed);
  Result.Add('speed_per_gate', SpeedPerGate);
  Result.Add('start_gap', StartGap);
  Result.Add('min_gap', MinGap);
  Result.Add('gap_per_gate', GapPerGate);
  Result.Add('start_spacing', StartSpacing);
  Result.Add('min_spacing', MinSpacing);
  Result.Add('spacing_per_gate', SpacingPerGate);
  Result.Add('boost_factor', BoostFactor);
  Result.Add('boost_drain_per_s', 0.4);
  Result.Add('boost_refill_per_s', 0.12);
  Result.Add('perfect_fraction', 0.35);
  Result.Add('rules', TJSONArray.Create([
    'level = gates spawned in this run (0 in the menu / autopilot)',
    'spacing = max(min_spacing, start_spacing - spacing_per_gate * level)',
    'gap radius = max(1.2, max(min_gap, start_gap - gap_per_gate * level) + difficulty.gap_add)',
    'speed = min(max_speed, start_speed + speed_per_gate * gates_passed) * difficulty.speed_mul (x boost_factor while boosting)',
    'speed eases toward its target: speed += (target - speed) * min(1, dt * 2)',
    'gap centre: random point in the disc of radius corridor_radius - 1.5, at most max_shift from the previous gap,',
    '  max_shift = lateral_speed * spacing / (speed_at_level * difficulty.speed_mul * boost_factor) * 0.7',
    'the first gate of a run is at camera z + 20 + spacing; gates are kept spawned up to camera z + far_clip + 6',
    'passing: distance(ship, gap centre) <= gap radius - player_radius; perfect when < gap radius * perfect_fraction',
    'points: 1 + perfect streak (if perfect), x2 while boosting; a crash costs a life and gives 1 s of protection',
    'ship steering: towards the mouse target (mouse -1..1 * (corridor_radius - 1.5)) or by keys, at lateral_speed;',
    '  clamped to the disc of radius corridor_radius - 1.5',
    'camera = ship: SetManualCamera(x + shake, y + shake, yaw = vx * 0.012, pitch = -vy * 0.008, roll = -vx * 0.02),',
    '  v = smoothed ship velocity (v += (dp/dt - v) * min(1, dt * 8)); shake = (random - 0.5) * shake_amount * 1.2,',
    '  shake_amount = 1 after a crash, -1.5 per second',
    'focus distance = max(2, distance to the next gate), 12 when there is none']));

  A := TJSONArray.Create;
  for i := 0 to 2 do
    A.Add(TJSONObject.Create(['name', DifficultyNames[i], 'gap_add', DiffGapAdd[i],
      'speed_mul', DiffSpeedMul[i], 'lives', DiffLives[i]]));
  Result.Add('difficulties', A);
  A := TJSONArray.Create;
  for i := 0 to 3 do
    A.Add(TJSONObject.Create(['name', QualityNames[i], 'render_scale', QualityScale[i]]));
  Result.Add('graphics_quality', A);
  Result.Add('look_overrides', TJSONObject.Create([
    'note', 'the game changes these engine settings at start (already included in "settings")',
    'hexagon_field.corridor_radius', 10, 'hexagon_field.edge_offset', -20, 'hexagon_field.fade_start', -1,
    'hexagon_field.density', 0.35, 'hexagon_field.loose_chance', 0, 'depth_of_field.focus_pull', 0,
    'depth_of_field.aperture', 0.9, 'camera.look_yaw', 4, 'camera.look_pitch', 3,
    'sparks.field_bias', 0, 'bokeh_dust.count', 70]));

  // ---- HUD
  Hud := TJSONObject.Create;
  Hud.Add('units', 'u = frame height / 100; x, y in pixels of the frame (render size); text y = top of the text');
  Hud.Add('font', TJSONObject.Create(['family', 'Segoe UI', 'weight', 'bold',
    'files', TJSONArray.Create(['segoeuib.ttf', 'seguisb.ttf', 'arialbd.ttf']),
    'size_note', 'text sizes are line heights in pixels (BGRABitmap FontHeight; SDL3_ttf point size = the same number)',
    'shadow', 'black, alpha 180, offset max(1, round(size * 0.06)) px right and down',
    'opacity', 'blinking / fading text is drawn with a copy opacity, blink = 0.55 + 0.45 * sin(time * 5)']));
  Pal := TJSONObject.Create;
  Pal.Add('white', Col(ColWhite));
  Pal.Add('gold', Col(ColGold));
  Pal.Add('soft', Col(ColSoft));
  Pal.Add('title_blue', Col(Rgba(130, 215, 255)));
  Pal.Add('red', Col(Rgba(255, 90, 80)));
  Pal.Add('crash_flash', Col(Rgba(255, 30, 30, 120)));
  Pal.Add('crosshair_far', Col(Rgba(255, 255, 255, 190)));
  Pal.Add('crosshair_in_gap', Col(Rgba(120, 255, 150)));
  Pal.Add('crosshair_outside', Col(Rgba(255, 90, 80)));
  Pal.Add('life_full_rim', Col(Rgba(130, 215, 255)));
  Pal.Add('life_full_fill', Col(Rgba(60, 120, 190, 200)));
  Pal.Add('life_lost', Col(Rgba(120, 130, 150, 140)));
  Pal.Add('boost_bar', Col(Rgba(110, 200, 255)));
  Pal.Add('boost_bar_boosting', Col(Rgba(255, 170, 70)));
  Pal.Add('menu_band', Col(Rgba(4, 8, 18, 140)));
  Pal.Add('menu_row_selected', Col(Rgba(255, 200, 110, 45)));
  Pal.Add('pause_dim', Col(Rgba(0, 0, 0, 120)));
  Pal.Add('game_over_dim', Col(Rgba(0, 0, 0, 100)));
  Hud.Add('palette', Pal);
  Hud.Add('elements', TJSONArray.Create([
    'crash flash: full frame, crash_flash colour with alpha 120 * flash (flash 1 -> 0 at 1.8 per second)',
    'gap ring: ellipse around the projected next gap centre, radius = gap radius * pixels per unit, gold with alpha 70 + 110 * (1 - min(1, distance / 40)), width max(1.5, u * 0.25); only while the gate is more than 1.5 units ahead',
    'crosshair (frame centre): circle radius r = u * 1.6, width u * 0.3, four ticks from r * 1.3 to r * 2.3; colour crosshair_far when the next gate is 15+ units away, else in_gap / outside; flickers (alpha / 3) during protection',
    'SCORE n: (u*3, u*2), white, size u*6, left',
    'BEST n: (u*3, u*9), soft, size u*3.4, left; PERFECT xN (streak > 1): (u*3, u*13.5), gold, size u*3.4',
    'lives: hexagons radius u*2.2 at (W - u*4.5 - i*u*5.5, u*5.5), full: rim life_full_rim width u*0.35 filled life_full_fill; lost: life_lost width u*0.3',
    'SPEED n (speed * 10): (u*3, H - u*8), soft, size u*3.4, left',
    'boost bar: width W*0.24 centred, top H - u*5, height u*1.4, outline white alpha 120 width u*0.2, fill inset u*0.3 by energy (boost_bar / boost_bar_boosting); label BOOST [SPACE] centred at y = bar top - u*4, size u*2.6',
    'message (GO!, PERFECT +n, CRASH!): centred at y = H/2 - u*18, size u*7, alpha 255 * min(1, time_left * 2), 1.2 s',
    'menu: dark band (W/2 +- u*42, H/2 - u*40 .. H/2 + u*44) menu_band; HEXGATE title centred at H/2 - u*38, size u*14, title_blue',
    'main menu: subtitle at H/2 - u*20 size u*3.4 soft; items PLAY / OPTIONS / EXIT at H/2 - u*8 + i*u*11; selected: gold size u*6.5 between hexagons radius u*1.6 at x = W/2 +- u*17 (fill gold alpha 90*blink); others white alpha 200 size u*5.5; best line at H/2 + u*30; help at H - u*7 size u*2.5',
    'options: header OPTIONS at H/2 - u*22 size u*5.5; rows at H/2 - u*12 + i*u*7 (BACK + u*2), label at W/2 - u*34 size u*3.8, value right-aligned at W/2 + u*34; selected row band menu_row_selected; volume = 10 hexagons over u*26 ending u*7 before the value',
    'pause: pause_dim over the frame, PAUSED size u*10 at H/2 - u*10, hint at H/2 + u*4 size u*4',
    'game over: game_over_dim, GAME OVER size u*12 red at H/2 - u*22, SCORE size u*7 at H/2 - u*6, best / NEW BEST! at H/2 + u*3, hint at H/2 + u*13',
    'FPS (option): bottom right, size u*2.8 at H - u*5, detail line size u*2.2 at H - u*8.5']));
  Result.Add('hud', Hud);
end;

procedure TGateGame.MenuKey(Key: Word);
begin
  if FState <> gsTitle then Exit;
  case Key of
    VK_UP, VK_W: MoveSel(-1);
    VK_DOWN, VK_S: MoveSel(1);
    VK_LEFT, VK_A: if FScreen = scOptions then Activate(-1);
    VK_RIGHT, VK_D: if FScreen = scOptions then Activate(1);
    VK_RETURN, VK_SPACE: Activate(1);
  end;
end;

// Left click: choose / next value, right click: previous value.
// Clicking on a volume bar sets the volume to that spot.
procedure TGateGame.Click(Right: boolean);
var
  i: integer;
  nx: single;
begin
  case FState of
    gsTitle:
      begin
        nx := (MouseX + 1) / 2;
        i := ItemAt(nx, (MouseY + 1) / 2);
        if i < 0 then Exit;
        FSel := i;
        if (FScreen = scOptions) and (i in [OptMusic, OptSfx]) and
          (nx >= FBarX0 - 0.01) and (nx <= FBarX1 + 0.01) then
        begin
          if i = OptMusic then
            FOptions.MusicVol := EnsureRange(Round((nx - FBarX0) / (FBarX1 - FBarX0) * 10), 0, 10)
          else
            FOptions.SfxVol := EnsureRange(Round((nx - FBarX0) / (FBarX1 - FBarX0) * 10), 0, 10);
          ApplyOptions;
          SaveOptions;
          Sound(sfxMenuSelect);
        end
        else if Right then
          Activate(-1)
        else
          Activate(1);
      end;
    gsGameOver: if not Right then Start;
  end;
end;

{ ---------------------------------------------------------------- update }

function TGateGame.NextGate: integer;
var
  i: integer;
begin
  for i := 0 to High(FGates) do
    if not FGates[i].Resolved and (FGates[i].Z > FHex.CameraPos.Z) then
      Exit(i);
  Result := -1;
end;

// Keep gates queued up to just beyond the view distance.
procedure TGateGame.SpawnGates;
var
  lvl, spacing, gr, spd, maxShift, lim, a, rr, gx, gy, d: single;
  Tries, i: integer;
begin
  lim := FHex.Settings^.CorridorRadius - 1.5;
  while FLastGateZ < FHex.CameraPos.Z + FHex.Settings^.FarClip + 6 do
  begin
    if FState = gsPlaying then lvl := FSpawned else lvl := 0;
    spacing := Max(MinSpacing, StartSpacing - SpacingPerGate * lvl);
    gr := Max(1.2, Max(MinGap, StartGap - GapPerGate * lvl) + FGapAdd);
    // worst case: boosting at the speed of that gate
    spd := Min(MaxSpeed, StartSpeed + SpeedPerGate * lvl) * FSpeedMul * BoostFactor;
    maxShift := LatSpeed * spacing / spd * 0.7;
    Tries := 0;
    repeat
      a := Random * 2 * Pi;
      rr := Sqrt(Random) * lim;
      gx := rr * Cos(a);
      gy := rr * Sin(a);
      d := Sqrt(Sqr(gx - FLastGX) + Sqr(gy - FLastGY));
      Inc(Tries);
    until (d <= maxShift) or (Tries > 30);
    if d > maxShift then
    begin
      // pull the random point back within reach
      gx := FLastGX + (gx - FLastGX) * maxShift / d;
      gy := FLastGY + (gy - FLastGY) * maxShift / d;
    end;
    FLastGateZ := FLastGateZ + spacing;
    FLastGX := gx;
    FLastGY := gy;
    i := Length(FGates);
    SetLength(FGates, i + 1);
    FGates[i].Z := FLastGateZ;
    FGates[i].GX := gx;
    FGates[i].GY := gy;
    FGates[i].GR := gr;
    FGates[i].Resolved := False;
    FHex.AddGate(FLastGateZ, gx, gy, gr);
    if FState = gsPlaying then Inc(FSpawned);
  end;
end;

procedure TGateGame.Update(dt: single);
var
  ox, oy, lim, l, kx, ky, target, z0, z1, d: single;
  i, g, pts: integer;

  procedure MoveToward(tx, ty: single);
  var
    dx, dy, len, step: single;
  begin
    dx := tx - FPX;
    dy := ty - FPY;
    len := Sqrt(dx * dx + dy * dy);
    step := LatSpeed * dt;
    if len <= step then
    begin
      FPX := tx;
      FPY := ty;
    end
    else
    begin
      FPX := FPX + dx / len * step;
      FPY := FPY + dy / len * step;
    end;
  end;

begin
  FTime := FTime + dt;

  // music follows the game
  if FAudio <> nil then
  begin
    case FState of
      gsPlaying, gsPaused:
        FAudio.Intensity := 0.45 + 0.55 * EnsureRange((FSpeed - StartSpeed) / (MaxSpeed - StartSpeed), 0, 1);
      gsGameOver: FAudio.Intensity := 0.1;
    else
      FAudio.Intensity := 0;
    end;
    FAudio.Paused := FState = gsPaused;
    FAudio.Boost := FBoosting and (FState = gsPlaying);
  end;

  // menu: the item under a moving mouse becomes the selection
  if (FState = gsTitle) and MouseActive and ((MouseX <> FLastMouseX) or (MouseY <> FLastMouseY)) then
  begin
    i := ItemAt((MouseX + 1) / 2, (MouseY + 1) / 2);
    if (i >= 0) and (i <> FSel) then
    begin
      FSel := i;
      Sound(sfxMenuMove);
    end;
  end;
  FLastMouseX := MouseX;
  FLastMouseY := MouseY;

  if FState = gsPaused then Exit;
  FStateTime := FStateTime + dt;
  FFlash := Max(0, FFlash - dt * 1.8);
  FShake := Max(0, FShake - dt * 1.5);
  FInvuln := Max(0, FInvuln - dt);
  FMsgTime := Max(0, FMsgTime - dt);

  // ---- steering
  ox := FPX;
  oy := FPY;
  lim := FHex.Settings^.CorridorRadius - 1.5;
  if FState = gsPlaying then
  begin
    kx := Ord(KeyRight) - Ord(KeyLeft);
    ky := Ord(KeyDown) - Ord(KeyUp);
    if (kx <> 0) or (ky <> 0) then
    begin
      MouseActive := False;            // keys win until the mouse moves again
      l := Sqrt(kx * kx + ky * ky);
      FPX := FPX + kx / l * LatSpeed * dt;
      FPY := FPY + ky / l * LatSpeed * dt;
    end
    else if MouseActive then
      MoveToward(MouseX * lim, MouseY * lim);
  end
  else
  begin
    // menu / game over: the autopilot shows the way
    g := NextGate;
    if g >= 0 then MoveToward(FGates[g].GX, FGates[g].GY) else MoveToward(0, 0);
  end;
  l := Sqrt(FPX * FPX + FPY * FPY);
  if l > lim then
  begin
    FPX := FPX * lim / l;
    FPY := FPY * lim / l;
  end;
  if dt > 0 then
  begin
    FVX := FVX + ((FPX - ox) / dt - FVX) * Min(1, dt * 8);
    FVY := FVY + ((FPY - oy) / dt - FVY) * Min(1, dt * 8);
  end;

  // ---- speed and boost
  FBoosting := (FState = gsPlaying) and KeyBoost and (FEnergy > 0.02);
  if FBoosting then FEnergy := Max(0, FEnergy - 0.4 * dt)
  else FEnergy := Min(1, FEnergy + 0.12 * dt);
  case FState of
    gsPlaying:
      begin
        target := Min(MaxSpeed, StartSpeed + SpeedPerGate * FPassed) * FSpeedMul;
        if FBoosting then target := target * BoostFactor;
      end;
    gsGameOver: target := 3;
  else
    target := StartSpeed;
  end;
  FSpeed := FSpeed + (target - FSpeed) * Min(1, dt * 2);
  FHex.Settings^.Speed := FSpeed;

  SpawnGates;

  // ---- gates reached during this step
  z0 := FHex.CameraPos.Z;
  z1 := z0 + FSpeed * dt;
  for i := 0 to High(FGates) do
    with FGates[i] do
      if not Resolved and (Z > z0) and (Z <= z1) then
      begin
        Resolved := True;
        if FState <> gsPlaying then
        begin
          Sound(sfxWhoosh, 0.25);        // the autopilot's flights are quieter
          Continue;
        end;
        d := Sqrt(Sqr(FPX - GX) + Sqr(FPY - GY));
        if d <= GR - PlayerR then
        begin
          Inc(FPassed);
          pts := 1;
          Sound(sfxWhoosh, 0.7);
          if d < GR * 0.35 then
          begin
            Inc(FCombo);
            pts := pts + FCombo;
            Sound(sfxPerfect, 0.9, 1 + Min(FCombo, 6) * 0.05);
            if FBoosting then
              Say(Format('PERFECT +%d', [pts * 2]), ColGold)
            else
              Say(Format('PERFECT +%d', [pts]), ColGold);
          end
          else
          begin
            FCombo := 0;
            Sound(sfxPass, 0.8);
          end;
          if FBoosting then pts := pts * 2;
          Inc(FScore, pts);
        end
        else if FInvuln <= 0 then
        begin
          Dec(FLives);
          FCombo := 0;
          FFlash := 1;
          FShake := 1;
          FInvuln := 1;
          Sound(sfxCrash);
          if FLives <= 0 then GameOver else Say('CRASH!', Rgba(255, 80, 70));
        end;
      end;
  while (Length(FGates) > 0) and (FGates[0].Z < z0 - 2) do
    Delete(FGates, 0, 1);

  // ---- camera: the ship, leaning into its motion, shaking after a crash
  FHex.SetManualCamera(FPX + (Random - 0.5) * FShake * 1.2, FPY + (Random - 0.5) * FShake * 1.2,
    FVX * 0.012, -FVY * 0.008, -FVX * 0.02);
  g := NextGate;
  if g >= 0 then FHex.FocusOverride := Max(2, FGates[g].Z - z0)
  else FHex.FocusOverride := 12;
end;

{ ------------------------------------------------------------------- draw }

procedure TGateGame.DrawMenu(Bmp: TBGRABitmap);
var
  W, H, i: integer;
  u, cx, cy, y, x0, x1, blink, a, bw: single;
  Sel: boolean;
  Lbl, Val: string;
  C: TBGRAPixel;

  procedure Item(Index: integer; const Rx0, Ry0, Rx1, Ry1: single);
  begin
    FItems[Index].X0 := Rx0 / W;
    FItems[Index].Y0 := Ry0 / H;
    FItems[Index].X1 := Rx1 / W;
    FItems[Index].Y1 := Ry1 / H;
  end;

  procedure Bar(x, yc, Width: single; Value: integer);
  var
    k: integer;
  begin
    // volume as ten little hexagons
    for k := 0 to 9 do
      if k < Value then
        Bmp.DrawPolygonAntialias(HexPolygon(x + k * Width / 10 + Width / 20, yc, Width / 24),
          ColGold(230), 1, ColGold(160))
      else
        Bmp.DrawPolygonAntialias(HexPolygon(x + k * Width / 10 + Width / 20, yc, Width / 24),
          ColSoft(120), 1);
  end;

begin
  W := Bmp.Width;
  H := Bmp.Height;
  u := H / 100;
  cx := W / 2;
  cy := H / 2;
  blink := 0.55 + 0.45 * Sin(FTime * 5);

  // a dark band behind the menu keeps it readable over the moving field
  Bmp.FillRect(Round(cx - u * 42), Round(cy - u * 40), Round(cx + u * 42), Round(cy + u * 44),
    Rgba(4, 8, 18, 140), dmDrawWithTransparency);
  DrawText(Bmp, cx, cy - u * 38, 'HEXGATE', Rgba(130, 215, 255), u * 14, taCenter);

  if FScreen = scMain then
  begin
    if FSel > High(MainItems) then FSel := 0;
    SetLength(FItems, Length(MainItems));
    DrawText(Bmp, cx, cy - u * 20, 'Thread the gaps in the honeycomb walls', ColSoft, u * 3.4, taCenter);
    for i := 0 to High(MainItems) do
    begin
      y := cy - u * 8 + i * u * 11;
      Sel := i = FSel;
      if Sel then
      begin
        // selected: gold text between two glowing hexagons
        DrawText(Bmp, cx, y, MainItems[i], ColGold, u * 6.5, taCenter);
        Bmp.DrawPolygonAntialias(HexPolygon(cx - u * 17, y + u * 4.2, u * 1.6), ColGold, u * 0.4, ColGold(90 * blink));
        Bmp.DrawPolygonAntialias(HexPolygon(cx + u * 17, y + u * 4.2, u * 1.6), ColGold, u * 0.4, ColGold(90 * blink));
      end
      else
        DrawText(Bmp, cx, y, MainItems[i], Rgba(225, 235, 250, 200), u * 5.5, taCenter);
      Item(i, cx - u * 20, y - u * 1, cx + u * 20, y + u * 9.5);
    end;
    DrawText(Bmp, cx, cy + u * 30, Format('BEST (%s)  %d',
      [DifficultyNames[FOptions.Difficulty], FBest[FOptions.Difficulty]]), ColSoft, u * 3.2, taCenter);
    DrawText(Bmp, cx, H - u * 7, 'Mouse or Up/Down + Enter   -   in game: mouse / WASD steer, hold Space boost, P pause',
      ColSoft(210), u * 2.5, taCenter);
  end
  else
  begin
    if FSel >= OptCount then FSel := 0;
    SetLength(FItems, OptCount);
    DrawText(Bmp, cx, cy - u * 22, 'OPTIONS', ColWhite, u * 5.5, taCenter);
    x0 := cx - u * 34;
    x1 := cx + u * 34;
    for i := 0 to OptCount - 1 do
    begin
      y := cy - u * 12 + i * u * 7;
      if i = OptBack then y := y + u * 2;
      Sel := i = FSel;
      if Sel then
        Bmp.FillRect(Round(x0 - u), Round(y - u * 0.6), Round(x1 + u), Round(y + u * 5.8),
          Rgba(255, 200, 110, 45), dmDrawWithTransparency);
      if Sel then C := ColGold else C := Rgba(225, 235, 250, 220);
      Item(i, x0 - u, y - u * 0.6, x1 + u, y + u * 5.8);
      case i of
        OptMusic: Lbl := 'MUSIC';
        OptSfx: Lbl := 'SOUND EFFECTS';
        OptDifficulty: Lbl := 'DIFFICULTY';
        OptQuality: Lbl := 'GRAPHICS';
        OptFullscreen: Lbl := 'FULLSCREEN';
        OptFps: Lbl := 'SHOW FPS';
      else
        Lbl := 'BACK';
      end;
      if i = OptBack then
      begin
        DrawText(Bmp, cx, y, Lbl, C, u * 4.2, taCenter);
        Continue;
      end;
      DrawText(Bmp, x0, y, Lbl, C, u * 3.8, taLeftJustify);
      case i of
        OptMusic, OptSfx:
          begin
            bw := u * 26;
            FBarX0 := (x1 - bw - u * 7) / W;
            FBarX1 := (x1 - u * 7) / W;
            if i = OptMusic then Bar(x1 - bw - u * 7, y + u * 2.6, bw, FOptions.MusicVol)
            else Bar(x1 - bw - u * 7, y + u * 2.6, bw, FOptions.SfxVol);
            if i = OptMusic then Val := IntToStr(FOptions.MusicVol * 10)
            else Val := IntToStr(FOptions.SfxVol * 10);
            DrawText(Bmp, x1, y, Val, C, u * 3.8, taRightJustify);
          end;
        OptDifficulty: DrawText(Bmp, x1, y, '<  ' + DifficultyNames[FOptions.Difficulty] + '  >', C, u * 3.8, taRightJustify);
        OptQuality: DrawText(Bmp, x1, y, '<  ' + QualityNames[FOptions.Quality] + '  >', C, u * 3.8, taRightJustify);
        OptFullscreen: DrawText(Bmp, x1, y, BoolToStr(FOptions.Fullscreen, 'ON', 'OFF'), C, u * 3.8, taRightJustify);
        OptFps: DrawText(Bmp, x1, y, BoolToStr(FOptions.ShowFps, 'ON', 'OFF'), C, u * 3.8, taRightJustify);
      end;
    end;
    a := 210;
    DrawText(Bmp, cx, cy + u * 37, 'Left/Right or click to change   -   Esc back', ColSoft(a), u * 2.6, taCenter);
  end;
end;

procedure TGateGame.DrawHud(Bmp: TBGRABitmap);
var
  W, H, i, g: integer;
  u, cx, cy, sx, sy, ppu, r, bw, bx, by, blink: single;
  Col: TBGRAPixel;
  InGap, Near: boolean;
begin
  W := Bmp.Width;
  H := Bmp.Height;
  u := H / 100;
  cx := W / 2;
  cy := H / 2;
  blink := 0.55 + 0.45 * Sin(FTime * 5);

  if FFlash > 0 then
    Bmp.FillRect(0, 0, W, H, Rgba(255, 30, 30, 120 * FFlash), dmDrawWithTransparency);

  if FState in [gsPlaying, gsPaused] then
  begin
    // ring around the next gap
    g := NextGate;
    InGap := False;
    Near := False;
    if g >= 0 then
      with FGates[g] do
      begin
        if (Z - FHex.CameraPos.Z > 1.5) and FHex.ProjectPoint(GX, GY, Z, W, H, sx, sy, ppu) then
          Bmp.EllipseAntialias(sx, sy, GR * ppu, GR * ppu,
            ColGold(70 + 110 * (1 - Min(1, (Z - FHex.CameraPos.Z) / 40))), Max(1.5, u * 0.25));
        InGap := Sqrt(Sqr(FPX - GX) + Sqr(FPY - GY)) <= GR - PlayerR;
        Near := Z - FHex.CameraPos.Z < 15;
      end;

    // crosshair = where the ship is; green inside the gap, red outside
    if not Near then Col := Rgba(255, 255, 255, 190)
    else if InGap then Col := Rgba(120, 255, 150)
    else Col := Rgba(255, 90, 80);
    if (FInvuln > 0) and (Frac(FTime * 8) < 0.5) then Col.alpha := Col.alpha div 3;
    r := u * 1.6;
    Bmp.EllipseAntialias(cx, cy, r, r, Col, u * 0.3);
    Bmp.DrawLineAntialias(cx - r * 2.3, cy, cx - r * 1.3, cy, Col, u * 0.3);
    Bmp.DrawLineAntialias(cx + r * 1.3, cy, cx + r * 2.3, cy, Col, u * 0.3);
    Bmp.DrawLineAntialias(cx, cy - r * 2.3, cx, cy - r * 1.3, Col, u * 0.3);
    Bmp.DrawLineAntialias(cx, cy + r * 1.3, cx, cy + r * 2.3, Col, u * 0.3);

    // score, best, combo
    DrawText(Bmp, u * 3, u * 2, 'SCORE ' + IntToStr(FScore), ColWhite, u * 6, taLeftJustify);
    DrawText(Bmp, u * 3, u * 9, 'BEST ' + IntToStr(Max(FBest[FOptions.Difficulty], FScore)), ColSoft, u * 3.4, taLeftJustify);
    if FCombo > 1 then
      DrawText(Bmp, u * 3, u * 13.5, Format('PERFECT x%d', [FCombo]), ColGold, u * 3.4, taLeftJustify);

    // lives as hexagons, top right
    for i := 0 to FMaxLives - 1 do
    begin
      sx := W - u * 4.5 - i * u * 5.5;
      sy := u * 5.5;
      if i < FLives then
        Bmp.DrawPolygonAntialias(HexPolygon(sx, sy, u * 2.2), Rgba(130, 215, 255), u * 0.35, Rgba(60, 120, 190, 200))
      else
        Bmp.DrawPolygonAntialias(HexPolygon(sx, sy, u * 2.2), Rgba(120, 130, 150, 140), u * 0.3);
    end;

    // speed and boost energy, bottom
    DrawText(Bmp, u * 3, H - u * 8, Format('SPEED %d', [Round(FSpeed * 10)]), ColSoft, u * 3.4, taLeftJustify);
    bw := W * 0.24;
    bx := cx - bw / 2;
    by := H - u * 5;
    if FBoosting then Col := Rgba(255, 170, 70) else Col := Rgba(110, 200, 255);
    Bmp.RectangleAntialias(bx, by, bx + bw, by + u * 1.4, Rgba(255, 255, 255, 120), u * 0.2);
    if FEnergy > 0.005 then
      Bmp.FillRectAntialias(bx + u * 0.3, by + u * 0.3, bx + u * 0.3 + (bw - u * 0.6) * FEnergy, by + u * 1.1, Col);
    DrawText(Bmp, cx, by - u * 4, 'BOOST  [SPACE]', ColSoft, u * 2.6, taCenter);
  end;

  if FMsgTime > 0 then
    DrawText(Bmp, cx, cy - u * 18, FMsg, Rgba(FMsgColor.red, FMsgColor.green, FMsgColor.blue,
      255 * Min(1, FMsgTime * 2)), u * 7, taCenter);

  case FState of
    gsTitle: DrawMenu(Bmp);
    gsPaused:
      begin
        Bmp.FillRect(0, 0, W, H, Rgba(0, 0, 0, 120), dmDrawWithTransparency);
        DrawText(Bmp, cx, cy - u * 10, 'PAUSED', ColWhite, u * 10, taCenter);
        DrawText(Bmp, cx, cy + u * 4, 'P continue   -   Esc main menu', ColGold(255 * blink), u * 4, taCenter);
      end;
    gsGameOver:
      begin
        Bmp.FillRect(0, 0, W, H, Rgba(0, 0, 0, 100), dmDrawWithTransparency);
        DrawText(Bmp, cx, cy - u * 22, 'GAME OVER', Rgba(255, 90, 80), u * 12, taCenter);
        DrawText(Bmp, cx, cy - u * 6, 'SCORE ' + IntToStr(FScore), ColWhite, u * 7, taCenter);
        if FNewBest then
          DrawText(Bmp, cx, cy + u * 3, 'NEW BEST!', ColGold(255 * blink), u * 4.5, taCenter)
        else
          DrawText(Bmp, cx, cy + u * 3, Format('BEST (%s)  %d', [DifficultyNames[FOptions.Difficulty],
            FBest[FOptions.Difficulty]]), ColSoft, u * 4, taCenter);
        if FStateTime > 0.8 then
          DrawText(Bmp, cx, cy + u * 13, 'Click or Space: play again   -   Esc: main menu', ColGold(255 * blink), u * 3.6, taCenter);
      end;
  end;

  if FOptions.ShowFps then
  begin
    DrawText(Bmp, W - u * 2, H - u * 5, Format('%.0f FPS', [Fps]), ColSoft(200), u * 2.8, taRightJustify);
    DrawText(Bmp, W - u * 2, H - u * 8.5, FpsDetail, ColSoft(170), u * 2.2, taRightJustify);
  end;
end;

initialization

finalization
  TextCache.Free;

end.
