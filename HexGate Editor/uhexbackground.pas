unit UHexBackground;

{ HexGate edition: on top of the HexFlight renderer it adds gate walls
  (AddGate / ClearGates), a clear corridor along the flight path
  (CorridorRadius), a camera driven by the game (SetManualCamera) and a
  focus distance set by the game (FocusOverride). }

{ Hex Background - camera fly-through of a 3D hexagon field (BGRABitmap).

  World
    Hexagon cells live in world space on honeycomb sheets stacked along +Z
    (one sheet every SheetGap, each cell jittered in Z, so it reads as a
    volume). Sheets are generated deterministically from Seed when they come
    into range ahead of the camera and dropped once behind it, so the field
    is endless. A diagonal mask keeps the cells in the lower-right half of the
    view and dissolves its edge into loose hexagons; 3D value noise breaks the
    field into clusters.

  Camera
    Flies forward along +Z at Speed with slow sway, roll and look-around; the
    mouse steers it (yaw / pitch). The focus distance drifts (focus pull).
    Everything depth-related comes from the distance to the camera:
      size      f x R / z                     (perspective)
      blur      circle of confusion = Aperture x |z - focus| / z
      fade      fog far away, near-fade close to the lens
      glow      strongest at the focus distance
      3D        back face = centre + (0, 0, Thickness) projected -> real
                perspective extrusion toward the vanishing point

  Rendering (real time)
    Each hexagon is drawn from cached sprites, one per (kind, size bucket,
    blur bucket). A sprite is rendered once (DrawPolygonAntialias +
    FilterBlurRadial), stored premultiplied, and drawn by BlitSprite with
    bilinear filtering at its exact sub-pixel position and exact size, so
    motion and growth are continuous. In the live view new sprites are
    built by two low-priority background threads (a big blurred one can
    take 50 ms); until one arrives the nearest cached sprite is scaled in,
    so frames never wait for it. Hexagons are sorted back to front.

  Parallel frame
    The main thread only builds a draw list (blits, antialiased lines,
    discs). Then all cores fill the frame in 16-row tiles taken from a shared
    counter; each tile copies the background rows, runs every command that
    touches it (clipped to the tile) and applies the vignette. Tiles never
    overlap, so no locking is needed and the drawing order is kept.

  Passes (each can be switched off or viewed alone)
    0 Background  1 Bokeh dust  2 Hex back faces  3 Hex side edges
    4 Hex glow    5 Hex front faces  6 Sparks  7 Vignette }

{$mode objfpc}{$H+}
{$Q-}{$R-}

interface

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  Classes, SysUtils, Math, IniFiles, BGRABitmap, BGRABitmapTypes;

const
  PassCount = 8;
  psBase = 0;
  psDust = 1;
  psBack = 2;
  psSides = 3;
  psGlow = 4;
  psFront = 5;
  psSparks = 6;
  psVignette = 7;

type
  TPassSet = set of 0..PassCount - 1;
  TInvalidate = (ivSprites, ivScreen, ivField, ivDust, ivSparks);
  TInvalidateSet = set of TInvalidate;

  TVec3 = record
    X, Y, Z: single;
  end;

  THexSettings = record
    // camera
    Fov, Speed, SwayX, SwayY, SwayFreq, RollAmp, LookYaw, LookPitch, LookFreq: single;
    MouseSteer, MouseSmooth, NearClip, FarClip: single;
    // depth of field
    FocusDist, FocusPullAmp, FocusPullFreq, Aperture, MaxBlur: single;
    // fog
    FogStart, FogEnd, NearFadeStart, NearFadeEnd: single;
    // hexagon field
    HexRadius, Gap, SheetGap, ZJitter, Thickness, SizeJitter: single;
    LayoutDist, EdgeSlope, EdgeOffset, FadeStart, FadeEnd, Density: single;
    NoiseScale, ClusterLo, ClusterHi, ClusterMin: single;
    LooseChance, LooseZone, LooseDrift, LooseShrink: single;
    // hexagon style
    EdgeColor, FillColor, BackColor, InnerColor, SpecColor, GlowColor: TBGRAPixel;
    LineWidth, RimAlpha, FillAlpha, BackAlpha, InnerSize, InnerAlpha, SpecAlpha: single;
    SideAlpha, SideMaxBlur: single;
    GlowWidth, GlowStrength, GlowBlur, GlowBase, GlowRange: single;
    // background
    BaseColor: TBGRAPixel;
    HazeColor: array[0..2] of TBGRAPixel;
    HazeX, HazeY, HazeR: array[0..2] of single;
    // bokeh dust
    DustCount, DustSizeMin, DustSizeMax, DustAlphaMin, DustAlphaMax, DustMinBlur: single;
    DustDotChance, DustDotSize: single;
    DustColor, DustDotColor: TBGRAPixel;
    // vignette
    VigAlpha, VigX, VigY, VigRadius, ShadowAlpha, ShadowX, ShadowY: single;
    // sparks
    SparkCount, SparkFieldBias, SparkSizeMin, SparkSizeMax, SparkAlphaMin, SparkAlphaMax: single;
    SparkRiseMin, SparkRiseMax, SparkSway, SparkLifeMin, SparkLifeMax: single;
    SparkTwinkleMin, SparkTwinkleMax, SparkTwinkleDepth, SparkHaloSize, SparkHaloAlpha: single;
    SparkCoreColor, SparkHaloColor: TBGRAPixel;
    // performance
    RenderScale, SizeStep, BlurStep, CacheMB, SpriteBudget, Threads: single;
    // game
    CorridorRadius, GateFillAlpha: single;
    GateRimColor, GateEdgeColor, GateEdgeGlow: TBGRAPixel;
  end;
  PHexSettings = ^THexSettings;

  TParamKind = (pkFloat, pkColor);

  TParamInfo = record
    Group, Name, Hint: string;
    Kind: TParamKind;
    PValue: PSingle;
    PColor: PBGRAPixel;
    Min, Max: single;
    Decimals: integer;
    Effects: TInvalidateSet;   // caches to rebuild when it changes (empty = live)
  end;
  TParamList = array of TParamInfo;

  TPass = record
    Name, Technique: string;
    Enabled: boolean;
    Items: integer;            // drawn in the last main frame
    TimeMs: double;            // smoothed time per main frame
  end;
  PPass = ^TPass;

  TCell = record
    X, Y, Z, R: single;
    Loose: boolean;
  end;

  TSheet = record
    K: integer;
    Cells: array of TCell;
  end;

  TDrawItem = record
    Z, SX, SY, R, Blur, Opa, BX, BY, BR: single;
    Kind: byte;                       // 0 ambient, 1 gate wall, 2 gate gap rim
  end;

  // A honeycomb wall across the corridor with one round gap.
  TGate = record
    Z, GX, GY, GR, Ext: single;       // gap centre / radius, disc radius
    Cells: array of TCell;
    Kinds: array of byte;
  end;

  TParticle = record
    P: TVec3;
    Size, Alpha, Life, LifeSpeed, Phase, Twinkle, Rise: single;
    Dot: boolean;
  end;

  TScreenCache = record
    W, H: integer;
    Base, Vig: TBGRABitmap;
    Stamp: QWord;
  end;

  TFrameStats = record
    Sheets, Cells, Visible, Culled, SpritesMade, Borrowed, Threads, Commands: integer;
    FrameMs, SetupMs, DrawMs: double;
    Queued, Skipped: integer;
  end;

  // Cached hexagon / disc image, premultiplied alpha, drawn by BlitSprite
  // at any fractional position and scale.
  TSprite = class
    W: integer;
    Rq: single;                       // hex radius it was rendered at, px
    Pix: array of TBGRAPixel;
    Handle: Pointer;                  // GPU copy owned by an output backend (or nil)
    Kind: integer;                    // sprite kind (SpriteKindNames)
    Bq: single;                       // blur radius it was rendered with, px
    destructor Destroy; override;
  end;

  // Called (main thread) when a sprite with a Handle is freed, so the
  // backend can release its GPU copy.
  TSpriteFreeHook = procedure(Spr: TSprite);

  // One drawing operation of a frame. The frame is first turned into a list
  // of these (serial), then the list is executed tile by tile on all cores.
  TCmdKind = (ckBlit, ckLine, ckDisc);
  TDrawCmd = record
    Kind: TCmdKind;
    Pass: integer;
    Y0, Y1: integer;                  // rows it can touch
    Spr: TSprite;
    X, Y, S, A, X2, Y2, HW: single;   // blit: centre, scale, opacity; disc: centre, radius
    CR, CG, CB, CA: integer;          // premultiplied colour of lines and discs
  end;
  PDrawCmd = ^TDrawCmd;

  THexBackground = class;

  // A sprite waiting to be built in the background. It carries its own copy
  // of the settings, so a slider change during the build cannot race.
  TSpriteReq = record
    Kind, Si, Bi, Gen: integer;
    Rq, Bq: single;
    Settings: THexSettings;
    Spr: TSprite;
  end;

  TSpriteBuilder = class(TThread)
  private
    FOwner: THexBackground;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: THexBackground);
  end;

  TRenderWorker = class(TThread)
  private
    FOwner: THexBackground;
    FSlot: integer;
    FStart, FDone: PRTLEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: THexBackground; ASlot: integer);
    destructor Destroy; override;
  end;

  { THexBackground }

  THexBackground = class
  private
    FSettings: THexSettings;
    FParams: TParamList;
    FPasses: array[0..PassCount - 1] of TPass;
    FSeed: integer;
    FRng: cardinal;
    FTime: double;
    // camera
    FCam: TVec3;
    FYaw, FPitch, FRoll, FFocus: single;
    FMouseX, FMouseY, FSteerYaw, FSteerPitch: single;
    FSinY, FCosY, FSinP, FCosP, FSinR, FCosR: single;
    // world
    FSheets: array of TSheet;
    FGates: array of TGate;
    FManual: boolean;
    FManX, FManY, FManYaw, FManPitch, FManRoll, FFocusOverride: single;
    FItems: array of TDrawItem;
    FItemCount: integer;
    FDust, FSparks: array of TParticle;
    // caches
    FSprites: array[0..8, 0..255, 0..63] of TSprite;
    FPending: array[0..8, 0..255, 0..63] of boolean;   // queued for a builder
    FBudgetEnd: double;
    // background sprite builders
    FAsync: boolean;
    FBuilders: array of TSpriteBuilder;
    FBuildLock: TRTLCriticalSection;
    FBuildWake: PRTLEvent;
    FQueue, FBuilt: array of TSpriteReq;
    FQueueCount, FBuiltCount, FGen: integer;
    // parallel drawing
    FWorkers: array of TRenderWorker;
    FCmds: array of TDrawCmd;
    FCmdCount: integer;
    FRows, FBaseRows, FVigRows: array of PBGRAPixel;
    FJobW, FJobH, FTileCount: integer;
    FJobBase, FJobVig: boolean;
    FN: array[0..PassCount - 1] of integer;   // items per pass of the last frame
    FScr: integer;                            // screen cache slot of the last frame
    FScreenGen: integer;                      // +1 whenever a background / vignette is (re)made
    FBuildStart: double;
    FNextTile: longint;
    FSlotT: array of double;
    FSpriteBytes: Int64;
    FSpriteCount, FSpritesTotal: integer;
    FLnSize, FLnBlur: single;
    FSizeOff: integer;
    FScreens: array[0..3] of TScreenCache;
    FStamp: QWord;
    FStats: TFrameStats;
    function Rnd: single;
    function RandRange(AMin, AMax: single): single;
    procedure UpdateCamera;
    procedure ToCamera(x, y, z: single; out V: TVec3);
    function MaskT(x, y: single): single;
    function Cluster(x, y, z: single): single;
    function Coc(z, H: single): single;
    function Fade(z: single): single;
    procedure GenerateSheet(K: integer; out S: TSheet);
    procedure UpdateField;
    procedure SpawnDust(var D: TParticle; Anywhere: boolean);
    procedure SpawnSpark(var S: TParticle; Anywhere: boolean);
    procedure InitParticles;
    procedure ClearSprites;
    procedure ClearScreens;
    function MakeSprite(Kind: integer; rq, bq: single): TSprite;
    procedure AccountSprite(Spr: TSprite);
    procedure EnqueueSprite(Kind, si, bi: integer; rq, bq: single);
    procedure CollectBuiltSprites;
    function PopRequest(out Req: TSpriteReq): boolean;
    procedure PushBuilt(const Req: TSpriteReq);
    function GetSprite(Kind: integer; r, blur: single; out Scale: single): TSprite;
    function GetScreen(W, H: integer): integer;
    procedure RenderBase(Bmp: TBGRABitmap; W, H: integer);
    procedure RenderVignette(Bmp: TBGRABitmap; W, H: integer);
    procedure CollectItems(W, H: integer; f: single);
    procedure EnsureWorkers;
    procedure FreeWorkers;
    procedure RunTiles(Slot: integer);
    function NewCmd(AKind: TCmdKind; APass: integer): PDrawCmd;
    procedure AddBlit(APass: integer; Spr: TSprite; x, y, Scale, Opacity: single);
    procedure AddLine(APass: integer; x1, y1, x2, y2, Width: single; Col: TBGRAPixel; Alpha: single);
    procedure AddDisc(APass: integer; x, y, Radius: single; Col: TBGRAPixel; Alpha: single);
    procedure BlitTile(C: PDrawCmd; ty0, ty1: integer);
    procedure LineTile(C: PDrawCmd; ty0, ty1: integer);
    procedure DiscTile(C: PDrawCmd; ty0, ty1: integer);
    procedure SortItems(L, R: integer);
    procedure BuildParams;
    function GetPass(Index: integer): PPass;
    function GetSettings: PHexSettings;
  public
    constructor Create;
    destructor Destroy; override;
    procedure ResetDefaults;
    procedure SetSeed(ASeed: integer);
    procedure SetMouse(X, Y: single);
    // game control
    procedure AddGate(Z, GX, GY, GR: single);
    procedure ClearGates;
    procedure SetManualCamera(X, Y, Yaw, Pitch, Roll: single);
    function ProjectPoint(x, y, z: single; W, H: integer; out SX, SY, PxPerUnit: single): boolean;
    property FocusOverride: single read FFocusOverride write FFocusOverride;   // <= 0: automatic
    procedure Invalidate(const AWhat: TInvalidateSet);
    procedure Animate(dt: single);
    procedure Render(Dest: TBGRABitmap; W, H: integer; APasses: TPassSet;
      ACheckers, AStats: boolean);
    // GPU backends: BuildFrame makes the frame's draw list without drawing
    // it; the list (far to near), the background and the vignette are then
    // read through Cmd / CmdCount / FrameBase / FrameVignette.
    procedure BuildFrame(W, H: integer; APasses: TPassSet; AStats: boolean);
    function Cmd(Index: integer): PDrawCmd;
    // one sprite made from the current settings (caller frees it); for exports
    function BakeSprite(Kind: integer; rq, bq: single): TSprite;
    function FrameBase: TBGRABitmap;
    function FrameVignette: TBGRABitmap;
    property CmdCount: integer read FCmdCount;
    property JobBase: boolean read FJobBase;
    property JobVig: boolean read FJobVig;
    property ScreenGen: integer read FScreenGen;
    function Report(FPS: double): string;
    procedure SaveToIni(const FileName: string);
    procedure LoadFromIni(const FileName: string);
    property Settings: PHexSettings read GetSettings;
    property Params: TParamList read FParams;
    property Passes[Index: integer]: PPass read GetPass;
    property Seed: integer read FSeed;
    property Stats: TFrameStats read FStats;
    property Time: double read FTime;
    property CameraPos: TVec3 read FCam;
    property FocusNow: single read FFocus;
    property SpriteCount: integer read FSpriteCount;
    property SpriteBytes: Int64 read FSpriteBytes;
    // True for the live view: missing sprites are built on background threads
    // (the frame borrows a neighbour meanwhile). False = build them right
    // away, for exact PNG export.
    property AsyncSprites: boolean read FAsync write FAsync;
  end;

