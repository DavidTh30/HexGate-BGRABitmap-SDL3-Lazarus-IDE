unit USimData;

{ Reads a "hexgate-graphics" file (written by HexGate SDL3: F9 or
  --export-graphics) for the simulator:

    settings        applied to the engine by key ("group.name"), so every number
                    and colour in the file drives the RECIPE mode
    game            numbers the autopilot needs (speeds, gaps, gate spacing)
    sprites.atlas   decoded and premultiplied, with a lookup table
                    (kind, size level, blur level) -> atlas rectangle, for the
                    ATLAS mode
    screen_layers   background and vignette images (ATLAS mode)

  Unknown keys are ignored and missing keys keep the engine default, so an
  edited or partial file still loads.

  SaveTo writes the file back with the engine's current settings, the
  game rule numbers below, and freshly baked atlas, screen layers and
  reference frame (usimexport.pas); everything else in the file is kept. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, fpjson, jsonparser, base64, BGRABitmap, BGRABitmapTypes,
  UHexBackground, USimExport;

type
  TAtlasEntry = record
    Kind: integer;
    Rq, Bq: single;
    X, Y, W, H: integer;
  end;

  { TSimData }

  TSimData = class
  private
    FRoot: TJSONObject;
    FLookup: array of integer;           // [kind][size level][blur level] -> entry, -1 = none
    function Num(const Path: string; Def: double): double;
    procedure LoadImages;
  public
    FileName: string;
    Seed: integer;
    SettingsTotal, SettingsApplied: integer;
    Atlas: TBGRABitmap;                  // premultiplied alpha
    Entries: array of TAtlasEntry;
    SizeLevels, BlurLevels: array of single;
    Background, Vignette: TBGRABitmap;
    // game rules used by the autopilot
    PlayerRadius, LateralSpeed, StartSpeed, MaxSpeed, SpeedPerGate: single;
    StartGap, MinGap, GapPerGate, StartSpacing, MinSpacing, SpacingPerGate: single;
    HudFontFiles: array of string;
    destructor Destroy; override;
    procedure Load(const AFileName: string);
    procedure ApplyTo(Hex: THexBackground);
    // writes the file (also re-bakes its images from Hex) and makes it the current file
    procedure SaveTo(const AFileName: string; Hex: THexBackground);
    property Root: TJSONObject read FRoot;
    // atlas rectangle for a sprite of this kind, on-screen radius and blur
    function FindSprite(Kind: integer; R, Blur: single; out Entry: TAtlasEntry): boolean;
  end;

function GfxKey(const Group, Name: string): string;
function DecodePng(const B64: string): TBGRABitmap;

implementation

function GfxKey(const Group, Name: string): string;

  function Part(const S: string): string;
  var
    c: char;
    Sep: boolean;
  begin
    Result := '';
    Sep := False;
    for c in LowerCase(S) do
      if c in ['a'..'z', '0'..'9'] then
      begin
        if Sep and (Result <> '') then Result := Result + '_';
        Result := Result + c;
        Sep := False;
      end
      else
        Sep := True;
  end;

begin
  Result := Part(Group) + '.' + Part(Name);
end;

function DecodePng(const B64: string): TBGRABitmap;
var
  S: TStringStream;
begin
  S := TStringStream.Create(DecodeStringBase64(B64));
  try
    S.Position := 0;
    Result := TBGRABitmap.Create(S);
  finally
    S.Free;
  end;
end;

{ TSimData }

destructor TSimData.Destroy;
begin
  FRoot.Free;
  Atlas.Free;
  Background.Free;
  Vignette.Free;
  inherited Destroy;
end;

function TSimData.Num(const Path: string; Def: double): double;
var
  D: TJSONData;
begin
  D := FRoot.FindPath(Path);
  if (D <> nil) and (D.JSONType = jtNumber) then Result := D.AsFloat else Result := Def;
end;

procedure TSimData.Load(const AFileName: string);
var
  F: TFileStream;
  D: TJSONData;
  i: integer;
begin
  FileName := AFileName;
  FreeAndNil(FRoot);
  FreeAndNil(Atlas);
  FreeAndNil(Background);
  FreeAndNil(Vignette);
  F := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    D := GetJSON(F);
  finally
    F.Free;
  end;
  if not (D is TJSONObject) then
  begin
    D.Free;
    raise Exception.Create('not a JSON object');
  end;
  FRoot := TJSONObject(D);
  if FRoot.Get('format', '') <> 'hexgate-graphics' then
    raise Exception.Create('format is not "hexgate-graphics"');

  Seed := Round(Num('seed', 2026));
  PlayerRadius := Num('game.player_radius', 0.3);
  LateralSpeed := Num('game.lateral_speed', 11);
  StartSpeed := Num('game.start_speed', 9);
  MaxSpeed := Num('game.max_speed', 26);
  SpeedPerGate := Num('game.speed_per_gate', 0.25);
  StartGap := Num('game.start_gap', 3);
  MinGap := Num('game.min_gap', 1.5);
  GapPerGate := Num('game.gap_per_gate', 0.05);
  StartSpacing := Num('game.start_spacing', 28);
  MinSpacing := Num('game.min_spacing', 18);
  SpacingPerGate := Num('game.spacing_per_gate', 0.35);
  HudFontFiles := nil;
  D := FRoot.FindPath('game.hud.font.files');
  if D is TJSONArray then
    for i := 0 to TJSONArray(D).Count - 1 do
    begin
      SetLength(HudFontFiles, Length(HudFontFiles) + 1);
      HudFontFiles[High(HudFontFiles)] := TJSONArray(D).Strings[i];
    end;

  LoadImages;
end;

procedure TSimData.LoadImages;
var
  D: TJSONData;
  A: TJSONArray;
  O: TJSONObject;
  i, k, si, bi, x, y: integer;
  P: PBGRAPixel;
  best, dd: single;
begin
  FreeAndNil(Atlas);
  FreeAndNil(Background);
  FreeAndNil(Vignette);
  // ---- screen layers
  D := FRoot.FindPath('screen_layers.background.png_base64');
  if D <> nil then Background := DecodePng(D.AsString);
  D := FRoot.FindPath('screen_layers.vignette.png_base64');
  if D <> nil then Vignette := DecodePng(D.AsString);

  // ---- atlas
  Entries := nil;
  SizeLevels := nil;
  BlurLevels := nil;
  D := FRoot.FindPath('sprites.atlas');
  if D is TJSONObject then
  begin
    O := TJSONObject(D);
    A := O.Arrays['size_levels'];
    SetLength(SizeLevels, A.Count);
    for i := 0 to A.Count - 1 do SizeLevels[i] := A.Floats[i];
    A := O.Arrays['blur_levels'];
    SetLength(BlurLevels, A.Count);
    for i := 0 to A.Count - 1 do BlurLevels[i] := A.Floats[i];
    A := O.Arrays['entries'];
    SetLength(Entries, A.Count);
    for i := 0 to A.Count - 1 do
      with A.Objects[i] do
      begin
        Entries[i].Kind := Integers['kind'];
        Entries[i].Rq := Floats['rq'];
        Entries[i].Bq := Floats['bq'];
        Entries[i].X := Integers['x'];
        Entries[i].Y := Integers['y'];
        Entries[i].W := Integers['w'];
        Entries[i].H := Integers['h'];
      end;
    Atlas := DecodePng(O.Strings['png_base64']);
    // straight -> premultiplied alpha (the GPU blends premultiplied)
    for y := 0 to Atlas.Height - 1 do
    begin
      P := Atlas.ScanLine[y];
      for x := 0 to Atlas.Width - 1 do
      begin
        P^.red := P^.red * P^.alpha div 255;
        P^.green := P^.green * P^.alpha div 255;
        P^.blue := P^.blue * P^.alpha div 255;
        Inc(P);
      end;
    end;
    Atlas.InvalidateBitmap;
    // lookup table by nearest size / blur level
    SetLength(FLookup, SpriteKindCount * Length(SizeLevels) * Length(BlurLevels));
    for i := 0 to High(FLookup) do FLookup[i] := -1;
    for i := 0 to High(Entries) do
    begin
      if (Entries[i].Kind < 0) or (Entries[i].Kind >= SpriteKindCount) then Continue;
      si := 0;
      best := 1e30;
      for k := 0 to High(SizeLevels) do
      begin
        dd := Abs(SizeLevels[k] - Entries[i].Rq);
        if dd < best then begin best := dd; si := k; end;
      end;
      bi := 0;
      best := 1e30;
      for k := 0 to High(BlurLevels) do
      begin
        dd := Abs(BlurLevels[k] - Entries[i].Bq);
        if dd < best then begin best := dd; bi := k; end;
      end;
      FLookup[(Entries[i].Kind * Length(SizeLevels) + si) * Length(BlurLevels) + bi] := i;
    end;
  end;
end;

procedure TSimData.SaveTo(const AFileName: string; Hex: THexBackground);
var
  G: TJSONObject;
  Dummy: TJSONObject;
  SL: TStringList;
  OldAsync: boolean;
  FS: TFormatSettings;

  procedure SetNum(const Key: string; V: single);
  begin
    G.Floats[Key] := StrToFloat(FloatToStrF(V, ffGeneral, 7, 0, FS), FS);
  end;

begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  OldAsync := Hex.AsyncSprites;
  Hex.AsyncSprites := False;          // exact sprites for the baked images
  try
    FRoot.Elements['settings'] := SettingsJSON(Hex);
    FRoot.Elements['sprites'] := SpritesJSON(Hex, Dummy);
    FRoot.Elements['screen_layers'] := ScreenLayersJSON(Hex);
    FRoot.Elements['reference_frame'] := ReferenceFrameJSON(Hex);
  finally
    Hex.AsyncSprites := OldAsync;
  end;
  if FRoot.Find('game') is TJSONObject then
  begin
    G := TJSONObject(FRoot.Find('game'));
    SetNum('player_radius', PlayerRadius);
    SetNum('lateral_speed', LateralSpeed);
    SetNum('start_speed', StartSpeed);
    SetNum('max_speed', MaxSpeed);
    SetNum('speed_per_gate', SpeedPerGate);
    SetNum('start_gap', StartGap);
    SetNum('min_gap', MinGap);
    SetNum('gap_per_gate', GapPerGate);
    SetNum('start_spacing', StartSpacing);
    SetNum('min_spacing', MinSpacing);
    SetNum('spacing_per_gate', SpacingPerGate);
  end;
  FRoot.Strings['generator'] := 'HexGate Simulator (edited)';
  FRoot.Strings['created'] := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss', Now);
  SL := TStringList.Create;
  try
    SL.Text := FRoot.FormatJSON([], 2);
    SL.SaveToFile(AFileName);
  finally
    SL.Free;
  end;
  FileName := AFileName;
  LoadImages;                          // the atlas mode shows the new images
end;

procedure TSimData.ApplyTo(Hex: THexBackground);
var
  i: integer;
  P: TParamInfo;
  D: TJSONData;
  S: TJSONObject;
  V: TJSONArray;
begin
  Hex.ResetDefaults;
  SettingsTotal := Length(Hex.Params);
  SettingsApplied := 0;
  D := FRoot.Find('settings');
  if D is TJSONObject then
  begin
    S := TJSONObject(D);
    for i := 0 to High(Hex.Params) do
    begin
      P := Hex.Params[i];
      D := S.Find(GfxKey(P.Group, P.Name));
      if not (D is TJSONObject) then Continue;
      D := TJSONObject(D).Find('value');
      if D = nil then Continue;
      if (P.Kind = pkFloat) and (D.JSONType = jtNumber) then
      begin
        P.PValue^ := D.AsFloat;
        Inc(SettingsApplied);
      end
      else if (P.Kind = pkColor) and (D is TJSONArray) and (TJSONArray(D).Count >= 3) then
      begin
        V := TJSONArray(D);
        P.PColor^.red := EnsureRange(V.Integers[0], 0, 255);
        P.PColor^.green := EnsureRange(V.Integers[1], 0, 255);
        P.PColor^.blue := EnsureRange(V.Integers[2], 0, 255);
        if V.Count >= 4 then P.PColor^.alpha := EnsureRange(V.Integers[3], 0, 255)
        else P.PColor^.alpha := 255;
        Inc(SettingsApplied);
      end;
    end;
  end;
  Hex.SetSeed(Seed);
  Hex.Invalidate([ivSprites, ivScreen, ivField, ivDust, ivSparks]);
end;

function TSimData.FindSprite(Kind: integer; R, Blur: single; out Entry: TAtlasEntry): boolean;
var
  si, bi, k, i: integer;
  best, dd: single;
begin
  Result := False;
  if (Length(SizeLevels) = 0) or (Length(BlurLevels) = 0) or (Kind < 0) or (Kind >= SpriteKindCount) then Exit;
  // the smallest size level that is not smaller than R (scaled down a little, never up)
  si := High(SizeLevels);
  for k := 0 to High(SizeLevels) do
    if SizeLevels[k] >= R then
    begin
      si := k;
      Break;
    end;
  // nearest blur level, measured at the level's size
  Blur := Blur * SizeLevels[si] / Max(0.5, R);
  bi := 0;
  best := 1e30;
  for k := 0 to High(BlurLevels) do
  begin
    dd := Abs(BlurLevels[k] - Blur);
    if dd < best then begin best := dd; bi := k; end;
  end;
  i := FLookup[(Kind * Length(SizeLevels) + si) * Length(BlurLevels) + bi];
  if i < 0 then Exit;
  Entry := Entries[i];
  Result := True;
end;

end.
