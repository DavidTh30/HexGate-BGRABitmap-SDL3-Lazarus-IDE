program HexGate;

{ HexGate - fly down a hexagon tunnel and thread the gaps in the honeycomb
  walls. Built on the HexFlight renderer (BGRABitmap, all CPU cores,
  OpenGL output with vsync).
    uhexbackground.pas  renderer (+ gates, corridor, game camera)
    ugateaudio.pas      synthesized music and sound effects
    ugategame.pas       rules, menus, options, scoring, HUD
    ugatemain.pas       window and input
    ugfxexport.pas      F9 / --export-graphics: all graphics data as one JSON file

  Without a window: HexGate --export-graphics [file.json] }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  SysUtils, Forms, UHexBackground, UGateAudio, UGateGame, UGfxExport, UGateMain;

{$R *.res}

// --export-graphics [file]: no window; the autopilot flies through a few
// gates first so the reference frame shows them.
procedure ExportFromCommandLine;
var
  FileName: string;
  Hex: THexBackground;
  Game: TGateGame;
  i: integer;
begin
  FileName := ParamStr(2);
  if FileName = '' then FileName := ExtractFilePath(ParamStr(0)) + 'hexgate_graphics.json';
  Hex := THexBackground.Create;
  Game := TGateGame.Create(Hex, nil, ChangeFileExt(ParamStr(0), '.ini'));
  try
    for i := 1 to 6 * 60 do
    begin
      Game.Update(1 / 60);
      Hex.Animate(1 / 60);
    end;
    ExportGraphics(Hex, Game, FileName);
  finally
    Game.Free;
    Hex.Free;
  end;
end;

begin
  if (ParamCount >= 1) and (ParamStr(1) = '--export-graphics') then
  begin
    ExportFromCommandLine;
    Exit;
  end;
  RequireDerivedFormResource := True;
  Application.Title := 'HexGate';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TGateForm, GateForm);
  Application.Run;
end.