const
  SpriteKindCount = 9;
  // index = TSprite.Kind
  SpriteKindNames: array[0..SpriteKindCount - 1] of string = ('front', 'back', 'glow', 'dust',
    'dot', 'front_glow', 'gate', 'gate_edge', 'gate_back');

var
  SpriteFreeHook: TSpriteFreeHook = nil;

function DefaultHexSettings: THexSettings;
procedure DrawCheckers(Dest: TBGRABitmap; Cell: integer);
function NowMs: double;

implementation

const
  TileH = 16;           // rows per parallel work item
  skFront = 0;
  skBack = 1;
  skGlow = 2;
  skDust = 3;
  skDot = 4;
  skFrontGlow = 5;    // front face with its glow baked in: one blit instead of two
  skGate = 6;         // gate wall face
  skGateEdge = 7;     // gate face around the gap
  skGateBack = 8;     // gate back face
  AllPasses: TPassSet = [0..PassCount - 1];
  AllCaches: TInvalidateSet = [ivSprites, ivScreen, ivField, ivDust, ivSparks];

var
  QpcScale: double = 0;

function NowMs: double;
{$IFDEF WINDOWS}
var
  C, F: TLargeInteger;
begin
  if QpcScale = 0 then
  begin
    QueryPerformanceFrequency(F);
    QpcScale := 1000.0 / F;
  end;
  QueryPerformanceCounter(C);
  Result := C * QpcScale;
end;
{$ELSE}
begin
  Result := GetTickCount64;
end;
{$ENDIF}

function DefaultHexSettings: THexSettings;
begin
  FillChar(Result, SizeOf(Result), 0);
  with Result do
  begin
    Fov := 55;  Speed := 2.0;  SwayX := 0.6;  SwayY := 0.4;  SwayFreq := 0.05;
    RollAmp := 1.5;  LookYaw := 3;  LookPitch := 2;  LookFreq := 0.03;
    MouseSteer := 8;  MouseSmooth := 2;  NearClip := 0.5;  FarClip := 42;

    FocusDist := 12;  FocusPullAmp := 3;  FocusPullFreq := 0.04;  Aperture := 1.0;  MaxBlur := 40;
    FogStart := 22;  FogEnd := 42;  NearFadeStart := 7;  NearFadeEnd := 3.5;

    HexRadius := 1;  Gap := 1.10;  SheetGap := 3.5;  ZJitter := 0.35;  Thickness := 0.30;
    SizeJitter := 0.10;  LayoutDist := 12;  EdgeSlope := 0.45;  EdgeOffset := 0.05;
    FadeStart := -0.05;  FadeEnd := 0.25;  Density := 0.60;
    NoiseScale := 0.08;  ClusterLo := 0.35;  ClusterHi := 0.65;  ClusterMin := 0.10;
    LooseChance := 0.06;  LooseZone := 0.30;  LooseDrift := 1.5;  LooseShrink := 0.40;

    EdgeColor := BGRA(195, 215, 250);  FillColor := BGRA(8, 14, 30);
    BackColor := BGRA(110, 140, 195);  InnerColor := BGRA(140, 170, 225);
    SpecColor := BGRA(235, 245, 255);  GlowColor := BGRA(70, 110, 190);
    LineWidth := 0.055;  RimAlpha := 230;  FillAlpha := 175;  BackAlpha := 0.30;
    InnerSize := 0.86;  InnerAlpha := 0.22;  SpecAlpha := 0.60;
    SideAlpha := 0.25;  SideMaxBlur := 3;
    GlowWidth := 2.5;  GlowStrength := 0.6;  GlowBlur := 0.22;  GlowBase := 0.10;  GlowRange := 4;

    BaseColor := BGRA(5, 8, 18);
    HazeColor[0] := BGRA(36, 54, 90, 255);  HazeX[0] := 0.28;  HazeY[0] := 0.70;  HazeR[0] := 0.70;
    HazeColor[1] := BGRA(45, 66, 110, 210); HazeX[1] := 0.65;  HazeY[1] := 0.95;  HazeR[1] := 0.55;
    HazeColor[2] := BGRA(32, 48, 82, 200);  HazeX[2] := 0.95;  HazeY[2] := 0.10;  HazeR[2] := 0.40;

    DustCount := 90;  DustSizeMin := 0.3;  DustSizeMax := 1.2;
    DustAlphaMin := 15;  DustAlphaMax := 55;  DustMinBlur := 6;
    DustDotChance := 0.3;  DustDotSize := 0.15;
    DustColor := BGRA(100, 130, 180);  DustDotColor := BGRA(170, 200, 240);

    VigAlpha := 160;  VigX := 0.50;  VigY := 0.55;  VigRadius := 0.62;
    ShadowAlpha := 130;  ShadowX := 0.45;  ShadowY := 0.40;

    SparkCount := 450;  SparkFieldBias := 0.9;  SparkSizeMin := 0.012;  SparkSizeMax := 0.035;
    SparkAlphaMin := 120;  SparkAlphaMax := 255;  SparkRiseMin := 0.3;  SparkRiseMax := 1.2;
    SparkSway := 0.3;  SparkLifeMin := 3;  SparkLifeMax := 9;
    SparkTwinkleMin := 2;  SparkTwinkleMax := 8;  SparkTwinkleDepth := 0.40;
    SparkHaloSize := 3;  SparkHaloAlpha := 0.18;
    SparkCoreColor := BGRA(255, 196, 110);  SparkHaloColor := BGRA(255, 130, 30);

    RenderScale := 0.7;  SizeStep := 1.08;  BlurStep := 1.12;  CacheMB := 384;  SpriteBudget := 4;  Threads := 0;
    CorridorRadius := 0;  GateFillAlpha := 215;
    GateRimColor := BGRA(130, 215, 255);  GateEdgeColor := BGRA(255, 200, 110);
    GateEdgeGlow := BGRA(255, 140, 40);
  end;
end;

{ --------------------------------------------------------------- helpers }

function SmoothStep(e0, e1, x: single): single;
begin
  if e1 = e0 then
    Exit(Ord(x >= e0));
  Result := EnsureRange((x - e0) / (e1 - e0), 0, 1);
  Result := Result * Result * (3 - 2 * Result);
end;

function WithAlpha(c: TBGRAPixel; a: single): TBGRAPixel;
begin
  Result := c;
  Result.alpha := EnsureRange(Round(a), 0, 255);
end;

function HexPoints(cx, cy, r: single): ArrayOfTPointF;
var
  i: integer;
begin
  SetLength(Result, 6);
  for i := 0 to 5 do                    // flat-top hexagon
    Result[i] := PointF(cx + r * Cos(i * Pi / 3), cy + r * Sin(i * Pi / 3));
end;

// Integer hash -> 0..1, used so the field is the same every time it is generated.
function HashF(a, b, c, d: longint): single;
var
  h: cardinal;
begin
  h := cardinal(a) * 73856093 xor cardinal(b) * 19349663 xor
    cardinal(c) * 83492791 xor cardinal(d) * 2654435761;
  h := h xor (h shr 16);
  h := h * $7FEB352D;
  h := h xor (h shr 15);
  h := h * $846CA68B;
  h := h xor (h shr 16);
  Result := h / 4294967296.0;
end;

function ValueNoise(x, y, z: single; Seed: longint): single;
var
  xi, yi, zi: longint;
  fx, fy, fz, a, b, c, d: single;
begin
  xi := Floor(x);
  yi := Floor(y);
  zi := Floor(z);
  fx := x - xi;
  fy := y - yi;
  fz := z - zi;
  fx := fx * fx * (3 - 2 * fx);
  fy := fy * fy * (3 - 2 * fy);
  fz := fz * fz * (3 - 2 * fz);
  // trilinear blend of the 8 hashed lattice corners
  a := HashF(xi, yi, zi, Seed);
  a := a + (HashF(xi + 1, yi, zi, Seed) - a) * fx;
  b := HashF(xi, yi + 1, zi, Seed);
  b := b + (HashF(xi + 1, yi + 1, zi, Seed) - b) * fx;
  c := HashF(xi, yi, zi + 1, Seed);
  c := c + (HashF(xi + 1, yi, zi + 1, Seed) - c) * fx;
  d := HashF(xi, yi + 1, zi + 1, Seed);
  d := d + (HashF(xi + 1, yi + 1, zi + 1, Seed) - d) * fx;
  a := a + (b - a) * fy;
  c := c + (d - c) * fy;
  Result := a + (c - a) * fz;
end;

procedure DrawCheckers(Dest: TBGRABitmap; Cell: integer);
var
  x, y: integer;
begin
  Dest.Fill(BGRA(34, 34, 40));
  for y := 0 to Dest.Height div Cell do
    for x := 0 to Dest.Width div Cell do
      if Odd(x + y) then
        Dest.FillRect(x * Cell, y * Cell, (x + 1) * Cell, (y + 1) * Cell, BGRA(24, 24, 29), dmSet);
end;

{ THexBackground }

constructor THexBackground.Create;
var
  i: integer;
begin
  FSeed := 2026;
  for i := 0 to PassCount - 1 do
    FPasses[i].Enabled := True;
  InitCriticalSection(FBuildLock);
  FBuildWake := RTLEventCreate;
  SetLength(FBuilders, 2);
  for i := 0 to High(FBuilders) do
    FBuilders[i] := TSpriteBuilder.Create(Self);
  FPasses[psBase].Name := 'Background';
  FPasses[psBase].Technique := 'Cached per output size: Fill(BaseColor) + 3 x GradientFill(gtRadial). ' +
    'Per frame: PutImage(dmSet).';
  FPasses[psDust].Name := 'Bokeh dust';
  FPasses[psDust].Technique := '3D particles behind the focus plane. Each is a cached disc sprite ' +
    '(FillEllipseAntialias + FilterBlurRadial) sized f x size / z, blurred by the CoC, ' +
    'drawn with PutImage(opacity = alpha x fog).';
  FPasses[psBack].Name := 'Hex back faces';
  FPasses[psBack].Technique := 'Back face = cell centre + (0, 0, Thickness) projected by the camera, ' +
    'so the extrusion follows real perspective. Cached outline sprite per (size, blur) bucket.';
  FPasses[psSides].Name := 'Hex side edges';
  FPasses[psSides].Technique := '6 DrawLineAntialias per sharp hexagon joining projected front and back ' +
    'corners (only where blur < Side max blur).';
  FPasses[psGlow].Name := 'Hex glow';
  FPasses[psGlow].Technique := 'Halo = thick rim + FilterBlurRadial, strength Glow base + (1 - base) x ' +
    'exp(-(blur / falloff)^2), so it peaks at the focus distance. Baked into the front-face sprite while ' +
    'both passes are on (its time is then counted in pass 5).';
  FPasses[psFront].Name := 'Hex front faces';
  FPasses[psFront].Technique := 'Cached sprite per (size, blur) bucket: rim + dark fill ' +
    '(DrawPolygonAntialias), inner rim, specular edge, FilterBlurRadial(CoC). Sorted back to front, ' +
    'PutImage with opacity = fog x near fade.';
  FPasses[psSparks].Name := 'Sparks';
  FPasses[psSparks].Technique := '3D embers that rise and twinkle. In focus: halo + core ' +
    'FillEllipseAntialias; out of focus: one soft disc as wide as the CoC.';
  FPasses[psVignette].Name := 'Vignette';
  FPasses[psVignette].Technique := 'Cached per output size: radial + linear GradientFill to black; ' +
    'PutImage(dmDrawWithTransparency) over the frame.';
  ResetDefaults;
