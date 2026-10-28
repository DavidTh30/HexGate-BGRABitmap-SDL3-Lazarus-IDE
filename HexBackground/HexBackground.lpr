program HexBackground;

{ Hex Background - sci-fi hexagon UI background made with BGRABitmap.
  The renderer is in uhexbackground.pas, the window in umain.pas.

  Command line (no window):
    HexBackground --png <file.png> [width] [height] [seed] [settings.ini | -] [time s] }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  SysUtils, Math, Forms, BGRABitmap, UHexBackground, UMain;

{$R *.res}

procedure RenderToFile;
var
  Hex: THexBackground;
  Frame: TBGRABitmap;
  T: double;
begin
  Hex := THexBackground.Create;
  Frame := TBGRABitmap.Create(1, 1);
  try
    Hex.SetSeed(StrToIntDef(ParamStr(5), 2026));
    if (ParamStr(6) <> '') and (ParamStr(6) <> '-') then Hex.LoadFromIni(ParamStr(6));
    // fly the camera to the requested time
    T := StrToFloatDef(ParamStr(7), 6);
    while Hex.Time < T do
      Hex.Animate(Min(1 / 30, T - Hex.Time));
    Hex.Animate(0);
    Hex.Render(Frame, StrToIntDef(ParamStr(3), 1920), StrToIntDef(ParamStr(4), 1080),
      [0..PassCount - 1], False, False);
    Frame.SaveToFile(ParamStr(2));
  finally
    Frame.Free;
    Hex.Free;
  end;
end;

begin
  if (ParamCount >= 2) and (ParamStr(1) = '--png') then
  begin
    RenderToFile;
    Exit;
  end;
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
