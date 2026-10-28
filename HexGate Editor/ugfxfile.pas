unit UGfxFile;

{ A "hexgate-graphics" file (written by HexGate or HexGate SDL3: F9 or
  --export-graphics) as the editor sees it:

    settings        applied to the engine by key ("group.name"); unknown keys
                    are ignored and missing keys keep the engine default, so an
                    edited or partial file still loads
    game            the numbers the autopilot uses (speeds, gaps, gate spacing)
    images          atlas, background, vignette and reference frame, decoded
                    on request for the Images page (straight alpha)

  SaveTo writes the file back with the engine's current settings, the game
  numbers below and freshly baked atlas, screen layers and reference frame
  (ugfxbake.pas). Everything else in the file (formulas, HUD, readme) is
  kept as it was. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, fpjson, jsonparser, base64, BGRABitmap, BGRABitmapTypes,
  UHexBackground, UGfxBake;

type
  TGfxImage = (giAtlas, giBackground, giVignette, giReference);

  { TGfxFile }

  TGfxFile = class
  private
    FRoot: TJSONObject;
    function Num(const Path: string; Def: double): double;
  public
    FileName: string;
    Seed: integer;
    SettingsTotal, SettingsApplied, UnknownKeys: integer;
    // game rules used by the autopilot (game.*)
    PlayerRadius, LateralSpeed, StartSpeed, MaxSpeed, SpeedPerGate: single;
    StartGap, MinGap, GapPerGate, StartSpacing, MinSpacing, SpacingPerGate: single;
    destructor Destroy; override;
    procedure Load(const AFileName: string);
    // a file with no settings yet (the engine's built-in look); Save completes it
    procedure NewEmpty(const AFileName: string);
    procedure ApplyTo(Hex: THexBackground);
    // writes the file (re-baking its images from Hex) and makes it the current file
    procedure SaveTo(const AFileName: string; Hex: THexBackground);
    // decoded image of the file, nil when it has none (caller frees)
    function Image(Which: TGfxImage): TBGRABitmap;
    // a short report of what the file holds
    function Summary: string;
    property Root: TJSONObject read FRoot;
  end;

const
  GfxImageNames: array[TGfxImage] of string = ('Sprite atlas', 'Background', 'Vignette',
    'Reference frame');
  GfxImagePaths: array[TGfxImage] of string = ('sprites.atlas.png_base64',
    'screen_layers.background.png_base64', 'screen_layers.vignette.png_base64',
    'reference_frame.png_base64');

function GfxKey(const Group, Name: string): string;

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

{ TGfxFile }

destructor TGfxFile.Destroy;
begin
  FRoot.Free;
  inherited Destroy;
end;

function TGfxFile.Num(const Path: string; Def: double): double;
var
  D: TJSONData;
begin
  D := FRoot.FindPath(Path);
  if (D <> nil) and (D.JSONType = jtNumber) then Result := D.AsFloat else Result := Def;
end;

procedure TGfxFile.Load(const AFileName: string);
var
  F: TFileStream;
  D: TJSONData;
begin
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
  if TJSONObject(D).Get('format', '') <> 'hexgate-graphics' then
  begin
    D.Free;
    raise Exception.Create('format is not "hexgate-graphics"');
  end;
  // the old file stays loaded until the new one is known to be good
  FRoot.Free;
  FRoot := TJSONObject(D);
  FileName := AFileName;

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
end;

procedure TGfxFile.NewEmpty(const AFileName: string);
begin
  FRoot.Free;
  FRoot := TJSONObject.Create(['format', 'hexgate-graphics', 'version', 1, 'seed', 2026]);
  FRoot.Add('game', TJSONObject.Create);
  FileName := AFileName;
  Seed := 2026;
  PlayerRadius := 0.3;
  LateralSpeed := 11;
  StartSpeed := 9;
  MaxSpeed := 26;
  SpeedPerGate := 0.25;
  StartGap := 3;
  MinGap := 1.5;
  GapPerGate := 0.05;
  StartSpacing := 28;
  MinSpacing := 18;
  SpacingPerGate := 0.35;
end;

procedure TGfxFile.ApplyTo(Hex: THexBackground);
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
  UnknownKeys := 0;
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
    UnknownKeys := Max(0, S.Count - SettingsApplied);
  end;
  Hex.SetSeed(Seed);
  Hex.Invalidate([ivSprites, ivScreen, ivField, ivDust, ivSparks]);
end;

procedure TGfxFile.SaveTo(const AFileName: string; Hex: THexBackground);
var
  G, Dummy: TJSONObject;
  SL: TStringList;
  OldAsync: boolean;
  FS: TFormatSettings;

  procedure SetNum(const Key: string; V: single);
  begin
    // 7 significant digits: 0.35 stays 0.35, not 0.349999994039536
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
  if not (FRoot.Find('game') is TJSONObject) then FRoot.Elements['game'] := TJSONObject.Create;
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
  FRoot.Integers['seed'] := Hex.Seed;
  FRoot.Strings['generator'] := 'HexGate Editor (edited)';
  FRoot.Strings['created'] := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss', Now);
  SL := TStringList.Create;
  try
    SL.Text := FRoot.FormatJSON([], 2);
    SL.SaveToFile(AFileName);
  finally
    SL.Free;
  end;
  FileName := AFileName;
  Seed := Hex.Seed;
end;

function TGfxFile.Image(Which: TGfxImage): TBGRABitmap;
var
  D: TJSONData;
  S: TStringStream;
begin
  Result := nil;
  if FRoot = nil then Exit;
  D := FRoot.FindPath(GfxImagePaths[Which]);
  if (D = nil) or (D.JSONType <> jtString) then Exit;
  S := TStringStream.Create(DecodeStringBase64(D.AsString));
  try
    S.Position := 0;
    Result := TBGRABitmap.Create(S);
  finally
    S.Free;
  end;
end;

function TGfxFile.Summary: string;
var
  SL: TStringList;
  D: TJSONData;
  i: integer;

  function Str(const Path: string): string;
  var
    X: TJSONData;
  begin
    X := FRoot.FindPath(Path);
    if X = nil then Result := '-' else Result := X.AsString;
  end;

  function Cnt(const Path: string): integer;
  var
    X: TJSONData;
  begin
    X := FRoot.FindPath(Path);
    if X = nil then Result := 0 else Result := X.Count;
  end;

begin
  SL := TStringList.Create;
  try
    if FRoot = nil then Exit('');
    SL.Add('File: ' + FileName);
    SL.Add(Format('Format: %s  version %s', [Str('format'), Str('version')]));
    SL.Add('Generator: ' + Str('generator'));
    SL.Add('Created: ' + Str('created'));
    SL.Add('Seed: ' + Str('seed'));
    SL.Add('');
    SL.Add('Sections:');
    for i := 0 to FRoot.Count - 1 do
    begin
      D := FRoot.Items[i];
      if D.JSONType in [jtObject, jtArray] then
        SL.Add(Format('  %-16s %d entries', [FRoot.Names[i], D.Count]))
      else if D.JSONType = jtString then
        SL.Add(Format('  %-16s %d characters', [FRoot.Names[i], Length(D.AsString)]))
      else
        SL.Add(Format('  %-16s %s', [FRoot.Names[i], D.AsString]));
    end;
    SL.Add('');
    SL.Add(Format('Settings: %d applied to the engine (of %d engine values), %d keys not known by this engine',
      [SettingsApplied, SettingsTotal, UnknownKeys]));
    SL.Add(Format('Sprite kinds: %d   atlas sprites: %d   size levels: %d   blur levels: %d',
      [Cnt('sprites.kinds'), Cnt('sprites.atlas.entries'), Cnt('sprites.atlas.size_levels'),
       Cnt('sprites.atlas.blur_levels')]));
    SL.Add(Format('Atlas image: %s x %s px', [Str('sprites.atlas.width'), Str('sprites.atlas.height')]));
    SL.Add('');
    D := FRoot.Find('readme');
    if D is TJSONArray then
    begin
      SL.Add('Readme:');
      for i := 0 to D.Count - 1 do SL.Add('  ' + TJSONArray(D).Strings[i]);
    end;
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

end.