end;

destructor THexBackground.Destroy;
var
  i: integer;
begin
  for i := 0 to High(FBuilders) do FBuilders[i].Terminate;
  for i := 0 to High(FBuilders) do
  begin
    RTLEventSetEvent(FBuildWake);
    FBuilders[i].WaitFor;
    FBuilders[i].Free;
  end;
  RTLEventDestroy(FBuildWake);
  FBuildWake := nil;                   // ClearSprites below must not touch the queue lock
  for i := 0 to FBuiltCount - 1 do FBuilt[i].Spr.Free;
  FreeWorkers;
  ClearSprites;
  DoneCriticalSection(FBuildLock);
  ClearScreens;
  inherited Destroy;
end;

function THexBackground.GetPass(Index: integer): PPass;
begin
  Result := @FPasses[Index];
end;

function THexBackground.GetSettings: PHexSettings;
begin
  Result := @FSettings;
end;

procedure THexBackground.ResetDefaults;
begin
  FSettings := DefaultHexSettings;
  BuildParams;
  Invalidate(AllCaches);
end;

procedure THexBackground.SetSeed(ASeed: integer);
begin
  if ASeed = FSeed then Exit;
  FSeed := ASeed;
  Invalidate([ivField, ivDust, ivSparks]);
end;

procedure THexBackground.SetMouse(X, Y: single);
begin
  FMouseX := EnsureRange(X, -1, 1);
  FMouseY := EnsureRange(Y, -1, 1);
end;

procedure THexBackground.Invalidate(const AWhat: TInvalidateSet);
begin
  if ivSprites in AWhat then ClearSprites;
  if ivScreen in AWhat then ClearScreens;
  if ivField in AWhat then FSheets := nil;
  if (ivDust in AWhat) or (ivSparks in AWhat) or (ivField in AWhat) then
  begin
    FRng := cardinal(FSeed) * 2654435761 + 1;
    if FRng = 0 then FRng := 1;
    UpdateCamera;
    if ivDust in AWhat then FDust := nil;
    if ivSparks in AWhat then FSparks := nil;
    InitParticles;
  end;
end;

function THexBackground.Rnd: single;
begin
  FRng := FRng xor (FRng shl 13);
  FRng := FRng xor (FRng shr 17);
  FRng := FRng xor (FRng shl 5);
  Result := FRng / 4294967296.0;
end;

function THexBackground.RandRange(AMin, AMax: single): single;
begin
  Result := AMin + Rnd * (AMax - AMin);
end;

{ ---------------------------------------------------------------- params }

procedure THexBackground.BuildParams;
var
  CurGroup: string;
  CurFx: TInvalidateSet;

  procedure F(const AName, AHint: string; var V: single; AMin, AMax: single; ADec: integer);
  var
    n: integer;
  begin
    n := Length(FParams);
    SetLength(FParams, n + 1);
    FParams[n].Group := CurGroup;
    FParams[n].Name := AName;
    FParams[n].Hint := AHint;
    FParams[n].Kind := pkFloat;
    FParams[n].PValue := @V;
    FParams[n].PColor := nil;
    FParams[n].Min := AMin;
    FParams[n].Max := AMax;
    FParams[n].Decimals := ADec;
    FParams[n].Effects := CurFx;
  end;

  procedure C(const AName, AHint: string; var V: TBGRAPixel);
  var
    n: integer;
  begin
    n := Length(FParams);
    SetLength(FParams, n + 1);
    FParams[n].Group := CurGroup;
    FParams[n].Name := AName;
    FParams[n].Hint := AHint;
    FParams[n].Kind := pkColor;
    FParams[n].PValue := nil;
    FParams[n].PColor := @V;
    FParams[n].Min := 0;
    FParams[n].Max := 255;
    FParams[n].Decimals := 0;
    FParams[n].Effects := CurFx;
  end;

var
  i: integer;
begin
  FParams := nil;
  with FSettings do
  begin
    CurGroup := 'Camera';
    CurFx := [];
    F('Speed', 'Forward speed, world units per second (hex radius = 1 unit by default).', Speed, -10, 20, 2);
    F('Sway X', 'Side-to-side drift amplitude, units.', SwayX, 0, 5, 2);
    F('Sway Y', 'Up-down drift amplitude, units.', SwayY, 0, 5, 2);
    F('Sway freq', 'Sway cycles per second.', SwayFreq, 0, 0.5, 3);
    F('Roll', 'Camera roll amplitude, degrees.', RollAmp, 0, 20, 1);
    F('Look freq', 'Speed of the automatic look-around and roll, cycles per second.', LookFreq, 0, 0.3, 3);
    F('Mouse smooth', 'How fast the camera follows the mouse (1/s).', MouseSmooth, 0.1, 10, 1);
    F('Near clip', 'Nothing closer than this is drawn, units.', NearClip, 0.05, 5, 2);
    CurFx := [ivField, ivDust, ivSparks];
    F('Field of view', 'Vertical field of view, degrees.', Fov, 10, 120, 0);
    F('Far clip', 'View distance, units. Larger = more hexagons to draw.', FarClip, 5, 150, 0);
    F('Look yaw', 'Automatic look-around left/right, degrees.', LookYaw, 0, 30, 1);
    F('Look pitch', 'Automatic look-around up/down, degrees.', LookPitch, 0, 30, 1);
    F('Mouse steer', 'How far the mouse turns the camera, degrees.', MouseSteer, 0, 40, 1);

    CurGroup := 'Depth of field';
    CurFx := [];
    F('Focus distance', 'Distance of the sharp plane, units.', FocusDist, 0.5, 60, 1);
    F('Focus pull', 'Automatic focus drift amplitude, units.', FocusPullAmp, 0, 30, 1);
    F('Focus pull freq', 'Focus drift cycles per second.', FocusPullFreq, 0, 0.5, 3);
    F('Aperture', 'Blur strength. CoC px = Aperture x H / 100 x |z - focus| / z.', Aperture, 0, 5, 2);
    F('Max blur', 'Largest blur radius, px per 1000 px of output height.', MaxBlur, 0, 150, 0);

    CurGroup := 'Fog';
    F('Fog start', 'Distance where hexagons start to fade, units.', FogStart, 0, 150, 1);
    F('Fog end', 'Distance where they are gone, units.', FogEnd, 0, 150, 1);
    F('Near fade start', 'Hexagons closer than this start to fade out, units.', NearFadeStart, 0, 20, 2);
    F('Near fade end', 'Hexagons closer than this are invisible, units.', NearFadeEnd, 0, 20, 2);

    CurGroup := 'Hexagon field';
    CurFx := [ivField];
    F('Hex radius', 'Hexagon size, world units.', HexRadius, 0.2, 5, 2);
    F('Cell gap', 'Lattice spacing / hex size. 1 = touching.', Gap, 0.9, 3, 2);
    F('Sheet gap', 'Distance between honeycomb sheets along the flight path, units.', SheetGap, 0.5, 20, 2);
    F('Z jitter', 'Random depth offset of each cell, x sheet gap.', ZJitter, 0, 2, 2);
    F('Thickness', 'Prism depth (front to back face), units.', Thickness, 0, 3, 2);
    F('Size jitter', 'Random size variation.', SizeJitter, 0, 0.6, 2);
    F('Layout distance', 'Distance at which the diagonal mask matches the screen, units.', LayoutDist, 1, 60, 1);
    F('Edge slope', 'Slope of the empty-area edge (screen heights per screen height).', EdgeSlope, -2, 2, 2);
    F('Edge offset', 'Moves the edge down (+) or up (-), screen heights.', EdgeOffset, -1, 1, 2);
    F('Fade start', 'Distance from the edge where cells start (negative = into the empty side).', FadeStart, -1, 1, 2);
    F('Fade end', 'Distance from the edge where the field is full.', FadeEnd, -1, 2, 2);
    F('Density', 'Chance a cell inside the field holds a hexagon.', Density, 0, 1, 2);
    F('Noise scale', 'Cluster noise frequency per unit.', NoiseScale, 0.005, 1, 3);
    F('Cluster low', 'Noise value where clusters start.', ClusterLo, 0, 1, 2);
    F('Cluster high', 'Noise value where clusters are full.', ClusterHi, 0, 1, 2);
    F('Cluster min', 'Density kept between clusters.', ClusterMin, 0, 1, 2);
    F('Loose chance', 'Chance an empty cell near the edge spawns a stray hexagon.', LooseChance, 0, 0.5, 3);
    F('Loose zone', 'Width of the zone where strays appear (screen heights).', LooseZone, 0, 1, 2);
    F('Loose drift', 'How far strays drift into the empty side (x hex radius).', LooseDrift, 0, 6, 2);
    F('Loose shrink', 'Max size reduction of strays.', LooseShrink, 0, 0.9, 2);

    CurGroup := 'Hexagon style';
    CurFx := [ivSprites];
    C('Rim colour', 'Front face outline.', EdgeColor);
    C('Face colour', 'Front face fill.', FillColor);
    C('Back colour', 'Back face and side edges.', BackColor);
    C('Inner rim colour', 'Thin inner outline.', InnerColor);
    C('Specular colour', 'Highlight on the upper-left edge.', SpecColor);
    F('Line width', 'Rim width x on-screen hex radius (min 1 px).', LineWidth, 0.01, 0.3, 3);
    F('Rim alpha', '0..255', RimAlpha, 0, 255, 0);
    F('Face alpha', '0..255 - how much the face hides what is behind it.', FillAlpha, 0, 255, 0);
    F('Back alpha', 'Back face alpha x rim alpha.', BackAlpha, 0, 1, 2);
    F('Inner size', 'Inner rim size relative to the face.', InnerSize, 0.3, 1, 2);
    F('Inner alpha', 'Inner rim alpha x rim alpha.', InnerAlpha, 0, 1, 2);
    F('Specular alpha', 'Highlight alpha x rim alpha.', SpecAlpha, 0, 1, 2);
    CurFx := [];
    F('Side alpha', 'Side edges alpha x rim alpha.', SideAlpha, 0, 1, 2);
    F('Side max blur', 'Side edges are drawn only below this blur (px per 1000 px height).', SideMaxBlur, 0, 50, 1);

    CurGroup := 'Glow';
    CurFx := [ivSprites];
    C('Glow colour', 'Halo colour.', GlowColor);
    F('Glow width', 'Halo stroke width x rim width.', GlowWidth, 0.5, 10, 1);
    F('Glow blur', 'Halo blur radius x on-screen hex radius.', GlowBlur, 0, 1.5, 2);
    F('Glow strength', 'Overall halo opacity.', GlowStrength, 0, 2, 2);
    F('Glow base', 'Glow kept on blurred (out of focus) hexagons, 0..1.', GlowBase, 0, 1, 2);
    F('Glow falloff', 'Blur radius (px) at which the glow has mostly faded: sharp = in focus = glowing.', GlowRange, 0.5, 40, 1);

    CurGroup := 'Background';
    CurFx := [ivScreen];
    C('Base colour', 'Background fill.', BaseColor);
    for i := 0 to 2 do
    begin
      C(Format('Haze %d colour', [i + 1]), 'Radial haze colour; alpha = strength.', HazeColor[i]);
      F(Format('Haze %d X', [i + 1]), 'Haze centre X (0..1).', HazeX[i], -0.5, 1.5, 2);
      F(Format('Haze %d Y', [i + 1]), 'Haze centre Y (0..1).', HazeY[i], -0.5, 1.5, 2);
      F(Format('Haze %d radius', [i + 1]), 'Haze radius x the longer image side.', HazeR[i], 0.05, 2, 2);
    end;

    CurGroup := 'Bokeh dust';
    CurFx := [ivDust];
    F('Count', 'Number of dust particles behind the focus plane.', DustCount, 0, 600, 0);
    F('Size min', 'World units.', DustSizeMin, 0.01, 5, 2);
    F('Size max', 'World units.', DustSizeMax, 0.01, 5, 2);
    F('Alpha min', '0..255', DustAlphaMin, 0, 255, 0);
    F('Alpha max', '0..255', DustAlphaMax, 0, 255, 0);
    F('Dot chance', 'Share of small bright dots.', DustDotChance, 0, 1, 2);
    F('Dot size', 'Dot size x dust size.', DustDotSize, 0.02, 1, 2);
    CurFx := [ivSprites];
    C('Dust colour', 'Big soft blobs.', DustColor);
    C('Dot colour', 'Small bright dots.', DustDotColor);
    CurFx := [];
    F('Min blur', 'Dust is always at least this blurred (px per 1000 px height).', DustMinBlur, 0, 60, 1);

    CurGroup := 'Sparks';
    CurFx := [ivSparks];
    F('Count', 'Number of embers.', SparkCount, 0, 2000, 0);
    F('Field bias', '0 = anywhere, 1 = only inside the hexagon field.', SparkFieldBias, 0, 1, 2);
    F('Size min', 'World units.', SparkSizeMin, 0.002, 0.5, 3);
    F('Size max', 'World units.', SparkSizeMax, 0.002, 0.5, 3);
    F('Alpha min', '0..255', SparkAlphaMin, 0, 255, 0);
    F('Alpha max', '0..255', SparkAlphaMax, 0, 255, 0);
    F('Rise min', 'Upward speed, units/s.', SparkRiseMin, -5, 10, 2);
    F('Rise max', 'Upward speed, units/s.', SparkRiseMax, -5, 10, 2);
    F('Life min', 'Seconds.', SparkLifeMin, 0.2, 30, 1);
    F('Life max', 'Seconds.', SparkLifeMax, 0.2, 30, 1);
    F('Twinkle min', 'Twinkle speed, rad/s.', SparkTwinkleMin, 0, 30, 1);
    F('Twinkle max', 'Twinkle speed, rad/s.', SparkTwinkleMax, 0, 30, 1);
    CurFx := [];
    F('Sway', 'Sideways sway, units/s.', SparkSway, 0, 5, 2);
    F('Twinkle depth', '0 = steady, 1 = blinks fully off.', SparkTwinkleDepth, 0, 1, 2);
    F('Halo size', 'Halo radius x core radius.', SparkHaloSize, 1, 10, 1);
    F('Halo alpha', 'Halo alpha x spark alpha.', SparkHaloAlpha, 0, 1, 2);
    C('Core colour', 'Bright centre.', SparkCoreColor);
    C('Halo colour', 'Glow around the centre.', SparkHaloColor);

    CurGroup := 'Vignette';
    CurFx := [ivScreen];
    F('Strength', 'Corner darkness alpha (0..255).', VigAlpha, 0, 255, 0);
    F('Centre X', '0..1', VigX, 0, 1, 2);
    F('Centre Y', '0..1', VigY, 0, 1, 2);
    F('Radius', 'x image diagonal.', VigRadius, 0.1, 2, 2);
    F('Shadow alpha', 'Top-left shadow alpha (0..255).', ShadowAlpha, 0, 255, 0);
    F('Shadow end X', 'Where the shadow fades out (0..1).', ShadowX, 0.01, 1.5, 2);
    F('Shadow end Y', 'Where the shadow fades out (0..1).', ShadowY, 0.01, 1.5, 2);

    CurGroup := 'Game';
    CurFx := [ivField];
    F('Corridor radius', 'No ambient hexagons closer than this to the flight path, units (0 = off).', CorridorRadius, 0, 30, 1);
    CurFx := [ivSprites];
    F('Gate face alpha', 'How solid the gate walls look (0..255).', GateFillAlpha, 0, 255, 0);
    C('Gate rim colour', 'Rim of the gate wall hexagons.', GateRimColor);
    C('Gap rim colour', 'Rim of the hexagons around the gap.', GateEdgeColor);
    C('Gap glow colour', 'Glow of the hexagons around the gap.', GateEdgeGlow);

    CurGroup := 'Performance';
    CurFx := [];
    F('Render scale', 'Internal resolution x window size (frame is stretched to fit).', RenderScale, 0.25, 1, 2);
    F('Cache MB', 'Sprite cache limit; the cache is emptied when it is exceeded.', CacheMB, 32, 2048, 0);
    F('Threads', 'Drawing threads. 0 = one per logical CPU.', Threads, 0, 64, 0);
    F('Sprite budget ms', 'Live view: time per frame allowed for making small sprites on the spot. ' +
      'Big sprites are always made by background threads; meanwhile the nearest cached sprite is ' +
      'scaled in, so no frame stalls.', SpriteBudget, 0, 20, 1);
    CurFx := [ivSprites];
    F('Size step', 'Sprite size buckets grow by this factor. Sprites are drawn at their exact size, ' +
      'so this only trades memory for sharpness.', SizeStep, 1.01, 1.5, 3);
    F('Blur step', 'Sprite blur buckets grow by this factor. Smaller = smoother focus changes, more sprites.', BlurStep, 1.03, 2, 2);
  end;
end;

{ ---------------------------------------------------------------- camera }

procedure THexBackground.UpdateCamera;
var
  w: double;
begin
  w := 2 * Pi * FTime;
  with FSettings do
  begin
    if FManual then
    begin
      // the game flies the camera
      FCam.X := FManX;
      FCam.Y := FManY;
      FYaw := FManYaw;
      FPitch := FManPitch;
      FRoll := FManRoll;
    end
    else
    begin
      FCam.X := SwayX * Sin(w * SwayFreq);
      FCam.Y := SwayY * Sin(w * SwayFreq * 0.73 + 1.3);
      FYaw := DegToRad(LookYaw) * Sin(w * LookFreq) + FSteerYaw;
      FPitch := DegToRad(LookPitch) * Sin(w * LookFreq * 0.81 + 0.7) + FSteerPitch;
      FRoll := DegToRad(RollAmp) * Sin(w * LookFreq * 0.57 + 2.1);
    end;
    if FFocusOverride > 0 then
      FFocus := FFocusOverride
    else
      FFocus := Max(0.3, FocusDist + FocusPullAmp * Sin(w * FocusPullFreq));
  end;
  SinCos(FYaw, FSinY, FCosY);
  SinCos(FPitch, FSinP, FCosP);
  SinCos(FRoll, FSinR, FCosR);
end;

procedure THexBackground.SetManualCamera(X, Y, Yaw, Pitch, Roll: single);
begin
  FManual := True;
  FManX := X;
  FManY := Y;
  FManYaw := Yaw;
  FManPitch := Pitch;
  FManRoll := Roll;
end;

function THexBackground.ProjectPoint(x, y, z: single; W, H: integer; out SX, SY, PxPerUnit: single): boolean;
var
  V: TVec3;
  f: single;
begin
  SX := 0;
  SY := 0;
  PxPerUnit := 0;
  ToCamera(x, y, z, V);
  Result := V.Z > FSettings.NearClip;
  if not Result then Exit;
  f := (H / 2) / Tan(DegToRad(FSettings.Fov) / 2);
  SX := W / 2 + f * V.X / V.Z;
  SY := H / 2 + f * V.Y / V.Z;
  PxPerUnit := f / V.Z;
end;

// A honeycomb disc across the corridor at depth Z with a round gap of
// radius GR around (GX, GY). Cells next to the gap are marked as its rim.
procedure THexBackground.AddGate(Z, GX, GY, GR: single);
var
  r, dx, dy, x, y, d, ext: single;
  col, row, n, i: integer;
begin
  i := Length(FGates);
  SetLength(FGates, i + 1);
  FGates[i].Z := Z;
  FGates[i].GX := GX;
  FGates[i].GY := GY;
  FGates[i].GR := GR;
  with FSettings do
  begin
    r := HexRadius;
    dx := 1.5 * r * Gap;
    dy := Sqrt(3) * r * Gap;
    ext := CorridorRadius + 4 * r;
    FGates[i].Ext := ext;
    n := 0;
    SetLength(FGates[i].Cells, 512);
    SetLength(FGates[i].Kinds, 512);
    for col := Floor(-ext / dx) - 1 to Ceil(ext / dx) + 1 do
      for row := Floor(-ext / dy) - 1 to Ceil(ext / dy) + 1 do
      begin
        x := col * dx;
        y := row * dy;
        if (col and 1) = 1 then y := y + dy / 2;
        if Sqr(x) + Sqr(y) > Sqr(ext) then Continue;
        d := Sqrt(Sqr(x - GX) + Sqr(y - GY));
        if d < GR + r * 0.85 then Continue;          // the gap
        if n > High(FGates[i].Cells) then
        begin
          SetLength(FGates[i].Cells, n * 2);
          SetLength(FGates[i].Kinds, n * 2);
        end;
        FGates[i].Cells[n].X := x;
        FGates[i].Cells[n].Y := y;
        FGates[i].Cells[n].Z := Z;
        FGates[i].Cells[n].R := r * 0.96;
        FGates[i].Cells[n].Loose := False;
        if d < GR + r * 2.4 then FGates[i].Kinds[n] := 2 else FGates[i].Kinds[n] := 1;
        Inc(n);
      end;
    SetLength(FGates[i].Cells, n);
    SetLength(FGates[i].Kinds, n);
  end;
end;

procedure THexBackground.ClearGates;
begin
  FGates := nil;
end;

// World -> camera space: x right, y down, z forward (distance along the view).
procedure THexBackground.ToCamera(x, y, z: single; out V: TVec3);
var
  x1, z1, y2, z2: single;
begin
  x := x - FCam.X;
  y := y - FCam.Y;
  z := z - FCam.Z;
  x1 := x * FCosY - z * FSinY;
  z1 := x * FSinY + z * FCosY;
  y2 := y * FCosP + z1 * FSinP;
  z2 := -y * FSinP + z1 * FCosP;
  V.X := x1 * FCosR - y2 * FSinR;
  V.Y := x1 * FSinR + y2 * FCosR;
  V.Z := z2;
end;

// Signed distance (screen heights, as seen from LayoutDist) below the
// diagonal edge of the field: > 0 inside the field (lower right).
function THexBackground.MaskT(x, y: single): single;
var
  s: single;
begin
  with FSettings do
  begin
    s := 2 * LayoutDist * Tan(DegToRad(Fov) / 2);
    Result := y / s - (EdgeOffset - EdgeSlope * x / s);
  end;
end;

function THexBackground.Cluster(x, y, z: single): single;
var
  s: single;
begin
  s := FSettings.NoiseScale;
  Result := 0.65 * ValueNoise(x * s, y * s, z * s, FSeed) +
    0.35 * ValueNoise(x * s * 2.1 + 17, y * s * 2.1 + 5, z * s * 2.1, FSeed + 1);
end;

function THexBackground.Coc(z, H: single): single;
begin
  with FSettings do
    Result := Min(MaxBlur * H / 1000, Aperture * H / 100 * Abs(z - FFocus) / z);
end;

function THexBackground.Fade(z: single): single;
begin
  with FSettings do
    Result := (1 - SmoothStep(FogStart, FogEnd, z)) * SmoothStep(NearFadeEnd, NearFadeStart, z);
end;

{ ----------------------------------------------------------------- world }

procedure THexBackground.GenerateSheet(K: integer; out S: TSheet);
var
  tanH, Ex, Ey, r, dx, dy, ox, oy, z0, x, y, t, p: single;
  c0, c1, r0, r1, col, row, n: integer;
  h: array[0..6] of single;
  i: integer;
  Loose: boolean;
begin
  S.K := K;
  S.Cells := nil;
  n := 0;
  with FSettings do
  begin
    tanH := Tan(DegToRad(Fov) / 2);
    // lateral extent: what the camera can ever see at the far clip
    Ex := FarClip * (tanH * 2 + Tan(DegToRad(Min(80, LookYaw + MouseSteer)))) + SwayX + 2 * HexRadius;
    Ey := FarClip * (tanH * 1.05 + Tan(DegToRad(Min(80, LookPitch + MouseSteer * 0.6)))) + SwayY + 2 * HexRadius;
    r := HexRadius;
    dx := 1.5 * r * Gap;
    dy := Sqrt(3) * r * Gap;
    ox := HashF(K, 11, 0, FSeed) * dx;
    oy := HashF(K, 12, 0, FSeed) * dy;
    z0 := K * SheetGap;
    c0 := Floor((-Ex - ox) / dx);
    c1 := Ceil((Ex - ox) / dx);
    r0 := Floor((-Ey - oy) / dy) - 1;
    r1 := Ceil((Ey - oy) / dy);
    SetLength(S.Cells, 256);
    for col := c0 to c1 do
      for row := r0 to r1 do
      begin
        x := ox + col * dx;
        y := oy + row * dy;
        if (col and 1) = 1 then y := y + dy / 2;
        for i := 0 to 6 do
          h[i] := HashF(col, row, K, FSeed * 8 + i);

        // keep the flight corridor clear for the gates
        if (CorridorRadius > 0) and (Sqr(x) + Sqr(y) < Sqr(CorridorRadius)) then Continue;
        t := MaskT(x, y);
        p := SmoothStep(FadeStart, FadeEnd, t) * Density *
          (ClusterMin + (1 - ClusterMin) * SmoothStep(ClusterLo, ClusterHi, Cluster(x, y, z0)));
        Loose := False;
        if h[0] >= p then
        begin
          if (t > -LooseZone) and (t < 0.05) and (h[1] < LooseChance) then
            Loose := True
          else
            Continue;
        end;

        if n > High(S.Cells) then SetLength(S.Cells, n * 2);
        S.Cells[n].X := x;
        S.Cells[n].Y := y;
        S.Cells[n].Z := z0 + (h[2] - 0.5) * ZJitter * SheetGap;
        S.Cells[n].R := r * (1 - SizeJitter * 0.7 + h[3] * SizeJitter);
        S.Cells[n].Loose := Loose;
        if Loose then
        begin
          // strays drift into the empty upper-left side
          p := r * (0.5 + h[4] * LooseDrift);
          S.Cells[n].X := S.Cells[n].X - p * 0.6;
          S.Cells[n].Y := S.Cells[n].Y - p * 0.8;
          S.Cells[n].R := S.Cells[n].R * (1 - LooseShrink * h[5]);
          S.Cells[n].Z := S.Cells[n].Z + (h[6] - 0.5) * SheetGap * 0.5;
        end;
        Inc(n);
      end;
  end;
  SetLength(S.Cells, n);
end;

procedure THexBackground.UpdateField;
var
  kMin, kMax, k, n, i: integer;
begin
  with FSettings do
  begin
    kMin := Floor((FCam.Z + NearClip - Thickness - ZJitter * SheetGap) / SheetGap);
    kMax := Ceil((FCam.Z + FarClip) / SheetGap);
  end;
  // drop sheets behind the camera
  n := 0;
  while (n < Length(FSheets)) and (FSheets[n].K < kMin) do Inc(n);
  if n > 0 then Delete(FSheets, 0, n);
  // add sheets coming into range
  if Length(FSheets) = 0 then k := kMin else k := FSheets[High(FSheets)].K + 1;
  while k <= kMax do
  begin
    i := Length(FSheets);
    SetLength(FSheets, i + 1);
    GenerateSheet(k, FSheets[i]);
    Inc(k);
  end;
end;

procedure THexBackground.SpawnDust(var D: TParticle; Anywhere: boolean);
var
  tanH, zr, x, y: single;
  Tries: integer;
begin
  with FSettings do
  begin
    tanH := Tan(DegToRad(Fov) / 2);
    Tries := 0;
    repeat
      if Anywhere then zr := RandRange(FocusDist * 1.2, FarClip)
      else zr := RandRange(FarClip * 0.8, FarClip);
      x := FCam.X + (Rnd * 2 - 1) * tanH * 1.8 * zr;
      y := FCam.Y + (Rnd * 2 - 1) * tanH * zr;
      Inc(Tries);
      // most dust floats along the edge of the field
    until (Rnd < 0.25 + 0.75 * Exp(-Sqr(MaskT(x, y) / 0.3))) or (Tries > 30);
    D.P.X := x;
    D.P.Y := y;
    D.P.Z := FCam.Z + zr;
    D.Dot := Rnd < DustDotChance;
    D.Size := RandRange(DustSizeMin, DustSizeMax);
    if D.Dot then D.Size := D.Size * DustDotSize;
    D.Alpha := RandRange(DustAlphaMin, DustAlphaMax);
    if D.Dot then D.Alpha := Min(255, D.Alpha * 2.5);
  end;
end;

procedure THexBackground.SpawnSpark(var S: TParticle; Anywhere: boolean);
var
  tanH, zr, x, y: single;
  Tries: integer;
begin
  with FSettings do
  begin
    tanH := Tan(DegToRad(Fov) / 2);
    Tries := 0;
    repeat
      zr := RandRange(Max(NearFadeStart, FocusDist * 0.4), FocusDist * 2.5);
      x := FCam.X + (Rnd * 2 - 1) * tanH * 1.8 * zr;
      y := FCam.Y + (Rnd * 2 - 1) * tanH * zr;
      Inc(Tries);
    until (Rnd < (1 - SparkFieldBias) + SparkFieldBias * SmoothStep(FadeStart - 0.05, FadeEnd + 0.1, MaskT(x, y)))
      or (Tries > 30);
    S.P.X := x;
    S.P.Y := y;
    S.P.Z := FCam.Z + zr;
    S.Size := RandRange(SparkSizeMin, SparkSizeMax);
    S.Alpha := RandRange(SparkAlphaMin, SparkAlphaMax);
    S.Phase := Rnd * 2 * Pi;
    S.Twinkle := RandRange(SparkTwinkleMin, SparkTwinkleMax);
    S.Rise := RandRange(SparkRiseMin, SparkRiseMax);
    S.LifeSpeed := 1 / Max(0.1, RandRange(SparkLifeMin, SparkLifeMax));
    if Anywhere then S.Life := Rnd else S.Life := 0;
  end;
end;

procedure THexBackground.InitParticles;
var
  i: integer;
begin
  if FDust = nil then
  begin
    SetLength(FDust, Round(FSettings.DustCount));
    for i := 0 to High(FDust) do SpawnDust(FDust[i], True);
  end;
  if FSparks = nil then
  begin
    SetLength(FSparks, Round(FSettings.SparkCount));
    for i := 0 to High(FSparks) do SpawnSpark(FSparks[i], True);
  end;
end;

procedure THexBackground.Animate(dt: single);
var
  i: integer;
  zr: single;
begin
  FTime := FTime + dt;
  while (Length(FGates) > 0) and (FGates[0].Z < FCam.Z - 2) do
    Delete(FGates, 0, 1);
  with FSettings do
  begin
    FCam.Z := FCam.Z + Speed * dt;
    // the camera eases toward the mouse direction
    zr := Min(1, dt * MouseSmooth);
    FSteerYaw := FSteerYaw + (FMouseX * DegToRad(MouseSteer) - FSteerYaw) * zr;
    FSteerPitch := FSteerPitch + (-FMouseY * DegToRad(MouseSteer) * 0.6 - FSteerPitch) * zr;
    UpdateCamera;
    UpdateField;
    InitParticles;

    for i := 0 to High(FDust) do
    begin
      zr := FDust[i].P.Z - FCam.Z;
      if (zr < FocusDist * 0.8) or (zr > FarClip * 1.05) then SpawnDust(FDust[i], zr > FarClip * 1.05);
    end;

    for i := 0 to High(FSparks) do
      with FSparks[i] do
      begin
        Life := Life + dt * LifeSpeed;
        P.Y := P.Y - Rise * dt;
        P.X := P.X + Cos(FTime * 0.7 + Phase) * SparkSway * dt;
        zr := P.Z - FCam.Z;
        if (Life >= 1) or (zr < NearClip * 2) or (zr > FarClip) then
          SpawnSpark(FSparks[i], False);
      end;
  end;
end;

{ --------------------------------------------------------------- sprites }

procedure THexBackground.ClearSprites;
var
  k, s, b: integer;
begin
  for k := 0 to 8 do
    for s := 0 to 255 do
      for b := 0 to 63 do
        FreeAndNil(FSprites[k, s, b]);
  FillChar(FPending, SizeOf(FPending), 0);
  // drop queued work; sprites still being built belong to the old generation
  // and are thrown away when they arrive
  Inc(FGen);
  if FBuildWake <> nil then
  begin
    EnterCriticalSection(FBuildLock);
    FQueueCount := 0;
    LeaveCriticalSection(FBuildLock);
  end;
  FSpriteBytes := 0;
  FSpriteCount := 0;
  FLnSize := Ln(Max(1.01, FSettings.SizeStep));
  FLnBlur := Ln(Max(1.05, FSettings.BlurStep));
  FSizeOff := -Floor(Ln(0.5) / FLnSize);
end;

// Renders one sprite. Thread-safe: it only touches its own bitmaps and the
// settings record it is given.
function BuildSpriteBase(const Settings: THexSettings; Kind: integer; rq, bq: single): TSprite;
var
  lw, gb, m, c, g: single;
  S: integer;
  P: ArrayOfTPointF;
  Face, Bmp: TBGRABitmap;
  x, y: integer;
  Src: PBGRAPixel;
  Dst: ^TBGRAPixel;
begin
  with Settings do
  begin
    lw := Max(1, rq * LineWidth);
    gb := bq;
    g := GlowStrength * (GlowBase + (1 - GlowBase) * Exp(-Sqr(bq / Max(0.1, GlowRange))));
    // an invisible halo is not worth the bigger sprite
    if (Kind = skFrontGlow) and (200 * g < 6) then Kind := skFront;
    if Kind in [skGlow, skFrontGlow] then
    begin
      gb := rq * GlowBlur + bq;
      m := gb * 1.2 + lw * GlowWidth + 2;
    end
    else
      m := bq * 1.2 + lw + 2;
    S := 2 * (Ceil(rq) + Ceil(m)) + 1;
    c := (S - 1) / 2;
    Bmp := TBGRABitmap.Create(S, S, BGRAPixelTransparent);

    if Kind in [skGlow, skFrontGlow] then
    begin
      // halo: strongest on sharp (in focus) hexagons
      Bmp.DrawPolygonAntialias(HexPoints(c, c, rq), WithAlpha(GlowColor, 200 * Min(1, g)), lw * GlowWidth);
      if gb > 0.3 then
        BGRAReplace(Bmp, Bmp.FilterBlurRadial(gb, rbFast));
    end;

    if Kind in [skFront, skFrontGlow, skBack, skDust, skDot] then
    begin
      Face := TBGRABitmap.Create(S, S, BGRAPixelTransparent);
      try
        case Kind of
          skFront, skFrontGlow:
            begin
              P := HexPoints(c, c, rq);
              Face.DrawPolygonAntialias(P, WithAlpha(EdgeColor, RimAlpha), lw, WithAlpha(FillColor, FillAlpha));
              Face.DrawPolygonAntialias(HexPoints(c, c, rq * InnerSize),
                WithAlpha(InnerColor, RimAlpha * InnerAlpha), lw * 0.5);
              Face.DrawLineAntialias(P[3].x, P[3].y, P[4].x, P[4].y,
                WithAlpha(SpecColor, RimAlpha * SpecAlpha), lw * 0.6);
            end;
          skBack:
            Face.DrawPolygonAntialias(HexPoints(c, c, rq), WithAlpha(BackColor, RimAlpha * BackAlpha), lw * 0.8);
          skDust:
            Face.FillEllipseAntialias(c, c, rq, rq, WithAlpha(DustColor, 255));
          skDot:
            Face.FillEllipseAntialias(c, c, rq, rq, WithAlpha(DustDotColor, 255));
        end;
        if bq > 0.3 then
          BGRAReplace(Face, Face.FilterBlurRadial(bq, rbFast));
        Bmp.PutImage(0, 0, Face, dmDrawWithTransparency);
      finally
        Face.Free;
      end;
    end;
  end;
  // premultiplied copy: lets BlitSprite interpolate without dark fringes
  Result := TSprite.Create;
  Result.W := S;
  Result.Rq := rq;
  SetLength(Result.Pix, S * S);
  for y := 0 to S - 1 do
  begin
    Src := Bmp.ScanLine[y];
    Dst := @Result.Pix[y * S];
    for x := 0 to S - 1 do
    begin
      Dst^ := BGRA(Src^.red * Src^.alpha div 255, Src^.green * Src^.alpha div 255,
        Src^.blue * Src^.alpha div 255, Src^.alpha);
      Inc(Src);
      Inc(Dst);
    end;
  end;
  Bmp.Free;
end;

// Gate sprites are ordinary hexagon sprites with the gate colours.
function BuildSprite(const Settings: THexSettings; Kind: integer; rq, bq: single): TSprite;
var
  S2: THexSettings;
begin
  case Kind of
    skGate, skGateEdge:
      begin
        S2 := Settings;
        if Kind = skGate then
          S2.EdgeColor := Settings.GateRimColor
        else
        begin
          S2.EdgeColor := Settings.GateEdgeColor;
          S2.GlowColor := Settings.GateEdgeGlow;
          S2.GlowStrength := Settings.GlowStrength * 1.6;
        end;
        S2.FillAlpha := Settings.GateFillAlpha;
        S2.GlowBase := 0.6;              // gates keep glowing when out of focus
        Result := BuildSpriteBase(S2, skFrontGlow, rq, bq);
      end;
    skGateBack:
      begin
        S2 := Settings;
        S2.BackColor := Settings.GateRimColor;
        S2.BackAlpha := 0.5;
        Result := BuildSpriteBase(S2, skBack, rq, bq);
      end;
  else
    Result := BuildSpriteBase(Settings, Kind, rq, bq);
  end;
  Result.Kind := Kind;
  Result.Bq := bq;
end;

function THexBackground.BakeSprite(Kind: integer; rq, bq: single): TSprite;
begin
  Result := BuildSprite(FSettings, Kind, rq, bq);
end;

function THexBackground.MakeSprite(Kind: integer; rq, bq: single): TSprite;
begin
  Result := BuildSprite(FSettings, Kind, rq, bq);
  AccountSprite(Result);
end;

procedure THexBackground.AccountSprite(Spr: TSprite);
begin
  Inc(FSpriteBytes, Int64(Spr.W) * Spr.W * SizeOf(TBGRAPixel));
  Inc(FSpriteCount);
  Inc(FSpritesTotal);
  Inc(FStats.SpritesMade);
end;

{ TSpriteBuilder }

constructor TSpriteBuilder.Create(AOwner: THexBackground);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(False);
  Priority := tpLower;                 // never steal time from the frame
end;

procedure TSpriteBuilder.Execute;
var
  Req: TSpriteReq;
begin
  while not Terminated do
  begin
    RTLEventWaitFor(FOwner.FBuildWake, 50);
    while (not Terminated) and FOwner.PopRequest(Req) do
    begin
      Req.Spr := BuildSprite(Req.Settings, Req.Kind, Req.Rq, Req.Bq);
      FOwner.PushBuilt(Req);
    end;
  end;
end;

function THexBackground.PopRequest(out Req: TSpriteReq): boolean;
begin
  EnterCriticalSection(FBuildLock);
  try
    // newest first: what the camera needs right now
    Result := FQueueCount > 0;
    if Result then
    begin
      Dec(FQueueCount);
      Req := FQueue[FQueueCount];
    end;
  finally
    LeaveCriticalSection(FBuildLock);
  end;
end;

procedure THexBackground.PushBuilt(const Req: TSpriteReq);
begin
  EnterCriticalSection(FBuildLock);
  try
    if FBuiltCount > High(FBuilt) then SetLength(FBuilt, Max(64, FBuiltCount * 2));
    FBuilt[FBuiltCount] := Req;
    Inc(FBuiltCount);
  finally
    LeaveCriticalSection(FBuildLock);
  end;
end;

procedure THexBackground.EnqueueSprite(Kind, si, bi: integer; rq, bq: single);
begin
  if FPending[Kind, si, bi] then Exit;
  EnterCriticalSection(FBuildLock);
  try
    if FQueueCount >= 512 then Exit;   // plenty queued already: borrow for now
    if FQueueCount > High(FQueue) then SetLength(FQueue, Max(64, FQueueCount * 2));
    FQueue[FQueueCount].Kind := Kind;
    FQueue[FQueueCount].Si := si;
    FQueue[FQueueCount].Bi := bi;
    FQueue[FQueueCount].Rq := rq;
    FQueue[FQueueCount].Bq := bq;
    FQueue[FQueueCount].Gen := FGen;
    FQueue[FQueueCount].Settings := FSettings;
    FQueue[FQueueCount].Spr := nil;
    Inc(FQueueCount);
  finally
    LeaveCriticalSection(FBuildLock);
  end;
  FPending[Kind, si, bi] := True;
  Inc(FStats.Queued);
  RTLEventSetEvent(FBuildWake);
end;

// Main thread, start of a frame: put finished sprites into the cache.
procedure THexBackground.CollectBuiltSprites;
var
  i: integer;
begin
  if FBuiltCount = 0 then Exit;        // racy read is fine: checked again below
  EnterCriticalSection(FBuildLock);
  try
    for i := 0 to FBuiltCount - 1 do
      with FBuilt[i] do
        if (Gen = FGen) and (FSprites[Kind, Si, Bi] = nil) then
        begin
          FSprites[Kind, Si, Bi] := Spr;
          FPending[Kind, Si, Bi] := False;
          AccountSprite(Spr);
        end
        else
        begin
          if Gen = FGen then FPending[Kind, Si, Bi] := False;
          Spr.Free;                    // stale generation, or built twice
        end;
    FBuiltCount := 0;
  finally
    LeaveCriticalSection(FBuildLock);
  end;
end;

function THexBackground.GetSprite(Kind: integer; r, blur: single; out Scale: single): TSprite;
var
  si, bi, d: integer;
  rq, bq: single;

  function Cached(ASi, ABi: integer): TSprite;
  begin
    if (ASi < 0) or (ASi > 255) or (ABi < 0) or (ABi > 63) then Result := nil
    else Result := FSprites[Kind, ASi, ABi];
  end;

  function Neighbour(MaxD: integer): TSprite;
  var
    dd: integer;
  begin
    Result := nil;
    for dd := 1 to MaxD do
    begin
      Result := Cached(si + dd, bi);
      if Result = nil then Result := Cached(si - dd, bi);
      if Result = nil then Result := Cached(si, bi + dd);
      if Result = nil then Result := Cached(si, bi - dd);
      if Result = nil then Result := Cached(si + dd, bi + dd);
      if Result = nil then Result := Cached(si - dd, bi - dd);
      if Result <> nil then Exit;
    end;
  end;

begin
  Scale := 0;
  r := Max(r, 0.5);
  // the bucket just above r: the sprite is scaled down a little, never up
  si := EnsureRange(Ceil(Ln(r) / FLnSize - 1e-4) + FSizeOff, 0, 255);
  if blur < 0.5 then bi := 0
  else bi := EnsureRange(1 + Round(Ln(blur / 0.5) / FLnBlur), 1, 63);
  Result := FSprites[Kind, si, bi];
  if Result = nil then
  begin
    rq := Exp((si - FSizeOff) * FLnSize);
    bq := IfThen(bi = 0, 0, 0.5 * Exp((bi - 1) * FLnBlur));
    if FAsync then
    begin
      // live view: never build big sprites inside a frame
      EnqueueSprite(Kind, si, bi, rq, bq);
      Result := Neighbour(12);
      if Result <> nil then
        Inc(FStats.Borrowed)
      else if (rq + bq < 12) and (NowMs < FBudgetEnd) then
      begin
        // nothing similar yet, but small enough to make right now
        Result := MakeSprite(Kind, rq, bq);
        FSprites[Kind, si, bi] := Result;
      end
      else
      begin
        Inc(FStats.Skipped);          // appears as soon as its sprite is built
        Exit;
      end;
    end
    else
    begin
      if FSpriteBytes > Int64(Round(FSettings.CacheMB)) * 1048576 then
        ClearSprites;
      Result := MakeSprite(Kind, rq, bq);
      FSprites[Kind, si, bi] := Result;
    end;
  end;
  Scale := r / Result.Rq;
end;

// Bilinear blit of a premultiplied sprite centred on (cx, cy) at any
// fractional position and scale, so hexagons glide and grow continuously
// instead of stepping by whole pixels and size buckets.
procedure BlendPx(p: PBGRAPixel; r, g, b, a: integer); inline;
var
  ia: integer;
begin
  // premultiplied "over": dest = src + dest x (1 - src alpha)
  ia := (255 - a) * 257;
  p^.red := Min(255, r + (p^.red * ia + 32768) shr 16);
  p^.green := Min(255, g + (p^.green * ia + 32768) shr 16);
  p^.blue := Min(255, b + (p^.blue * ia + 32768) shr 16);
  p^.alpha := Min(255, a + (p^.alpha * ia + 32768) shr 16);
end;

{ TRenderWorker }

constructor TRenderWorker.Create(AOwner: THexBackground; ASlot: integer);
begin
  FOwner := AOwner;
  FSlot := ASlot;
  FStart := RTLEventCreate;
  FDone := RTLEventCreate;
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TRenderWorker.Destroy;
begin
  RTLEventDestroy(FStart);
  RTLEventDestroy(FDone);
  inherited Destroy;
end;

procedure TRenderWorker.Execute;
begin
  while True do
  begin
    RTLEventWaitFor(FStart);
    if Terminated then Break;
    FOwner.RunTiles(FSlot);
    RTLEventSetEvent(FDone);
  end;
end;

{ -------------------------------------------------------- screen layers }

procedure THexBackground.ClearScreens;
var
  i: integer;
begin
  for i := 0 to High(FScreens) do
  begin
    FreeAndNil(FScreens[i].Base);
    FreeAndNil(FScreens[i].Vig);
    FScreens[i].W := 0;
  end;
  Inc(FScreenGen);
end;

function THexBackground.GetScreen(W, H: integer): integer;
var
  i: integer;
begin
  Inc(FStamp);
  Result := 0;
  for i := 0 to High(FScreens) do
  begin
    if (FScreens[i].W = W) and (FScreens[i].H = H) then
    begin
      FScreens[i].Stamp := FStamp;
      Exit(i);
    end;
    if FScreens[i].Stamp < FScreens[Result].Stamp then Result := i;
  end;
  // reuse the least recently used slot
  FreeAndNil(FScreens[Result].Base);
  FreeAndNil(FScreens[Result].Vig);
  FScreens[Result].Base := TBGRABitmap.Create(W, H);
  FScreens[Result].Vig := TBGRABitmap.Create(W, H, BGRAPixelTransparent);
  FScreens[Result].Stamp := FStamp;
  FScreens[Result].W := W;
  FScreens[Result].H := H;
  RenderBase(FScreens[Result].Base, W, H);
  RenderVignette(FScreens[Result].Vig, W, H);
  Inc(FScreenGen);
end;

procedure THexBackground.RenderBase(Bmp: TBGRABitmap; W, H: integer);
var
  M: single;
  i: integer;
begin
  M := Max(W, H);
  with FSettings do
  begin
    Bmp.Fill(WithAlpha(BaseColor, 255));
    for i := 0 to 2 do
      Bmp.GradientFill(0, 0, W, H, HazeColor[i], WithAlpha(HazeColor[i], 0), gtRadial,
        PointF(W * HazeX[i], H * HazeY[i]), PointF(W * HazeX[i] + M * HazeR[i], H * HazeY[i]),
        dmDrawWithTransparency);
  end;
end;

procedure THexBackground.RenderVignette(Bmp: TBGRABitmap; W, H: integer);
var
  D: single;
begin
  D := Sqrt(Sqr(W) + Sqr(H));
  with FSettings do
  begin
    Bmp.GradientFill(0, 0, W, H, BGRA(0, 0, 0, 0), WithAlpha(BGRABlack, VigAlpha), gtRadial,
      PointF(W * VigX, H * VigY), PointF(W * VigX + D * VigRadius, H * VigY), dmDrawWithTransparency);
    Bmp.GradientFill(0, 0, W, H, WithAlpha(BGRABlack, ShadowAlpha), BGRA(0, 0, 0, 0), gtLinear,
      PointF(0, 0), PointF(W * ShadowX, H * ShadowY), dmDrawWithTransparency);
  end;
end;

{ ---------------------------------------------------------------- render }

{ -------------------------------------------------------- parallel drawing }

procedure THexBackground.EnsureWorkers;
var
  n, i: integer;
begin
  n := Round(FSettings.Threads);
  if n <= 0 then n := TThread.ProcessorCount;
  n := EnsureRange(n, 1, 64) - 1;             // the main thread works too
  if Length(FWorkers) = n then Exit;
  FreeWorkers;
  SetLength(FWorkers, n);
  for i := 0 to n - 1 do
    FWorkers[i] := TRenderWorker.Create(Self, i + 1);
end;

procedure THexBackground.FreeWorkers;
var
  i: integer;
begin
  for i := 0 to High(FWorkers) do
  begin
    FWorkers[i].Terminate;
    RTLEventSetEvent(FWorkers[i].FStart);
    FWorkers[i].WaitFor;
    FWorkers[i].Free;
  end;
  FWorkers := nil;
end;

function THexBackground.NewCmd(AKind: TCmdKind; APass: integer): PDrawCmd;
begin
  if FCmdCount > High(FCmds) then SetLength(FCmds, Max(1024, FCmdCount * 2));
  Result := @FCmds[FCmdCount];
  Inc(FCmdCount);
  Result^.Kind := AKind;
  Result^.Pass := APass;
end;

procedure THexBackground.AddBlit(APass: integer; Spr: TSprite; x, y, Scale, Opacity: single);
var
  C: PDrawCmd;
  half: single;
begin
  if (Spr = nil) or (Opacity <= 0) or (Scale <= 0) then Exit;
  half := ((Spr.W - 1) / 2 + 1) * Scale;
  if (y + half < 0) or (y - half > FJobH) or (x + half < 0) or (x - half > FJobW) then Exit;
  C := NewCmd(ckBlit, APass);
  C^.Spr := Spr;
  C^.X := x;
  C^.Y := y;
  C^.S := Scale;
  C^.A := Opacity;
  C^.Y0 := Floor(y - half);
  C^.Y1 := Ceil(y + half);
end;

procedure SetCmdColor(C: PDrawCmd; Col: TBGRAPixel; Alpha: single);
begin
  C^.CA := EnsureRange(Round(Alpha), 0, 255);
  C^.CR := Col.red * C^.CA div 255;
  C^.CG := Col.green * C^.CA div 255;
  C^.CB := Col.blue * C^.CA div 255;
end;

procedure THexBackground.AddLine(APass: integer; x1, y1, x2, y2, Width: single; Col: TBGRAPixel; Alpha: single);
var
  C: PDrawCmd;
begin
  if Alpha < 1 then Exit;
  C := NewCmd(ckLine, APass);
  C^.X := x1;
  C^.Y := y1;
  C^.X2 := x2;
  C^.Y2 := y2;
  C^.HW := Width / 2;
  C^.Y0 := Floor(Min(y1, y2) - C^.HW - 1);
  C^.Y1 := Ceil(Max(y1, y2) + C^.HW + 1);
  SetCmdColor(C, Col, Alpha);
end;

procedure THexBackground.AddDisc(APass: integer; x, y, Radius: single; Col: TBGRAPixel; Alpha: single);
var
  C: PDrawCmd;
begin
  // a disc smaller than a pixel is drawn one pixel wide and a bit fainter
  if Radius < 0.9 then
  begin
    Alpha := Alpha * Radius / 0.9;
    Radius := 0.9;
  end;
  if Alpha < 1 then Exit;
  C := NewCmd(ckDisc, APass);
  C^.X := x;
  C^.Y := y;
  C^.S := Radius;
  C^.Y0 := Floor(y - Radius - 1);
  C^.Y1 := Ceil(y + Radius + 1);
  SetCmdColor(C, Col, Alpha);
end;

// Bilinear blit of a premultiplied sprite at any fractional position and
// scale, limited to rows ty0..ty1 (one tile).
procedure THexBackground.BlitTile(C: PDrawCmd; ty0, ty1: integer);
var
  W, x0, x1, y0, y1, x, y, ui, vi, fu, fv, op: integer;
  w00, w10, w01, w11, sa, sr, sg, sb: integer;
  ctr, half, inv, v: single;
  uF, duF: longint;
  p, r0, r1: PBGRAPixel;
  a00, a10, a01, a11: TBGRAPixel;
  Spr: TSprite;
begin
  Spr := C^.Spr;
  op := EnsureRange(Round(C^.A * 256), 0, 256);
  if op = 0 then Exit;
  W := Spr.W;
  ctr := (W - 1) / 2;
  half := (ctr + 1) * C^.S;
  x0 := Max(0, Floor(C^.X - half));
  x1 := Min(FJobW - 1, Ceil(C^.X + half));
  y0 := Max(ty0, Max(0, C^.Y0));
  y1 := Min(ty1, Min(FJobH - 1, C^.Y1));
  if (x0 > x1) or (y0 > y1) then Exit;
  inv := 1 / C^.S;
  duF := Round(inv * 65536);
  for y := y0 to y1 do
  begin
    v := (y - C^.Y) * inv + ctr;
    vi := Floor(v);
    if (vi < -1) or (vi >= W) then Continue;
    fv := Round((v - vi) * 256);
    if vi >= 0 then r0 := @Spr.Pix[vi * W] else r0 := nil;
    if vi + 1 < W then r1 := @Spr.Pix[(vi + 1) * W] else r1 := nil;
    p := FRows[y];
    Inc(p, x0);
    uF := Round(((x0 - C^.X) * inv + ctr) * 65536);
    for x := x0 to x1 do
    begin
      ui := SarLongint(uF, 16);
      fu := (uF shr 8) and $FF;
      Inc(uF, duF);
      if (ui >= -1) and (ui < W) then
      begin
        a00 := BGRAPixelTransparent;
        a10 := BGRAPixelTransparent;
        a01 := BGRAPixelTransparent;
        a11 := BGRAPixelTransparent;
        if r0 <> nil then
        begin
          if ui >= 0 then a00 := r0[ui];
          if ui + 1 < W then a10 := r0[ui + 1];
        end;
        if r1 <> nil then
        begin
          if ui >= 0 then a01 := r1[ui];
          if ui + 1 < W then a11 := r1[ui + 1];
        end;
        if (a00.alpha or a10.alpha or a01.alpha or a11.alpha) <> 0 then
        begin
          w00 := (256 - fu) * (256 - fv);
          w10 := fu * (256 - fv);
          w01 := (256 - fu) * fv;
          w11 := fu * fv;
          sa := (a00.alpha * w00 + a10.alpha * w10 + a01.alpha * w01 + a11.alpha * w11) shr 16;
          sr := (a00.red * w00 + a10.red * w10 + a01.red * w01 + a11.red * w11) shr 16;
          sg := (a00.green * w00 + a10.green * w10 + a01.green * w01 + a11.green * w11) shr 16;
          sb := (a00.blue * w00 + a10.blue * w10 + a01.blue * w01 + a11.blue * w11) shr 16;
          BlendPx(p, (sr * op) shr 8, (sg * op) shr 8, (sb * op) shr 8, (sa * op) shr 8);
        end;
      end;
      Inc(p);
    end;
  end;
end;

// Antialiased thick segment (coverage from the distance to the segment).
procedure THexBackground.LineTile(C: PDrawCmd; ty0, ty1: integer);
var
  x, y, x0, x1, y0, y1, cov: integer;
  dx, dy, l2, t, px, py, fc: single;
  p: PBGRAPixel;
begin
  x0 := Max(0, Floor(Min(C^.X, C^.X2) - C^.HW - 1));
  x1 := Min(FJobW - 1, Ceil(Max(C^.X, C^.X2) + C^.HW + 1));
  y0 := Max(ty0, Max(0, C^.Y0));
  y1 := Min(ty1, Min(FJobH - 1, C^.Y1));
  dx := C^.X2 - C^.X;
  dy := C^.Y2 - C^.Y;
  l2 := Max(1e-6, dx * dx + dy * dy);
  for y := y0 to y1 do
  begin
    p := FRows[y];
    Inc(p, x0);
    for x := x0 to x1 do
    begin
      t := EnsureRange(((x - C^.X) * dx + (y - C^.Y) * dy) / l2, 0, 1);
      px := C^.X + t * dx - x;
      py := C^.Y + t * dy - y;
      fc := C^.HW + 0.5 - Sqrt(px * px + py * py);
      if fc > 0 then
      begin
        cov := Round(Min(1, fc) * 256);
        BlendPx(p, (C^.CR * cov) shr 8, (C^.CG * cov) shr 8, (C^.CB * cov) shr 8, (C^.CA * cov) shr 8);
      end;
      Inc(p);
    end;
  end;
end;

procedure THexBackground.DiscTile(C: PDrawCmd; ty0, ty1: integer);
var
  x, y, x0, x1, y0, y1, cov: integer;
  fc: single;
  p: PBGRAPixel;
begin
  x0 := Max(0, Floor(C^.X - C^.S - 1));
  x1 := Min(FJobW - 1, Ceil(C^.X + C^.S + 1));
  y0 := Max(ty0, Max(0, C^.Y0));
  y1 := Min(ty1, Min(FJobH - 1, C^.Y1));
  for y := y0 to y1 do
  begin
    p := FRows[y];
    Inc(p, x0);
    for x := x0 to x1 do
    begin
      fc := C^.S + 0.5 - Sqrt(Sqr(x - C^.X) + Sqr(y - C^.Y));
      if fc > 0 then
      begin
        cov := Round(Min(1, fc) * 256);
        BlendPx(p, (C^.CR * cov) shr 8, (C^.CG * cov) shr 8, (C^.CB * cov) shr 8, (C^.CA * cov) shr 8);
      end;
      Inc(p);
    end;
  end;
end;

// Runs on every drawing thread: grab 16-row tiles until none are left.
procedure THexBackground.RunTiles(Slot: integer);
var
  tile, ty0, ty1, y, x, i, a, ia: integer;
  t: double;
  Tm: PDouble;
  p, v: PBGRAPixel;
  C: PDrawCmd;
begin
  Tm := @FSlotT[Slot * PassCount];
  repeat
    tile := InterLockedIncrement(FNextTile) - 1;
    if tile >= FTileCount then Break;
    ty0 := tile * TileH;
    ty1 := Min(FJobH - 1, ty0 + TileH - 1);

    if FJobBase then
    begin
      t := NowMs;
      for y := ty0 to ty1 do
        Move(FBaseRows[y]^, FRows[y]^, FJobW * SizeOf(TBGRAPixel));
      Tm[psBase] := Tm[psBase] + NowMs - t;
    end;

    for i := 0 to FCmdCount - 1 do
    begin
      C := @FCmds[i];
      if (C^.Y1 < ty0) or (C^.Y0 > ty1) then Continue;
      t := NowMs;
      case C^.Kind of
        ckBlit: BlitTile(C, ty0, ty1);
        ckLine: LineTile(C, ty0, ty1);
        ckDisc: DiscTile(C, ty0, ty1);
      end;
      Tm[C^.Pass] := Tm[C^.Pass] + NowMs - t;
    end;

    if FJobVig then
    begin
      // the vignette is black: only darken by its alpha
      t := NowMs;
      for y := ty0 to ty1 do
      begin
        p := FRows[y];
        v := FVigRows[y];
        for x := 0 to FJobW - 1 do
        begin
          a := v^.alpha;
          if a > 0 then
          begin
            ia := (255 - a) * 257;
            p^.red := (p^.red * ia + 32768) shr 16;
            p^.green := (p^.green * ia + 32768) shr 16;
            p^.blue := (p^.blue * ia + 32768) shr 16;
          end;
          Inc(p);
          Inc(v);
        end;
      end;
      Tm[psVignette] := Tm[psVignette] + NowMs - t;
    end;
  until False;
end;

procedure THexBackground.CollectItems(W, H: integer; f: single);
var
  s, c: integer;
  // occlusion by the nearest gate wall (screen space)
  Occ: boolean;
  OccZ, WallX, WallY, WallR, HoleX, HoleY, HoleR: single;

  procedure Consider(const Cell: TCell; AKind: byte; NearStart, NearEnd: single);
  var
    V, B: TVec3;
    inv, rp, cb, op, pad, sx, sy: single;
    Item: ^TDrawItem;
  begin
    Inc(FStats.Cells);
    ToCamera(Cell.X, Cell.Y, Cell.Z, V);
    if V.Z < FSettings.NearClip then begin Inc(FStats.Culled); Exit; end;
    op := (1 - SmoothStep(FSettings.FogStart, FSettings.FogEnd, V.Z)) * SmoothStep(NearEnd, NearStart, V.Z);
    if op < 0.02 then begin Inc(FStats.Culled); Exit; end;
    inv := 1 / V.Z;
    rp := f * Cell.R * inv;
    sx := W / 2 + f * V.X * inv;
    sy := H / 2 + f * V.Y * inv;
    cb := Coc(V.Z, H);
    pad := rp * (1.6 + FSettings.GlowBlur * 2) + cb * 2 + 4;
    // hidden behind the nearest gate wall and not visible through its gap
    if Occ and (V.Z > OccZ + 0.3) and
      (Sqrt(Sqr(sx - WallX) + Sqr(sy - WallY)) + pad < WallR) and
      (Sqrt(Sqr(sx - HoleX) + Sqr(sy - HoleY)) - pad > HoleR) then
    begin
      Inc(FStats.Culled);
      Exit;
    end;
    if (sx + pad < 0) or (sx - pad > W) or (sy + pad < 0) or (sy - pad > H) then
    begin
      Inc(FStats.Culled);
      Exit;
    end;
    if FItemCount > High(FItems) then SetLength(FItems, Max(1024, FItemCount * 2));
    Item := @FItems[FItemCount];
    Item^.Z := V.Z;
    Item^.SX := sx;
    Item^.SY := sy;
    Item^.R := rp;
    Item^.Blur := cb;
    Item^.Opa := op;
    Item^.Kind := AKind;
    // back face: the same hexagon Thickness further away
    ToCamera(Cell.X, Cell.Y, Cell.Z + FSettings.Thickness, B);
    if B.Z > FSettings.NearClip then
    begin
      Item^.BX := W / 2 + f * B.X / B.Z;
      Item^.BY := H / 2 + f * B.Y / B.Z;
      Item^.BR := f * Cell.R / B.Z;
    end
    else
      Item^.BR := 0;
    Inc(FItemCount);
  end;

  procedure FindOccluder;
  var
    g: integer;
    V: TVec3;
  begin
    Occ := False;
    for g := 0 to High(FGates) do
    begin
      ToCamera(0, 0, FGates[g].Z, V);
      if V.Z < 5.5 then Continue;                   // still fading out
      // only a fully opaque wall hides what is behind it
      if V.Z > FSettings.FogStart then Exit;
      OccZ := V.Z;
      WallX := W / 2 + f * V.X / V.Z;
      WallY := H / 2 + f * V.Y / V.Z;
      WallR := f * (FGates[g].Ext - 1.5 * FSettings.HexRadius) / V.Z;
      ToCamera(FGates[g].GX, FGates[g].GY, FGates[g].Z, V);
      HoleX := W / 2 + f * V.X / V.Z;
      HoleY := H / 2 + f * V.Y / V.Z;
      HoleR := f * (FGates[g].GR + FSettings.HexRadius) / V.Z;
      Occ := True;
      Exit;
    end;
  end;

begin
  FItemCount := 0;
  FStats.Cells := 0;
  FStats.Culled := 0;
  FStats.Sheets := Length(FSheets);
  FindOccluder;
  for s := 0 to High(FSheets) do
    for c := 0 to High(FSheets[s].Cells) do
      Consider(FSheets[s].Cells[c], 0, FSettings.NearFadeStart, FSettings.NearFadeEnd);
  // gates fade out just before the camera passes through them: right at the
  // wall each hexagon would cover a large part of the screen
  for s := 0 to High(FGates) do
    for c := 0 to High(FGates[s].Cells) do
      Consider(FGates[s].Cells[c], FGates[s].Kinds[c], 5.0, 2.2);
  FStats.Visible := FItemCount;
end;

// far to near
procedure THexBackground.SortItems(L, R: integer);
var
  i, j: integer;
  P: single;
  T: TDrawItem;
begin
  while L < R do
  begin
    i := L;
    j := R;
    P := FItems[(L + R) shr 1].Z;
    repeat
      while FItems[i].Z > P do Inc(i);
      while FItems[j].Z < P do Dec(j);
      if i <= j then
      begin
        T := FItems[i];
        FItems[i] := FItems[j];
        FItems[j] := T;
        Inc(i);
        Dec(j);
      end;
    until i > j;
    if j - L < R - i then
    begin
      if L < j then SortItems(L, j);
      L := i;
    end
    else
    begin
      if i < R then SortItems(i, R);
      R := j;
    end;
  end;
end;

procedure THexBackground.Render(Dest: TBGRABitmap; W, H: integer; APasses: TPassSet;
  ACheckers, AStats: boolean);
var
  T: array[0..PassCount - 1] of double;
  i, Slots: integer;
  tDraw: double;
begin
  W := Max(W, 8);
  H := Max(H, 8);
  Dest.SetSize(W, H);
  BuildFrame(W, H, APasses, AStats);
  if not (psBase in APasses) then
    if ACheckers then DrawCheckers(Dest, Max(4, H div 50)) else Dest.Fill(BGRABlack);
  FillChar(T, SizeOf(T), 0);

  // row pointers are read here, on the main thread, so the workers only
  // touch plain memory
  if Length(FRows) < H then
  begin
    SetLength(FRows, H);
    SetLength(FBaseRows, H);
    SetLength(FVigRows, H);
  end;
  for i := 0 to H - 1 do
  begin
    FRows[i] := Dest.ScanLine[i];
    if FJobBase then FBaseRows[i] := FScreens[FScr].Base.ScanLine[i];
    if FJobVig then FVigRows[i] := FScreens[FScr].Vig.ScanLine[i];
  end;

  // ---- parallel part: every thread takes 16-row tiles and runs the list
  tDraw := NowMs;
  EnsureWorkers;
  Slots := Length(FWorkers) + 1;
  SetLength(FSlotT, Slots * PassCount);
  FillChar(FSlotT[0], Length(FSlotT) * SizeOf(double), 0);
  FTileCount := (H + TileH - 1) div TileH;
  FNextTile := 0;
  for i := 0 to High(FWorkers) do RTLEventSetEvent(FWorkers[i].FStart);
  RunTiles(0);
  for i := 0 to High(FWorkers) do RTLEventWaitFor(FWorkers[i].FDone);
  Dest.InvalidateBitmap;       // pixels were written through ScanLine

  if AStats then
  begin
    for i := 0 to Slots * PassCount - 1 do
      T[i mod PassCount] := T[i mod PassCount] + FSlotT[i];
    for i := 0 to PassCount - 1 do
    begin
      FPasses[i].Items := FN[i];
      FPasses[i].TimeMs := FPasses[i].TimeMs * 0.9 + T[i] * 0.1;
    end;
    FStats.Threads := Slots;
    FStats.DrawMs := FStats.DrawMs * 0.9 + (NowMs - tDraw) * 0.1;
    FStats.FrameMs := FStats.FrameMs * 0.9 + (NowMs - FBuildStart) * 0.1;
  end;
end;

procedure THexBackground.BuildFrame(W, H: integer; APasses: TPassSet; AStats: boolean);
var
  f, a, rp, blur, lw, ca, sa, sc, x, y: single;
  i, k: integer;
  V: TVec3;
  Spr: TSprite;
begin
  W := Max(W, 8);
  H := Max(H, 8);
  if FSheets = nil then UpdateField;
  InitParticles;
  if FLnSize = 0 then ClearSprites;
  FillChar(FN, SizeOf(FN), 0);
  FStats.SpritesMade := 0;
  FStats.Borrowed := 0;
  FStats.Queued := 0;
  FStats.Skipped := 0;
  if FSpriteBytes > Int64(Round(FSettings.CacheMB)) * 1048576 then
    ClearSprites;
  CollectBuiltSprites;
  // only the live view is time-limited; thumbnails and PNG export get full quality
  if AStats then FBudgetEnd := NowMs + FSettings.SpriteBudget else FBudgetEnd := 1e300;
  f := (H / 2) / Tan(DegToRad(FSettings.Fov) / 2);
  FBuildStart := NowMs;
  FScr := GetScreen(W, H);
  FJobW := W;
  FJobH := H;
  FCmdCount := 0;

  // ---- serial part: build the draw list (far to near)
  with FSettings do
  begin
    FN[psBase] := 1;

    // 1 bokeh dust (always behind the focus plane)
    if psDust in APasses then
      for i := 0 to High(FDust) do
        with FDust[i] do
        begin
          ToCamera(P.X, P.Y, P.Z, V);
          if V.Z < NearClip then Continue;
          a := Alpha / 255 * Fade(V.Z) * SmoothStep(FocusDist * 0.8, FocusDist * 1.3, V.Z);
          if a < 0.01 then Continue;
          rp := f * Size / V.Z;
          blur := Max(Coc(V.Z, H), DustMinBlur * H / 1000);
          if Dot then k := skDot else k := skDust;
          Spr := GetSprite(k, rp, blur, sc);
          AddBlit(psDust, Spr, W / 2 + f * V.X / V.Z, H / 2 + f * V.Y / V.Z, sc, a);
          Inc(FN[psDust]);
        end;

    // 2..5 hexagons, back to front: back face, side edges, front face
    CollectItems(W, H, f);
    if FItemCount > 1 then SortItems(0, FItemCount - 1);
    for i := 0 to FItemCount - 1 do
      with FItems[i] do
      begin
        if (psBack in APasses) and (BR > 0.3) then
        begin
          if Kind = 0 then k := skBack else k := skGateBack;
          Spr := GetSprite(k, BR, Blur, sc);
          AddBlit(psBack, Spr, BX, BY, sc, Opa);
          Inc(FN[psBack]);
        end;
        if (psSides in APasses) and (BR > 0.3) and (R > 5) and (Blur < SideMaxBlur * H / 1000) then
        begin
          lw := Max(1, R * LineWidth * 0.7);
          for k := 0 to 5 do
          begin
            SinCos(k * Pi / 3, sa, ca);
            AddLine(psSides, SX + R * ca, SY + R * sa, BX + BR * ca, BY + BR * sa, lw,
              BackColor, RimAlpha * SideAlpha * Opa);
          end;
          Inc(FN[psSides]);
        end;
        if psFront in APasses then
        begin
          if Kind = 1 then
            Spr := GetSprite(skGate, R, Blur, sc)
          else if Kind = 2 then
            Spr := GetSprite(skGateEdge, R, Blur, sc)
          else if psGlow in APasses then
          begin
            Spr := GetSprite(skFrontGlow, R, Blur, sc);
            Inc(FN[psGlow]);
          end
          else
            Spr := GetSprite(skFront, R, Blur, sc);
          AddBlit(psFront, Spr, SX, SY, sc, Opa);
          Inc(FN[psFront]);
        end
        else if psGlow in APasses then
        begin
          Spr := GetSprite(skGlow, R, Blur, sc);
          AddBlit(psGlow, Spr, SX, SY, sc, Opa);
          Inc(FN[psGlow]);
        end;
      end;

    // 6 sparks
    if psSparks in APasses then
      for i := 0 to High(FSparks) do
        with FSparks[i] do
        begin
          ToCamera(P.X, P.Y, P.Z, V);
          if V.Z < NearClip then Continue;
          a := Alpha * Sin(Pi * Life) * Fade(V.Z) *
            ((1 - SparkTwinkleDepth) + SparkTwinkleDepth * Sin(FTime * Twinkle + Phase));
          if a < 3 then Continue;
          rp := Max(0.3, f * Size / V.Z);
          blur := Coc(V.Z, H);
          x := W / 2 + f * V.X / V.Z;
          y := H / 2 + f * V.Y / V.Z;
          if (x < -blur - 10) or (x > W + blur + 10) or (y < -blur - 10) or (y > H + blur + 10) then
            Continue;
          if blur > rp * 2 then
            // out of focus: the light spreads over the circle of confusion
            AddDisc(psSparks, x, y, blur, SparkHaloColor, Max(a * 0.05, a * Sqr(rp * 2 / blur) * 0.4))
          else
          begin
            AddDisc(psSparks, x, y, rp * SparkHaloSize, SparkHaloColor, a * SparkHaloAlpha);
            AddDisc(psSparks, x, y, rp, SparkCoreColor, a);
          end;
          Inc(FN[psSparks]);
        end;
  end;

  FJobBase := psBase in APasses;
  FJobVig := psVignette in APasses;
  if FJobVig then FN[psVignette] := 1;
  if AStats then
  begin
    FStats.Commands := FCmdCount;
    FStats.SetupMs := FStats.SetupMs * 0.9 + (NowMs - FBuildStart) * 0.1;
  end;
end;

function THexBackground.Cmd(Index: integer): PDrawCmd;
begin
  Result := @FCmds[Index];
end;

function THexBackground.FrameBase: TBGRABitmap;
begin
  Result := FScreens[FScr].Base;
end;

function THexBackground.FrameVignette: TBGRABitmap;
begin
  Result := FScreens[FScr].Vig;
end;

destructor TSprite.Destroy;
begin
  if (Handle <> nil) and Assigned(SpriteFreeHook) then SpriteFreeHook(Self);
  inherited Destroy;
end;

{ ---------------------------------------------------------------- report }

function THexBackground.Report(FPS: double): string;
var
  SL: TStringList;
  i, Loose, Cells: integer;
  LastGroup, V: string;
  s, c: integer;
begin
  SL := TStringList.Create;
  try
    Loose := 0;
    Cells := 0;
    for s := 0 to High(FSheets) do
      for c := 0 to High(FSheets[s].Cells) do
      begin
        Inc(Cells);
        if FSheets[s].Cells[c].Loose then Inc(Loose);
      end;
    SL.Add('HEX BACKGROUND - CAMERA FLY-THROUGH');
    SL.Add(StringOfChar('=', 60));
    SL.Add(Format('Time            : %.1f s   seed %d   %.1f fps   frame %.1f ms',
      [FTime, FSeed, FPS, FStats.FrameMs]));
    SL.Add(Format('Camera position : (%.2f, %.2f, %.2f)  moving %.2f units/s',
      [FCam.X, FCam.Y, FCam.Z, FSettings.Speed]));
    SL.Add(Format('Camera rotation : yaw %.2f  pitch %.2f  roll %.2f deg  (mouse steer %.2f / %.2f)',
      [RadToDeg(FYaw), RadToDeg(FPitch), RadToDeg(FRoll), RadToDeg(FSteerYaw), RadToDeg(FSteerPitch)]));
    SL.Add(Format('Lens            : FOV %.0f deg, focus now %.2f units, aperture %.2f',
      [FSettings.Fov, FFocus, FSettings.Aperture]));
    SL.Add(Format('World           : %d sheets in range (z %.1f .. %.1f), %d cells (%d loose)',
      [Length(FSheets), FCam.Z + FSettings.NearClip, FCam.Z + FSettings.FarClip, Cells, Loose]));
    SL.Add(Format('Last frame      : %d hexagons drawn, %d culled (behind, faded or off-screen)',
      [FStats.Visible, FStats.Culled]));
    SL.Add(Format('Sprite cache    : %d sprites, %.1f MB of %.0f MB, %d made last frame, %d made in total',
      [FSpriteCount, FSpriteBytes / 1048576, FSettings.CacheMB, FStats.SpritesMade, FSpritesTotal]));
    SL.Add(Format('                  last frame: %d drawn with a borrowed neighbour, %d skipped, %d queued ' +
      'for the 2 background builders (%d waiting)',
      [FStats.Borrowed, FStats.Skipped, FStats.Queued, FQueueCount]));
    SL.Add(Format('Particles       : %d dust, %d sparks', [Length(FDust), Length(FSparks)]));
    SL.Add('');
    SL.Add(Format('Frame split     : %.2f ms building the draw list (%d commands, 1 thread) + ' +
      '%.2f ms drawing on %d threads', [FStats.SetupMs, FStats.Commands, FStats.DrawMs, FStats.Threads]));
    SL.Add('');
    SL.Add('PASSES (bottom to top; time = CPU ms per frame summed over all drawing threads)');
    SL.Add(StringOfChar('-', 60));
    for i := 0 to PassCount - 1 do
      with FPasses[i] do
      begin
        SL.Add(Format('%d  %-16s %-3s %6d items %7.2f ms', [i, Name, BoolToStr(Enabled, 'on', 'off'),
          Items, TimeMs]));
        SL.Add('     ' + Technique);
      end;
    SL.Add('');
    SL.Add('PARAMETERS  (live = applied every frame, else the cache it rebuilds)');
    SL.Add(StringOfChar('-', 60));
    LastGroup := '';
    for i := 0 to High(FParams) do
      with FParams[i] do
      begin
        if Group <> LastGroup then
        begin
          SL.Add('[' + Group + ']');
          LastGroup := Group;
        end;
        if Kind = pkColor then
          V := Format('RGBA(%d, %d, %d, %d)', [PColor^.red, PColor^.green, PColor^.blue, PColor^.alpha])
        else
          V := FloatToStrF(PValue^, ffFixed, 15, Decimals);
        if Effects = [] then V := V + ' (live)';
        SL.Add(Format('  %-18s = %-27s %s', [Name, V, Hint]));
      end;
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

{ ------------------------------------------------------------- ini files }

procedure THexBackground.SaveToIni(const FileName: string);
var
  Ini: TIniFile;
  FS: TFormatSettings;
  i: integer;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Ini := TIniFile.Create(FileName);
  try
    Ini.WriteInteger('General', 'Seed', FSeed);
    for i := 0 to PassCount - 1 do
      Ini.WriteBool('Passes', FPasses[i].Name, FPasses[i].Enabled);
    for i := 0 to High(FParams) do
      with FParams[i] do
        if Kind = pkColor then
          Ini.WriteString(Group, Name, Format('%.2x%.2x%.2x%.2x',
            [PColor^.red, PColor^.green, PColor^.blue, PColor^.alpha]))
        else
          Ini.WriteString(Group, Name, FloatToStr(PValue^, FS));
  finally
    Ini.Free;
  end;
end;

procedure THexBackground.LoadFromIni(const FileName: string);
var
  Ini: TIniFile;
  FS: TFormatSettings;
  i: integer;
  s: string;
  c: longint;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Ini := TIniFile.Create(FileName);
  try
    FSeed := Ini.ReadInteger('General', 'Seed', FSeed);
    for i := 0 to PassCount - 1 do
      FPasses[i].Enabled := Ini.ReadBool('Passes', FPasses[i].Name, FPasses[i].Enabled);
    for i := 0 to High(FParams) do
      with FParams[i] do
      begin
        s := Ini.ReadString(Group, Name, '');
        if s = '' then Continue;
        if Kind = pkColor then
        begin
          if (Length(s) = 8) and TryStrToInt('$' + s, c) then
            PColor^ := BGRA((c shr 24) and $FF, (c shr 16) and $FF, (c shr 8) and $FF, c and $FF);
        end
        else
          PValue^ := StrToFloatDef(s, PValue^, FS);
      end;
  finally
    Ini.Free;
  end;
  Invalidate(AllCaches);
end;

end.
